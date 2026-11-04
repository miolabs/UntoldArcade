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
/// seams and sharp edges, so one drives several. Beside the garments, the skin's
/// colliders: a convex hull per bone of the skin that bone moves, which the game puts
/// in the world as kinematic bodies on the joints. Pure data; the game turns it into a
/// Jolt soft body, its colliders and the engine's deformation override.
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

    /// One of the skin's colliders: the skin a bone moves, as a convex hull in that
    /// bone's frame, for the cloth to collide with where the back-stop cannot stand for
    /// the skin. The back-stop is a plane behind each particle's skinned position, so
    /// it is the skin only where the particle sits near its target; with the arms
    /// raised the skinned targets spread (the armhole edges 2.4 times at the 99th
    /// percentile), a particle sits up to 15 cm from its target, and a stop placed at
    /// the target no longer stands for the arm under the particle — the sleeve sank
    /// into the arm in patches on the headset (2026-10-31). The hulls are the skin
    /// itself, fitted by the prep to the vertices each bone moves most: a millimetre
    /// inside it along the bone, and standing back by up to 3 cm toward the joints,
    /// where the skin is blended between bones and a hull rigid on its own bone would
    /// stand proud of the posed skin (the prep's bend inset: inset the millimetre
    /// alone, the first cook's torso hulls stood 27 mm proud of the arms-forward
    /// chest and pushed the buttoned front 3.8 cm past its 5 mm slack), and clear of
    /// the resting shirt by a particle's radius (the prep's garment margin: a convex
    /// hull fills the armpit's hollow, where the shirt lies, and filled it stood 11 mm
    /// through the resting proxy and moved the shirt before the arm had). `ZombieCloth`
    /// moves each with its joint every step on a layer only the awake cloth meets
    /// (`ZombiePhysics.Configuration.skinColliderLayer`). The
    /// ragdoll's capsules cannot do this: inscribed in the body, they are a centimetre
    /// thin at the arms and stand centimetres outside the skin at the torso.
    public struct Collider: Codable, Sendable, Equatable {
        /// The skeleton joint the hull follows, as the engine names it
        /// (`/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l`).
        public var joint: String
        /// `hull`: the points are the vertices of a convex hull (Jolt builds the hull;
        /// at least four, a few dozen at most).
        public var shape: String
        /// The hull's points in the joint's local frame at the bind pose, engine space,
        /// three floats per point: a point's world position is the joint's world
        /// transform applied to it, in every pose.
        public var points: [Float]

        public var pointVectors: [SIMD3<Float>] {
            stride(from: 0, to: points.count - 2, by: 3).map { SIMD3(points[$0], points[$0 + 1], points[$0 + 2]) }
        }
    }

    public var garments: [Garment]
    /// The skin's colliders, when the prep wrote them (a sidecar cooked before they
    /// existed decodes without them, and the cloth then runs on its back-stop alone).
    public var colliders: [Collider]?

    /// The garment of that name, if present.
    public func garment(named name: String) -> Garment? {
        garments.first { $0.name == name }
    }

    /// Decodes a sidecar file.
    public static func load(from url: URL) throws -> ZombieClothAsset {
        try JSONDecoder().decode(ZombieClothAsset.self, from: Data(contentsOf: url))
    }

    /// The sidecar the kit runs on unless `ZombieCloth.Configuration.sidecar`
    /// names another: `Zombie.cloth`, the 3,995-particle cook of
    /// 2026-11-03 (2,948,037 bytes). Phase 2 of `Docs/GPUCloth.md` cooks a
    /// second file beside it, `Zombie.cloth16k` — the same shell, the same
    /// colliders and the same trousers over a 16,000-particle shirt proxy,
    /// whose 8.4 mm spacing is the drawn shell's own 8.25 mm median edge,
    /// so finer than it buys nothing the shell can show — and the two are a
    /// live A/B on the GPU arm (`-clothSidecar Zombie.cloth16k`, the
    /// hosts' Proxy picker); the 4k stays the default until the design's
    /// gate 2, the owner's quality verdict on the headset, and the Jolt arm
    /// keeps it whatever is named, since at 16k Jolt's one-thread edge
    /// pass is four times its 3.4 ms step.
    public static let defaultSidecarName = "Zombie.cloth"
    /// The phase-2 cook's name, `Zombie.cloth16k`: what the hosts' Proxy
    /// picker and `-clothSidecar Zombie.cloth16k` select on the GPU arm.
    public static let sidecar16kName = "Zombie.cloth16k"

    /// A sidecar's file name from its name, with or without the `.json`
    /// (`Zombie.cloth16k` and `Zombie.cloth16k.json` are the same file).
    public static func sidecarFileName(_ name: String) -> String {
        name.hasSuffix(".json") ? name : name + ".json"
    }

    /// The sidecar bundled with the kit, beside the model.
    public static var bundledURL: URL? { bundledURL(named: defaultSidecarName) }

    /// A bundled sidecar by name (`Models/Zombie/<name>.json`); nil when
    /// the kit has no resource bundle. Whether the file exists is the
    /// loader's to say.
    public static func bundledURL(named name: String) -> URL? {
        ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/\(sidecarFileName(name))")
    }

    /// Whether a sidecar of that name is in the bundle: what a host's
    /// Proxy picker offers, and what the loader falls back from.
    public static func isBundled(named name: String) -> Bool {
        guard let url = bundledURL(named: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Decodes the bundled sidecar.
    public static func loadBundled() throws -> ZombieClothAsset {
        try loadBundled(named: defaultSidecarName)
    }

    /// Decodes a bundled sidecar by name; throws `fileNoSuchFile` with the
    /// path when the bundle lacks it, so the caller can name the file it
    /// did not find.
    public static func loadBundled(named name: String) throws -> ZombieClothAsset {
        guard let url = bundledURL(named: name), FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Models/Zombie/\(sidecarFileName(name))"])
        }
        return try load(from: url)
    }
}
