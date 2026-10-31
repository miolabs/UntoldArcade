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
/// as the simulation needs it: the shirt's drawn shell is in the exported mesh and bound
/// to the proxy, which is not (the trousers proxy still is: its particles are vertices
/// of the mesh), the game binds either to the mesh by position, the skin weights are
/// the exported skeleton's joints with no hand in them, each proxy is one piece with the
/// openings a garment has, slack scheduled so the shirt hangs from its shoulders,
/// triangulated consistently and at a particle spacing the solver can hold.
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
            // A millimetre: Jolt's back stop starts that far BEHIND the skinned position,
            // and the push-out leaves the proxy 2 mm off the skin the export keeps under
            // the shirt (5 mm let it sink 3 mm into that skin and, not short of the
            // buttoned front's 5 mm slack, switched that band's stop off; 2026-10-31).
            XCTAssertEqual(g.backstop, 0.001, accuracy: 1e-6, g.name)
            XCTAssertFalse(g.sourceHash.isEmpty, g.name)
            XCTAssertEqual(g.sourceFile, "Zombie_new_cloth.blend", g.name)
            XCTAssertGreaterThan(g.triangles.count, 0, g.name)
            for p in g.particles { XCTAssertEqual(p.count, 3, g.name) }
            for t in g.triangles { XCTAssertEqual(t.count, 3, g.name); XCTAssertTrue(t.allSatisfy { $0 >= 0 && $0 < g.particles.count }, g.name) }
        }
        // The shirt is drawn as its shell and carries the binding; the trousers are
        // drawn as their proxy and carry none.
        let render = try XCTUnwrap(cloth.garment(named: "shirt")?.render, "the shirt has no render binding")
        XCTAssertNil(cloth.garment(named: "trousers")?.render)
        XCTAssertTrue(render.isConsistent(triangles: cloth.garment(named: "shirt")!.triangles.count), "the render arrays disagree")
        XCTAssertGreaterThan(render.vertexCount, 20000, "the shell has \(render.vertexCount) vertices")
        for (v, w) in render.barycentricVectors.enumerated() {
            XCTAssertEqual(w.x + w.y + w.z, 1, accuracy: 1e-4, "shell vertex \(v): barycentric sum")
            XCTAssertTrue(w.min() >= 0 && w.max() <= 1, "shell vertex \(v): barycentric \(w) outside its triangle")
        }
        // The rigid islands are disjoint runs after the shell proper: seven buttons of
        // 410 vertices and fourteen bits of thread of 35.
        let runs = render.rigidIslands.map { $0[0] ..< $0[0] + $0[1] }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertEqual(runs.count, 21)
        XCTAssertEqual(runs.map(\.count).sorted(), Array(repeating: 35, count: 14) + Array(repeating: 410, count: 7))
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound, "the rigid islands are not contiguous runs") }
        XCTAssertEqual(runs.last?.upperBound, render.vertexCount, "the rigid islands end the vertex list")
        print("CoolZombie cloth shirt: \(render.vertexCount) shell vertices, \(runs.first?.lowerBound ?? 0) in the shell proper, \(runs.count) rigid islands")
    }

    /// What the game draws sits on exported vertices, matched by position (a sidecar
    /// that drifted from the export — another scale, another axis convention, a stale
    /// cook — would drive nothing): every shell vertex of the shirt, every particle of
    /// the trousers. The shirt proxy is not in the export; its particles are a subset
    /// of the shell's outer layer by construction (the decimation collapses edges onto
    /// surviving vertices and moves none, the push-out and the placket weld move a few
    /// dozen), so most of them do coincide with an exported vertex — the shell's. What
    /// says the proxy adds nothing of its own is that every exported vertex within
    /// 0.2 mm of a particle is within 0.2 mm of a shell vertex too.
    func testTheShellIsInTheExportAndTheProxyIsNot() throws {
        let cloth = try loadCloth()
        guard let model = try loadModel() else { throw XCTSkip("Models/Zombie is not bundled") }
        // Hash the exported vertices into millimetre cells; a point matches when a
        // vertex within 0.2 mm sits in its cell or a neighbouring one.
        let cell: Float = 0.001
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        func grid(_ points: [SIMD3<Float>]) -> [SIMD3<Int32>: [SIMD3<Float>]] {
            var grid: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
            for p in points { grid[key(p), default: []].append(p) }
            return grid
        }
        func around(_ p: SIMD3<Float>, in grid: [SIMD3<Int32>: [SIMD3<Float>]]) -> [SIMD3<Float>] {
            let k = key(p)
            var found: [SIMD3<Float>] = []
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                for q in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(p, q) <= 0.0002 { found.append(q) }
            } } }
            return found
        }
        let exported = grid(model.positions)
        func check(_ points: [SIMD3<Float>], _ label: String) {
            var unmatched = 0
            for p in points where around(p, in: exported).isEmpty { unmatched += 1 }
            print("CoolZombie cloth \(label): \(points.count) points, \(unmatched) without an exported vertex within 0.2 mm")
            XCTAssertEqual(unmatched, 0, "\(label): \(unmatched) match no exported vertex")
        }
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt")), trousers = try XCTUnwrap(cloth.garment(named: "trousers"))
        let shell = try XCTUnwrap(shirt.render).restPositionVectors
        check(shell, "shirt shell vertices")
        check(trousers.positions, "trousers particles")
        for g in cloth.garments {
            XCTAssertEqual(g.exportedVertexCount, model.positions.count, "\(g.name): the sidecar was cooked with another export")
        }
        let shellGrid = grid(shell)
        var coinciding = 0, proxyOnly = 0
        for p in shirt.positions {
            let near = around(p, in: exported)
            if !near.isEmpty { coinciding += 1 }
            for q in near where around(q, in: shellGrid).isEmpty { proxyOnly += 1 }
        }
        print("CoolZombie cloth shirt: \(coinciding) of \(shirt.particles.count) particles coincide with an exported vertex (the shell's outer layer), \(proxyOnly) exported vertices are the proxy's alone")
        XCTAssertEqual(proxyOnly, 0, "\(proxyOnly) exported vertices sit on the shirt proxy and not on the shell: the proxy is in the export")
    }

    /// The render binding rebuilds the shell at the bind pose: from the proxy's own
    /// particles, every shell vertex comes back within a tenth of a millimetre of its
    /// rest position — the inner layer a millimetre behind the outer, the buttons a
    /// centimetre in front — and every button and bit of thread binds whole to one
    /// triangle. (The normals are the exported mesh's, not the sidecar's;
    /// `ZombieClothTests` holds the shell evaluated at the bind pose to the export,
    /// normals included.) And the shell proper hangs off no triangle's edge as a lever:
    /// no vertex of it sits more than a centimetre below the lowest corner of its
    /// triangle, nor more than 25 mm from the closest point on it. When the outer-layer
    /// cut dropped the artist's hem strip the proxy's hem stopped 9-33 mm above the
    /// drawn hem and 569 shell vertices rode the boundary triangles from up to 33 mm
    /// below them, on the hem band's 12 cm of slack; with the strip sewn back on the
    /// cook's worst is 8.7 mm below (the strip's bottom edge between proxy vertices) and
    /// 20 mm off (the placket's hidden panel, which the proxy trims; 2026-10-31).
    func testTheRenderBindingRebuildsTheShellAtTheBindPose() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let render = try XCTUnwrap(shirt.render)
        let p = shirt.positions
        let rest = render.restPositionVectors, bary = render.barycentricVectors, offset = render.offsetVectors
        let shellProper = render.rigidIslands.map { $0[0] }.min() ?? render.vertexCount
        var worstPosition: Float = 0, farthestOffset: Float = 0, inner = 0, lowest: Float = 0, hanging = 0
        for v in 0 ..< render.vertexCount {
            let t = shirt.triangles[render.triangle[v]]
            let a = p[t[0]], b = p[t[1]], c = p[t[2]]
            let e1 = simd_normalize(b - a), n = simd_normalize(simd_cross(e1, c - a)), tt = simd_cross(n, e1)
            let w = bary[v], o = offset[v]
            let rebuilt = w.x * a + w.y * b + w.z * c + o.x * e1 + o.y * n + o.z * tt
            worstPosition = max(worstPosition, simd_distance(rebuilt, rest[v]))
            if o.y < -0.0005 { inner += 1 }
            if v < shellProper {
                farthestOffset = max(farthestOffset, simd_length(o))
                let below = min(a.y, b.y, c.y) - rest[v].y
                if below > 0.002 { hanging += 1 }
                lowest = max(lowest, below)
            }
        }
        XCTAssertLessThan(worstPosition, 1e-4, "a shell vertex rebuilds \(worstPosition) m off its rest position")
        XCTAssertGreaterThan(inner, render.vertexCount / 4, "the inner layer (vertices more than 0.5 mm behind the proxy) is \(inner) vertices")
        XCTAssertLessThan(lowest, 0.010, "a shell vertex hangs \(lowest) m below its triangle's lowest corner: the proxy's hem stops above the drawn hem")
        XCTAssertLessThan(farthestOffset, 0.025, "a shell vertex sits \(farthestOffset) m from its triangle")
        for island in render.rigidIslands {
            let triangles = Set(render.triangle[island[0] ..< island[0] + island[1]])
            XCTAssertEqual(triangles.count, 1, "a rigid island of \(island[1]) vertices binds to \(triangles.count) triangles")
        }
        print(String(format: "CoolZombie cloth shirt render binding: %d vertices rebuilt within %.4f mm; %d behind the proxy; the shell proper at most %.1f mm from its triangle, %d vertices more than 2 mm below their triangle's lowest corner, the lowest %.1f mm",
                     render.vertexCount, worstPosition * 1000, inner, farthestOffset * 1000, hanging, lowest * 1000))
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
    /// hangs: the shirt at the collar band and the cuffs, the trousers at the waist. The
    /// shirt is buttoned and the prep sews its front, so its openings are the collar, the
    /// hem and the two cuffs: four loops; the trousers' are the waist and two hems:
    /// three. The shirt's slack is the schedule `testTheShirtSlackScheduleHangsItFromTheShoulders`
    /// holds (the buttoned front 5 mm, the yoke 1 cm, the sleeves 5, the armhole band 6,
    /// the chest 8, the back 10, the hem band 12); the trousers' hems 2 cm, the rest 3.
    func testTheProxiesAreOnePieceWithTheirOpeningsAndPins() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let trousers = try XCTUnwrap(cloth.garment(named: "trousers"))
        for (g, expectedLoops, minPins, slacks) in [(shirt, 4, 300, [Float(0), 0.005, 0.01, 0.05, 0.06, 0.08, 0.10, 0.12]), (trousers, 3, 60, [0, 0.02, 0.03])] {
            let e = edges(of: g.triangles)
            XCTAssertEqual(islandCount(particles: g.particles.count, edges: e.undirected), 1, "\(g.name) is not one piece")
            let loops = boundaryLoopCount(triangles: g.triangles, g.name)
            print("CoolZombie cloth \(g.name): \(g.particles.count) particles, \(g.triangles.count) triangles, \(loops) boundary loops, \(g.pinCount) pins")
            XCTAssertEqual(loops, expectedLoops, "\(g.name): \(loops) boundary loops")
            XCTAssertGreaterThanOrEqual(g.pinCount, minPins, "\(g.name): too few pins")
            XCTAssertLessThan(g.pinCount, g.particles.count / 4, "\(g.name): most of the garment is pinned")
            XCTAssertEqual(Set(g.maxDistance), Set(slacks), "\(g.name): slack values")
        }
        // The shirt's pins are its collar band (the top of it) and its cuffs (out at the
        // wrists), the trousers' their waist (the top).
        for (i, d) in shirt.maxDistance.enumerated() where d == 0 {
            let p = shirt.particles[i]
            XCTAssertTrue(p[1] > 1.34 || (abs(p[0]) > 0.40 && p[1] < 1.06), "shirt: a pin at (\(p[0]), \(p[1])), neither collar nor cuff")
        }
        for (i, d) in trousers.maxDistance.enumerated() where d == 0 {
            XCTAssertGreaterThan(trousers.particles[i][1], 0.95, "trousers: a pin at height \(trousers.particles[i][1])")
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

    /// The shirt's slack schedule (`shirt_slack` in the prep) hangs it from its
    /// shoulders: the collar band — the collar, its stand and its points, within 8 cm
    /// along the surface of the collar loop — and the cuffs — within 6 cm of the cuff
    /// loops — are hard skinned (0), so the folded collar follows the body as one thick
    /// piece and the rolled cuffs ride the forearm's animation without fighting the hand
    /// parts' tracking error; the yoke (the back and the shoulder tops within 12 cm below
    /// the collar band, not the chest) is held to 1 cm, which is what the shirt hangs
    /// from; the chest has 8 cm, the back 10, the hem band (the lowest 12 cm of the body
    /// panels) 12, the sleeves 5, the armhole band (within 6 cm of the sleeve seam, where
    /// the graded skin still stretches the edges most) 6; the buttoned front keeps its
    /// 5 mm. The counts are the cook's (2026-10-31, with the hem strip sewn into the
    /// proxy: 395 pins, 85 front, 345 yoke, 895 sleeve, 781 armhole, 499 chest, 565
    /// back, 430 hem) held within a quarter, and each
    /// region lies where its name says: engine x is Blender x, engine y the height,
    /// engine z minus Blender y (the body faces +z, the spine runs at z about -0.10).
    func testTheShirtSlackScheduleHangsItFromTheShoulders() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let p = shirt.positions
        var histogram: [Float: Int] = [:]
        for d in shirt.maxDistance { histogram[d, default: 0] += 1 }
        print("CoolZombie cloth shirt slack histogram: " + histogram.sorted { $0.key < $1.key }.map { String(format: "%.3f: %d", $0.key, $0.value) }.joined(separator: ", "))
        let expected: [(slack: Float, count: Int, name: String)] = [(0, 395, "collar band and cuffs"), (0.005, 85, "buttoned front"), (0.01, 345, "yoke"), (0.05, 895, "sleeves"),
                                                                    (0.06, 781, "armhole band"), (0.08, 499, "chest"), (0.10, 565, "back"), (0.12, 430, "hem band")]
        XCTAssertEqual(Set(histogram.keys), Set(expected.map(\.slack)), "the schedule's values")
        for region in expected {
            let count = histogram[region.slack] ?? 0
            XCTAssertGreaterThan(count, region.count * 3 / 4, "the \(region.name) has \(count) particles")
            XCTAssertLessThan(count, region.count * 5 / 4, "the \(region.name) has \(count) particles")
        }
        for (i, slack) in shirt.maxDistance.enumerated() {
            let x = p[i].x, y = p[i].y, z = p[i].z
            switch slack {
            case 0: XCTAssertTrue(y > 1.34 || (abs(x) > 0.40 && y < 1.06), "a pin at (\(x), \(y), \(z)), neither collar nor cuff")
            case 0.005: XCTAssertTrue(abs(x) < 0.02 && z > -0.06 && y < 1.36, "a buttoned-front particle at (\(x), \(y), \(z))")
            case 0.01: XCTAssertTrue(y > 1.36 && abs(x) < 0.23 && (z <= -0.10 + 1e-3 || y >= 1.40 - 1e-3), "a yoke particle at (\(x), \(y), \(z)): not the back nor a shoulder top")
            case 0.05: XCTAssertTrue(abs(x) > 0.12 && y < 1.37, "a sleeve particle at (\(x), \(y), \(z))")
            case 0.06: XCTAssertTrue(abs(x) < 0.29 && y > 1.17 && y < 1.44, "an armhole-band particle at (\(x), \(y), \(z))")
            case 0.08: XCTAssertTrue(z > -0.10 - 1e-3 && abs(x) < 0.19 && y > 0.95 && y < 1.41, "a chest particle at (\(x), \(y), \(z))")
            case 0.10: XCTAssertTrue(z <= -0.10 + 1e-3 && abs(x) < 0.19 && y > 0.94 && y < 1.40, "a back particle at (\(x), \(y), \(z))")
            case 0.12: XCTAssertTrue(y < 1.03 && abs(x) < 0.20, "a hem-band particle at (\(x), \(y), \(z))")
            default: XCTFail("slack \(slack) is not in the schedule")
            }
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

    /// The shirt's skin weights are graded across the seams between bones' regions
    /// (`grade_weight_seams` in the prep). The artist's automatic weights handed the shirt
    /// from one bone to the next across single edges — upperarm 0.98 to spine_02 0.73 a
    /// centimetre apart at the armhole, as sharply from spine_01 to spine_02 at the waist
    /// — so skinned with the arms forward those edges stretched to twenty times their
    /// length, and the cloth, keeping its rest lengths, sat 13 cm from its target under
    /// each arm. Graded, the L1 distance between the weight vectors of an edge's two
    /// particles stays under 0.8 on every edge of the shirt (it was 1.885 at the armhole,
    /// 1.78 at the collar, 1.65 at the waist; the 16-pass blur over every seam and the
    /// 200 more over the 12 cm around the armhole leave the worst edge at the waist, 0.675
    /// from spine_02 to spine_01, and 9 edges over 0.5), and the armhole band — the
    /// particles with the schedule's 6 cm — lies along the seam between the sleeves and
    /// the body panel: every one of them within 15 cm of an edge whose particles are
    /// dominated by an arm bone (an upper arm, a forearm) on one side and a body bone (a
    /// spine link, the neck, the pelvis, a clavicle) on the other. The prep measures the
    /// band from the artist's crisp seam before the grading, two chains of 125 and 85
    /// edges that meander from the shoulder down the flank (the stretch the band is for
    /// happens where the WEIGHTS hand over, not where a tailor's seam runs); graded, the
    /// dominant bone flips back and forth across the blurred 12 cm and the seam between
    /// dominants moves and zigzags, so 21 of the band's particles lie 10-13 cm from it
    /// (2026-10-31), which is why the bound here is loose. The trousers keep the
    /// artist's weights (they are not simulated yet); their jumps are printed for the
    /// record.
    func testTheShirtWeightsAreGradedAcrossTheSeamsAndTheArmholeBandLiesAlongTheSeam() throws {
        let cloth = try loadCloth()
        func jumps(_ g: ZombieClothAsset.Garment) -> [(jump: Float, a: Int, b: Int)] {
            var vectors = [[Float]](repeating: [Float](repeating: 0, count: g.jointPaths.count), count: g.particles.count)
            for (i, influences) in g.influences.enumerated() {
                for pair in influences { vectors[i][Int(pair[0])] = pair[1] }
            }
            return edges(of: g.triangles).undirected.map { e in
                (zip(vectors[e[0]], vectors[e[1]]).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }, e[0], e[1])
            }.sorted { $0.jump > $1.jump }
        }
        func name(_ g: ZombieClothAsset.Garment, _ particle: Int) -> String {
            String(g.jointPaths[g.dominantJoint[particle]].split(separator: "/").last ?? "")
        }
        for g in cloth.garments {
            let sorted = jumps(g)
            let p = g.positions
            let worst = sorted.prefix(5).map { String(format: "%.3f %@-%@ at (%.2f,%.2f,%.2f)", $0.jump, name(g, $0.a), name(g, $0.b), p[$0.a].x, p[$0.a].y, p[$0.a].z) }
            print("CoolZombie cloth \(g.name): weight jumps over 0.5 on \(sorted.filter { $0.jump > 0.5 }.count) of \(sorted.count) edges, over 0.3 on \(sorted.filter { $0.jump > 0.3 }.count); worst \(worst)")
            if g.name == "shirt" {
                XCTAssertLessThan(sorted[0].jump, 0.8, "the shirt's weights jump \(sorted[0].jump) across an edge: the seams are not graded")
                XCTAssertLessThan(sorted.filter { $0.jump > 0.5 }.count, 20, "too many shirt edges jump over 0.5")
            }
        }

        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let sleeve = ["upperarm_", "lowerarm_"], body = ["spine_", "neck_", "pelvis", "clavicle_"]
        func side(_ particle: Int) -> Int {
            let joint = name(shirt, particle)
            if sleeve.contains(where: { joint.hasPrefix($0) }) { return 1 }
            if body.contains(where: { joint.hasPrefix($0) }) { return -1 }
            return 0
        }
        let p = shirt.positions
        let seam = edges(of: shirt.triangles).undirected.filter { side($0[0]) * side($0[1]) < 0 }
        XCTAssertGreaterThan(seam.count, 50, "the sleeve seam was not found")
        func distanceToSeam(_ q: SIMD3<Float>) -> Float {
            var best = Float.greatestFiniteMagnitude
            for e in seam {
                let a = p[e[0]], ab = p[e[1]] - a
                let t = min(max(simd_dot(q - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
                best = min(best, simd_distance(q, a + ab * t))
            }
            return best
        }
        var banded = 0, stray = 0, beyondTen = 0, farthest: Float = 0, farthestAt = SIMD3<Float>.zero
        for (i, slack) in shirt.maxDistance.enumerated() where slack == 0.06 {
            banded += 1
            let d = distanceToSeam(p[i])
            if d > farthest { farthest = d; farthestAt = p[i] }
            if d > 0.10 { beyondTen += 1 }
            if d > 0.15 { stray += 1 }
        }
        print(String(format: "CoolZombie cloth shirt: %d sleeve seam edges between dominants, %d particles in the 6 cm armhole band, %d of them 10-15 cm from the seam, the farthest %.0f mm at (%.2f,%.2f,%.2f)",
                     seam.count, banded, beyondTen, farthest * 1000, farthestAt.x, farthestAt.y, farthestAt.z))
        XCTAssertGreaterThan(banded, 500, "the armhole band is too small")
        XCTAssertLessThan(banded, shirt.particles.count / 4, "the armhole band is a quarter of the shirt")
        XCTAssertEqual(stray, 0, "\(stray) particles farther than 15 cm from the sleeve seam have the band's 6 cm")
    }
}
