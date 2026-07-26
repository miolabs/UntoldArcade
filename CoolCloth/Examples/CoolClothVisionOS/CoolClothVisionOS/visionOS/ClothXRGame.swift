//
//  ClothXRGame.swift  (visionOS)
//  CoolCloth
//
//  Mixed-reality cloth demo logic. The cloth lives in its local [-1,1]² sheet
//  space (z = 0 at rest) and is placed into the real world by a model matrix:
//      world = T(center) · Ry(yaw) · S(scale)
//  so a scale of 0.75 gives a 1.5 m sheet. Pinch the cloth to grab the particle
//  under your gaze, pinch the ball to throw it through the cloth, pinch anywhere
//  else to slide the whole cloth, two-hand pinch to resize/rotate it.
//

import simd
import Metal
import MetalKit
import UntoldEngine
import CoolCloth

/// Visual presets for the sheet. Silk is the plain deep-red fabric; the flag
/// styles map a texture once across the cloth and widen it to flag proportions.
enum ClothStyle {
    case silk
    case spainFlag
}

final class ClothXRGame {

    private let ballRadius: Float = 0.11
    private let clothTopHeight: Float = 1.85   // metres above the floor
    private let occlusion = CoolClothARKitOcclusionProvider()

    // Cloth placement (world). The engine's XR world frame is ARKit's world
    // origin, which visionOS puts ON THE FLOOR beneath the user when the
    // immersive space opens — so y = 0 is the best floor guess until the ARKit
    // scene mesh confirms it (scene reconstruction never runs in the simulator).
    private var floorY: Float = 0.0                     // detected floor height
    private var floorDetected = false
    private var clothCenterXZ = simd_float2(0.0, -1.2)  // ~1.2 m in front of the start pose
    private var clothScale: Float = 0.75                // half-side → 1.5 m sheet
    private var clothAspectX: Float = 1.0               // 1.5 for 3:2 flag proportions
    private var clothYaw: Float = 0.0
    private var placed = false
    private var flagTexture: MTLTexture?

    // Ball state (world space).
    private var ballWorld = simd_float3(0.35, 1.0, -0.9)
    private var ballVelocity = simd_float3(0, 0, 0)
    private let gravity: Float = -9.81

    // Interaction (driven by the gaze/pinch ray + engine-computed pinch deltas).
    private enum Drag { case none, ball, cloth, sheet }
    private var drag: Drag = .none
    private var grabOffset = simd_float3(0, 0, 0)   // grabbed particle → hand anchor
    private var grabTarget = simd_float3(0, 0, 0)
    private var wasPinching = false

    func start() {
        let style = XRHolder.shared.style
        setCoolClothLightDirection(simd_float3(0.6, 1.4, 0.8))
        setCoolClothGravity(simd_float3(0, gravity, 0))
        setCoolClothMaterial(.silk)
        setCoolClothWind(
            directionWorld: simd_float3(0.2, 0, 1),
            strength: style == .spainFlag ? 1.2 : 0.35,
            gustiness: style == .spainFlag ? 0.8 : 0.5
        )
        setCoolClothBallVisible(true)
        apply(style: style)
        resetCoolCloth(pinMode: style == .spainFlag ? .leftEdge : .topEdge)
        updateBall()

        // Required for spatial input: the engine's onSpatialEvent handler drops all
        // pinch events unless XR events are enabled AND the scene is marked ready.
        registerXREvents()
        setSceneReady(true)

        // Real-world occlusion: real surfaces occlude the cloth.
        occlusion.start()

        print(
            "CoolCloth: starting — cloth top at y \(floorY + clothTopHeight), " +
            "\(abs(clothCenterXZ.y)) m in front of the world origin. " +
            "Scene reconstruction supported: \(CoolClothARKitOcclusionProvider.isSupported)"
        )
    }

    private func clothCenter() -> simd_float3 {
        // Top edge (local y = +1) at clothTopHeight above the detected floor.
        simd_float3(
            clothCenterXZ.x,
            floorY + clothTopHeight - clothScale,
            clothCenterXZ.y
        )
    }

    private func model() -> simd_float4x4 {
        let t = simd_float4x4(translation: clothCenter())
        let r = simd_float4x4(rotationY: clothYaw)
        let s = simd_float4x4(
            scale: simd_float3(clothScale * clothAspectX, clothScale, clothScale)
        )
        return simd_mul(simd_mul(t, r), s)
    }

    // MARK: - Styles

    /// Applies a visual style. The pin mode is owned by the UI picker, so the
    /// caller resets the cloth separately after switching.
    func apply(style: ClothStyle) {
        switch style {
        case .silk:
            clothAspectX = 1.0
            setCoolClothFabricTexture(nil)
            setCoolClothColors(
                front: simd_float3(0.62, 0.07, 0.13),
                back: simd_float3(0.42, 0.05, 0.10),
                sheen: simd_float3(1.0, 0.75, 0.72),
                sheenIntensity: 0.35
            )
        case .spainFlag:
            if flagTexture == nil {
                flagTexture = Self.loadTexture(named: "spain_flag")
            }
            clothAspectX = 1.5   // real flag proportions (2:3)
            // The texture carries the color: white base shows it unmodified,
            // the back face is dimmed slightly like light through fabric.
            setCoolClothFabricTexture(flagTexture, tiling: 1.0)
            setCoolClothColors(
                front: simd_float3(1.0, 1.0, 1.0),
                back: simd_float3(0.78, 0.78, 0.78),
                sheen: simd_float3(1.0, 0.95, 0.85),
                sheenIntensity: 0.22
            )
        }
        updateModel()
    }

