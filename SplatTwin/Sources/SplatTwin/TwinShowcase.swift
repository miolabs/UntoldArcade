//
//  TwinShowcase.swift
//  SplatTwin
//
//  The objects on show: each is a mesh entity linked to a splat twin. Walk towards one and the
//  mesh cross-fades to its "capture"; walk away and it fades back. A real capture pair dropped
//  into GameData/Twins joins the line-up.
//

import Foundation
import simd
import SwiftUI
import UntoldEngine
import UntoldGaussianTwins

/// One object on show, and what its twin is doing this frame.
struct TwinReadout: Identifiable, Equatable {
    let id: EntityID
    let name: String
    var state: GaussianTwinState
    var distance: Float
    var fadeProgress: Float
    var splatCount: Int
}

final class TwinShowcase {
    private struct Object {
        let entity: EntityID
        let name: String
        /// From the payload header; the engine keeps its own count private.
        let splatCount: Int
    }

    private var objects: [Object] = []

    /// Swap settings shared by every object; the HUD edits them live.
    var swapDistance: Float = 4.0 {
        didSet { applyOptions() }
    }

    var crossFadeDuration: Float = 0.3 {
        didSet { applyOptions() }
    }

    private static let occluderShrinkMeters: Float = 0.02

    /// Builds the floor and the three primitives with their synthesised twins, plus the optional
    /// real pair from GameData.
    func build() {
        makeFloor()
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SplatTwin", isDirectory: true)

        addSynthesised(
            name: "Crate",
            shape: .cube(extent: 1.0),
            meshes: BasicPrimitives.createCube(extent: 1.0),
            baseColor: SIMD3(0.86, 0.48, 0.20),
            position: SIMD3(-2.6, 0.5, 0),
            cacheDirectory: cacheDirectory
        )
        addSynthesised(
            name: "Ball",
            shape: .sphere(extent: 1.2),
            meshes: BasicPrimitives.createSphere(extent: 1.2, segments: [48, 24]),
            baseColor: SIMD3(0.25, 0.55, 0.90),
            position: SIMD3(0, 0.6, 0),
            cacheDirectory: cacheDirectory
        )
        addSynthesised(
            name: "Drum",
            shape: .cylinder(height: 1.2, radius: 0.45),
            meshes: BasicPrimitives.createCylinder(height: 1.2, radius: 0.45, segments: [48, 1]),
            baseColor: SIMD3(0.45, 0.78, 0.35),
            position: SIMD3(2.6, 0.6, 0),
            cacheDirectory: cacheDirectory
        )
        addBundledCaptureIfPresent()
    }

    /// The twin states for the HUD, measured from the camera like the swap itself.
    func readouts() -> [TwinReadout] {
        var cameraPosition = SIMD3<Float>(repeating: 0)
        if let camera = CameraSystem.shared.activeCamera,
           let cameraComponent = scene.get(component: CameraComponent.self, for: camera)
        {
            cameraPosition = SceneRootTransform.shared.effectiveCameraPosition(cameraComponent.localPosition)
        }
        return objects.compactMap { object in
            guard let twin = scene.get(component: GaussianTwinComponent.self, for: object.entity) else { return nil }
            let world = scene.get(component: WorldTransformComponent.self, for: object.entity)?.space ?? matrix_identity_float4x4
            let position = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            return TwinReadout(
                id: object.entity,
                name: object.name,
                state: twin.state,
                distance: simd_distance(cameraPosition, position),
                fadeProgress: twin.fadeProgress,
                splatCount: object.splatCount
            )
        }
    }

    // MARK: - Building

    private func makeFloor() {
        let floor = createEntity()
        setEntityName(entityId: floor, name: "Floor")
        setEntityMeshDirect(entityId: floor, meshes: BasicPrimitives.createPlane(width: 14, depth: 14), assetName: "floor")
        translateTo(entityId: floor, position: SIMD3(0, 0, 0))
        updateMaterialColor(entityId: floor, color: Color(red: 0.82, green: 0.80, blue: 0.76))
        updateMaterialRoughness(entityId: floor, roughness: 0.9)
    }

    private func addSynthesised(
        name: String,
        shape: SplatSynthesizer.Shape,
        meshes: [Mesh],
        baseColor: SIMD3<Float>,
        position: SIMD3<Float>,
        cacheDirectory: URL
    ) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: name.lowercased())
        translateTo(entityId: entity, position: position)
        updateMaterialColor(entityId: entity, color: Color(red: Double(baseColor.x), green: Double(baseColor.y), blue: Double(baseColor.z)))
        updateMaterialRoughness(entityId: entity, roughness: 0.6)

        do {
            let payload = try SplatSynthesizer.twinFile(
                for: shape,
                baseColor: baseColor,
                spacing: 0.02,
                name: name.lowercased(),
                in: cacheDirectory
            )
            setEntityGaussianTwin(entityId: entity, payloadURL: payload, options: options())
            objects.append(Object(entity: entity, name: name, splatCount: Self.splatCount(of: payload)))
        } catch {
            Logger.logWarning(message: "[SplatTwin] Could not synthesise the twin of \(name): \(error)")
        }
    }

    /// A real capture pair: `GameData/Twins/capture.untold` (the mesh) and
    /// `GameData/Twins/capture.untoldgs` (its cooked splat), both in the same space.
    private func addBundledCaptureIfPresent() {
        guard let meshURL = LoadingSystem.shared.resourceURL(forResource: "capture", withExtension: "untold", subResource: nil),
              let splatURL = LoadingSystem.shared.resourceURL(forResource: "capture", withExtension: "untoldgs", subResource: nil)
        else { return }
        let entity = createEntity()
        setEntityName(entityId: entity, name: "Capture")
        setEntityMesh(entityId: entity, filename: meshURL.deletingPathExtension().path, withExtension: "untold")
        translateTo(entityId: entity, position: SIMD3(0, 0, -3.5))
        setEntityGaussianTwin(entityId: entity, payloadURL: splatURL, options: options())
        objects.append(Object(entity: entity, name: "Capture", splatCount: Self.splatCount(of: splatURL)))
    }

    private static func splatCount(of payload: URL) -> Int {
        Int((try? UntoldGSFormat.readHeaderV3(from: payload).splatCount) ?? 0)
    }

    private func options() -> GaussianTwinOptions {
        GaussianTwinOptions(
            swapDistanceMeters: swapDistance,
            hysteresisMeters: 0.5,
            crossFadeDuration: crossFadeDuration,
            occluderShrinkMeters: Self.occluderShrinkMeters
        )
    }

    private func applyOptions() {
        for object in objects {
            scene.get(component: GaussianTwinComponent.self, for: object.entity)?.options = options()
        }
    }
}
