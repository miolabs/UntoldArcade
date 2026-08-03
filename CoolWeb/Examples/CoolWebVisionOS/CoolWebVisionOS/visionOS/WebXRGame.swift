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
        session.start()
        WebXRHolder.shared.resetDiagnostics()
    }

    func shutdown() {
        started = false
        session.stop()
        shooter.reset()
        clearCoolWebScene()
        clearCoolWebGloves()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let holder = WebXRHolder.shared

        for side in CoolWebHandSide.allCases {
            guard let pose = session.handPose(side) else {
                holder.setHandDiagnostics(side, tracked: false, extensions: nil)
                updateCoolWebGlove(side: side, pose: nil)
                continue
            }
            // Rebuild the Spider-Man glove over this hand (no-op while the
            // glove option is off; hides the glove while tracking is lost).
            updateCoolWebGlove(side: side, pose: pose)
            holder.setHandDiagnostics(
                side,
                tracked: pose.isTracked,
                extensions: classifiers[side]?.lastExtensions
            )
            guard pose.isTracked else {
                _ = classifiers[side]?.update(pose: pose) // resets the classifier
                continue
            }

            shooter.updateHand(side, position: pose.wrist)

            switch classifiers[side]?.update(pose: pose) {
            case let .webShooterFired(origin, direction):
                shooter.fire(hand: side, origin: origin, direction: direction, now: now)
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
