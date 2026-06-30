//
//  WaterGame.swift
//  WebGLWater
//
//  Cross-platform game logic for the water demo (a port of Evan Wallace's WebGL
//  Water). Sets up the engine's water feature, drives the ball physics, and
//  handles interaction: draw-on-water ripples, dragging the sphere, orbiting the
//  camera, and keyboard toggles. Rendering of the pool, water surface, caustics
//  and sphere is done entirely by the engine's WaterRenderer.
//

import simd
import Metal
import UntoldEngine

final class WaterGame {

    private let radius: Float = 0.3

    // Ball state
    private var sphereCenter = simd_float3(-0.4, 0.4, 0.2) // starts above water -> splash
    private var velocity = simd_float3(0.0, 0.0, 0.0)
    private var gravityOn = true
    private let gravity: Float = -4.0
    private var paused = true   // start frozen; press Space to begin

    // Camera orbit state — yaw/pitch in degrees, matching the original demo's
    // parameterization and initial viewpoint so the drag direction matches too.
    private var camTarget = simd_float3(0.0, -0.5, 0.0)
    private var camDistance: Float = 4.0
    private var angleX: Float = -25.0    // pitch
    private var angleY: Float = -200.5   // yaw

    // Interaction state
    private enum DragMode { case none, sphere, ripple, orbit }
    private var dragMode: DragMode = .none
    private var lastPan = simd_float2(0, 0)
    private var viewport = simd_float2(1, 1)
    // Sphere drag: a camera-facing plane through the grab point, moved by the relative
    // cursor delta (matches the original).
    private var dragPrevHit = simd_float3(0, 0, 0)
    private var dragPlaneNormal = simd_float3(0, 0, 1)

    private var time: Float = 0.0

    // MARK: - Setup

    func start() {
        applyCamera()

        enableWater(true)
        setWaterSphere(center: sphereCenter, radius: radius)
        setWaterLightDirection(simd_float3(2.0, 2.0, -1.0))
        loadArt()

        // Start frozen: still water, ball floating above the surface. The first Space
        // press unpauses (the ball falls in and the simulation runs).
        WaterRenderer.shared.isPaused = true
    }

    private func loadArt() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        if let tiles = DemoAssets.loadTexture(device: device, name: "tiles", ext: "jpg", srgb: true, mipmapped: true) {
            setWaterTilesTexture(tiles)
        }
        if let sky = DemoAssets.loadCubemap(device: device) {
            setWaterSkyTexture(sky)
        }
    }

    private func cameraEye() -> simd_float3 {
        let tx = angleX * .pi / 180.0, ty = angleY * .pi / 180.0
        let ct = cos(tx), st = sin(tx)
        return camTarget + camDistance * simd_float3(ct * sin(ty), -st, ct * cos(ty))
    }

    private func applyCamera() {
        cameraLookAt(entityId: findGameCamera(), eye: cameraEye(), target: camTarget, up: simd_float3(0, 1, 0))
    }

    // MARK: - Per-frame

    func update(deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt

        // Ball physics (gravity + floor bounce), unless it's being dragged.
        if dragMode != .sphere, gravityOn, !paused {
            velocity.y += gravity * dt
            sphereCenter += velocity * dt
            let floorY = radius - 1.0
            if sphereCenter.y < floorY {
                sphereCenter.y = floorY
                velocity.y = abs(velocity.y) * 0.7
                if abs(velocity.y) < 0.2 { velocity.y = 0.0 }
            }
            let limit = 1.0 - radius
            sphereCenter.x = min(max(sphereCenter.x, -limit), limit)
            sphereCenter.z = min(max(sphereCenter.z, -limit), limit)
        }
        setWaterSphereCenter(sphereCenter)
    }

    func handleInput() {}

    // MARK: - Interaction (called from the platform input layer)

    func setViewport(_ vp: simd_float2) { viewport = vp }

    func dragBegan(at p: simd_float2) {
        lastPan = p
        if let hit = WaterRenderer.shared.sphereHitPoint(screenPoint: p, viewport: viewport) {
            dragMode = .sphere
            velocity = .zero
            dragPrevHit = hit
            // Plane facing the camera (the center-screen ray, negated), held constant
            // for the duration of the drag.
            let center = simd_float2(viewport.x * 0.5, viewport.y * 0.5)
            if let (_, dir) = WaterRenderer.shared.screenRay(screenPoint: center, viewport: viewport) {
                dragPlaneNormal = -dir
            }
        } else if let xz = WaterRenderer.shared.pickWaterPlane(screenPoint: p, viewport: viewport) {
            dragMode = .ripple
            addWaterDrop(center: xz, radius: 0.03, strength: 0.04)
        } else {
            dragMode = .orbit
        }
    }

    func dragMoved(to p: simd_float2) {
        switch dragMode {
        case .sphere:
            if let (eye, d) = WaterRenderer.shared.screenRay(screenPoint: p, viewport: viewport) {
                let denom = simd_dot(dragPlaneNormal, d)
                if abs(denom) > 1e-5 {
                    let t = -simd_dot(dragPlaneNormal, eye - dragPrevHit) / denom
                    let nextHit = eye + d * t
                    sphereCenter += nextHit - dragPrevHit
                    let limit = 1.0 - radius
                    sphereCenter.x = min(max(sphereCenter.x, -limit), limit)
                    sphereCenter.z = min(max(sphereCenter.z, -limit), limit)
                    sphereCenter.y = min(max(sphereCenter.y, radius - 1.0), 10.0)
                    dragPrevHit = nextHit
                    velocity = .zero
                }
            }
        case .ripple:
            if let xz = WaterRenderer.shared.pickWaterPlane(screenPoint: p, viewport: viewport) {
                addWaterDrop(center: xz, radius: 0.03, strength: 0.03)
            }
        case .orbit:
            // Screen points are bottom-left (y-up) here; the original's pitch uses
            // top-left deltas (angleX -= Δy_topleft), i.e. angleX += Δy_bottomleft.
            let d = p - lastPan
            angleY -= d.x * 0.3
            angleX += d.y * 0.3
            angleX = min(max(angleX, -89.0), 89.0)
            applyCamera()
        case .none:
            break
        }
        lastPan = p
    }

    func dragEnded() { dragMode = .none }

    func zoom(by delta: Float) {
        camDistance = min(max(camDistance + delta, 2.2), 9.0)
        applyCamera()
    }

    // MARK: - Keyboard / discrete actions

    func togglePause() {
        paused.toggle()
        WaterRenderer.shared.isPaused = paused
    }

    func toggleGravity() {
        gravityOn.toggle()
        if gravityOn { velocity = .zero }
    }

    func aimLightAtCamera() {
        setWaterLightDirection(simd_normalize(cameraEye() - camTarget))
    }
}