    private static func loadTexture(named name: String) -> MTLTexture? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            print("CoolCloth: missing texture \(name).png")
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage([.shaderRead]).rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        return try? loader.newTexture(URL: url, options: options)
    }

    private func updateModel() {
        setCoolClothModelMatrix(model())
        setCoolClothFloor(worldY: floorY)
    }

    private func updateBall() {
        setCoolClothSphere(centerWorld: ballWorld, radius: ballRadius, active: true)
    }

    /// Does the world-space ray hit the ball?
    private func rayHitsBall(origin: simd_float3, direction: simd_float3) -> Bool {
        let len = simd_length(direction)
        guard len > 1e-5 else { return false }
        let d = direction / len
        let oc = origin - ballWorld
        let b = simd_dot(oc, d)
        let c = simd_dot(oc, oc) - ballRadius * ballRadius
        let disc = b * b - c
        return disc > 0 && (-b - sqrt(disc)) > 0
    }

    // MARK: - Per-frame

    func update(deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        advanceCoolCloth(deltaTime: dt)

        let input = InputSystem.shared.xrSpatialInputState
        let pinching = input.spatialPinchActive
        let pinchBegan = pinching && !wasPinching

        // On pinch start, decide what's being grabbed: the ball (gaze ray hits it),
        // a cloth particle (ray passes near the sheet), or otherwise the whole
        // sheet. Everything is then DRAGGED by the hand's movement (relative).
        if pinchBegan {
            if rayHitsBall(origin: input.rayOriginWorld, direction: input.rayDirectionWorld) {
                drag = .ball
                ballVelocity = .zero
            } else if let pick = pickCoolClothParticle(
                rayOriginWorld: input.rayOriginWorld,
                rayDirectionWorld: input.rayDirectionWorld,
                maxDistanceToRay: 0.05 * max(clothScale, 0.2)
            ) {
                drag = .cloth
                grabTarget = pick.worldPosition
                grabCoolClothParticle(
                    column: pick.column,
                    row: pick.row,
                    targetWorld: grabTarget
                )
            } else {
                drag = .sheet
            }
            placed = true   // any interaction locks placement (stops auto floor-snapping)
        }

        if pinching {
            let world = input.spatialPinchDragDelta   // world-space movement of the pinch
            switch drag {
            case .ball:
                ballWorld += world
                ballVelocity = world / max(dt, 1e-4)   // throwing velocity on release
            case .cloth:
                grabTarget += world
                setCoolClothGrabTarget(worldPosition: grabTarget)
            case .sheet:
                clothCenterXZ += simd_float2(world.x, world.z)
                if let floor = pickRealSurfacePosition(
                    rayOrigin: simd_float3(clothCenterXZ.x, floorY + 2.0, clothCenterXZ.y),
                    rayDirection: simd_float3(0, -1, 0), filter: .floorOnly
                ) {
                    floorY = floor.worldPosition.y
                }
            case .none:
                break
            }
        }
        if !pinching {
            if drag == .cloth { releaseCoolClothGrab() }
            drag = .none
        }
        wasPinching = pinching

        // Until first placed/grabbed, snap to the detected floor (down-ray) so the
        // cloth doesn't hang at the default height while ARKit warms up.
        if !placed, let floor = pickRealSurfacePosition(
            rayOrigin: simd_float3(clothCenterXZ.x, 3.0, clothCenterXZ.y),
            rayDirection: simd_float3(0, -1, 0), filter: .floorOnly
        ) {
            floorY = floor.worldPosition.y
            if !floorDetected {
                floorDetected = true
                print("CoolCloth: real floor detected at y \(floorY)")
            }
        }

        // Two-hand pinch: scale + rotate (engine-detected). Allowed once placed.
        if placed {
            if input.spatialZoomActive {
                clothScale = min(max(clothScale * (1.0 + input.spatialZoomDelta), 0.3), 1.5)
            }
            if input.spatialRotateActive {
                clothYaw += input.spatialRotateDeltaRadians
            }
        }

        // When not held, the ball falls under gravity and bounces off the floor.
        if drag != .ball {
            ballVelocity.y += gravity * dt
            ballWorld += ballVelocity * dt
            let restY = floorY + ballRadius
            if ballWorld.y < restY {
                ballWorld.y = restY
                ballVelocity.y = abs(ballVelocity.y) * 0.55
                ballVelocity.x *= 0.92
                ballVelocity.z *= 0.92
                if abs(ballVelocity.y) < 0.25 { ballVelocity.y = 0 }
            }
        }

        updateBall()
        updateModel()
    }

    func handleInput() {}
}

// MARK: - Matrix helpers

private extension simd_float4x4 {
    init(translation t: simd_float3) {
        self.init(
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(t.x, t.y, t.z, 1)
        )
    }
    init(scale s: simd_float3) {
        self.init(
            simd_float4(s.x, 0, 0, 0),
            simd_float4(0, s.y, 0, 0),
            simd_float4(0, 0, s.z, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
    init(rotationY a: Float) {
        let c = cos(a), s = sin(a)
        self.init(
            simd_float4(c, 0, -s, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(s, 0, c, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
}
