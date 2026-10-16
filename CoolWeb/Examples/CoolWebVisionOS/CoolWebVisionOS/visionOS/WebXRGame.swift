//
//  WebXRGame.swift  (visionOS)
//  CoolWeb
//
//  Per-frame web-shooter logic, driven from the XR render thread:
//    hand poses → gesture classifier → fire/release; scene-mesh raycast (with
//    plane-store fallback) picks the attach point; the CoolWeb shooter owns
//    the rope simulation and publishes the drawable scene each frame.
//
//  Coordinates: the engine's XR world frame is ARKit's world origin (on the
//  floor beneath the user at immersive-space open). CoolWeb's own ARKitSession
//  reports hand and mesh anchors in the same frame.
//

import CoolWeb
import Foundation
import simd
import UntoldEngine

final class WebXRGame: @unchecked Sendable {
    private let session = CoolWebSpatialSession()
    private let shooter: CoolWebShooter
    private let classifiers: [CoolWebHandSide: CoolWebGestureClassifier] = [
        .left: CoolWebGestureClassifier(),
        .right: CoolWebGestureClassifier(),
    ]
    private var started = false

    init() {
        // Meshes first (attach anywhere), detected planes as the fallback for
        // surfaces the reconstruction hasn't covered yet.
        shooter = CoolWebShooter(surfaceQuery: { origin, direction, maxDistance in
            if let meshHit = raycastCoolWebSurface(
                origin: origin,
                direction: direction,
                maxDistance: maxDistance
            ) {
                return meshHit
            }
            if let planeHit = pickRealSurfacePosition(
                rayOrigin: origin,
                rayDirection: direction,
                maxDistance: maxDistance
            ) {
                return CoolWebSurfaceHit(
                    position: planeHit.worldPosition,
                    normal: planeHit.surfaceNormal,
                    distance: planeHit.distance
                )
            }
            return nil
        })
        shooter.onAttach = { hand, hit in
            print(String(
                format: "CoolWeb: %@ web attached at (%.2f, %.2f, %.2f)",
                hand == .left ? "left" : "right",
                hit.position.x, hit.position.y, hit.position.z
            ))
        }
    }

    func start() {
        guard !started else { return }
        started = true
        loadGloveAssets()
        session.start()
        WebXRHolder.shared.resetDiagnostics()
    }

    /// Loads the rigged movie-suit gloves the render extension draws. Missing
    /// assets only disable the glove visuals — webs still work bare-handed.
    private func loadGloveAssets() {
        // Folder reference lands at the bundle root. NOTE: it must NOT be
        // named "Resources" — a root folder of that name breaks codesign's
        // sealed-resource rules in shallow (iOS-style) bundles.
        let models = "Models"
        guard
            let right = Bundle.main.url(
                forResource: "hand_right", withExtension: "usdz",
                subdirectory: models
            ),
            let left = Bundle.main.url(
                forResource: "hand_left", withExtension: "usdz",
                subdirectory: models
            ),
            let textures = Bundle.main.url(
                forResource: "GloveTextures", withExtension: nil,
                subdirectory: models
            )
        else {
            print("CoolWeb: glove assets missing from the app bundle — gloves disabled")
            return
        }
        do {
            try loadCoolWebGloveAssets(
                rightURL: right,
                leftURL: left,
                texturesDirectory: textures
            )
            print("CoolWeb: rigged glove assets loaded")
        } catch {
            print("CoolWeb: glove asset load failed — \(error)")
        }
    }

    func shutdown() {
        started = false
        session.stop()
        shooter.reset()
        clearCoolWebScene()
        clearCoolWebGloves()
    }

