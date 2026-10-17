//
//  EyeGrid.swift
//  RealityKitPresenter spike
//
//  One eye's LowLevelMesh grid: columns x rows vertices (position + uv + a half2 mask),
//  a static index buffer, one part with a large bound. The vertex buffer is rewritten
//  every ticket by the fillGrid kernel through replace(bufferIndex:using:).
//

import Metal
import RealityKit

@MainActor
final class EyeGrid {
    static let columns = 256
    static let rows = 240
    /// packed_float3 position (12) + packed_float2 uv (8) + half2 mask (4): see SpikeShaders.metal.
    static let vertexStride = 24

    let mesh: LowLevelMesh
    let vertexCount: Int
    let indexCount: Int

    init() throws {
        let columns = Self.columns
        let rows = Self.rows
        vertexCount = columns * rows
        indexCount = (columns - 1) * (rows - 1) * 6

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCount
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 12),
            .init(semantic: .uv1, format: .half2, layoutIndex: 0, offset: 20),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: Self.vertexStride)]
        mesh = try LowLevelMesh(descriptor: descriptor)

        // Static indices: two counter-clockwise triangles per cell as seen from the eye.
        mesh.replaceUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var k = 0
            for row in 0 ..< (rows - 1) {
                for column in 0 ..< (columns - 1) {
                    let a = UInt32(row * columns + column)
                    let b = a + 1
                    let c = a + UInt32(columns)
                    let d = c + 1
                    indices[k] = a; indices[k + 1] = c; indices[k + 2] = b
                    indices[k + 3] = b; indices[k + 4] = c; indices[k + 5] = d
                    k += 6
                }
            }
        }

        // Something to show before the first ticket: a 4 x 3 m plane 2 m ahead of the origin
        // at head height (the kernel overwrites it on the first frame).
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            let stride = Self.vertexStride
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let u = Float(column) / Float(columns - 1)
                    let v = Float(row) / Float(rows - 1)
                    let base = raw.baseAddress!.advanced(by: (row * columns + column) * stride)
                    let position = base.assumingMemoryBound(to: Float.self)
                    position[0] = (u - 0.5) * 4
                    position[1] = 1.5 + (0.5 - v) * 3
                    position[2] = -2
                    position[3] = u
                    position[4] = v
                    let mask = base.advanced(by: 20).assumingMemoryBound(to: Float16.self)
                    mask[0] = 0
                    mask[1] = 0
                }
            }
        }

        let bound: Float = 200
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: indexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(min: [-bound, -bound, -bound], max: [bound, bound, bound])
            ),
        ])
    }
}
