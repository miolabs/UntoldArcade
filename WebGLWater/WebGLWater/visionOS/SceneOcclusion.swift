//
//  SceneOcclusion.swift  (visionOS)
//  WebGLWater
//
//  Runs ARKit scene reconstruction and exposes the real-world mesh as engine
//  occlusion meshes, so real surfaces (floor, furniture, a meshed person) occlude
//  the virtual water.
//

import ARKit
import Metal
import simd
import UntoldEngine

final class SceneOcclusion: @unchecked Sendable {
    static let shared = SceneOcclusion()

    private let session = ARKitSession()
    private let provider = SceneReconstructionProvider()
    private let lock = NSLock()
    private var meshesById: [UUID: WaterOcclusionMesh] = [:]

    func start() {
        guard SceneReconstructionProvider.isSupported else {
            NSLog("WWXR SceneReconstruction not supported")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.run([self.provider])
            } catch {
                NSLog("WWXR SceneReconstruction run failed: \(error)")
                return
            }
            for await update in self.provider.anchorUpdates {
                self.handle(update)
            }
        }
    }

    func currentMeshes() -> [WaterOcclusionMesh] {
        lock.withLock { Array(meshesById.values) }
    }

    private func handle(_ update: AnchorUpdate<MeshAnchor>) {
        let anchor = update.anchor
        switch update.event {
        case .removed:
            lock.withLock { _ = meshesById.removeValue(forKey: anchor.id) }
        case .added, .updated:
            let geometry = anchor.geometry
            let verts = geometry.vertices
            let faces = geometry.faces
            let indexType: MTLIndexType = faces.bytesPerIndex == 2 ? .uint16 : .uint32
            let mesh = WaterOcclusionMesh(
                vertexBuffer: verts.buffer,
                vertexOffset: verts.offset,
                vertexStride: verts.stride,
                indexBuffer: faces.buffer,
                indexOffset: 0,
                indexCount: faces.count * 3,   // triangles
                indexType: indexType,
                transform: anchor.originFromAnchorTransform
            )
            lock.withLock { meshesById[anchor.id] = mesh }
        }
    }
}
