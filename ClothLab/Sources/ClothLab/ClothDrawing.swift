//
//  ClothDrawing.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import MetalKit
import ModelIO
import simd
import SwiftUI
import UntoldEngine

/// The simulated mesh drawn by the engine, lit like any other mesh: one
/// runtime mesh whose vertex buffers are rewritten every frame from the
/// particles. The engine culls back faces, so the cloth is drawn twice:
/// every particle is a front vertex and a back vertex (opposite normal,
/// opposite winding).
final class ClothDrawing {
    let entity: EntityID
    private let particleCount: Int
    private let triangles: [SIMD3<Int32>]
    private let edges: [SIMD2<Int32>]
    private var positionBuffer: MTKMeshBuffer?
    private var normalBuffer: MTKMeshBuffer?
    private var normals: [SIMD3<Float>]

    init?(mesh: ClothMesh, topology: ClothTopology, color: Color) {
        particleCount = mesh.positions.count
        triangles = mesh.triangles
        edges = topology.edges
        normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: mesh.positions.count)

        // Interleaved position / normal / uv, front copy then back copy.
        let stride = 8 * MemoryLayout<Float>.stride
        var vertices = [Float](repeating: 0, count: particleCount * 2 * 8)
        Self.computeNormals(positions: mesh.positions, triangles: triangles, into: &normals)
        for side in 0 ..< 2 {
            let sign: Float = side == 0 ? 1 : -1
            for i in 0 ..< particleCount {
                let base = (side * particleCount + i) * 8
                let p = mesh.positions[i], n = normals[i] * sign
                let uv = i < mesh.uvs.count ? mesh.uvs[i] : .zero
                vertices[base + 0] = p.x; vertices[base + 1] = p.y; vertices[base + 2] = p.z
                vertices[base + 3] = n.x; vertices[base + 4] = n.y; vertices[base + 5] = n.z
                vertices[base + 6] = uv.x; vertices[base + 7] = uv.y
            }
        }
        var indices = [UInt32]()
        indices.reserveCapacity(triangles.count * 6)
        let offset = UInt32(particleCount)
        for t in triangles {
            indices.append(contentsOf: [UInt32(t.x), UInt32(t.y), UInt32(t.z)])
        }
        for t in triangles {
            indices.append(contentsOf: [UInt32(t.x) + offset, UInt32(t.z) + offset, UInt32(t.y) + offset])
        }

        let allocator = MTKMeshBufferAllocator(device: renderInfo.device)
        let vertexBuffer = allocator.newBuffer(
            with: vertices.withUnsafeBufferPointer { Data(buffer: $0) }, type: .vertex
        )
        let indexBuffer = allocator.newBuffer(
            with: indices.withUnsafeBufferPointer { Data(buffer: $0) }, type: .index
        )
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: stride)
        let material = MDLMaterial(name: "cloth", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer, indexCount: indices.count, indexType: .uInt32,
            geometryType: .triangles, material: material
        )
        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer, vertexCount: particleCount * 2, descriptor: descriptor, submeshes: [submesh]
        )
        mdlMesh.name = "ClothLab cloth"

        let meshes = BasicPrimitives.createMesh(from: mdlMesh)
        guard let engineMesh = meshes.first else { return nil }
        // The engine's own layout: one buffer per attribute, positions and
        // normals as four floats each, in slots 0 and 1.
        let buffers = engineMesh.metalKitMesh.vertexBuffers
        guard buffers.count >= 2,
              buffers[0].buffer.storageMode != .private, buffers[1].buffer.storageMode != .private,
              engineMesh.metalKitMesh.vertexCount == particleCount * 2
        else {
            print("ClothLab: the engine mesh is not writable (\(buffers.count) buffers, \(engineMesh.metalKitMesh.vertexCount) vertices)")
            return nil
        }
        positionBuffer = buffers[0]
        normalBuffer = buffers[1]

        entity = createEntity()
        setEntityName(entityId: entity, name: "Cloth")
        setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: "cloth")
        updateMaterialColor(entityId: entity, color: color)
        updateMaterialRoughness(entityId: entity, roughness: 0.85)
        updateMaterialMetallic(entityId: entity, metallic: 0)
    }

    func destroy() {
        clearDebugLines(named: "cloth.wire")
        clearDebugLines(named: "cloth.pins")
        destroyEntity(entityId: entity)
    }

    /// Writes the particles into the drawn mesh.
    func write(positions: [SIMD3<Float>]) {
        guard let positionBuffer, let normalBuffer, positions.count == particleCount else { return }
        Self.computeNormals(positions: positions, triangles: triangles, into: &normals)
        let count = particleCount
        let p = positionBuffer.buffer.contents().advanced(by: positionBuffer.offset)
            .bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
        let n = normalBuffer.buffer.contents().advanced(by: normalBuffer.offset)
            .bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
        for i in 0 ..< count {
            let position = SIMD4<Float>(positions[i], 1)
            p[i] = position
            p[i + count] = position
            n[i] = SIMD4<Float>(normals[i], 0)
            n[i + count] = SIMD4<Float>(-normals[i], 0)
        }
        #if os(macOS)
            if positionBuffer.buffer.storageMode == .managed {
                positionBuffer.buffer.didModifyRange(positionBuffer.offset ..< positionBuffer.offset + count * 2 * 16)
                normalBuffer.buffer.didModifyRange(normalBuffer.offset ..< normalBuffer.offset + count * 2 * 16)
            }
        #endif
    }

    /// Every edge of the simulated mesh as a line (drawn over everything,
    /// so the far side shows through).
    func showWireframe(_ show: Bool, positions: [SIMD3<Float>]) {
        guard show else {
            clearDebugLines(named: "cloth.wire")
            return
        }
        let color = SIMD4<Float>(0.05, 0.12, 0.35, 1)
        setDebugLines(edges.map {
            DebugLineSegment(from: positions[Int($0.x)], to: positions[Int($0.y)], color: color)
        }, named: "cloth.wire")
    }

    /// A small cross on every pinned particle.
    func showPins(_ show: Bool, pinned: [Int], positions: [SIMD3<Float>]) {
        guard show else {
            clearDebugLines(named: "cloth.pins")
            return
        }
        let color = SIMD4<Float>(1, 0.15, 0.1, 1)
        let r: Float = 0.004
        var segments: [DebugLineSegment] = []
        segments.reserveCapacity(pinned.count * 3)
        for i in pinned {
            let p = positions[i]
            segments.append(DebugLineSegment(from: p - SIMD3(r, 0, 0), to: p + SIMD3(r, 0, 0), color: color))
            segments.append(DebugLineSegment(from: p - SIMD3(0, r, 0), to: p + SIMD3(0, r, 0), color: color))
            segments.append(DebugLineSegment(from: p - SIMD3(0, 0, r), to: p + SIMD3(0, 0, r), color: color))
        }
        setDebugLines(segments, named: "cloth.pins")
    }

    /// Area-weighted vertex normals.
    private static func computeNormals(positions: [SIMD3<Float>], triangles: [SIMD3<Int32>], into normals: inout [SIMD3<Float>]) {
        for i in normals.indices {
            normals[i] = .zero
        }
        for t in triangles {
            let a = Int(t.x), b = Int(t.y), c = Int(t.z)
            let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += face
            normals[b] += face
            normals[c] += face
        }
        for i in normals.indices {
            let length = simd_length(normals[i])
            normals[i] = length > 1e-12 ? normals[i] / length : SIMD3(0, 0, 1)
        }
    }
}
