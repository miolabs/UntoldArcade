//
//  ZombieClothAsset.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// The cloth sidecar `Models/Zombie/Zombie.cloth.json` that `Tools/blender/prep_zombie.py`
/// writes beside the model: one simulation proxy per garment (the shirt's outer layer,
/// the sewn trousers), in engine space, with everything a skinned soft body needs — the
/// particles, their triangles, the joints that skin them and how far each particle may
/// stray from its skinned position (0 pins it). What the proxy drives in the mesh is
/// either itself — the trousers proxy is in the export, its particles vertices of the
/// mesh matched by position — or, with a `render` binding, the artist's drawn shell:
/// the shirt proxy is not in the export; the shell is, and every shell vertex is bound
/// to a proxy triangle, carried rigidly in its frame. Positions are matched to the
/// exported vertices by position in both cases: the exporter splits a vertex on UV
/// seams and sharp edges, so one drives several. Pure data; the game turns it into a
/// Jolt soft body and the engine's deformation override.
public struct ZombieClothAsset: Codable, Sendable, Equatable {
    /// The drawn shell's binding to its garment's proxy, at the bind pose. Every shell
    /// vertex names the proxy triangle nearest to it, the barycentric coordinates of the
    /// closest point on it, and its rest offset in that triangle's frame — `e1` along
    /// the first edge (b − a), `n` the face normal (e1 × (c − a)), `t = n × e1` — so a
    /// triangle that tilts or moves carries the vertex rigidly: position = bary(a, b, c)
    /// + off.x e1 + off.y n + off.z t. The normals are not here: the exporter writes a
    /// normal per face corner and splits a vertex whose corners disagree (the artist's
    /// sharp edges — the cuff rolls, the placket's edge, the collar's creases — make a
    /// thousand shell vertices two or more exported ones with normals up to 180° apart,
    /// opposite), so the game reads each exported copy's own normal off the mesh at the
    /// attach and carries it in the same frame (`ZombieCloth.RenderShell`): the shell
    /// keeps its fold shading and its creases, where the proxy's normals would flatten
    /// both. The buttons and the bits of thread are rigid islands: every vertex of one
    /// binds to the single triangle nearest the island's centre. The arrays are flat
    /// triples (x y z, u v w); the rest positions are what the game binds to the
    /// exported vertices.
    public struct RenderBinding: Codable, Sendable, Equatable {
        /// How many shell vertices the arrays describe.
        public var vertexCount: Int
        /// Rest positions in engine space, three floats per vertex.
        public var restPositions: [Float]
        /// Per vertex, the index of its proxy triangle.
        public var triangle: [Int]
        /// Per vertex, the barycentric coordinates of the closest point, three per vertex.
        public var barycentric: [Float]
        /// Per vertex, the rest offset from that point in the triangle's frame, three per vertex.
        public var offset: [Float]
        /// The rigid islands (buttons, bits of thread) as `[first, count]` runs of vertices;
        /// the vertices before the first run are the shell proper.
        public var rigidIslands: [[Int]]

        private static func triples(_ values: [Float]) -> [SIMD3<Float>] {
            stride(from: 0, to: values.count - 2, by: 3).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
        }

        public var restPositionVectors: [SIMD3<Float>] { Self.triples(restPositions) }
        public var barycentricVectors: [SIMD3<Float>] { Self.triples(barycentric) }
        public var offsetVectors: [SIMD3<Float>] { Self.triples(offset) }

        /// Whether every array describes `vertexCount` vertices and every triangle index
        /// lies within `triangles` of the proxy.
        public func isConsistent(triangles: Int) -> Bool {
            vertexCount > 0 && restPositions.count == vertexCount * 3 && triangle.count == vertexCount
                && barycentric.count == vertexCount * 3 && offset.count == vertexCount * 3
                && triangle.allSatisfy { $0 >= 0 && $0 < triangles }
                && rigidIslands.allSatisfy { $0.count == 2 && $0[0] >= 0 && $0[1] > 0 && $0[0] + $0[1] <= vertexCount }
        }
    }

    /// One garment's proxy.
    public struct Garment: Codable, Sendable, Equatable {
        /// `shirt` or `trousers`.
        public var name: String
        /// Particle positions in engine space (metres), the exported mesh's frame.
        public var particles: [[Float]]
        /// Particle indices, wound consistently (an edge shared by two triangles runs
        /// opposite ways in them) and counter-clockwise seen from outside the garment on
        /// the whole; the particles whose own normal points at the body instead are in
        /// `bodyFacingParticles`.
        public var triangles: [[Int]]
        /// The skeleton joints the influences index, as the engine names them
        /// (`/root/pelvis/spine_01`); a subset of the model's joints.
        public var jointPaths: [String]
        /// Per particle, up to four `[jointIndex, weight]` pairs summing to 1.
        public var influences: [[[Float]]]
        /// Per particle, how far it may stray from its skinned position; 0 pins it.
        public var maxDistance: [Float]
        /// How far behind the skinned surface the back-stop starts, for every particle.
        public var backstop: Float
        /// The particles whose normal (from the triangles around them) points at the body
        /// rather than away from it: the rolled cuffs and the inside of the collar wrap
        /// back towards the arm and the neck. A back-stop placed behind their faces would
        /// sit on the wrong side, so the game puts theirs on the body side.
        public var bodyFacingParticles: [Int]
        /// How many particles are pinned (`maxDistance == 0`).
        public var pinCount: Int
        /// Per particle, the index into `jointPaths` of its heaviest joint.
        public var dominantJoint: [Int]
        /// Per joint, its bind-pose model matrix in engine space as 16 column-major floats.
        public var bindJointWorldMatrices: [[Float]]
        /// The artist file this was cooked from, and its SHA-256.
        public var sourceFile: String
        public var sourceHash: String
        /// Vertex count of the `.untold` written in the same run, to tell a stale sidecar.
        public var exportedVertexCount: Int
        /// The drawn shell's binding to this proxy, when the garment is drawn as the
        /// artist's shell (the shirt); absent, the proxy itself is in the export and is
        /// what the particles drive (the trousers).
        public var render: RenderBinding?

        /// `bindJointWorldMatrices` as matrices.
        public var bindMatrices: [simd_float4x4] {
            bindJointWorldMatrices.map { m in
                simd_float4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]),
                    SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]),
                    SIMD4(m[12], m[13], m[14], m[15])
                ))
            }
        }

        /// The particle positions as vectors.
        public var positions: [SIMD3<Float>] {
            particles.map { SIMD3($0[0], $0[1], $0[2]) }
        }
    }

    public var garments: [Garment]

    /// The garment of that name, if present.
    public func garment(named name: String) -> Garment? {
        garments.first { $0.name == name }
    }

    /// Decodes a sidecar file.
    public static func load(from url: URL) throws -> ZombieClothAsset {
        try JSONDecoder().decode(ZombieClothAsset.self, from: Data(contentsOf: url))
    }

    /// The sidecar bundled with the kit, beside the model.
    public static var bundledURL: URL? {
        ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.cloth.json")
    }

    /// Decodes the bundled sidecar.
    public static func loadBundled() throws -> ZombieClothAsset {
        guard let url = bundledURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Models/Zombie/Zombie.cloth.json"])
        }
        return try load(from: url)
    }
}
