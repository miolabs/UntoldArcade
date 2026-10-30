//
//  ZombieClothAssetTests.swift
//  CoolZombieKitTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import XCTest
@testable import CoolZombieKit
@testable import UntoldEngine

/// The cloth sidecar (`Models/Zombie/Zombie.cloth.json`, from `Tools/blender/prep_zombie.py`)
/// as the simulation needs it: every particle is a vertex of the exported mesh (the game
/// binds them by position), the skin weights are the exported skeleton's joints with no
/// hand in them, each proxy is one piece with the openings a garment has, pinned where
/// it hangs from the body, triangulated consistently and at a particle spacing the
/// solver can hold.
final class ZombieClothAssetTests: XCTestCase {
    private struct Model {
        let positions: [SIMD3<Float>]
        let jointPaths: [String]
        let jointWorld: [simd_float4x4]
    }

    private static let modelURL = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold")

    /// The exported mesh's vertex positions and the skeleton's bind-pose model matrices,
    /// read the way the model tests read them.
    private func loadModel() throws -> Model? {
        guard let url = Self.modelURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = try NativeFormatLoader().loadAssetSync(from: url)
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first,
              let primitive = asset.nodes.flatMap(\.primitives).first else { return nil }
        let stride = primitive.vertexLayout.stride
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(primitive.vertexCount)
        primitive.vertexData.withUnsafeBytes { raw in
            for v in 0 ..< primitive.vertexCount {
                let p = raw.baseAddress!.advanced(by: v * stride).assumingMemoryBound(to: Float.self)
                positions.append(SIMD3(p[0], p[1], p[2]))
            }
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        for index in skeleton.jointPaths.indices {
            let parent = skeleton.parentIndices[index].map { world[$0] } ?? matrix_identity_float4x4
            world[index] = parent * skeleton.restTransforms[index]
        }
        return Model(positions: positions, jointPaths: skeleton.jointPaths, jointWorld: world)
    }

    private func loadCloth() throws -> ZombieClothAsset {
        guard let url = ZombieClothAsset.bundledURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Models/Zombie/Zombie.cloth.json is not bundled")
        }
        return try ZombieClothAsset.load(from: url)
    }

    /// Edges of a triangle list, each once, with how often each direction occurs.
    private func edges(of triangles: [[Int]]) -> (undirected: Set<[Int]>, directed: [[Int]: Int]) {
        var undirected = Set<[Int]>(), directed: [[Int]: Int] = [:]
        for t in triangles {
            for k in 0 ..< 3 {
                let a = t[k], b = t[(k + 1) % 3]
                undirected.insert([min(a, b), max(a, b)])
                directed[[a, b], default: 0] += 1
            }
        }
        return (undirected, directed)
    }

    /// Connected components of the particle graph.
    private func islandCount(particles: Int, edges: Set<[Int]>) -> Int {
        var parent = Array(0 ..< particles)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for e in edges { let a = find(e[0]), b = find(e[1]); if a != b { parent[a] = b } }
        return Set((0 ..< particles).map(find)).count
    }

    /// The boundary of a triangle list (the edges with one triangle) traced as closed
    /// cycles. Every boundary vertex must carry exactly two boundary edges, or the
    /// boundary is torn or pinched and the count means nothing: a hole that touches an
    /// opening at one vertex is a failure here, not one loop more or less.
    private func boundaryLoopCount(triangles: [[Int]], _ name: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var count: [[Int]: Int] = [:]
        for t in triangles {
            for k in 0 ..< 3 {
                let a = t[k], b = t[(k + 1) % 3]
                count[[min(a, b), max(a, b)], default: 0] += 1
            }
        }
        var next: [Int: [Int]] = [:]
        for (e, n) in count where n == 1 {
            next[e[0], default: []].append(e[1]); next[e[1], default: []].append(e[0])
        }
        let pinched = next.filter { $0.value.count != 2 }
        XCTAssertTrue(pinched.isEmpty, "\(name): \(pinched.count) boundary vertices carry \(Set(pinched.values.map(\.count)).sorted()) boundary edges instead of two", file: file, line: line)
        var seen = Set<Int>(), loops = 0
        for start in next.keys.sorted() where !seen.contains(start) {
            loops += 1
            var previous = -1, v = start
            repeat {
                seen.insert(v)
                let around = next[v] ?? []
                let step = around.first { $0 != previous } ?? around[0]
                previous = v; v = step
            } while v != start && !seen.contains(v)
        }
        return loops
    }

