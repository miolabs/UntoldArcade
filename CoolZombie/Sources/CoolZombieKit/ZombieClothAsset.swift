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
/// stray from its skinned position (0 pins it). The particles are vertices of the
/// exported mesh, matched by position: the exporter splits a vertex on UV seams, so one
/// particle drives several exported vertices. Pure data; the game turns it into a Jolt
/// soft body and the engine's deformation override.
public struct ZombieClothAsset: Codable, Sendable, Equatable {
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