    /// True when the user's head is oriented at `point` (within ~23°) — the
    /// gaze gate for the suit-up. With no head data yet, don't block.
    private func isLookingAt(_ point: SIMD3<Float>, head: simd_float4x4?) -> Bool {
        guard let head else { return true }
        let headPosition = SIMD3<Float>(
            head.columns.3.x, head.columns.3.y, head.columns.3.z
        )
        // ARKit device anchor looks along -Z.
        let forward = -SIMD3<Float>(
            head.columns.2.x, head.columns.2.y, head.columns.2.z
        )
        let toPoint = point - headPosition
        let distance = simd_length(toPoint)
        guard distance > 0.05 else { return true }
        return simd_dot(toPoint / distance, simd_normalize(forward)) > 0.92
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let holder = WebXRHolder.shared
        let head = session.headTransform()

        for side in CoolWebHandSide.allCases {
            // Predicted pose ~50 ms ahead: keeps the glove glued to a moving
            // hand instead of trailing it by the anchor-stream latency.
            guard let pose = session.predictedHandPose(side, at: now + 0.05) else {
                holder.setHandDiagnostics(side, tracked: false, extensions: nil)
                updateCoolWebGlove(side: side, pose: nil, now: now)
                shooter.clearHandColliders(side)
                continue
            }
            // Rebuild the Spider-Man glove over this hand. The suit-up only
            // starts once the user actually looks at the hand (gaze gate on
            // the palm center).
            let palmCenter = (pose.wrist
                + (pose.index.points[1] + pose.little.points[1]) * 0.5) * 0.5
            var gloveConfig = CoolWebGloveConfig()
            gloveConfig.fit = holder.gloveFit
            updateCoolWebGlove(
                side: side,
                pose: pose,
                config: gloveConfig,
                lookedAt: isLookingAt(palmCenter, head: head),
                now: now
            )
            holder.setHandDiagnostics(
                side,
                tracked: pose.isTracked,
                extensions: classifiers[side]?.lastExtensions
            )
            guard pose.isTracked else {
                _ = classifiers[side]?.update(pose: pose) // resets the classifier
                continue
            }

            // The strand roots at (and fires from) the gray web-shooter
            // barrel on the inner wrist, matching the drawn glove geometry.
            // A few spheres approximate the gloved hand so the held strand
            // drapes over a closed fist instead of clipping the fingers.
            let muzzle = CoolWebGloveBuilder.webShooterMuzzle(
                pose: pose, side: side, config: gloveConfig
            ) ?? pose.wrist
            // Colliders hug the glove surface: a few big spheres read as an
            // invisible cushion the strand hovers over, so the hand is a
            // cloud of small ones — wrist, a palm slab from the wrist toward
            // each knuckle, then every finger joint down to the tips.
            var colliders = [
                CoolWebCollisionSphere(center: pose.wrist, radius: 0.028),
            ]
            for chain in [pose.index, pose.middle, pose.ring, pose.little]
            where chain.points.count >= 5 {
                let knuckle = chain.points[1]
                for t in [Float(0.45), 0.75] {
                    colliders.append(CoolWebCollisionSphere(
                        center: pose.wrist + (knuckle - pose.wrist) * t,
                        radius: 0.024
                    ))
                }
                colliders += [
                    CoolWebCollisionSphere(center: knuckle, radius: 0.02),
                    CoolWebCollisionSphere(center: chain.points[2], radius: 0.016),
                    CoolWebCollisionSphere(center: chain.points[3], radius: 0.014),
                    CoolWebCollisionSphere(center: chain.points[4], radius: 0.013),
                ]
            }
            // The thumb splays away from the palm: cover it and the thenar
            // mound so a strand leaving the emitter can't slice through it.
            if pose.thumb.points.count >= 5 {
                let thumb = pose.thumb.points
                colliders += [
                    CoolWebCollisionSphere(
                        center: (pose.wrist + thumb[1]) * 0.5, radius: 0.026
                    ),
                    CoolWebCollisionSphere(center: thumb[1], radius: 0.02),
                    CoolWebCollisionSphere(center: thumb[2], radius: 0.017),
                    CoolWebCollisionSphere(center: thumb[3], radius: 0.015),
                    CoolWebCollisionSphere(center: thumb[4], radius: 0.013),
                ]
            }
            shooter.updateHand(side, position: muzzle, collision: colliders)

            switch classifiers[side]?.update(pose: pose) {
            case let .webShooterFired(_, direction):
                shooter.fire(hand: side, origin: muzzle, direction: direction, now: now)
                print("CoolWeb: \(side == .left ? "left" : "right") hand fired")
            case .palmOpened:
                shooter.release(hand: side, now: now)
            case nil:
                break
            }
        }

        // Control-window actions, handed over through the holder.
        if holder.takeTestFireRequest() {
            // Pipeline check without the gesture: fire from chest height,
            // forward in the space's initial orientation.
            shooter.fire(
                hand: .right,
                origin: SIMD3<Float>(0, 1.3, 0),
                direction: SIMD3<Float>(0, 0.05, -1),
                now: now
            )
        }
        if holder.takeReleaseAllRequest() {
            shooter.releaseAll(now: now)
        }

        shooter.step(now: now, dt: deltaTime)

        holder.setSceneDiagnostics(
            strandCount: shooter.liveNetCount,
            surfaceTriangles: CoolWebSurfaceStore.shared.triangleCount
        )
    }

    func handleInput() {}
}
