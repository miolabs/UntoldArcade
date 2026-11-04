//
//  ZombieCloth16kAssetTests.swift
//  CoolZombieKitTests
//
//  The second sidecar of `Docs/GPUCloth.md` (section 5, "Prep changes";
//  section 6, `ZombieClothAsset16kTests`): `Models/Zombie/Zombie.cloth16k.json`,
//  the same export's shirt cooked at about 16,000 particles for the GPU
//  solver — the 8.4 mm spacing that shows the 3-5 cm folds the drawn shell's
//  own 8.25 mm edge can show, where the 3,995 proxy's 17.5 mm median edge
//  could show nothing under 8 cm — beside the bundled `Zombie.cloth.json`,
//  which the Jolt arm keeps (at 16k Jolt is four times its 3.4 ms step).
//  The file is the phase-2 cook's; these tests hold it to what the 4k
//  sidecar's tests hold that one to (ZombieClothAssetTests: one piece, four
//  openings, the schedule's nine values each where its name says, the pins
//  and the armhole band in their ratios, the shell rebuilt by the binding,
//  the eleven hulls) with the counts re-pinned from this cook, and to what
//  the design added for phase 2 — a `restNormal` per particle, a `region`
//  index into a `regions` table, `planes` per collider and
//  `constraintCounts` for the solver's graph — read off the JSON itself,
//  so the keys are judged whether or not the kit's model decodes them yet.
//  Every test skips when the file is not bundled. Written 2026-11-04 against
//  the design's projections (15,994 particles, 29,783 triangles, edges
//  4.5-25.7 mm, about 47,700 edges and 168,000 CSR entries) and re-pinned
//  the same day from the cook as it landed (4,986,962 bytes, measured with
//  numpy over the file, scratchpad tests16k/measure16k.py): 15,979
//  particles and 31,681 triangles (the design's experiment stopped at
//  29,783; this cook's collapse left 1,900 more, 281 boundary edges), edges
//  4.52 / 6.86 / 8.79 / 10.63 / 29.11 mm (min, quartiles, max), 1,848 pins,
//  47,662 edges of which 5,222 pin-pin, 47,381 cross pairs of which 4,957,
//  42,440 + 42,424 constraints and 169,728 CSR entries (the design's
//  168,000 within 1 %), 22 entries at most on a particle; the schedule 1,848
//  / 329 / 271 / 1,057 / 1,995 / 2,173 / 2,390 / 1,731 / 4,185 for the pins,
//  the front, the wrist, the yoke, the chest, the back, the sleeves, the hem
//  and the armhole band (against 532 / 85 / 66 / 287 / 478 / 497 / 532 / 430
//  / 1,088 at 4k: 3.5 to 4.1 times, the bands that are measured along the
//  edges a little wider); 588 body-facing particles; the shell's 29,402
//  vertices rebuilt by the binding with 12,993 behind the proxy and the
//  farthest offset 10.14 mm (20.31 at 4k: the offsets shrank as the design
//  expected). The same cook rewrote the 4k sidecar with the same shirt
//  (every count of 2026-11-03 held) and, in BOTH files, the colliders with
//  the neck hull at 28 points instead of 35 and the right arm's at 38 and
//  32 instead of 37 and 34 — 438 points and 816 planes in all where the
//  design's figures were 446 and 832 — so the 4k hull tests are re-pinned
//  beside these.
//

import Foundation
import simd
import XCTest
@testable import CoolZombieKit
@testable import UntoldEngine

final class ZombieCloth16kAssetTests: XCTestCase {
    /// The 16k sidecar, decoded by the kit, or a skip.
    private func loadCloth() throws -> ZombieClothAsset {
        guard let cloth = ClothFixtures.sidecar(named: ClothFixtures.sidecar16kName) else {
            throw XCTSkip("Models/Zombie/\(ClothFixtures.sidecar16kName) is not bundled (the phase-2 cook)")
        }
        return cloth
    }

