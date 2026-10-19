//
//  SwimProbe.swift
//  RealityKitPresenterExample
//
//  A probe for the frame's lead, drawn by the engine: a thin cross locked to the room 1.5 m
//  ahead of where the head was when the probe came on, and a small dot locked to the head
//  the same distance ahead, placed every frame from the pose the frame's eyes are posed by.
//  Turn the head and watch. The cross must stay put in the room; the dot must stay put in
//  view. A dot that lags a head turn and catches up when the head stops says the lead is
//  short (the frame reaches the display later than it was posed for); one that runs ahead
//  says it is long. The cross shows what a wrong lead does to world-locked content on the
//  path that shows it: on the RealityKit path the grid reprojects it from the engine's
//  depth, so the error lands on its silhouettes (a halo, a tear, a stretch) and on the room
//  showing through beside it; on the Compositor path the compositor reprojects. The same
//  probe in a Compositor example compares the two paths at one pose. Needs only the engine
//  (`UntoldEngineXR.devicePose(forPresentationAt:)` and the frame's `currentFrameTime`).
//

import Foundation
import simd
import UntoldEngine
import UntoldEngineXR

final class SwimProbe: @unchecked Sendable {
    /// How far ahead of the head the cross is placed, and the dot kept, metres.
    static let distanceMetres: Float = 1.5

    private let lock = NSLock()
    private var wanted = false
    private var vertical: EntityID = .invalid
    private var horizontal: EntityID = .invalid
    private var dot: EntityID = .invalid
    /// Whether the cross stands where the head was when the probe came on and the three are
    /// shown; cleared when the probe goes off, so that the next time places it afresh.
    private var placed = false

    /// Whether the probe is wanted on; from the window at any time.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        wanted = enabled
        lock.unlock()
    }

    /// Makes the probe's entities, hidden: once, with the scene, before the loop.
    @MainActor
    func start() {
        // Two bars of 2 cm (ten texels at 1.5 m through the presenter's frustum, over a cell
        // of the grid) 0.5 m long, lit by their own emission so the light does not matter.
        let vertical = Self.makeBar(name: "SwimCrossVertical", scale: simd_float3(0.02, 0.5, 0.02))
        let horizontal = Self.makeBar(name: "SwimCrossHorizontal", scale: simd_float3(0.5, 0.02, 0.02))
        let dot = createEntity()
        setEntityName(entityId: dot, name: "SwimDot")
        setEntityMeshDirect(entityId: dot, meshes: BasicPrimitives.createSphere(extent: 0.02), assetName: "SwimDot")
        updateMaterialRoughness(entityId: dot, roughness: 1)
        updateMaterialEmmisive(entityId: dot, emmissive: simd_float3(0.2, 2.5, 3.0))
        Self.setVisible(dot, false)
        lock.lock()
        self.vertical = vertical
        self.horizontal = horizontal
        self.dot = dot
        placed = false
        lock.unlock()
    }

    @MainActor
    private static func makeBar(name: String, scale: simd_float3) -> EntityID {
        let bar = createEntity()
        setEntityName(entityId: bar, name: name)
        setEntityMeshDirect(entityId: bar, meshes: BasicPrimitives.createCube(extent: 1), assetName: name)
        scaleTo(entityId: bar, scale: scale)
        updateMaterialRoughness(entityId: bar, roughness: 1)
        updateMaterialEmmisive(entityId: bar, emmissive: simd_float3(3.0, 2.6, 0.2))
        setVisible(bar, false)
        return bar
    }

    /// Shown or hidden through the render component's flag, which the draws, the shadows and
    /// the batches honour; from any thread.
    private static func setVisible(_ entity: EntityID, _ visible: Bool) {
        scene.get(component: RenderComponent.self, for: entity)?.isVisible = visible
    }

    /// Forgets the entities (the engine's shutdown destroys them): with the scene's stop.
    func stop() {
        lock.lock()
        vertical = .invalid
        horizontal = .invalid
        dot = .invalid
        placed = false
        lock.unlock()
    }

    /// On the engine's thread, inside the game's update of a frame: the cross placed and the
    /// three shown when the probe comes on, the dot kept ahead of the head for this frame's
    /// pose, all three hidden when the probe goes off.
    func update(xr: UntoldEngineXR) {
        lock.lock()
        let (wanted, vertical, horizontal, dot, placed) = (wanted, vertical, horizontal, dot, placed)
        lock.unlock()
        guard dot != .invalid else { return }
        guard wanted else {
            if placed {
                for entity in [vertical, horizontal, dot] {
                    Self.setVisible(entity, false)
                }
                setPlaced(false)
            }
            return
        }
        // The pose the frame's eyes will be posed by: predicted for the frame's instant.
        guard let pose = xr.devicePose(forPresentationAt: currentFrameTime.presentationTime) ?? xr.currentDevicePose else { return }
        let position = simd_make_float3(pose.columns.3)
        let right = simd_normalize(simd_make_float3(pose.columns.0))
        let up = simd_normalize(simd_make_float3(pose.columns.1))
        let forward = -simd_normalize(simd_make_float3(pose.columns.2))
        let ahead = position + forward * Self.distanceMetres
        if !placed {
            // The cross: in the room where the head looked when the probe came on, facing it.
            for bar in [vertical, horizontal] {
                translateTo(entityId: bar, position: ahead)
                rotateTo(entityId: bar, rotation: pose)
            }
            for entity in [vertical, horizontal, dot] {
                Self.setVisible(entity, true)
            }
            setPlaced(true)
        }
        // The dot: ahead of the head every frame, a little up and to the right of the centre
        // of view, so that at the cross's pose it sits in the quadrant beside the bars.
        translateTo(entityId: dot, position: ahead + right * 0.04 + up * 0.04)
    }

    private func setPlaced(_ value: Bool) {
        lock.lock()
        placed = value
        lock.unlock()
    }
}