    func testTheSidecarDecodesWithBothGarments() throws {
        let cloth = try loadCloth()
        XCTAssertEqual(cloth.garments.map(\.name), ["shirt", "trousers"])
        for g in cloth.garments {
            XCTAssertEqual(g.influences.count, g.particles.count, g.name)
            XCTAssertEqual(g.maxDistance.count, g.particles.count, g.name)
            XCTAssertEqual(g.dominantJoint.count, g.particles.count, g.name)
            XCTAssertEqual(g.pinCount, g.maxDistance.filter { $0 == 0 }.count, g.name)
            XCTAssertEqual(g.backstop, 0.003, accuracy: 1e-6, g.name)
            XCTAssertFalse(g.sourceHash.isEmpty, g.name)
            XCTAssertEqual(g.sourceFile, "Zombie_new_cloth.blend", g.name)
            XCTAssertGreaterThan(g.triangles.count, 0, g.name)
            for p in g.particles { XCTAssertEqual(p.count, 3, g.name) }
            for t in g.triangles { XCTAssertEqual(t.count, 3, g.name); XCTAssertTrue(t.allSatisfy { $0 >= 0 && $0 < g.particles.count }, g.name) }
        }
    }

    /// Every particle sits on an exported vertex: the game binds them by position, and
    /// a proxy that drifted from the export (another scale, another axis convention, a
    /// stale sidecar) would drive nothing.
    func testEveryParticleIsAnExportedVertex() throws {
        let cloth = try loadCloth()
        guard let model = try loadModel() else { throw XCTSkip("Models/Zombie is not bundled") }
        // Hash the exported vertices into millimetre cells; a particle matches when a
        // vertex within 0.2 mm sits in its cell or a neighbouring one.
        let cell: Float = 0.001
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        var grid: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for p in model.positions { grid[key(p), default: []].append(p) }
        for g in cloth.garments {
            var unmatched = 0
            var worst: Float = 0
            for p in g.positions {
                let k = key(p)
                var best = Float.greatestFiniteMagnitude
                for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                    for q in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] {
                        best = min(best, simd_distance(p, q))
                    }
                } } }
                if best > 0.0002 { unmatched += 1 }
                worst = max(worst, min(best, 1))
            }
            print("CoolZombie cloth \(g.name): \(g.particles.count) particles, \(unmatched) without an exported vertex within 0.2 mm (worst \(worst * 1000) mm)")
            XCTAssertEqual(unmatched, 0, "\(g.name): \(unmatched) particles match no exported vertex")
            XCTAssertEqual(g.exportedVertexCount, model.positions.count, "\(g.name): the sidecar was cooked with another export")
        }
    }

    /// The skin weights are the exported skeleton's, four at most and summing to one,
    /// and nothing of a garment follows a hand: the cuffs stay on the forearms.
    func testInfluencesAreNormalisedSkeletonJointsWithoutHands() throws {
        let cloth = try loadCloth()
        guard let model = try loadModel() else { throw XCTSkip("Models/Zombie is not bundled") }
        let known = Set(model.jointPaths)
        let hand = ["hand_", "thumb_", "index_", "middle_", "ring_", "pinky_"]
        for g in cloth.garments {
            XCTAssertFalse(g.jointPaths.isEmpty, g.name)
            for path in g.jointPaths {
                XCTAssertTrue(known.contains(path), "\(g.name): \(path) is not a joint of the model")
                let joint = String(path.split(separator: "/").last ?? "")
                XCTAssertFalse(hand.contains { joint.hasPrefix($0) }, "\(g.name) weighs on \(path)")
            }
            for (i, influences) in g.influences.enumerated() {
                XCTAssertTrue((1 ... 4).contains(influences.count), "\(g.name) particle \(i): \(influences.count) influences")
                let sum = influences.reduce(Float(0)) { $0 + $1[1] }
                XCTAssertEqual(sum, 1, accuracy: 1e-3, "\(g.name) particle \(i)")
                for pair in influences {
                    XCTAssertEqual(pair.count, 2)
                    let joint = Int(pair[0])
                    XCTAssertTrue(joint >= 0 && joint < g.jointPaths.count, "\(g.name) particle \(i): joint \(joint)")
                    XCTAssertGreaterThan(pair[1], 0, "\(g.name) particle \(i)")
                }
                let heaviest = influences.max { $0[1] < $1[1] }.map { Int($0[0]) }
                XCTAssertEqual(g.dominantJoint[i], heaviest, "\(g.name) particle \(i): dominant joint")
            }
        }
    }

    /// Each proxy is one piece with the openings its garment has, and pinned where it
    /// hangs: the shirt at the collar, the trousers at the waist. The shirt is buttoned
    /// and the prep sews its front, so its openings are the collar, the hem and the two
    /// cuffs: four loops; the trousers' are the waist and two hems: three. The buttoned
    /// front gets 5 mm of slack (the buttons hold the panels to the chest), the cuffs
    /// 1 cm, the trousers' hems 2 cm, the rest 3 cm.
    func testTheProxiesAreOnePieceWithTheirOpeningsAndPins() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let trousers = try XCTUnwrap(cloth.garment(named: "trousers"))
        for (g, expectedLoops, minPins, slacks) in [(shirt, 4, 20, [Float(0), 0.005, 0.01, 0.03]), (trousers, 3, 60, [0, 0.02, 0.03])] {
            let e = edges(of: g.triangles)
            XCTAssertEqual(islandCount(particles: g.particles.count, edges: e.undirected), 1, "\(g.name) is not one piece")
            let loops = boundaryLoopCount(triangles: g.triangles, g.name)
            print("CoolZombie cloth \(g.name): \(g.particles.count) particles, \(g.triangles.count) triangles, \(loops) boundary loops, \(g.pinCount) pins")
            XCTAssertEqual(loops, expectedLoops, "\(g.name): \(loops) boundary loops")
            XCTAssertGreaterThanOrEqual(g.pinCount, minPins, "\(g.name): too few pins")
            XCTAssertLessThan(g.pinCount, g.particles.count / 4, "\(g.name): most of the garment is pinned")
            XCTAssertEqual(Set(g.maxDistance), Set(slacks), "\(g.name): slack values")
        }
        // The shirt pins sit at the top of it (the collar), the trousers' at theirs (the waist).
        for (g, top) in [(shirt, Float(1.35)), (trousers, Float(0.95))] {
            for (i, d) in g.maxDistance.enumerated() where d == 0 {
                XCTAssertGreaterThan(g.particles[i][1], top, "\(g.name): a pin at height \(g.particles[i][1])")
            }
        }
        // The shirt's 5 mm band is the buttoned front: a strip down the centre line, on
        // the front of the body (engine z = Blender -y; the body's front is at negative
        // Blender y), below the collar.
        let front = shirt.maxDistance.indices.filter { shirt.maxDistance[$0] == 0.005 }
        XCTAssertGreaterThan(front.count, 50, "the buttoned front has \(front.count) particles")
        for i in front {
            let p = shirt.particles[i]
            XCTAssertLessThan(abs(p[0]), 0.02, "a buttoned-front particle at x \(p[0])")
            XCTAssertGreaterThan(p[2], -0.06, "a buttoned-front particle behind the body at z \(p[2])")
        }
    }

    /// The particles listed as facing the body are a small part of each garment (the
    /// rolled cuffs, the inside of the collar), each a valid index, listed once.
    func testFewParticlesFaceTheBody() throws {
        let cloth = try loadCloth()
        for g in cloth.garments {
            XCTAssertEqual(Set(g.bodyFacingParticles).count, g.bodyFacingParticles.count, "\(g.name): a particle listed twice")
            XCTAssertTrue(g.bodyFacingParticles.allSatisfy { $0 >= 0 && $0 < g.particles.count }, "\(g.name): an index out of range")
            print("CoolZombie cloth \(g.name): \(g.bodyFacingParticles.count) of \(g.particles.count) particles face the body")
            XCTAssertLessThan(g.bodyFacingParticles.count, g.particles.count / 10, "\(g.name): the garment faces the body")
        }
    }

    /// Particle spacing the solver can hold, and a triangle list wound one way: an edge
    /// shared by two faces runs opposite ways in them.
    func testEdgesAreBetweenEightAndFortyMillimetresAndWindingIsConsistent() throws {
        let cloth = try loadCloth()
        for g in cloth.garments {
            let p = g.positions
            let e = edges(of: g.triangles)
            var shortest = Float.greatestFiniteMagnitude, longest: Float = 0
            for edge in e.undirected {
                let l = simd_distance(p[edge[0]], p[edge[1]])
                shortest = min(shortest, l); longest = max(longest, l)
            }
            print("CoolZombie cloth \(g.name): edges \(shortest * 1000)..\(longest * 1000) mm")
            XCTAssertGreaterThanOrEqual(shortest, 0.008, "\(g.name): an edge of \(shortest * 1000) mm")
            XCTAssertLessThanOrEqual(longest, 0.040, "\(g.name): an edge of \(longest * 1000) mm")
            let sameWay = e.directed.values.filter { $0 > 1 }.count
            XCTAssertEqual(sameWay, 0, "\(g.name): \(sameWay) edges run the same way in two faces")
            // Every edge of two faces also appears reversed: the faces agree.
            var unmatched = 0
            for (edge, _) in e.directed where (e.directed[[edge[1], edge[0]]] ?? 0) == 0 {
                if e.undirected.contains([min(edge[0], edge[1]), max(edge[0], edge[1])]), g.triangles.filter({ t in t.contains(edge[0]) && t.contains(edge[1]) }).count == 2 { unmatched += 1 }
            }
            XCTAssertEqual(unmatched, 0, "\(g.name): \(unmatched) interior edges without a reversed twin")
        }
    }

    /// Faces point away from the body on the whole: for a garment worn around the torso,
    /// the mean face normal points outward from the garment's own axis, which is where
    /// the back-stop expects the body to be (the exceptions are listed per particle in
    /// `bodyFacingParticles`).
    func testTheFacesPointAwayFromTheBody() throws {
        let cloth = try loadCloth()
        for g in cloth.garments {
            let p = g.positions
            var outward = 0, inward = 0
            for t in g.triangles {
                let a = p[t[0]], b = p[t[1]], c = p[t[2]]
                let n = simd_cross(b - a, c - a)
                let centre = (a + b + c) / 3
                // Radial direction from the body's vertical axis through the garment's centre.
                var radial = SIMD3<Float>(centre.x, 0, centre.z)
                if g.name == "trousers" { radial.x = centre.x > 0 ? centre.x - 0.1 : centre.x + 0.1 } // each leg around its own axis
                guard simd_length(radial) > 0.03 else { continue }
                if simd_dot(n, radial) > 0 { outward += 1 } else { inward += 1 }
            }
            print("CoolZombie cloth \(g.name): \(outward) faces point outward, \(inward) inward")
            XCTAssertGreaterThan(outward, inward * 3, "\(g.name): the faces do not point away from the body")
        }
    }

    /// The bind matrices are the exported skeleton's bind pose: one rigid transform per
    /// joint, equal to the model's rest-pose joint matrices.
    func testBindMatricesMatchTheSkeleton() throws {
        let cloth = try loadCloth()
        guard let model = try loadModel() else { throw XCTSkip("Models/Zombie is not bundled") }
        for g in cloth.garments {
            XCTAssertEqual(g.bindJointWorldMatrices.count, g.jointPaths.count, g.name)
            for (path, m) in zip(g.jointPaths, g.bindMatrices) {
                let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
                let y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
                let z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
                XCTAssertEqual(simd_length(x), 1, accuracy: 1e-3, "\(g.name) \(path) X scale")
                XCTAssertEqual(simd_length(y), 1, accuracy: 1e-3, "\(g.name) \(path) Y scale")
                XCTAssertEqual(simd_length(z), 1, accuracy: 1e-3, "\(g.name) \(path) Z scale")
                XCTAssertEqual(simd_dot(x, y), 0, accuracy: 1e-3, "\(g.name) \(path) XY shear")
                XCTAssertEqual(simd_dot(y, z), 0, accuracy: 1e-3, "\(g.name) \(path) YZ shear")
                XCTAssertEqual(simd_dot(simd_cross(x, y), z), 1, accuracy: 1e-3, "\(g.name) \(path) handedness")
                XCTAssertEqual(m.columns.3.w, 1, accuracy: 1e-6, "\(g.name) \(path) affine row")
                guard let index = model.jointPaths.firstIndex(of: path) else { return XCTFail("\(path) not in the model") }
                let expected = model.jointWorld[index]
                for c in 0 ..< 4 {
                    XCTAssertEqual(simd_distance(m[c], expected[c]), 0, accuracy: 2e-3, "\(g.name) \(path) column \(c) differs from the model's bind pose")
                }
            }
        }
    }
}
