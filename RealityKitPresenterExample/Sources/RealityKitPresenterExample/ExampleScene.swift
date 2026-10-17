//
//  ExampleScene.swift
//  RealityKitPresenterExample
//
//  A procedural scene with nothing to load: a slab 1.6 m ahead of where the session began,
//  three cubes turning on it, a sphere above, a sun. A pinch on a cube lights it up, so that
//  pinches reaching the engine through the presenter's input target can be seen.
//

import Foundation
import simd
import UntoldEngine
import UntoldEngineXR

final class ExampleScene: @unchecked Sendable {
    private let lock = NSLock()
    private var cubes: [EntityID] = []
    private var lit: Set<EntityID> = []
    private var angle: Float = 0
    private var taps = 0

    var tapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return taps
    }

    /// Builds the scene and installs the callbacks: once, from the presenter view's `onReady`.
    @MainActor
    func start(_ xr: UntoldEngineXR) {
        gameMode = true
        InputSystem.shared.registerXREvents()
        InputSystem.shared.setXRSpatialPickingBackendPreference(.octreeGPUPreferred)

        // The ARKit origin is on the floor where the session began; the slab stands at table
        // height 1.6 m ahead (-Z), the cubes on it, the sphere above.
        let slab = createEntity()
        setEntityName(entityId: slab, name: "Slab")
        setEntityMeshDirect(entityId: slab, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Slab")
        scaleTo(entityId: slab, scale: simd_float3(1.2, 0.05, 0.6))
        translateTo(entityId: slab, position: simd_float3(0, 0.9, -1.6))
        updateMaterialRoughness(entityId: slab, roughness: 0.8)

        var cubes: [EntityID] = []
        for (index, x) in [Float(-0.35), 0, 0.35].enumerated() {
            let cube = createEntity()
            setEntityName(entityId: cube, name: "Cube\(index)")
            setEntityMeshDirect(entityId: cube, meshes: BasicPrimitives.createCube(extent: 0.2), assetName: "Cube\(index)")
            translateTo(entityId: cube, position: simd_float3(x, 1.025, -1.6))
            updateMaterialRoughness(entityId: cube, roughness: 0.4)
            updateMaterialMetallic(entityId: cube, metallic: Float(index) * 0.4)
            cubes.append(cube)
        }
        lock.lock()
        self.cubes = cubes
        lock.unlock()

        let sphere = createEntity()
        setEntityName(entityId: sphere, name: "Sphere")
        setEntityMeshDirect(entityId: sphere, meshes: BasicPrimitives.createSphere(extent: 0.12), assetName: "Sphere")
        translateTo(entityId: sphere, position: simd_float3(0, 1.45, -1.6))
        updateMaterialRoughness(entityId: sphere, roughness: 0.2)

        let sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        setLight(entityId: sun, .strength(3))

        xr.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in self?.update(deltaTime: deltaTime) },
            handleInput: { [weak self] in self?.handleInput() }
        )
        setSceneReady(true)
    }

    func stop() {
        lock.lock()
        cubes = []
        lit = []
        taps = 0
        lock.unlock()
    }

    private func update(deltaTime: Float) {
        angle += deltaTime * 0.5
        lock.lock()
        let cubes = cubes
        lock.unlock()
        for (index, cube) in cubes.enumerated() {
            rotateTo(entityId: cube, angle: angle * (180 / .pi) * (index % 2 == 0 ? 1 : -1), axis: simd_float3(0, 1, 0))
        }
    }

    private func handleInput() {
        let state = InputSystem.shared.xrSpatialInputState
        guard state.spatialTapActive, let picked = state.pickedEntityId else { return }
        lock.lock()
        guard cubes.contains(picked) else {
            lock.unlock()
            return
        }
        taps += 1
        let on = !lit.contains(picked)
        if on { lit.insert(picked) } else { lit.remove(picked) }
        lock.unlock()
        updateMaterialEmmisive(entityId: picked, emmissive: on ? simd_float3(2.0, 0.9, 0.2) : .zero)
    }
}