    /// The 16k sidecar as raw JSON, for the phase-2 keys the kit's model may
    /// not carry; or a skip.
    private func loadRaw() throws -> [String: Any] {
        guard let url = ClothFixtures.sidecarURL(named: ClothFixtures.sidecar16kName), FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Models/Zombie/\(ClothFixtures.sidecar16kName) is not bundled (the phase-2 cook)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "the sidecar is not a JSON object")
    }

    /// The raw shirt garment's dictionary.
    private func rawShirt(_ raw: [String: Any]) throws -> [String: Any] {
        let garments = try XCTUnwrap(raw["garments"] as? [[String: Any]], "no garments")
        return try XCTUnwrap(garments.first { ($0["name"] as? String) == "shirt" }, "no garment named shirt")
    }

    /// The exported mesh's vertex positions, as the 4k asset tests read them.
    private func loadModelPositions() throws -> [SIMD3<Float>]? {
        guard let url = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = try NativeFormatLoader().loadAssetSync(from: url)
        guard let primitive = asset.nodes.flatMap(\.primitives).first else { return nil }
        let stride = primitive.vertexLayout.stride
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(primitive.vertexCount)
        primitive.vertexData.withUnsafeBytes { raw in
            for v in 0 ..< primitive.vertexCount {
                let p = raw.baseAddress!.advanced(by: v * stride).assumingMemoryBound(to: Float.self)
                positions.append(SIMD3(p[0], p[1], p[2]))
            }
        }
        return positions
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

    /// The boundary loops of a triangle list, every boundary vertex on exactly
    /// two boundary edges or the count means nothing (ZombieClothAssetTests).
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

    // MARK: - The file and its garments

    /// The second sidecar decodes with the kit's model as the first does —
    /// the shirt (named `shirt`, since `ZombieCloth.Configuration.garments`
    /// simulates by that name and the harness looks it up; the design's
    /// `shirt16k` is the prep's internal name) and the trousers, the same
    /// back-stop, the same source file, the same export — and the shirt is
    /// about four times the 4k proxy: the design's `refine_proxy` collapses
    /// the once-subdivided outer layer to 16,000, and the cook of
    /// 2026-11-04 wrote 15,979 particles and 31,681 triangles (the design's
    /// experiment measured 15,994 and 29,783), held within 2 % of the cook.
    /// The file stays under the prep's 8 MB warning (4,986,962 bytes; 4.19 MB
    /// projected).
    func testTheSecondSidecarDecodesWithFourTimesTheParticles() throws {
        let cloth = try loadCloth()
        XCTAssertEqual(cloth.garments.map(\.name), ["shirt", "trousers"])
        for g in cloth.garments {
            XCTAssertEqual(g.influences.count, g.particles.count, g.name)
            XCTAssertEqual(g.maxDistance.count, g.particles.count, g.name)
            XCTAssertEqual(g.dominantJoint.count, g.particles.count, g.name)
            XCTAssertEqual(g.pinCount, g.maxDistance.filter { $0 == 0 }.count, g.name)
            XCTAssertEqual(g.backstop, 0.001, accuracy: 1e-6, g.name)
            XCTAssertEqual(g.sourceFile, "Zombie_new_cloth.blend", g.name)
            for p in g.particles { XCTAssertEqual(p.count, 3, g.name) }
            for t in g.triangles { XCTAssertEqual(t.count, 3, g.name); XCTAssertTrue(t.allSatisfy { $0 >= 0 && $0 < g.particles.count }, g.name) }
        }
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        XCTAssertEqual(Double(shirt.particles.count), 15979, accuracy: 15979 * 0.02, "the shirt has \(shirt.particles.count) particles, not the cook's 15,979 within 2 %")
        XCTAssertEqual(Double(shirt.triangles.count), 31681, accuracy: 31681 * 0.02, "the shirt has \(shirt.triangles.count) triangles, not the cook's 31,681 within 2 %")
        if let four = ClothFixtures.asset?.garment(named: "shirt") {
            XCTAssertGreaterThan(shirt.particles.count, four.particles.count * 3, "the 16k shirt is not three times the 4k one's \(four.particles.count)")
            XCTAssertEqual(shirt.jointPaths, four.jointPaths, "the two cooks skin the shirt to different joints")
            XCTAssertEqual(cloth.garment(named: "trousers")?.particles.count, ClothFixtures.asset?.garment(named: "trousers")?.particles.count, "the trousers differ between the cooks")
        }
        let bytes = try Data(contentsOf: XCTUnwrap(ClothFixtures.sidecarURL(named: ClothFixtures.sidecar16kName))).count
        XCTAssertLessThan(bytes, 8 << 20, "the 16k sidecar is \(bytes) B, over the prep's 8 MB warning")
        print("CoolZombie cloth 16k: \(shirt.particles.count) particles, \(shirt.triangles.count) triangles, \(shirt.pinCount) pins, \(shirt.jointPaths.count) joints; \(bytes) B")
    }

    /// What the game draws is still the artist's shell: the 16k shirt
    /// carries a render binding of the same shell (the same vertex count and
    /// rest positions as the 4k binding's, every one on an exported vertex
    /// within 0.2 mm), the same 21 rigid islands (seven buttons of 410
    /// vertices, fourteen bits of 35), and the binding rebuilds the shell at
    /// the bind pose from the 16k particles within a tenth of a millimetre:
    /// the inner layer still behind the proxy, the islands each on one
    /// triangle, no shell vertex hanging more than a centimetre below its
    /// triangle's lowest corner nor 25 mm from it — the design expects the
    /// offsets to shrink, since more shell vertices now sit near a proxy
    /// vertex, and the cook of 2026-11-04 halves the farthest: 10.14 mm
    /// against 20.31 at 4k, with 12,993 vertices behind the proxy against
    /// 11,774 (the figures are printed; the bounds stay the 4k test's).
    func testTheRenderBindingRebuildsTheShellFromTheFinerProxy() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let render = try XCTUnwrap(shirt.render, "the 16k shirt has no render binding")
        XCTAssertNil(cloth.garment(named: "trousers")?.render)
        XCTAssertTrue(render.isConsistent(triangles: shirt.triangles.count), "the render arrays disagree")
        XCTAssertEqual(render.vertexCount, 29402, "the shell is the artist's 29,402 vertices in both cooks")
        if let four = ClothFixtures.asset?.garment(named: "shirt")?.render {
            XCTAssertEqual(render.vertexCount, four.vertexCount)
            var worst: Float = 0
            for (a, b) in zip(render.restPositionVectors, four.restPositionVectors) { worst = max(worst, simd_distance(a, b)) }
            XCTAssertLessThan(worst, 1e-5, "the shell's rest positions differ between the cooks by \(worst) m")
            XCTAssertEqual(render.rigidIslands, four.rigidIslands, "the rigid islands differ between the cooks")
        }
        let runs = render.rigidIslands.map { $0[0] ..< $0[0] + $0[1] }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertEqual(runs.count, 21)
        XCTAssertEqual(runs.map(\.count).sorted(), Array(repeating: 35, count: 14) + Array(repeating: 410, count: 7))
        for (v, w) in render.barycentricVectors.enumerated() {
            XCTAssertEqual(w.x + w.y + w.z, 1, accuracy: 1e-4, "shell vertex \(v): barycentric sum")
            XCTAssertTrue(w.min() >= 0 && w.max() <= 1, "shell vertex \(v): barycentric \(w) outside its triangle")
        }
        let p = shirt.positions
        let rest = render.restPositionVectors, bary = render.barycentricVectors, offset = render.offsetVectors
        let shellProper = render.rigidIslands.map { $0[0] }.min() ?? render.vertexCount
        var worstPosition: Float = 0, farthestOffset: Float = 0, inner = 0, lowest: Float = 0, hanging = 0, onVertex = 0
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
                if simd_length(o) < 1e-4, w.max() > 1 - 1e-4 { onVertex += 1 }
                let below = min(a.y, b.y, c.y) - rest[v].y
                if below > 0.002 { hanging += 1 }
                lowest = max(lowest, below)
            }
        }
        XCTAssertLessThan(worstPosition, 1e-4, "a shell vertex rebuilds \(worstPosition) m off its rest position")
        XCTAssertGreaterThan(inner, render.vertexCount / 4, "the inner layer (vertices more than 0.5 mm behind the proxy) is \(inner) vertices")
        XCTAssertLessThan(lowest, 0.010, "a shell vertex hangs \(lowest) m below its triangle's lowest corner")
        XCTAssertLessThan(farthestOffset, 0.025, "a shell vertex sits \(farthestOffset) m from its triangle")
        for island in render.rigidIslands {
            let triangles = Set(render.triangle[island[0] ..< island[0] + island[1]])
            XCTAssertEqual(triangles.count, 1, "a rigid island of \(island[1]) vertices binds to \(triangles.count) triangles")
        }
        print(String(format: "CoolZombie cloth 16k render binding: %d vertices rebuilt within %.4f mm; %d behind the proxy; %d of the shell proper on a proxy vertex; the shell proper at most %.1f mm from its triangle, %d vertices more than 2 mm below their triangle's lowest corner, the lowest %.1f mm",
                     render.vertexCount, worstPosition * 1000, inner, onVertex, farthestOffset * 1000, hanging, lowest * 1000))
        // The shell is in the export, as before.
        guard let model = try loadModelPositions() else { throw XCTSkip("Models/Zombie is not bundled") }
        for g in cloth.garments { XCTAssertEqual(g.exportedVertexCount, model.count, "\(g.name): the sidecar was cooked with another export") }
        let cell: Float = 0.001
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        var grid: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for q in model { grid[key(q), default: []].append(q) }
        var unmatched = 0
        for q in rest {
            let k = key(q)
            var found = false
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 where !found {
                found = (grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? []).contains { simd_distance($0, q) <= 0.0002 }
            } } }
            if !found { unmatched += 1 }
        }
        XCTAssertEqual(unmatched, 0, "\(unmatched) shell vertices match no exported vertex within 0.2 mm")
    }

    // MARK: - The proxy

    /// The finer proxy is still one piece with the shirt's four openings (the
    /// collar, the hem, two cuffs), pinned at the collar band and the cuffs
    /// (300 pins at least and under a quarter of the particles, as the 4k
    /// rule has it), the schedule's nine slack values and no other, the
    /// buttoned front a strip down the centre line on the body's front, and
    /// its edges between 4 and 30 mm (the design's `report_proxy` limits for
    /// the shirt16k, 0.004 / 0.030 / 10 degrees; the 4k file's are 8-40 mm):
    /// the cook's collapse targets `min_edge` 4.5 mm and `max_edge` 18; the
    /// design's experiment measured 4.5 / 5.5 / 8.4 / 12.1 / 25.7 mm for the
    /// minimum, the quartiles and the maximum, the cook of 2026-11-04 4.52 /
    /// 6.86 / 8.79 / 10.63 / 29.11 over 47,662 edges (281 boundary) with
    /// 1,848 pins, 329 in the buttoned front and 588 body-facing particles.
    /// Wound one way: an edge shared by two faces runs opposite ways in them.
    func testTheFinerProxyIsOnePieceWithItsOpeningsPinsAndSpacing() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let e = edges(of: shirt.triangles)
        XCTAssertEqual(islandCount(particles: shirt.particles.count, edges: e.undirected), 1, "the 16k shirt is not one piece")
        let loops = boundaryLoopCount(triangles: shirt.triangles, "shirt 16k")
        XCTAssertEqual(loops, 4, "the 16k shirt has \(loops) boundary loops, not the collar, the hem and two cuffs")
        XCTAssertGreaterThanOrEqual(shirt.pinCount, 300, "too few pins")
        XCTAssertLessThan(shirt.pinCount, shirt.particles.count / 4, "most of the garment is pinned")
        XCTAssertEqual(Set(shirt.maxDistance), Set([Float(0), 0.005, 0.03, 0.07, 0.09, 0.10, 0.11, 0.12, 0.15]), "the schedule's values")
        let p = shirt.positions
        var lengths: [Float] = []
        lengths.reserveCapacity(e.undirected.count)
        for edge in e.undirected { lengths.append(simd_distance(p[edge[0]], p[edge[1]])) }
        lengths.sort()
        let shortest = lengths.first ?? 0, longest = lengths.last ?? 0
        let median = lengths[lengths.count / 2], q1 = lengths[lengths.count / 4], q3 = lengths[lengths.count * 3 / 4]
        print(String(format: "CoolZombie cloth 16k shirt: %d particles, %d triangles, %d edges %.1f / %.1f / %.1f / %.1f / %.1f mm (min, quartiles, max), %d boundary loops, %d pins",
                     shirt.particles.count, shirt.triangles.count, lengths.count, shortest * 1000, q1 * 1000, median * 1000, q3 * 1000, longest * 1000, loops, shirt.pinCount))
        XCTAssertGreaterThanOrEqual(shortest, 0.004, "an edge of \(shortest * 1000) mm")
        XCTAssertLessThanOrEqual(longest, 0.030, "an edge of \(longest * 1000) mm")
        XCTAssertLessThan(median, 0.012, "the median edge is \(median * 1000) mm: not the 8.4 mm spacing the folds need")
        let sameWay = e.directed.values.filter { $0 > 1 }.count
        XCTAssertEqual(sameWay, 0, "\(sameWay) edges run the same way in two faces")
        for (i, d) in shirt.maxDistance.enumerated() where d == 0 {
            let q = p[i]
            XCTAssertTrue(q.y > 1.34 || (abs(q.x) > 0.40 && q.y < 1.07), "a pin at (\(q.x), \(q.y), \(q.z)), neither collar nor cuff")
        }
        let front = shirt.maxDistance.indices.filter { shirt.maxDistance[$0] == 0.005 }
        XCTAssertGreaterThan(front.count, 200, "the buttoned front has \(front.count) particles")
        for i in front {
            XCTAssertLessThan(abs(p[i].x), 0.02, "a buttoned-front particle at x \(p[i].x)")
            XCTAssertGreaterThan(p[i].z, -0.06, "a buttoned-front particle behind the body at z \(p[i].z)")
        }
        // The faces point away from the body on the whole, as the 4k test holds.
        var outward = 0, inward = 0
        for t in shirt.triangles {
            let a = p[t[0]], b = p[t[1]], c = p[t[2]]
            let n = simd_cross(b - a, c - a), centre = (a + b + c) / 3
            let radial = SIMD3<Float>(centre.x, 0, centre.z)
            guard simd_length(radial) > 0.03 else { continue }
            if simd_dot(n, radial) > 0 { outward += 1 } else { inward += 1 }
        }
        XCTAssertGreaterThan(outward, inward * 3, "the faces do not point away from the body (\(outward) out, \(inward) in)")
        XCTAssertLessThan(shirt.bodyFacingParticles.count, shirt.particles.count / 10, "\(shirt.bodyFacingParticles.count) particles face the body")
        XCTAssertEqual(Set(shirt.bodyFacingParticles).count, shirt.bodyFacingParticles.count, "a body-facing particle listed twice")
        print("CoolZombie cloth 16k shirt: \(shirt.bodyFacingParticles.count) of \(shirt.particles.count) particles face the body; \(outward) faces point outward, \(inward) inward")
    }

    /// The slack schedule on the finer proxy, by value: the same nine regions
    /// (`shirt_slack` in the prep, metres throughout, so no change for the
    /// cook) each lying where the 4k test says its name does — the pins at
    /// the collar and the cuffs, the wrist band at the forearms' ends, the
    /// buttoned front on the centre line, the yoke on the back and the
    /// shoulder tops, the sleeves out past |x| 0.12, the armhole band at the
    /// shoulders, the chest in front of the torso's axis, the back behind it,
    /// the hem band in the lowest 12 cm — with the counts of THIS cook held
    /// within a quarter, as the 4k counts are. The bands are measured along
    /// the proxy's edges (Dijkstra, which overestimates the geodesic by a
    /// few per cent and so shifts a band outward a little on a finer mesh),
    /// so the counts are not four times the 4k's exactly: the cook of
    /// 2026-11-04 (measured with numpy over the file) gives 1,848 pins, 329
    /// in the buttoned front, 271 in the wrist band, 1,057 in the yoke,
    /// 2,390 sleeve, 4,185 armhole band (2,214 left, 1,971 right), 1,995
    /// chest, 2,173 back and 1,731 hem — 3.5 to 4.1 times the 4k's 532 /
    /// 85 / 66 / 287 / 532 / 1,088 / 478 / 497 / 430 — and the rows below
    /// are those, held within a quarter (`measured` true; a projected row
    /// would be held within a half).
    func testTheSlackScheduleOnTheFinerProxy() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let p = shirt.positions
        var histogram: [Float: Int] = [:]
        for d in shirt.maxDistance { histogram[d, default: 0] += 1 }
        print("CoolZombie cloth 16k shirt slack histogram: " + histogram.sorted { $0.key < $1.key }.map { String(format: "%.3f: %d", $0.key, $0.value) }.joined(separator: ", "))
        let expected: [(slack: Float, count: Int, name: String, measured: Bool)] = [
            (0, 1848, "collar band and cuffs", true), (0.005, 329, "buttoned front", true), (0.03, 271, "wrist band", true), (0.07, 1057, "yoke", true),
            (0.11, 2390, "sleeves", true), (0.15, 4185, "armhole band", true), (0.09, 1995, "chest", true), (0.10, 2173, "back", true), (0.12, 1731, "hem band", true),
        ]
        XCTAssertEqual(Set(histogram.keys), Set(expected.map(\.slack)), "the schedule's values")
        for region in expected {
            let count = histogram[region.slack] ?? 0
            let margin = region.measured ? 4 : 2
            XCTAssertGreaterThan(count, region.count * (margin - 1) / margin, "the \(region.name) has \(count) particles against \(region.count) \(region.measured ? "measured" : "projected")")
            XCTAssertLessThan(count, region.count * (margin + 1) / margin, "the \(region.name) has \(count) particles against \(region.count) \(region.measured ? "measured" : "projected")")
        }
        for (i, slack) in shirt.maxDistance.enumerated() {
            let x = p[i].x, y = p[i].y, z = p[i].z
            switch slack {
            case 0: XCTAssertTrue(y > 1.34 || (abs(x) > 0.40 && y < 1.07), "a pin at (\(x), \(y), \(z)), neither collar nor cuff")
            case 0.03: XCTAssertTrue(abs(x) > 0.38 && abs(x) < 0.47 && y > 1.00 && y < 1.09, "a wrist-band particle at (\(x), \(y), \(z))")
            case 0.005: XCTAssertTrue(abs(x) < 0.02 && z > -0.06 && y < 1.36, "a buttoned-front particle at (\(x), \(y), \(z))")
            case 0.07: XCTAssertTrue(y > 1.36 && abs(x) < 0.23 && (z <= -0.10 + 1e-3 || y >= 1.40 - 1e-3), "a yoke particle at (\(x), \(y), \(z)): not the back nor a shoulder top")
            case 0.11: XCTAssertTrue(abs(x) > 0.12 && y < 1.37, "a sleeve particle at (\(x), \(y), \(z))")
            case 0.15: XCTAssertTrue(abs(x) < 0.31 && y > 1.14 && y < 1.45, "an armhole-band particle at (\(x), \(y), \(z))")
            case 0.09: XCTAssertTrue(z > -0.10 - 1e-3 && abs(x) < 0.19 && y > 0.95 && y < 1.41, "a chest particle at (\(x), \(y), \(z))")
            case 0.10: XCTAssertTrue(z <= -0.10 + 1e-3 && abs(x) < 0.19 && y > 0.94 && y < 1.42, "a back particle at (\(x), \(y), \(z))")
            case 0.12: XCTAssertTrue(y < 1.03 && abs(x) < 0.20, "a hem-band particle at (\(x), \(y), \(z))")
            default: XCTFail("slack \(slack) is not in the schedule")
            }
        }
        // The armhole band rings each sleeve as the 4k test holds: over 500
        // particles, under three in ten of the shirt, the two rings within
        // an eighth of each other, each at a shoulder.
        var left: [SIMD3<Float>] = [], right: [SIMD3<Float>] = []
        for (i, slack) in shirt.maxDistance.enumerated() where slack == 0.15 {
            if p[i].x < 0 { left.append(p[i]) } else { right.append(p[i]) }
        }
        let banded = left.count + right.count
        print("CoolZombie cloth 16k shirt: \(banded) particles in the armhole band, \(left.count) left and \(right.count) right")
        XCTAssertGreaterThan(banded, 500, "the armhole band is too small")
        XCTAssertLessThan(banded, shirt.particles.count * 3 / 10, "the armhole band is \(banded) of the shirt's \(shirt.particles.count) particles: more than three in ten")
        XCTAssertLessThan(abs(left.count - right.count), banded / 8, "the band's two rings differ: \(left.count) left, \(right.count) right")
        for (side, ring) in [("left", left), ("right", right)] {
            let centroid = ring.reduce(SIMD3<Float>.zero, +) / Float(max(ring.count, 1))
            XCTAssertTrue(abs(centroid.x) > 0.14 && abs(centroid.x) < 0.26, "the \(side) ring's centroid is at x \(centroid.x), not at a shoulder")
            XCTAssertTrue(centroid.y > 1.22 && centroid.y < 1.40, "the \(side) ring's centroid is at height \(centroid.y), not at an armhole")
        }
    }

    /// The skin weights are the exported skeleton's, four at most and
    /// summing to one, nothing of the shirt follows a hand, and the bind
    /// matrices are the model's: the finer proxy inherits the body's weights
    /// through `transfer_weights` as the 4k one does (`recap_influences`
    /// handles the subdivided vertices that inherit five).
    func testTheFinerProxyCarriesTheBodysWeights() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let hands = ["hand_", "thumb_", "index_", "middle_", "ring_", "pinky_"]
        for path in shirt.jointPaths {
            let joint = String(path.split(separator: "/").last ?? "")
            XCTAssertFalse(hands.contains { joint.hasPrefix($0) }, "the 16k shirt weighs on \(path)")
        }
        var histogram = [Int](repeating: 0, count: 6)
        for (i, influences) in shirt.influences.enumerated() {
            XCTAssertTrue((1 ... 4).contains(influences.count), "particle \(i): \(influences.count) influences")
            histogram[min(influences.count, 5)] += 1
            let sum = influences.reduce(Float(0)) { $0 + $1[1] }
            XCTAssertEqual(sum, 1, accuracy: 1e-3, "particle \(i)")
            for pair in influences {
                XCTAssertEqual(pair.count, 2)
                let joint = Int(pair[0])
                XCTAssertTrue(joint >= 0 && joint < shirt.jointPaths.count, "particle \(i): joint \(joint)")
                XCTAssertGreaterThan(pair[1], 0, "particle \(i)")
            }
            let heaviest = influences.max { $0[1] < $1[1] }.map { Int($0[0]) }
            XCTAssertEqual(shirt.dominantJoint[i], heaviest, "particle \(i): dominant joint")
        }
        XCTAssertEqual(shirt.bindJointWorldMatrices.count, shirt.jointPaths.count)
        if let four = ClothFixtures.asset?.garment(named: "shirt") {
            for (a, b) in zip(shirt.bindMatrices, four.bindMatrices) {
                for c in 0 ..< 4 { XCTAssertEqual(simd_distance(a[c], b[c]), 0, accuracy: 1e-5, "the bind matrices differ between the cooks") }
            }
        }
        print("CoolZombie cloth 16k shirt: influences per particle 1: \(histogram[1]), 2: \(histogram[2]), 3: \(histogram[3]), 4: \(histogram[4])")
    }

    // MARK: - The phase-2 keys

    /// The design's phase-2 additions to the sidecar are there to be read:
    /// per particle a `restNormal` and a `region`, a `regions` name table,
    /// `planes` on every collider and `constraintCounts` on the shirt — the
    /// runtime keeps computing planes and normals when a sidecar lacks them,
    /// so this test alone says whether the cook wrote them; the tests below
    /// skip on the keys they need.
    func testTheCookWroteThePhaseTwoKeys() throws {
        let raw = try loadRaw()
        let shirt = try rawShirt(raw)
        let particles = try XCTUnwrap(shirt["particles"] as? [[Any]]).count
        let missing = ["restNormal", "region", "regions", "constraintCounts"].filter { shirt[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "the 16k shirt lacks \(missing)")
        if let normals = shirt["restNormal"] as? [[Any]] { XCTAssertEqual(normals.count, particles, "one restNormal per particle") }
        if let regions = shirt["region"] as? [Any] { XCTAssertEqual(regions.count, particles, "one region per particle") }
        let colliders = try XCTUnwrap(raw["colliders"] as? [[String: Any]], "no colliders")
        XCTAssertEqual(colliders.count, 11)
        let withoutPlanes = colliders.filter { $0["planes"] == nil }.compactMap { $0["joint"] as? String }
        XCTAssertTrue(withoutPlanes.isEmpty, "colliders without planes: \(withoutPlanes)")
        print("CoolZombie cloth 16k keys: shirt \(shirt.keys.sorted()); collider \(colliders.first?.keys.sorted() ?? [])")
    }

    /// `restNormal`: a unit normal per particle (within 1e-3), the
    /// area-weighted normal of the faces around it as the solver computes
    /// its own at attach (`GPUClothSolver.areaWeightedNormals`): the two
    /// agree within 5 degrees on at least 99 % of the particles (the rest are
    /// the rims and the body-facing cuffs, where the prep's and the kit's
    /// weightings can part), and the normals point away from the body on the
    /// whole as the faces do.
    func testTheRestNormalsAreUnitAndTheSolversOwn() throws {
        let raw = try loadRaw()
        let shirt = try rawShirt(raw)
        guard let rows = shirt["restNormal"] as? [[NSNumber]] else { throw XCTSkip("the cook wrote no restNormal") }
        let cloth = try loadCloth()
        let garment = try XCTUnwrap(cloth.garment(named: "shirt"))
        XCTAssertEqual(rows.count, garment.particles.count)
        let normals = rows.map { SIMD3<Float>($0[0].floatValue, $0[1].floatValue, $0[2].floatValue) }
        let faces = garment.triangles.map { SIMD3<UInt32>(UInt32($0[0]), UInt32($0[1]), UInt32($0[2])) }
        let own = GPUClothSolver.areaWeightedNormals(faces: faces, positions: garment.positions)
        var worstLength: Float = 0, agreeing = 0, worstAngle: Float = 0
        for (n, m) in zip(normals, own) {
            worstLength = max(worstLength, abs(simd_length(n) - 1))
            let angle = acos(min(1, max(-1, simd_dot(simd_normalize(n), m)))) * 180 / .pi
            if angle < 5 { agreeing += 1 }
            worstAngle = max(worstAngle, angle)
        }
        XCTAssertLessThan(worstLength, 1e-3, "a restNormal is \(worstLength) off unit length")
        XCTAssertGreaterThan(Float(agreeing) / Float(normals.count), 0.99, "\(normals.count - agreeing) restNormals differ from the solver's own by 5 degrees or more")
        print(String(format: "CoolZombie cloth 16k restNormal: %d normals within %.1e of unit, %d within 5 degrees of the solver's area-weighted normal, the worst %.1f degrees apart", normals.count, worstLength, agreeing, worstAngle))
    }

    /// `region` and `regions`: every particle's index names a region of the
    /// table, the table names the schedule's bands (`SLACK`'s keys: collar,
    /// cuff, wrist, placket, yoke, sleeve, armhole, chest, back, hem), and
    /// every particle of one region carries one slack value — the table is
    /// the schedule by name, the slack the schedule by value, and they agree.
    func testTheRegionsNameTheSchedulesBands() throws {
        let raw = try loadRaw()
        let shirt = try rawShirt(raw)
        guard let region = shirt["region"] as? [NSNumber], let regions = shirt["regions"] as? [String] else { throw XCTSkip("the cook wrote no region table") }
        let cloth = try loadCloth()
        let garment = try XCTUnwrap(cloth.garment(named: "shirt"))
        XCTAssertEqual(region.count, garment.particles.count)
        let known: Set<String> = ["collar", "cuff", "wrist", "placket", "yoke", "sleeve", "armhole", "chest", "back", "hem"]
        XCTAssertTrue(Set(regions).isSubset(of: known), "regions not in the schedule: \(Set(regions).subtracting(known))")
        var slackByRegion: [Int: Set<Float>] = [:]
        var counts: [Int: Int] = [:]
        for (i, r) in region.enumerated() {
            let index = r.intValue
            XCTAssertTrue(regions.indices.contains(index), "particle \(i): region \(index) is not in the table of \(regions.count)")
            slackByRegion[index, default: []].insert(garment.maxDistance[i])
            counts[index, default: 0] += 1
        }
        for (index, slacks) in slackByRegion {
            XCTAssertEqual(slacks.count, 1, "the \(regions.indices.contains(index) ? regions[index] : "?") region carries \(slacks.count) slack values: \(slacks.sorted())")
        }
        print("CoolZombie cloth 16k regions: " + regions.indices.map { "\(regions[$0]) \(counts[$0] ?? 0) (slack \(slackByRegion[$0]?.first.map { String(format: "%.3f", $0) } ?? "-"))" }.joined(separator: ", "))
    }

    /// `planes` on each of the eleven colliders — the hull's faces as
    /// [n.x, n.y, n.z, d] quadruples in the joint's frame (the design's form;
    /// the day's first cook wrote them flat, as it writes the points, and
    /// both are read), unit normals, every one of the hull's points inside all
    /// of them within 1e-5 m — so the runtime can skip the brute force at
    /// attach; the kit's own `HullPlaneSet` over the same points gives the
    /// same planes, the same count (the prep's `hull_planes` takes the
    /// convex hull's faces, the kit every enclosing triple deduplicated at
    /// 1e-4, which coincide on a hull in general position: 87 / 83 / 82 /
    /// 88 / 52 / 84 / 82 / 66 / 72 / 60 / 60 = 816 on the cook of
    /// 2026-11-04, whose neck hull has 28 points and the right arm's 38 and
    /// 32; the 4k cook of the day before had 66 / 70 / 64 there on 35, 37
    /// and 34 points, 832 in all), and the points are the 4k file's, since
    /// the same cook writes both (the design keeps the colliders).
    func testTheColliderPlanesEncloseTheirPoints() throws {
        let raw = try loadRaw()
        let colliders = try XCTUnwrap(raw["colliders"] as? [[String: Any]], "no colliders")
        let cloth = try loadCloth()
        let decoded = try XCTUnwrap(cloth.colliders)
        XCTAssertEqual(decoded.count, 11)
        XCTAssertEqual(decoded.map { String($0.joint.split(separator: "/").last ?? "") }, ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "clavicle_l", "clavicle_r", "upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r"])
        if let four = ClothFixtures.asset?.colliders { XCTAssertEqual(decoded, four, "the colliders differ between the cooks") }
        let expected = [87, 83, 82, 88, 52, 84, 82, 66, 72, 60, 60]
        var written = 0, kit = 0, points = 0
        var counts: [String] = []
        for (index, collider) in colliders.enumerated() {
            let joint = String((collider["joint"] as? String ?? "").split(separator: "/").last ?? "")
            // The design's quadruples, or the flat list an earlier cook of
            // the day wrote (the points are flat too).
            let rows: [SIMD4<Float>]
            if let nested = collider["planes"] as? [[NSNumber]] {
                XCTAssertTrue(nested.allSatisfy { $0.count == 4 }, "\(joint): a plane is not four numbers")
                rows = nested.filter { $0.count == 4 }.map { SIMD4<Float>($0[0].floatValue, $0[1].floatValue, $0[2].floatValue, $0[3].floatValue) }
            } else if let flat = collider["planes"] as? [NSNumber] {
                XCTAssertEqual(flat.count % 4, 0, "\(joint): the planes are not quadruples")
                rows = stride(from: 0, to: flat.count - 3, by: 4).map { SIMD4<Float>(flat[$0].floatValue, flat[$0 + 1].floatValue, flat[$0 + 2].floatValue, flat[$0 + 3].floatValue) }
            } else {
                throw XCTSkip("the cook wrote no planes on \(joint)")
            }
            let hullPoints = decoded[index].pointVectors
            points += hullPoints.count
            let hull = try XCTUnwrap(GPUClothSolver.HullPlaneSet(points: hullPoints, joint: index, vertexRadius: 0.003))
            var worstInside: Float = -.greatestFiniteMagnitude, farthestFromKit: Float = 0
            for row in rows {
                let n = SIMD3<Float>(row.x, row.y, row.z), d = row.w
                XCTAssertEqual(simd_length(n), 1, accuracy: 1e-4, "\(joint): a plane's normal is not unit")
                for p in hullPoints { worstInside = max(worstInside, simd_dot(n, p) + d) }
                // The nearest of the kit's planes, by normal and offset.
                let nearest = hull.planes.map { simd_length($0 - row) }.min() ?? .greatestFiniteMagnitude
                farthestFromKit = max(farthestFromKit, nearest)
            }
            XCTAssertLessThan(worstInside, 1e-5, "\(joint): a hull point reads \(worstInside) m outside one of the written planes")
            XCTAssertEqual(rows.count, hull.planeCount, "\(joint): \(rows.count) planes written, the kit builds \(hull.planeCount)")
            XCTAssertEqual(rows.count, expected[index], "\(joint): \(rows.count) planes, \(expected[index]) measured off the cook of 2026-11-04")
            XCTAssertLessThan(farthestFromKit, 1e-3, "\(joint): a written plane is \(farthestFromKit) from every plane the kit builds")
            written += rows.count; kit += hull.planeCount
            counts.append("\(joint) \(rows.count)/\(hull.planeCount) on \(hullPoints.count) points")
        }
        XCTAssertEqual(written, 816)
        XCTAssertEqual(points, 438)
        print("CoolZombie cloth 16k planes (written/kit): \(counts.joined(separator: ", ")); \(written) written, \(kit) in the kit, over \(points) points")
    }

    /// `constraintCounts` — the cook's own count of the solver's graph,
    /// written under the kit's names rather than the design's three
    /// (`edges`, `bendPairs`, `boundaryEdges`, `pinPinEdgesDropped`,
    /// `pinPinBendPairsDropped`, `stretchConstraints`, `bendConstraints`,
    /// `entries`, `maxEntriesPerParticle`; the design's `pinPinDropped` is
    /// the two drops apart) — equals what the kit builds from the same faces
    /// at attach (`GPUClothSolver.ConstraintGraph`, Jolt's
    /// `CreateConstraints` set: one constraint per unique edge, one across
    /// every interior edge, none between two pins), key for key, and the
    /// graph is the size the design budgeted for: 47,662 edges (281
    /// boundary; the design's Euler estimate 47,726), 47,381 cross pairs,
    /// 5,222 and 4,957 pin-pin dropped (11 % and 10 %; 12 % at 4k), 42,440 +
    /// 42,424 constraints, 169,728 CSR entries (the design's 168,000 within
    /// 1 %), 22 entries at most on a particle as at 4k — measured with numpy
    /// over the cook of 2026-11-04 and pinned (the 4k's are 11,849 / 11,707
    /// / 1,424 + 1,282 / 41,700).
    func testTheConstraintCountsMatchTheKitsGraph() throws {
        let cloth = try loadCloth()
        let shirt = try XCTUnwrap(cloth.garment(named: "shirt"))
        let faces = shirt.triangles.map { SIMD3<UInt32>(UInt32($0[0]), UInt32($0[1]), UInt32($0[2])) }
        let graph = GPUClothSolver.ConstraintGraph(faces: faces, positions: shirt.positions, inverseMasses: shirt.maxDistance.map { $0 == 0 ? 0 : 20000 }, maxDistance: shirt.maxDistance)
        print("cloth gpu graph 16k: \(graph.edgeCount) edges (\(graph.boundaryEdgeCount) boundary, \(graph.pinPinEdgesDropped) pin-pin dropped), \(graph.bendPairCount) cross pairs (\(graph.pinPinBendPairsDropped) pin-pin dropped, \(graph.shearPairCount) shear), \(graph.stretchConstraintCount) + \(graph.bendConstraintCount) constraints, \(graph.entryCount) entries, degree \(graph.maxEntriesPerParticle) at most and \(String(format: "%.2f", graph.meanEntriesPerParticle)) on average, stretch rest \(String(format: "%.4f-%.4f", graph.restLengthRange.lowerBound, graph.restLengthRange.upperBound)) m, regions \(graph.regionSlack)")
        XCTAssertEqual(graph.particleCount, shirt.particles.count)
        XCTAssertEqual(Int(graph.offsets.last ?? 0), graph.entryCount)
        XCTAssertEqual(graph.entryCount, 2 * (graph.stretchConstraintCount + graph.bendConstraintCount))
        XCTAssertEqual(graph.edgeCount, 47662, "unique edges")
        XCTAssertEqual(graph.boundaryEdgeCount, 281, "boundary edges")
        XCTAssertEqual(graph.bendPairCount, 47381, "cross pairs")
        XCTAssertEqual(graph.pinPinEdgesDropped, 5222, "pin-pin edges dropped")
        XCTAssertEqual(graph.pinPinBendPairsDropped, 4957, "pin-pin cross pairs dropped")
        XCTAssertEqual(graph.stretchConstraintCount, 42440)
        XCTAssertEqual(graph.bendConstraintCount, 42424)
        XCTAssertEqual(graph.entryCount, 169_728, "CSR entries")
        XCTAssertEqual(graph.maxEntriesPerParticle, 22)
        XCTAssertLessThan(graph.entryCount, 200_000, "\(graph.entryCount) CSR entries, over the design's 168,000 budget by more than a fifth")
        XCTAssertGreaterThanOrEqual(graph.restLengthRange.lowerBound, 0.004)
        XCTAssertLessThanOrEqual(graph.restLengthRange.upperBound, 0.030)
        XCTAssertEqual(graph.regionSlack, [0, 0.005, 0.03, 0.07, 0.09, 0.10, 0.11, 0.12, 0.15])
        let raw = try loadRaw()
        guard let counts = try rawShirt(raw)["constraintCounts"] as? [String: NSNumber] else { throw XCTSkip("the cook wrote no constraintCounts") }
        print("CoolZombie cloth 16k constraintCounts: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        let kit: [(key: String, value: Int)] = [
            ("edges", graph.edgeCount), ("bendPairs", graph.bendPairCount), ("boundaryEdges", graph.boundaryEdgeCount),
            ("pinPinEdgesDropped", graph.pinPinEdgesDropped), ("pinPinBendPairsDropped", graph.pinPinBendPairsDropped),
            ("stretchConstraints", graph.stretchConstraintCount), ("bendConstraints", graph.bendConstraintCount),
            ("entries", graph.entryCount), ("maxEntriesPerParticle", graph.maxEntriesPerParticle),
        ]
        for (key, value) in kit {
            XCTAssertEqual(counts[key]?.intValue, value, "the cook's \(key) against the kit's")
        }
        // The design's own name for the two drops together, when the cook
        // writes it beside the kit's (one cook of the day did).
        if let together = counts["pinPinDropped"]?.intValue {
            XCTAssertEqual(together, graph.pinPinEdgesDropped + graph.pinPinBendPairsDropped, "the cook's pinPinDropped against the kit's two drops together")
        }
        XCTAssertEqual(Set(counts.keys).subtracting(["pinPinDropped"]), Set(kit.map(\.key)), "the cook's keys")
    }
}
