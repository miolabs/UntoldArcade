//
//  ZombieClothGPUTests.swift
//  CoolZombieKitTests
//
//  The shirt on the GPU XPBD solver of `Docs/GPUCloth.md` (section 6), the
//  twin of ZombieClothTests: the same harness, the same fit scenarios and
//  the same figures printed, with bounds of the GPU's own, plus the solver's
//  own tests — the metallib and its kernels, the struct layouts pinned to
//  the Metal header, the constraint graph and the hull planes against the
//  figures measured off the sidecar, the exactness of the pins, the slack
//  clamp and the back-stop (which Jolt's skin-before-edges order could not
//  give, README "Cloth"), the stretch residual that decides the relaxation
//  form, the substep rule and the per-substep targets, the hull friction
//  the Jolt arm could not have, determinism, the sleeping solver's silence
//  and the runaway. Every test takes its device from
//  `MTLCreateSystemDefaultDevice()` and skips without one, so the suite runs
//  wherever the Jolt one does (CoolCloth's harness,
//  CC/Tests/CoolClothTests/CoolClothGPUTests.swift). Float results differ
//  across GPU generations, so the bounds are this Mac's (an Apple M-series
//  GPU) with the Jolt literals' margins; the headset gates are the device's
//  own tests.
//
//  Written 2026-11-03, the day the solver landed; the GPU fit bounds were
//  first Jolt's literals (the penetration and swing counts at Jolt's plus
//  25 %, as the design allows for a first commit) and were re-pinned the
//  same day from the green runs' printed figures, at two gathers with the
//  weights renormalised in the kernel (`gpuBounds` says what they are).
//

@testable import CoolZombieKit
import Metal
import simd
@testable import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class ZombieClothGPUTests: XCTestCase {
    private let dt: Float = 0.01
    private var device: MTLDevice!

    /// The Mac's GPU, or the test is skipped: the GPU suite needs a Metal
    /// device as CoolCloth's does, and a CI box without one runs the Jolt
    /// suite alone.
    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
    }

    // MARK: - The GPU bounds

    /// The GPU arm's fit bounds, measured 2026-11-03 on the M4 Max (the
    /// solver's first day; a debug build, 16 substeps, the default's two
    /// gathers of the raw sum at 0.5, the weights renormalised in the
    /// kernel) and pinned with the Jolt literals' margins — a few particles,
    /// a millimetre or two. The GPU shirt sits in another regime than
    /// Jolt's, because its clamp and its back-stop are exact at every
    /// substep's end: the hang sags 9.4 mm at the chest and the back
    /// (Jolt 10.5; 14.2 at one gather, where the edges' 3.4 % residual was
    /// sag of its own) with the hem band's mean 7.8 mm over the yoke's 1.3,
    /// no particle past its slack by more than 2e-7 m anywhere in the hang,
    /// the idle or the sway (Jolt strayed 11 mm over the lagging ragdoll),
    /// the pins within 3.1e-6 m (the clamp test), 1.25 mm behind the skin
    /// at the worst, nothing inside the posed skin after the hang or the
    /// sway on any model, 0.0 mm of sag without gravity; in the
    /// arms-forward idle the armhole band's farthest particle rests
    /// 143.4 mm from its target (Jolt 67.0) — on its 150 mm slack ball,
    /// which the exact clamp lets it reach — 18.0 mm behind its skinned
    /// plane, 12 particles inside the posed skin with the hulls (Jolt 65; 7
    /// at one gather) and 18 without (Jolt 154); the arm swing leaves none
    /// inside at any read frame (Jolt 9), 1.1 mm deep at the worst, 0.0 mm
    /// past the slack, the sleeves 50.0 mm off the skin (Jolt 50.0) and the
    /// skin-only control 3 inside (Jolt 48). Re-pin from the printed lines
    /// when the solver changes (the gathers, the substeps, the weights).
    private static let gpuBounds = ClothFitBounds(
        hang: .init(penetration: 0, sag: 0.008, hemOverYoke: 0.005, excess: 0.001, pins: 1e-5, clearance: 0.001, inward: 0.00175, rigid: 1e-4, controlSag: 0.001),
        idle: .init(excess: 0.001, pins: 1e-5),
        sway: .init(penetration: 0, excess: 0.001, excessOverLaggingParts: 0.005, pins: 1e-5),
        dent: .init(dent: 0.02),
        armsForward: .init(penetration: 15, armhole: 0.15, excess: 0.001, inward: 0.025),
        swing: .init(inside: 2, deepest: 0.003, excess: 0.001, lift: 0.055)
    )
    /// Per collision model, the sway's count of particles more than 2 mm
    /// inside the posed skin: none on any model (measured 2026-11-03; Jolt
    /// 0 / 0 / 4, the ragdoll's lagging forearm pushing two cuff particles
    /// in on that arm, which the exact clamp does not allow here).
    private let swayPenetrationBound: [String: Int] = ["skin only": 0, "world": 0, "ragdoll and skin": 0]

    // MARK: - The harness

    /// The Jolt harness on the GPU solver: the configuration's `solver` set
    /// to `gpu` and the Mac's device handed to the cloth, everything else —
    /// the Jolt world for the floor, the parts and the balls, the recording
    /// body, the skeleton — as the Jolt tests have it. A gravity other than
    /// the world's goes to the Jolt world (the parts) as the Jolt harness
    /// does it and to the GPU solver's own `gravity`, since the cloth reads
    /// the coordinator's world configuration, not the harness's backend.
    private func makeHarness(configuration: ZombieCloth.Configuration = ZombieCloth.Configuration(), world: simd_float4x4 = ClothFixtures.standing,
                             ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil, normals: [SIMD3<Float>]? = nil,
                             pose: [simd_float4x4]? = nil, gravity: SIMD3<Float> = SIMD3(0, -9.8, 0), device: MTLDevice? = nil) throws -> ClothHarness
    {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let harness = ClothHarness(dt: dt, asset: asset, joints: joints, configuration: configuration, world: world, ragdoll: ragdoll, obstacles: obstacles, mesh: mesh,
                                   normals: normals, pose: pose, gravity: gravity, solver: .gpu, device: device ?? self.device)
        XCTAssertTrue(harness.attached, "the shirt attached")
        XCTAssertEqual(harness.cloth.activeSolver, .gpu, "the shirt is not on the GPU solver (\(harness.cloth.report))")
        if gravity != SIMD3(0, -9.8, 0) { harness.cloth.gpuSolver(ofGarment: 0)?.gravity = gravity }
        return harness
    }

    /// The default configuration with the GPU arm's knobs set.
    private func gpuConfiguration(substeps: Int = 16, iterations: Int = 2, relaxation: Float = 0.5, averaged: Bool = false,
                                  hullFriction: Float = 0, collisionModel: ZombieCloth.Configuration.CollisionModel = .skinAndWorld) -> ZombieCloth.Configuration
    {
        var configuration = ZombieCloth.Configuration()
        configuration.solver = .gpu
        configuration.gpuSubsteps = substeps
        configuration.gpuIterations = iterations
        configuration.gpuRelaxation = relaxation
        configuration.gpuAveragedJacobi = averaged
        configuration.gpuHullFriction = hullFriction
        configuration.collisionModel = collisionModel
        return configuration
    }

    private var skinOnly: ZombieCloth.Configuration { gpuConfiguration(collisionModel: .skinOnly) }
    private var ragdollAndSkin: ZombieCloth.Configuration { gpuConfiguration(collisionModel: .ragdollAndSkin) }

    /// The shirt's GPU solver.
    private func gpu(_ h: ClothHarness) throws -> GPUClothSolver {
        try XCTUnwrap(h.cloth.gpuSolver(ofGarment: 0), "the shirt is not on the GPU solver")
    }

    /// The shirt's unique edges with a movable end, as Jolt's
    /// `CreateConstraints` keeps them and the GPU graph must: 11,849 edges
    /// on the sidecar of 2026-11-03, 1,424 of them pin-pin and dropped,
    /// 10,425 kept (judge_counts.py over the sidecar, 2026-11-03).
    private static func stretchEdges(of shirt: ZombieClothAsset.Garment) -> [(Int, Int)] {
        var seen = Set<UInt64>()
        var edges: [(Int, Int)] = []
        for tri in shirt.triangles {
            for i in 0 ..< 3 {
                let a = tri[i], b = tri[(i + 1) % 3]
                let u = min(a, b), v = max(a, b)
                guard seen.insert(UInt64(u) << 32 | UInt64(v)).inserted else { continue }
                guard shirt.maxDistance[u] > 0 || shirt.maxDistance[v] > 0 else { continue }
                edges.append((u, v))
            }
        }
        return edges
    }

    // MARK: - The metallib and the layouts

    /// The platform metallib `Scripts/build-cloth-metallib.sh` commits under
    /// `Resources/Shaders` is found in `Bundle.module` by the engine's
    /// platform-suffix rule (`ZombieCloth-macos.metallib` here, 24,105 B on
    /// 2026-11-03), loads on the device and exposes the three phase-1
    /// kernels — `zcPredict`, `zcSolve` and `zcStats` — each of which makes
    /// a compute pipeline wide enough for the threadgroup the solver
    /// dispatches (64, and 1,024 for the stats); a stale build (a kernel
    /// renamed in the source and the script not run) fails here and nowhere
    /// quieter. The Swift mirrors of the Metal structs have the header's
    /// strides — 256, 8, 48 (the hull header, a box since 2026-11-03) and
    /// 64 B, with the two per-entry structs the ABI named, `ZCInfluence`
    /// 16 B and `ZCSphere` 32 B — and
    /// `ZCLayout.mismatches()` pins every member's offset and alignment. The
    /// design's `zcTriangleFrames` and `zcShell` are phase 2 and are checked
    /// there.
    func testTheMetallibExposesTheKernels() throws {
        let name = RenderShaderLibraryPlatformResource.resourceName(baseName: "ZombieCloth")
        let url = try XCTUnwrap(GPUClothSolver.metallibURL, "\(name).metallib is not in the kit's Shaders resources")
        XCTAssertEqual(url.lastPathComponent, "\(name).metallib")
        let library = try device.makeLibrary(URL: url)
        let names = Set(library.functionNames)
        XCTAssertEqual(GPUClothSolver.kernelNames, ["zcPredict", "zcSolve", "zcStats"])
        for kernel in GPUClothSolver.kernelNames {
            XCTAssertTrue(names.contains(kernel), "\(name).metallib has no \(kernel) (\(library.functionNames))")
            let function = try XCTUnwrap(library.makeFunction(name: kernel), kernel)
            let pipeline = try device.makeComputePipelineState(function: function)
            XCTAssertGreaterThanOrEqual(pipeline.maxTotalThreadsPerThreadgroup, kernel == "zcStats" ? zcStatsThreadgroupSize : zcThreadgroupSize,
                                        "\(kernel) cannot run the threadgroup the solver dispatches")
        }
        XCTAssertEqual(MemoryLayout<ZCParams>.stride, 256)
        XCTAssertEqual(MemoryLayout<ZCEntry>.stride, 8)
        XCTAssertEqual(MemoryLayout<ZCHullHeader>.stride, 48)
        XCTAssertEqual(MemoryLayout<ZCStats>.stride, 64)
        XCTAssertEqual(MemoryLayout<ZCInfluence>.stride, 16)
        XCTAssertEqual(MemoryLayout<ZCSphere>.stride, 32)
        let mismatches = ZCLayout.mismatches()
        XCTAssertTrue(mismatches.isEmpty, "the Swift mirrors drift from the Metal header: \(mismatches)")
        XCTAssertNotNil(GPUClothSolver(device: device, configuration: gpuConfiguration()), "the solver could not be built on \(device.name)")
        let bytes = try Data(contentsOf: url).count
        print("cloth gpu metallib: \(url.lastPathComponent) (\(bytes) B) exposes \(library.functionNames.sorted()) on \(device.name); strides params \(MemoryLayout<ZCParams>.stride) entry \(MemoryLayout<ZCEntry>.stride) hull \(MemoryLayout<ZCHullHeader>.stride) stats \(MemoryLayout<ZCStats>.stride)")
    }

    // MARK: - The constraint graph and the hull planes

    /// The CSR graph the solver builds from the sidecar's faces is Jolt's
    /// `CreateConstraints` set, measured off the sidecar as cooked on
    /// 2026-11-03 with numpy (judge_counts.py): 11,849 unique edges, 142 of
    /// them boundary and 11,707 interior (no non-manifold edge), 1,424 edges
    /// between two pins dropped and 10,425 kept; one cross pair per interior
    /// edge, 1,282 of them pin-pin and dropped, 10,425 kept (1,556 of the
    /// 11,707 lie across a quad-like diagonal at Jolt's 8-degree tolerance
    /// — `shearPairCount` counts them before the pin-pin drop, 68 of them
    /// dropped and 1,488 kept with the shear compliance, 8,937 with the
    /// bend's; 45 coincide with an edge and are kept, as Jolt keeps them);
    /// 20,850 constraints and 41,700 CSR entries, two per constraint, 22 at
    /// most on a particle and 10.44 on average over the 3,995 (11.90 over
    /// the free ones); every kept edge's rest length within [0.0085,
    /// 0.0392] m (the cook's 8.5 / 17.5 / 39.1 mm). Of the entries, 17,874
    /// are the bend's, 5,948 the shear's (the 1,488 pairs and the 1,486
    /// edges on a quad's diagonal, which Jolt gives the shear compliance
    /// too) and 17,878 the stretch's — in single precision, Jolt's and the
    /// solver's; the double-precision judge put one pair at the 8-degree
    /// threshold on the other side (1,487 + 1,485). The offsets close on the
    /// entry count, every entry's neighbour is a particle other than its
    /// owner, every rest length is the bind-pose distance, no entry joins
    /// two pins, and the region table lists the schedule's nine slack
    /// values ascending.
    func testTheConstraintGraphMatchesJolts() throws {
        guard let asset = ClothFixtures.asset, let shirt = asset.garment(named: "shirt") else { throw XCTSkip("the sidecar is not bundled") }
        let positions = shirt.positions
        let pins = shirt.maxDistance.map { $0 == 0 }
        let faces = shirt.triangles.map { SIMD3<UInt32>(UInt32($0[0]), UInt32($0[1]), UInt32($0[2])) }
        let graph = GPUClothSolver.ConstraintGraph(faces: faces, positions: positions, inverseMasses: pins.map { $0 ? 0 : 20000 }, maxDistance: shirt.maxDistance)
        XCTAssertEqual(graph.particleCount, 3995)
        XCTAssertEqual(graph.edgeCount, 11849, "unique edges")
        XCTAssertEqual(graph.boundaryEdgeCount, 142, "boundary edges (one face)")
        XCTAssertEqual(graph.bendPairCount, 11707, "cross pairs, one per interior edge")
        XCTAssertEqual(graph.pinPinEdgesDropped, 1424, "edges between two pins, dropped as Jolt drops them")
        XCTAssertEqual(graph.pinPinBendPairsDropped, 1282, "cross pairs between two pins, dropped")
        XCTAssertEqual(graph.stretchConstraintCount, 10425, "stretch constraints kept")
        XCTAssertEqual(graph.bendConstraintCount, 10425, "shear and bend constraints kept")
        XCTAssertEqual(graph.shearPairCount, 1556, "cross pairs across a quad-like diagonal, the pin-pin ones counted before the drop")
        XCTAssertEqual(graph.entryCount, 41700, "two CSR entries per constraint")
        XCTAssertEqual(graph.entries.count, graph.entryCount)
        XCTAssertEqual(graph.offsets.count, positions.count + 1)
        XCTAssertEqual(Int(graph.offsets.last ?? 0), graph.entryCount, "csrOffsets[N] closes on the entry count")
        XCTAssertEqual(Int(graph.offsets.first ?? 1), 0)
        XCTAssertEqual(graph.maxEntriesPerParticle, 22, "the busiest particle's entries")
        XCTAssertEqual(graph.meanEntriesPerParticle, 10.44, accuracy: 0.01, "the mean degree")
        XCTAssertGreaterThanOrEqual(graph.restLengthRange.lowerBound, 0.0085, "a stretch edge shorter than the cook's 8.5 mm")
        XCTAssertLessThanOrEqual(graph.restLengthRange.upperBound, 0.0392, "a stretch edge longer than the cook's 39.1 mm")
        XCTAssertEqual(graph.regionSlack, [0, 0.005, 0.03, 0.07, 0.09, 0.10, 0.11, 0.12, 0.15], "the schedule's slack values by region index")
        var maxDegree = 0, families = [0, 0, 0]
        for i in 0 ..< positions.count {
            let run = Int(graph.offsets[i]) ..< Int(graph.offsets[i + 1])
            maxDegree = max(maxDegree, run.count)
            for e in run {
                let entry = graph.entries[e]
                XCTAssertLessThan(entry.neighbour, positions.count, "entry \(e) names particle \(entry.neighbour)")
                XCTAssertNotEqual(entry.neighbour, i, "entry \(e) is a self loop")
                XCTAssertLessThan(entry.region, graph.regionSlack.count, "entry \(e) names region \(entry.region)")
                families[Int(entry.family.rawValue)] += 1
                XCTAssertEqual(entry.rest, simd_distance(positions[i], positions[entry.neighbour]), accuracy: 1e-6, "entry \(e): the rest length is not the bind-pose distance")
                XCTAssertFalse(pins[i] && pins[entry.neighbour], "entry \(e) joins two pins")
                XCTAssertEqual(graph.regionSlack[entry.region], min(shirt.maxDistance[i], shirt.maxDistance[entry.neighbour]), "entry \(e): the region is not the stiffer end's slack")
            }
        }
        XCTAssertEqual(maxDegree, graph.maxEntriesPerParticle)
        XCTAssertEqual(families[0], 17878, "stretch entries")
        XCTAssertEqual(families[1], 5948, "shear entries: the quad diagonals' pairs and edges")
        XCTAssertEqual(families[2], 17874, "bend entries")
        print("cloth gpu graph: \(graph.edgeCount) edges (\(graph.boundaryEdgeCount) boundary, \(graph.pinPinEdgesDropped) pin-pin dropped), \(graph.bendPairCount) cross pairs (\(graph.pinPinBendPairsDropped) pin-pin dropped, \(graph.shearPairCount) shear), \(graph.stretchConstraintCount) + \(graph.bendConstraintCount) constraints, \(graph.entryCount) entries, degree \(graph.maxEntriesPerParticle) at most and \(String(format: "%.2f", graph.meanEntriesPerParticle)) on average, stretch rest \(String(format: "%.4f-%.4f", graph.restLengthRange.lowerBound, graph.restLengthRange.upperBound)) m, entries stretch \(families[0]) shear \(families[1]) bend \(families[2]), regions \(graph.regionSlack)")
    }

    /// The sidecar's eleven hulls (32 to 48 points each, 446 in all) as plane
    /// sets: every triple's plane kept when all the hull's points lie on one
    /// side of it, deduplicated at 1e-4 on the normal's components and the
    /// offset, which gives 87, 83, 82, 88, 66, 84, 82, 66, 70, 60 and 64
    /// planes for the pelvis, the three spine links, the neck, the two
    /// clavicles, the two upper arms and the two forearms — 832 in all,
    /// under the 2n - 4 bound of 848 (judge_counts.py over the sidecar,
    /// 2026-11-03). Every point of a hull reads inside all its planes within
    /// 1e-5 m, a point moved 3 mm out along a plane's normal reads outside
    /// that plane by 3 mm, the bounding sphere holds every point and is
    /// inflated by the vertex radius, and the attached solver counts the
    /// same 832.
    func testTheHullPlanesEncloseTheirPoints() throws {
        guard let colliders = ClothFixtures.asset?.colliders, colliders.count == 11 else { throw XCTSkip("the sidecar carries no skin colliders") }
        let expected = [87, 83, 82, 88, 66, 84, 82, 66, 70, 60, 64]
        var total = 0
        var counts: [Int] = []
        for (index, collider) in colliders.enumerated() {
            let points = collider.pointVectors
            let hull = try XCTUnwrap(GPUClothSolver.HullPlaneSet(points: points, joint: index, vertexRadius: 0.003), "\(collider.joint): no planes")
            counts.append(hull.planeCount)
            total += hull.planeCount
            XCTAssertEqual(hull.pointCount, points.count)
            XCTAssertLessThanOrEqual(hull.planeCount, 2 * points.count - 4, "\(collider.joint): more planes than a convex polytope on \(points.count) points has faces")
            var worstInside: Float = -.greatestFiniteMagnitude, farthestFromCentre: Float = 0
            for plane in hull.planes {
                let n = SIMD3(plane.x, plane.y, plane.z)
                XCTAssertEqual(simd_length(n), 1, accuracy: 1e-4, "\(collider.joint): a plane's normal is not unit")
                for p in points { worstInside = max(worstInside, simd_dot(n, p) + plane.w) }
            }
            for p in points {
                XCTAssertTrue(hull.contains(p, tolerance: 1e-5), "\(collider.joint): a hull point reads \(hull.signedDistance(to: p)) m outside")
                farthestFromCentre = max(farthestFromCentre, simd_distance(p, hull.sphereCenter))
            }
            XCTAssertLessThan(worstInside, 1e-5, "\(collider.joint): a hull point reads \(worstInside) m outside one of its own planes")
            XCTAssertEqual(hull.sphereRadius, farthestFromCentre + 0.003, accuracy: 1e-5, "\(collider.joint): the bounding sphere is not the farthest point plus the vertex radius")
            var low = points[0], high = points[0]
            for p in points { low = simd_min(low, p); high = simd_max(high, p) }
            XCTAssertEqual(simd_length(hull.boundsMin - (low - SIMD3(repeating: 0.006))), 0, accuracy: 1e-6, "\(collider.joint): the box's lower corner is not the points' minimum less two vertex radii")
            XCTAssertEqual(simd_length(hull.boundsMax - (high + SIMD3(repeating: 0.006))), 0, accuracy: 1e-6, "\(collider.joint): the box's upper corner is not the points' maximum plus two vertex radii")
            // A point pushed 3 mm out along the first plane's normal from the
            // hull's point farthest along it.
            let plane = hull.planes[0]
            let n = SIMD3(plane.x, plane.y, plane.z)
            let farthest = points.max { simd_dot(n, $0) < simd_dot(n, $1) }!
            let outside = farthest + n * 0.003
            XCTAssertGreaterThan(simd_dot(n, outside) + plane.w, 0.0029, "\(collider.joint): a point 3 mm outside reads inside")
            XCTAssertFalse(hull.contains(outside, tolerance: 0.001), "\(collider.joint): a point 3 mm outside reads inside the hull")
            XCTAssertEqual(hull.planeCount, expected[index], "\(collider.joint): \(hull.planeCount) planes, \(expected[index]) measured off the sidecar")
        }
        XCTAssertEqual(total, 832, "planes in all: \(counts)")
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        XCTAssertEqual(solver.hullCount, 11)
        XCTAssertEqual(solver.planeCount, 832, "the attached solver's planes")
        XCTAssertEqual(solver.hullPlaneSets.map(\.planeCount), expected)
        print("cloth gpu hulls: \(counts) planes, \(total) in all over \(colliders.reduce(0) { $0 + $1.pointVectors.count }) points; \(h.cloth.report)")
    }

    // MARK: - Exactness: the hard skin, the pins, the clamp, the back-stop

    /// After the attach every particle sits on its skinned target (the CPU
    /// hard skin writes the position, previous and velocity buffers, the
    /// targets and their normals, and waits for nothing since nothing is
    /// in flight) within the float rounding between the CPU blend of
    /// `skinnedTargets` and the solver's own, 1e-5 m on world coordinates
    /// of a few metres; `hardSkinCount` 1, the slack shut
    /// (`skinMultiplier` 0), no frame encoded yet and nothing pending, as
    /// on the Jolt arm.
    func testAHardSkinPutsEveryParticleOnItsTarget() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        XCTAssertEqual(h.cloth.hardSkinCount, 1, "the attach hard skinned")
        XCTAssertEqual(h.cloth.skinMultiplier, 0, "the slack is shut right after a hard skin")
        XCTAssertEqual(solver.ringState.encodedFrames, 0, "a frame was encoded before any step")
        XCTAssertFalse(solver.ringState.pending)
        XCTAssertEqual(solver.particleCount, h.shirt.particles.count)
        let p = h.particles, t = h.targets
        XCTAssertEqual(p.count, h.shirt.particles.count)
        var worst: Float = 0
        for (a, b) in zip(p, t) { worst = max(worst, simd_distance(a, b)) }
        XCTAssertLessThan(worst, 1e-5, "a particle is \(worst) m off its target right after the hard skin")
        // The buffer's w lane is the inverse mass: 0 on the 532 pins, 20,000 elsewhere.
        let buffer = try XCTUnwrap(solver.currentPositionBuffer)
        let lanes = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: p.count)
        var pins = 0
        for i in 0 ..< p.count {
            if lanes[i].w == 0 { pins += 1 } else { XCTAssertEqual(lanes[i].w, 20000, accuracy: 1, "particle \(i): the inverse mass lane") }
        }
        XCTAssertEqual(pins, 532)
        print(String(format: "cloth gpu hard skin: %d particles within %.2e m of their targets, %d pins by their w lane; %@", p.count, worst, pins, h.cloth.report))
    }

    /// The clamp is the last pass over the skin, so it is exact where Jolt's
    /// skin-before-edges order left the cuff 3 mm behind: after 300 idle
    /// frames (the cloth asleep since frame 177) the 532 pins sit on their
    /// targets and every free particle within its slack, both to the float
    /// arithmetic — measured 2026-11-03 on the M4 Max: pins 2.88e-6 m, free
    /// 1.30e-6 m past the slack, against Jolt's 3.2 um pins and 5 mm bound
    /// (ZombieClothTests, the idle); held to 1e-5 m, three times the
    /// measurement. The first run of the day read 0.50 mm and 0.19 mm:
    /// the kernel's weights travel as `half4` (`ZCInfluence`, 16 B) and
    /// their rounded sum was off 1 by up to 3.5e-4, which times a position
    /// a metre or two from the origin is half a millimetre; `zcPredict`
    /// now divides the blended matrix by the rounded weights' sum, and
    /// what is left is the rounding of the weights' ratios. With gravity
    /// raised to 50 m/s^2 the shirt is still edge-bound, not slack-bound:
    /// about 2 % of the 3,463 free particles sit on their slack ball (71 of
    /// them), 1.6 % at 9.8 m/s^2 — the design expected nine in ten, and
    /// the figure says the schedule is not what bounds the look — and the
    /// stats kernel's `onClamp` share agrees with the read-back's count
    /// within two points, which is the figure the report prints.
    func testPinsNeverMoveAndTheSlackClampIsExact() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        h.frames(300)
        let p = h.particles, t = h.targets
        var pins: Float = 0, pinCount = 0, free: Float = -.greatestFiniteMagnitude
        for index in p.indices {
            let d = simd_distance(p[index], t[index])
            if h.shirt.maxDistance[index] == 0 { pinCount += 1; pins = max(pins, d) } else { free = max(free, d - h.shirt.maxDistance[index]) }
        }
        XCTAssertEqual(pinCount, 532)
        XCTAssertLessThan(pins, 1e-5, "a pin is \(pins) m off its target after 300 frames")
        XCTAssertLessThan(free, 1e-5, "a free particle is \(free) m past its slack after 300 frames")
        XCTAssertEqual(h.cloth.runawayCount, 0)
        var normalOnClamp = 0, normalFree = 0
        for index in p.indices where h.shirt.maxDistance[index] > 0 {
            normalFree += 1
            if simd_distance(p[index], t[index]) >= h.shirt.maxDistance[index] - 1e-4 { normalOnClamp += 1 }
        }
        let normalShare = Float(normalOnClamp) / Float(max(normalFree, 1))
        let normalStats = try gpu(h).stats
        print(String(format: "cloth gpu clamp: pins within %.2e m, free particles within %.2e m of their slack; %d of %d free particles on their slack ball (%.1f%%), the stats kernel says %.1f%%; %@",
                     pins, free, normalOnClamp, normalFree, normalShare * 100, normalStats.onClampShare * 100, h.cloth.report))
        XCTAssertEqual(normalStats.onClampShare, normalShare, accuracy: 0.02, "the stats kernel's onClamp share disagrees with the read-back's")

        let heavy = try makeHarness(configuration: gpuConfiguration(), gravity: SIMD3(0, -50, 0))
        heavy.frames(300)
        let hp = heavy.particles, ht = heavy.targets
        var onClamp = 0, freeCount = 0
        for index in hp.indices where heavy.shirt.maxDistance[index] > 0 {
            freeCount += 1
            if simd_distance(hp[index], ht[index]) >= heavy.shirt.maxDistance[index] - 1e-4 { onClamp += 1 }
        }
        let share = Float(onClamp) / Float(max(freeCount, 1))
        let stats = try gpu(heavy).stats
        print(String(format: "cloth gpu clamp at 50 m/s^2: %d of %d free particles on their slack ball (%.1f%%), the stats kernel says %.1f%%; %@",
                     onClamp, freeCount, share * 100, stats.onClampShare * 100, heavy.cloth.report))
        XCTAssertGreaterThan(onClamp, 0, "no free particle hangs on the clamp under 50 m/s^2")
        XCTAssertLessThan(share, 0.1, "\(share) of the free particles hang on the clamp under 50 m/s^2: the shirt turned slack-bound (2.1 % measured)")
        XCTAssertEqual(stats.onClampShare, share, accuracy: 0.02, "the stats kernel's onClamp share disagrees with the read-back's")
        XCTAssertTrue(heavy.cloth.report.contains("onClamp="), heavy.cloth.report)
    }

    /// The back-stop holds 1 mm behind the skinned plane after the hang: no
    /// particle with a stop (the 148 body-facing ones have none) sits more
    /// than `backstop` plus the rounding behind its target along the skin's
    /// normal there — Jolt's figure was 3.14 mm at the right cuff, since its
    /// edges had the last word (ZombieClothTests, the hang). The normal read
    /// here is the targets' face normal, Jolt's; the kernel rotates the
    /// rest normal, which differs from it only where the fabric stretched
    /// or folded since the bind pose: measured 1.25 mm at particle 2925,
    /// the hem, on 2026-11-03 (M4 Max; 1.43 mm at one gather, 1.38 with the
    /// weights renormalised), held to the millimetre and three quarters.
    func testTheBackStopHoldsOneMillimetreBehindTheSkin() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        h.frames(200)
        let worst = h.worstInward()
        let at = h.shirt.positions[worst.index]
        print(String(format: "cloth gpu back-stop after the hang: farthest behind the skin %.2f mm at particle %d (slack %.3f) at rest (%.2f,%.2f,%.2f); %@",
                     worst.depth * 1000, worst.index, h.shirt.maxDistance[worst.index], at.x, at.y, at.z, h.cloth.report))
        XCTAssertLessThan(worst.depth, h.shirt.backstop + 0.00075, "particle \(worst.index) sits \(worst.depth) m behind its skinned plane")
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }

    // MARK: - Convergence

    /// The gate that decides the relaxation form (design section 2): after
    /// 200 frames of the hang the stretch edges' residual |len - rest| /
    /// rest under 1 % on average and 3 % at the 99th percentile at 16
    /// substeps, under 2 % / 6 % at 8; both forms run — the raw sum at 0.5
    /// (CoolCloth's, the default) and the averaged Jacobi at omega 1.5 —
    /// and the figures printed decide the default. Measured 2026-11-03 on
    /// the M4 Max, one gather: raw 0.5 at 16 substeps mean 0.73 %, p99
    /// 3.38 %, worst 10.2 %; averaged 1.5 at 16 mean 2.53 %, p99 10.1 %;
    /// raw 0.5 at 8 mean 12.6 %, p99 42.9 %, worst 98.7 %; averaged 1.5 at
    /// 8 mean 5.63 %, p99 22.2 %. So the raw sum is the better form at both
    /// counts (the averaged form is three and a half times weaker per pass
    /// at the proxy's mean degree, as the design computed), the default
    /// meets the gate's mean and misses its 99th percentile by 0.38
    /// points, and at 8 substeps one gather leaves the shirt an eighth
    /// stretched. The second gather is what meets the gate: raw 0.5 with
    /// `gpuIterations` 2 gives mean 0.40 %, p99 2.12 %, worst 3.89 % at 16
    /// substeps and 0.79 % / 3.77 % / 8.50 % at 8 (49 and 25 dispatches a
    /// frame against 33 and 17), both inside the design's 1 % / 3 % and
    /// 2 % / 6 %; so the two-gather rows are held to the gate itself and
    /// the one-gather rows to their measurements with a quarter of margin,
    /// the gate's verdict printed on every row. That verdict made two
    /// gathers `gpuIterations`' default the same day (49 dispatches a frame
    /// at 16 substeps; `-clothGPUIterations 1` is the A/B back). Jolt's
    /// equilibrium stretch at 1e-2 m/N is a few per cent under the shirt's
    /// weight (README "Cloth"), which is what the gate's 1 % mean allows
    /// for.
    func testStretchResidualAtRest() throws {
        guard let shirt = ClothFixtures.asset?.garment(named: "shirt") else { throw XCTSkip("the sidecar is not bundled") }
        let edges = Self.stretchEdges(of: shirt)
        XCTAssertEqual(edges.count, 10425)
        let rest = edges.map { simd_distance(shirt.positions[$0.0], shirt.positions[$0.1]) }
        var measured = 0
        for (label, substeps, gathers, averaged, relaxation, meanBound, p99Bound, gateMean, gateP99) in [
            ("raw sum 0.5, 16 substeps", 16, 1, false, Float(0.5), Float(0.01), Float(0.045), Float(0.01), Float(0.03)),
            ("averaged 1.5, 16 substeps", 16, 1, true, 1.5, 0.032, 0.13, 0.01, 0.03),
            ("raw sum 0.5, 8 substeps", 8, 1, false, 0.5, 0.16, 0.54, 0.02, 0.06),
            ("averaged 1.5, 8 substeps", 8, 1, true, 1.5, 0.071, 0.28, 0.02, 0.06),
            ("raw sum 0.5, 16 substeps, 2 gathers", 16, 2, false, 0.5, 0.01, 0.03, 0.01, 0.03),
            ("raw sum 0.5, 8 substeps, 2 gathers", 8, 2, false, 0.5, 0.02, 0.06, 0.02, 0.06),
        ] {
            let h = try makeHarness(configuration: gpuConfiguration(substeps: substeps, iterations: gathers, relaxation: relaxation, averaged: averaged))
            h.frames(200)
            let p = h.particles
            var residuals = edges.indices.map { abs(simd_distance(p[edges[$0].0], p[edges[$0].1]) - rest[$0]) / rest[$0] }
            residuals.sort()
            let mean = residuals.reduce(0, +) / Float(residuals.count)
            let p99 = residuals[Int(Float(residuals.count - 1) * 0.99)]
            let worst = residuals.last ?? 0
            let gate = mean < gateMean && p99 < gateP99 ? "met" : "NOT met"
            print(String(format: "cloth gpu stretch residual, %@: mean %.2f%%, p99 %.2f%%, worst %.2f%% over %d edges; the design's gate (%.0f%% / %.0f%%) %@; %@",
                         label, mean * 100, p99 * 100, worst * 100, edges.count, gateMean * 100, gateP99 * 100, gate, h.cloth.report))
            XCTAssertLessThan(mean, meanBound, "\(label): the mean stretch residual is \(mean * 100)%")
            XCTAssertLessThan(p99, p99Bound, "\(label): the 99th-percentile stretch residual is \(p99 * 100)%")
            XCTAssertEqual(h.cloth.runawayCount, 0)
            XCTAssertEqual(try gpu(h).ringState.substeps, substeps)
            XCTAssertEqual(try gpu(h).ringState.dispatches, substeps * (1 + gathers) + 1, "\(label): the last encoded frame's dispatches")
            measured += 1
        }
        XCTAssertEqual(measured, 6)
    }

    // MARK: - The substeps

    /// The substep count follows the frame delta (the engine's contract, no
    /// constant): the delta clamped to [1/240, 1/30] s, the substep 0.01 /
    /// `gpuSubsteps`, the count ceil(delta / substep) clamped to [1, 32] —
    /// 16 at the headset's 10 ms, 18 at 11.1 ms, 27 at the Mac's 16.7 ms, 8
    /// at 5 ms, 32 at 50 ms (a 30 fps hitch), and `gpuSubsteps` 8 gives 8
    /// at 10 ms and 14 at 16.7 ms. A frame of the harness's 10 ms encodes
    /// 16 substeps of 0.625 ms, 49 dispatches (a predict and the default's
    /// two gathers each, the stats once), 17 at 8 substeps and one gather.
    func testTheSubstepRuleFollowsTheFrame() throws {
        XCTAssertEqual(GPUClothSolver.substepLength(substeps: 16), 0.000625)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.010, substeps: 16), 16)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.0111, substeps: 16), 18)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 1 / 60, substeps: 16), 27)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.005, substeps: 16), 8)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.050, substeps: 16), 32)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.001, substeps: 16), 7, "the delta is clamped to 1/240 s first")
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: .nan, substeps: 16), 27, "a delta that is not a number is the Mac's frame")
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.010, substeps: 8), 8)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 1 / 60, substeps: 8), 14)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.010, substeps: 32), 32)
        XCTAssertEqual(GPUClothSolver.substepCount(frameDelta: 0.010, substeps: 1), 1)
        let h = try makeHarness(configuration: gpuConfiguration())
        h.frames(2)
        let solver = try gpu(h)
        XCTAssertEqual(solver.ringState.substeps, 16)
        XCTAssertEqual(solver.lastSubstepSeconds, 0.000625)
        XCTAssertEqual(solver.stats.substeps, 16)
        XCTAssertEqual(solver.stats.dispatches, 49, "16 substeps of a predict and two gathers, and the stats")
        XCTAssertTrue(h.cloth.report.contains("sub=16 it=2"), h.cloth.report)
        let eight = try makeHarness(configuration: gpuConfiguration(substeps: 8, iterations: 1))
        eight.frames(2)
        XCTAssertEqual(try gpu(eight).ringState.substeps, 8)
        XCTAssertEqual(try gpu(eight).stats.dispatches, 8 * 2 + 1, "8 substeps of a predict and one gather, and the stats")
        XCTAssertTrue(eight.cloth.report.contains("sub=8 it=1"), eight.cloth.report)
    }

    /// The skinned target moves continuously inside the frame: the solver
    /// slerps each joint between the two feeds once per substep, and the
    /// recorded per-substep skin matrices put a particle on the arc. A
    /// free sheet's joint turned 30 degrees about y in one frame of 16
    /// substeps, after one still frame on the bind pose whose sixteen
    /// targets do not move: the sixteen targets of a corner particle keep
    /// its radius about the axis within 1e-5 m, their angles grow
    /// monotonically in equal steps of 30/16 degrees within a tenth of a
    /// degree, the last one is the new pose's and the first is one step
    /// from the old, so nothing jumps at substep 0. The end-target chord
    /// of a 30 cm bone turning 10 degrees in a frame would sit 1.1 mm off
    /// the arc at mid-frame, which is why the matrices are slerped and not
    /// the targets lerped. And the first soft feed after a hard skin
    /// interpolates from the hard-skinned pose whatever previous pose it
    /// carries (the review of 2026-11-03: the solver used to take that
    /// feed as a jump and stand at its end pose from substep 0): a hard
    /// skin on the bind pose, then the turn fed with the turned pose as
    /// its own previous, still puts the first substep's target one step
    /// from the bind pose, not thirty degrees away.
    func testTheSubstepTargetsInterpolate() throws {
        let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration()), "the GPU solver could not be built")
        solver.floorY = -10
        XCTAssertTrue(solver.build(sheet(n: 20, spacing: 0.4 / 19, y: 1.3), hulls: []))
        let identity = [matrix_identity_float4x4, matrix_identity_float4x4]
        solver.hardSkin(ClothFeed(jointWorld: identity, previousJointWorld: identity, multiplier: 0, deltaTime: dt, hard: true))
        var positions: [SIMD3<Float>] = []
        // One still frame on the pose: the targets stand.
        solver.feed(ClothFeed(jointWorld: identity, previousJointWorld: identity, multiplier: 1, deltaTime: dt, hard: false))
        solver.beginFrame(spheres: [])
        _ = solver.readPositions(into: &positions)
        for k in 0 ..< solver.ringState.substeps {
            let target = try XCTUnwrap(solver.substepTarget(particle: 0, substep: k))
            XCTAssertEqual(simd_distance(target, SIMD3(-0.2, 1.3, -0.2)), 0, accuracy: 1e-6, "substep \(k) of a still frame: the target moved")
        }
        let turned = [simd_float4x4(simd_quatf(angle: 30 * .pi / 180, axis: SIMD3(0, 1, 0))), matrix_identity_float4x4]
        solver.feed(ClothFeed(jointWorld: turned, previousJointWorld: identity, multiplier: 1, deltaTime: dt, hard: false))
        solver.beginFrame(spheres: [])
        _ = solver.readPositions(into: &positions)
        let substeps = solver.ringState.substeps
        XCTAssertEqual(substeps, 16)
        XCTAssertEqual(solver.lastSkinMatrices.count, substeps)
        let corner = 0
        let rest = SIMD3<Float>(-0.2, 1.3, -0.2)
        let radius = simd_length(SIMD3(rest.x, 0, rest.z))
        var angles: [Float] = []
        for k in 0 ..< substeps {
            let target = try XCTUnwrap(solver.substepTarget(particle: corner, substep: k), "substep \(k)")
            XCTAssertEqual(target.y, rest.y, accuracy: 1e-5, "substep \(k): the target left the plane of the turn")
            XCTAssertEqual(simd_length(SIMD3(target.x, 0, target.z)), radius, accuracy: 1e-5, "substep \(k): the target is off the arc")
            let angle = atan2(simd_cross(SIMD3(rest.x, 0, rest.z), SIMD3(target.x, 0, target.z)).y, simd_dot(SIMD3(rest.x, 0, rest.z), SIMD3(target.x, 0, target.z))) * 180 / .pi
            angles.append(angle)
        }
        let step: Float = 30 / Float(substeps)
        for k in angles.indices {
            XCTAssertEqual(angles[k], step * Float(k + 1), accuracy: 0.1, "substep \(k): the target turned \(angles[k]) degrees, not \(step * Float(k + 1))")
            if k > 0 { XCTAssertGreaterThan(angles[k], angles[k - 1], "substep \(k): the angle went back") }
        }
        XCTAssertEqual(angles.last ?? 0, 30, accuracy: 0.1, "the last substep's target is not the new pose's")
        XCTAssertLessThan(angles.first ?? 99, step + 0.1, "the first substep's target jumped \(angles.first ?? 99) degrees from the old pose")
        print("cloth gpu substep targets: corner particle over \(substeps) substeps at " + angles.map { String(format: "%.2f", $0) }.joined(separator: " ") + " degrees")
        // Hard skin on the bind pose, then the turn fed with a previous pose
        // the solver must ignore: the interpolation starts from the hard skin.
        solver.hardSkin(ClothFeed(jointWorld: identity, previousJointWorld: identity, multiplier: 0, deltaTime: dt, hard: true))
        solver.feed(ClothFeed(jointWorld: turned, previousJointWorld: turned, multiplier: 1, deltaTime: dt, hard: false))
        solver.beginFrame(spheres: [])
        _ = solver.readPositions(into: &positions)
        let first = try XCTUnwrap(solver.substepTarget(particle: corner, substep: 0))
        let last = try XCTUnwrap(solver.substepTarget(particle: corner, substep: solver.ringState.substeps - 1))
        let firstAngle = atan2(simd_cross(SIMD3(rest.x, 0, rest.z), SIMD3(first.x, 0, first.z)).y, simd_dot(SIMD3(rest.x, 0, rest.z), SIMD3(first.x, 0, first.z))) * 180 / .pi
        let lastAngle = atan2(simd_cross(SIMD3(rest.x, 0, rest.z), SIMD3(last.x, 0, last.z)).y, simd_dot(SIMD3(rest.x, 0, rest.z), SIMD3(last.x, 0, last.z))) * 180 / .pi
        XCTAssertEqual(firstAngle, step, accuracy: 0.1, "after a hard skin the first substep's target is \(firstAngle) degrees from the hard-skinned pose, not one step")
        XCTAssertEqual(lastAngle, 30, accuracy: 0.1, "after a hard skin the last substep's target is not the fed pose's")
        print(String(format: "cloth gpu substep targets after a hard skin: first %.2f last %.2f degrees", firstAngle, lastAngle))
        solver.destroy()
    }

    // MARK: - The colliders on a free sheet

    /// A free sheet for the collider tests: `n` x `n` particles `spacing`
    /// apart in the xz plane at height `y`, two triangles per quad, every
    /// particle free (inverse mass 20,000 1/kg, the shirt's), skinned to
    /// joint 0 with a slack of 10 m (never binding) and no back-stop (every
    /// particle body-facing), the shirt's material; joint 1 is the hull's,
    /// so a moving hull never moves the sheet's targets.
    private func sheet(n: Int, spacing: Float, y: Float) -> ClothGarmentSetup {
        var positions: [SIMD3<Float>] = []
        for row in 0 ..< n {
            for column in 0 ..< n {
                positions.append(SIMD3(Float(column) * spacing - Float(n - 1) * spacing / 2, y, Float(row) * spacing - Float(n - 1) * spacing / 2))
            }
        }
        var faces: [SIMD3<UInt32>] = []
        for row in 0 ..< n - 1 {
            for column in 0 ..< n - 1 {
                let a = UInt32(row * n + column), b = a + 1, c = a + UInt32(n), d = c + 1
                // Wound so the face normal points +y (up), as the shirt's point out.
                faces.append(SIMD3(a, c, b))
                faces.append(SIMD3(b, c, d))
            }
        }
        let count = positions.count
        return ClothGarmentSetup(
            name: "sheet", origin: .zero, bindPositions: positions, faces: faces,
            inverseMasses: Array(repeating: 20000, count: count),
            influences: Array(repeating: [ClothInfluence(joint: 0, weight: 1)], count: count),
            maxDistance: Array(repeating: 10, count: count),
            backstop: Array(repeating: .greatestFiniteMagnitude, count: count),
            bodyFacing: Set(0 ..< count),
            bindJointWorld: [matrix_identity_float4x4, matrix_identity_float4x4],
            stretchCompliance: 1e-2, shearCompliance: 2e-2, bendCompliance: 0.3, linearDamping: 4, maxLinearVelocity: 4,
            vertexRadius: 0.003, friction: 0.5, iterations: 4, oneWayAgainstRagdolls: true, layer: 0
        )
    }

    /// A unit cube as a hull on joint 1, its eight corners at +-0.5 in the
    /// joint's frame; `world` places the joint.
    private func cube(world: simd_float4x4, friction: Float) -> ClothHullSetup {
        var points: [SIMD3<Float>] = []
        for x in [Float(-0.5), 0.5] { for y in [Float(-0.5), 0.5] { for z in [Float(-0.5), 0.5] { points.append(SIMD3(x, y, z)) } } }
        return ClothHullSetup(joint: 1, points: points, friction: friction, layer: 9, world: world)
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// The solver driven as the cloth drives it, frame by frame: the first
    /// feed hard (as the bridge enforces on Jolt), then `feed`, `beginFrame`
    /// and the read each frame at 10 ms with joint 1 where `hull` puts it
    /// for the frame; `each` sees the positions after a frame's read;
    /// returns the positions after the last frame.
    private func drive(_ solver: any ClothSolver, frames: Int, hull: (Int) -> simd_float4x4, each: ((Int, [SIMD3<Float>]) -> Void)? = nil) -> [SIMD3<Float>] {
        var previous = [matrix_identity_float4x4, hull(0)]
        solver.hardSkin(ClothFeed(jointWorld: previous, previousJointWorld: previous, multiplier: 0, deltaTime: dt, hard: true))
        var positions: [SIMD3<Float>] = []
        for frame in 0 ..< frames {
            let now = [matrix_identity_float4x4, hull(frame)]
            solver.feed(ClothFeed(jointWorld: now, previousJointWorld: previous, multiplier: 1, deltaTime: dt, hard: false))
            solver.beginFrame(spheres: [])
            _ = solver.readPositions(into: &positions)
            each?(frame, positions)
            previous = now
        }
        return positions
    }

    /// A 0.4 m sheet dropped from 30 cm above a unit cube's top lands on it:
    /// after two seconds no particle over the cube is inside its top plane
    /// (y 1.0) — the push-out holds each a radius (3 mm) off the most-facing
    /// plane, so the lowest particle over the cube sits at 1.003 within half
    /// a millimetre — every particle is finite and the sheet has not flown
    /// apart (its extent under 0.6 m); 49 dispatches a frame.
    func testACubeHullPushesParticlesOut() throws {
        let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration()), "the GPU solver could not be built")
        solver.floorY = -10
        let garment = sheet(n: 20, spacing: 0.4 / 19, y: 1.3)
        XCTAssertTrue(solver.build(garment, hulls: [cube(world: Self.translation(SIMD3(0, 0.5, 0)), friction: 0)]), "the solver refused the sheet")
        XCTAssertEqual(solver.particleCount, 400)
        XCTAssertEqual(solver.hullCount, 1)
        XCTAssertEqual(solver.planeCount, 6, "a cube has six faces")
        let p = drive(solver, frames: 200) { _ in Self.translation(SIMD3(0, 0.5, 0)) }
        XCTAssertEqual(p.count, 400)
        var lowest: Float = .greatestFiniteMagnitude, over = 0
        var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
        for q in p {
            XCTAssertTrue(q.x.isFinite && q.y.isFinite && q.z.isFinite, "a particle is not finite")
            minX = min(minX, q.x); maxX = max(maxX, q.x)
            if abs(q.x) < 0.5, abs(q.z) < 0.5 { over += 1; lowest = min(lowest, q.y) }
        }
        print(String(format: "cloth gpu cube: %d of 400 particles over the cube, the lowest at y %.4f (the top at 1.000, the radius 0.003), x extent %.3f m; %d dispatches a frame", over, lowest, maxX - minX, solver.stats.dispatches))
        XCTAssertGreaterThan(over, 300, "the sheet slid off the cube")
        XCTAssertGreaterThanOrEqual(lowest, 1.0 - 1e-4, "a particle sits \(1.0 - lowest) m inside the cube's top")
        XCTAssertEqual(lowest, 1.003, accuracy: 0.0005, "the lowest particle is not a radius off the top")
        XCTAssertLessThan(maxX - minX, 0.6, "the sheet flew apart")
        XCTAssertEqual(solver.stats.dispatches, 49)
        solver.destroy()
        XCTAssertEqual(solver.particleCount, 0)
        XCTAssertEqual(solver.hullCount, 0)
    }

    /// The same sheet dropped from 30 cm onto the floor plane at y 0 lands on
    /// it: no particle below the floor plus the radius, the lowest at
    /// 0.003 within half a millimetre (CoolCloth's contact: y clamped to
    /// floor + radius, xz mixed 0.4 toward the previous position), and the
    /// sheet neither flies apart nor slides; with the floor off it falls
    /// through.
    func testTheFloorStopsASheet() throws {
        let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration()), "the GPU solver could not be built")
        solver.floorY = 0
        XCTAssertTrue(solver.build(sheet(n: 20, spacing: 0.4 / 19, y: 0.3), hulls: []), "the solver refused the sheet")
        let p = drive(solver, frames: 200) { _ in matrix_identity_float4x4 }
        var lowest: Float = .greatestFiniteMagnitude, centre = SIMD3<Float>.zero
        for q in p {
            XCTAssertTrue(q.x.isFinite && q.y.isFinite && q.z.isFinite, "a particle is not finite")
            lowest = min(lowest, q.y)
            centre += q / Float(p.count)
        }
        print(String(format: "cloth gpu floor: the lowest particle at y %.4f (the floor at 0, the radius 0.003), the sheet's centre at (%.3f,%.3f,%.3f)", lowest, centre.x, centre.y, centre.z))
        XCTAssertGreaterThanOrEqual(lowest, 0.003 - 1e-4, "a particle sits \(0.003 - lowest) m into the floor")
        XCTAssertEqual(lowest, 0.003, accuracy: 0.0005)
        XCTAssertLessThan(simd_length(SIMD3(centre.x, 0, centre.z)), 0.01, "the sheet slid \(simd_length(SIMD3(centre.x, 0, centre.z))) m on the floor")
        solver.destroy()

        let open = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration()))
        open.floorEnabled = false
        XCTAssertTrue(open.build(sheet(n: 20, spacing: 0.4 / 19, y: 0.3), hulls: []))
        let fallen = drive(open, frames: 100) { _ in matrix_identity_float4x4 }
        XCTAssertLessThan(fallen.map(\.y).max() ?? 0, -0.5, "with the floor off the sheet did not fall through")
        open.destroy()
    }

    /// Friction against a hull is the one thing the Jolt arm could not have
    /// (Jolt reads a collider's velocity only from a dynamic body, so
    /// `skinColliderFriction` is 0): the hull's own motion over the substep
    /// is known on the GPU, and the tangential part of a particle's
    /// displacement relative to the hull's point motion is scaled by
    /// 1 - `gpuHullFriction`. The sheet rests on the cube for a second, then
    /// the cube moves 2 cm a frame along x for 20 frames (40 cm): with the
    /// friction at 0.2 the sheet's centre follows by at least 20 % of that
    /// (8 cm), and at 0 by under a millimetre, since the push-out is along
    /// the top's normal alone.
    func testAMovingHullCarriesTheClothByFriction() throws {
        var carried: [Float] = []
        for friction in [Float(0.2), 0] {
            let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration(hullFriction: friction)), "the GPU solver could not be built")
            solver.floorY = -10
            XCTAssertTrue(solver.build(sheet(n: 20, spacing: 0.4 / 19, y: 1.05), hulls: [cube(world: Self.translation(SIMD3(0, 0.5, 0)), friction: friction)]))
            let settle = 100, push = 20
            var before = SIMD3<Float>.zero
            let p = drive(solver, frames: settle + push, hull: { frame in
                Self.translation(SIMD3(0.02 * Float(max(0, min(frame - settle + 1, push))), 0.5, 0))
            }, each: { frame, positions in
                // The sheet as it rests on the frame before the cube moves.
                if frame == settle - 1 { before = positions.reduce(.zero, +) / Float(max(positions.count, 1)) }
            })
            let after = p.reduce(.zero, +) / Float(p.count)
            let dx = after.x - before.x
            carried.append(dx)
            XCTAssertTrue(p.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "friction \(friction): a particle is not finite")
            XCTAssertGreaterThanOrEqual(p.filter { abs($0.x - 0.02 * Float(push)) < 0.5 && abs($0.z) < 0.5 }.map(\.y).min() ?? 0, 1.0 - 1e-4, "friction \(friction): a particle sank into the cube")
            print(String(format: "cloth gpu hull friction %.1f: the cube moved 0.40 m and the sheet's centre %.4f m along it (%.0f%%)", friction, dx, dx / 0.40 * 100))
            solver.destroy()
        }
        XCTAssertGreaterThanOrEqual(carried[0], 0.08, "with friction 0.2 the sheet followed the cube by only \(carried[0]) m of 0.40")
        XCTAssertLessThan(abs(carried[1]), 0.001, "without friction the sheet followed the cube by \(carried[1]) m")
    }

    /// With the wait off (`-clothGPUWait off`) the positions are read from
    /// a three-slot read-back ring and the stats from the four-slot stats
    /// ring with no fence, so the encode keeps at most two frames in
    /// flight behind the one it commits (the review of 2026-11-03: the
    /// input ring's own guard alone allowed four, and a GPU three frames
    /// behind would blit over the slot being read): the sheet dropped on
    /// the cube for 200 frames without ever waiting at the read shows at
    /// most two command buffers in flight after every encode, a read-back
    /// slot and a lag of one frame once the first buffer completed, every
    /// read finite, and the sheet resting on the cube's top at the end as
    /// in the waited run (lowest particle over the cube at 1.003 within
    /// half a millimetre).
    func testTheWaitOffModeKeepsTwoFramesInFlight() throws {
        var configuration = gpuConfiguration()
        configuration.gpuWait = false
        let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: configuration), "the GPU solver could not be built")
        solver.floorY = -10
        XCTAssertTrue(solver.build(sheet(n: 20, spacing: 0.4 / 19, y: 1.3), hulls: [cube(world: Self.translation(SIMD3(0, 0.5, 0)), friction: 0)]))
        var deepest = 0, lagged = 0, waited = 0
        let p = drive(solver, frames: 200, hull: { _ in Self.translation(SIMD3(0, 0.5, 0)) }) { frame, positions in
            let ring = solver.ringState
            XCTAssertLessThanOrEqual(ring.inFlight, 2, "frame \(frame): \(ring.inFlight) command buffers in flight behind the encode")
            deepest = max(deepest, ring.inFlight)
            let stats = solver.stats
            if stats.lagFrames == 1 {
                lagged += 1
                XCTAssertNotNil(ring.readBackSlot, "frame \(frame): a lagged read without a read-back slot")
            } else {
                waited += 1
            }
            for q in positions { XCTAssertTrue(q.x.isFinite && q.y.isFinite && q.z.isFinite, "frame \(frame): a particle is not finite") }
        }
        var lowest: Float = .greatestFiniteMagnitude, over = 0
        for q in p where abs(q.x) < 0.5 && abs(q.z) < 0.5 { over += 1; lowest = min(lowest, q.y) }
        print(String(format: "cloth gpu wait off: at most %d in flight, %d lagged reads and %d waited over 200 frames, %d of 400 over the cube, the lowest at y %.4f", deepest, lagged, waited, over, lowest))
        XCTAssertGreaterThan(lagged, 150, "the wait-off mode waited at the read")
        XCTAssertGreaterThan(over, 300, "the sheet slid off the cube")
        XCTAssertGreaterThanOrEqual(lowest, 1.0 - 1e-4, "a particle sits \(1.0 - lowest) m inside the cube's top")
        XCTAssertLessThanOrEqual(lowest, 1.003 + 5e-4, "the lowest particle floats \(lowest - 1.003) m above the radius")
        solver.waitForAll()
        solver.destroy()
    }

    // MARK: - The balls and the sleep

    /// The dent (`ClothFitScenarios.dent`, Jolt's `testAThrownBallDentsTheShirt`):
    /// the harness's ball reaches the GPU solver as a sphere through
    /// `backend.bodyState(for:)` after the step, backed along its velocity
    /// to each substep's time in the kernel, and dents the settled chest by
    /// more than 2 cm (the slack there is 3 cm; Jolt's bound, parity).
    func testAThrownBallDentsTheGPUShirt() throws {
        let h = try makeHarness(configuration: gpuConfiguration(), world: matrix_identity_float4x4)
        try ClothFitScenarios.dent(h, bounds: Self.gpuBounds.dent)
    }

    /// The ball through the sleeper (`ClothFitScenarios.ballWakesTheSleeper`):
    /// asleep, the GPU solver encodes nothing and the ball's swept sphere is
    /// read against the particles' bounds from the last stats; the hit
    /// wakes the cloth within 60 frames, the solver is active again and the
    /// writes resume (Jolt's `testABallThroughASleepingShirtWakesIt`,
    /// parity).
    func testABallThroughASleepingGPUShirtWakesIt() throws {
        let h = try makeHarness(configuration: gpuConfiguration(), world: matrix_identity_float4x4, ragdoll: false)
        try ClothFitScenarios.ballWakesTheSleeper(h)
    }

    /// Asleep, the solver encodes nothing: over 20 asleep frames the
    /// solver's dispatch total stands still, `isActive` is false, nothing
    /// is pending and the position buffer's bytes are what they were — the
    /// buffers are untouched across sleeping frames, as the Jolt tests
    /// compare the particles for exact equality.
    func testASleepingSolverEncodesNothing() throws {
        let h = try makeHarness(configuration: skinOnly)
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body for 2.5 s: asleep (\(h.cloth.report))")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "the solver is at rest")
        let solver = try gpu(h)
        XCTAssertFalse(solver.isActive)
        let dispatches = solver.totalDispatches, frames = solver.ringState.encodedFrames
        let buffer = try XCTUnwrap(solver.currentPositionBuffer)
        let bytes = Data(bytes: buffer.contents(), count: h.shirt.particles.count * MemoryLayout<SIMD4<Float>>.stride)
        let resting = h.particles
        let writes = h.body.overrideWrites
        h.frames(20)
        XCTAssertEqual(solver.totalDispatches, dispatches, "the sleeping solver dispatched")
        XCTAssertEqual(solver.ringState.encodedFrames, frames, "the sleeping solver encoded a frame")
        XCTAssertFalse(solver.ringState.pending)
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0))
        XCTAssertEqual(h.particles, resting, "a particle moved while asleep")
        XCTAssertEqual(Data(bytes: buffer.contents(), count: bytes.count), bytes, "the position buffer's bytes changed while asleep")
        XCTAssertEqual(h.body.overrideWrites, writes, "asleep, nothing is written")
        print("cloth gpu sleep: asleep after \(writes) writes, \(frames) frames and \(dispatches) dispatches encoded; \(h.cloth.report)")
    }

    /// A game frame without a physics step — the engine's fixed stepping
    /// gives two in five at 100 Hz, the hosts' per-frame stepping only a
    /// frame under 1/250 s — feeds the solver nothing, and the solver
    /// encodes nothing (the review of 2026-11-03: it used to simulate the
    /// last feed's delta again and replay its joint motion from the pose
    /// before it, so the targets snapped back a frame at substep 0): after
    /// five stepped frames, a `beginUpdate` and `readBack` with no step
    /// between them leave the encoded-frame count and the dispatch total
    /// where they were, report `sub=0` with `gpu=0`, keep the solver awake
    /// and the particles bitwise where the last frame put them; the next
    /// stepped frame encodes one frame of 49 dispatches again.
    func testAFrameWithoutAStepEncodesNothing() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        h.frames(5)
        let solver = try gpu(h)
        let frames = solver.ringState.encodedFrames, dispatches = solver.totalDispatches
        XCTAssertEqual(frames, 5, "five stepped frames encode five")
        let before = h.particles
        h.cloth.beginUpdate()
        h.cloth.readBack(deltaTime: h.dt, playerPosition: nil)
        XCTAssertEqual(solver.ringState.encodedFrames, frames, "a frame without a step encoded a frame")
        XCTAssertEqual(solver.totalDispatches, dispatches, "a frame without a step dispatched")
        XCTAssertTrue(solver.isActive, "the step-less frame put the solver to rest")
        XCTAssertEqual(solver.stats.dispatches, 0)
        XCTAssertEqual(solver.stats.substeps, 0)
        XCTAssertEqual(solver.stats.gpuMilliseconds, 0, "a frame that encoded nothing reports the last buffer's GPU time")
        XCTAssertEqual(h.particles, before, "a particle moved on a frame without a step")
        h.frame()
        XCTAssertEqual(solver.ringState.encodedFrames, frames + 1, "the stepped frame after it did not encode")
        XCTAssertEqual(solver.stats.dispatches, 49)
        XCTAssertGreaterThan(solver.stats.gpuMilliseconds, 0)
        print("cloth gpu no-step frame: \(frames) frames and \(dispatches) dispatches before and after it; \(h.cloth.report)")
    }

    // MARK: - Determinism and the runaway

    /// The gather is order-fixed and atomic-free, so two solvers on one
    /// device through 120 frames of the sway end bitwise equal — the bounds
    /// of this suite are per device class, and this is what makes a figure
    /// printed here repeatable on this Mac.
    func testTheGPUStepIsDeterministic() throws {
        let a = try makeHarness(configuration: gpuConfiguration())
        let b = try makeHarness(configuration: gpuConfiguration())
        for h in [a, b] {
            for _ in 0 ..< 120 {
                let t = h.time + h.dt
                h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
                h.frame()
            }
        }
        let pa = a.particles, pb = b.particles
        XCTAssertEqual(pa.count, pb.count)
        var differing = 0
        for (x, y) in zip(pa, pb) where x.x.bitPattern != y.x.bitPattern || x.y.bitPattern != y.y.bitPattern || x.z.bitPattern != y.z.bitPattern { differing += 1 }
        XCTAssertEqual(differing, 0, "\(differing) particles differ between two runs of the same 120 frames")
        let ga = try gpu(a), gb = try gpu(b)
        ga.waitForAll(); gb.waitForAll()
        let count = pa.count * MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(Data(bytes: try XCTUnwrap(ga.currentPositionBuffer).contents(), count: count), Data(bytes: try XCTUnwrap(gb.currentPositionBuffer).contents(), count: count), "the position buffers differ")
        XCTAssertEqual(a.cloth.runawayCount, 0)
        print("cloth gpu determinism: \(pa.count) particles bitwise equal over two runs of 120 frames; \(a.cloth.report)")
    }

    /// A NaN written into the current position buffer through its shared
    /// storage (particle 2000, a chest particle with 7 cm of slack, after a
    /// wait for anything in flight): the gather spreads it to its
    /// neighbours within the frame's substeps, the read-back finds it,
    /// counts one runaway, hard skins the shirt (`hardSkinCount` + 1) and
    /// every particle is finite and on its target again, as the Jolt path's
    /// runaway rule does it; the frames after count nothing more. The
    /// design's particle 7 is a pin, and a pin cannot run away on the GPU:
    /// `zcSolve` writes a pin's target over whatever its position holds at
    /// every substep, so a NaN there is healed before any read sees it
    /// (measured 2026-11-03: no runaway, no hard skin).
    func testARunawayParticleHardSkinsTheGPUShirt() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        h.frames(50)
        let solver = try gpu(h)
        let hardSkins = h.cloth.hardSkinCount
        solver.waitForAll()
        let buffer = try XCTUnwrap(solver.currentPositionBuffer)
        let victim = 2000
        XCTAssertGreaterThan(h.shirt.maxDistance[victim], 0, "the victim must be a free particle: a pin is rewritten every substep")
        buffer.contents().advanced(by: victim * MemoryLayout<SIMD4<Float>>.stride).storeBytes(of: SIMD4<Float>(.nan, .nan, .nan, 20000), as: SIMD4<Float>.self)
        h.frame()
        XCTAssertEqual(h.cloth.runawayCount, 1, "the NaN was not counted as a runaway")
        XCTAssertEqual(h.cloth.hardSkinCount, hardSkins + 1, "the runaway did not hard skin")
        let p = h.particles, t = h.targets
        XCTAssertTrue(p.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "a particle is still not finite")
        var worst: Float = 0
        for (a, b) in zip(p, t) { worst = max(worst, simd_distance(a, b)) }
        XCTAssertLessThan(worst, 1e-3, "after the hard skin a particle is \(worst) m off its target")
        h.frames(10)
        XCTAssertEqual(h.cloth.runawayCount, 1, "the runaway counted again")
        XCTAssertTrue(h.excess().finite)
        print("cloth gpu runaway: \(h.cloth.report)")
    }

    // MARK: - The pick without a device, and the colliders

    /// `Configuration.solver` set to `gpu` with no Metal device to build on:
    /// the attach says once that Jolt stands in (`activeSolver` reads
    /// `jolt`) and builds what the Jolt arm builds — the soft body and the
    /// eleven hulls as Jolt bodies — so the hosts' pickers are safe to flip
    /// on a box without a GPU (Jolt's
    /// `testTheGPUPickStandsOnJoltUntilTheGPUSolverIsBuilt` was this test's
    /// forerunner).
    func testTheGPUSolverIsRefusedWithoutADevice() throws {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton, let colliders = asset.colliders, !colliders.isEmpty else { throw XCTSkip("Models/Zombie is not bundled") }
        let h = ClothHarness(dt: dt, asset: asset, joints: joints, configuration: gpuConfiguration(), solver: .gpu, device: nil)
        XCTAssertTrue(h.attached, "the GPU pick attaches on Jolt without a device")
        XCTAssertEqual(h.cloth.configuration.solver, .gpu, "the pick is kept")
        XCTAssertEqual(h.cloth.activeSolver, .jolt, "Jolt stands in")
        XCTAssertNil(h.cloth.gpuSolver(ofGarment: 0))
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20 + 1 + colliders.count, "Jolt stood in: the floor slab, twenty parts, the shirt and the hulls as Jolt bodies")
        XCTAssertEqual(h.cloth.skinColliderCount, colliders.count)
        XCTAssertFalse(h.cloth.report.contains("[gpu]"), h.cloth.report)
        h.frames(5)
        XCTAssertEqual(h.cloth.runawayCount, 0)
        XCTAssertGreaterThan(h.body.overrideWrites, 0)
    }

    /// On the GPU path the hulls are plane sets in the solver's buffers, not
    /// Jolt bodies: `skinColliderCount` is 11 while the Jolt world holds
    /// only the floor slab and the twenty parts (no soft body, no kinematic
    /// hulls); `-clothColliders off` gives 0 hulls and the same world; the
    /// report names the arm (`shirt[gpu]`) and counts them as `colliders=`,
    /// `hulls=` and `planes=` beside the constraints.
    func testTheSkinCollidersAreCountedOnTheGPUPath() throws {
        guard let colliders = ClothFixtures.asset?.colliders, !colliders.isEmpty else { throw XCTSkip("the sidecar carries no skin colliders") }
        let world = try makeHarness(configuration: gpuConfiguration())
        XCTAssertEqual(world.cloth.skinColliderCount, colliders.count, "every collider of the sidecar is a hull in the solver")
        XCTAssertEqual(world.physics.backend.bodyCount, 1 + 20, "the floor slab and the twenty parts: no Jolt soft body, no Jolt hulls")
        XCTAssertTrue(world.cloth.report.hasPrefix("cloth shirt[gpu]:"), world.cloth.report)
        XCTAssertTrue(world.cloth.report.contains("colliders=\(colliders.count)"), world.cloth.report)
        XCTAssertTrue(world.cloth.report.contains("hulls=11 planes=832 stretch=10425 bend=10425"), world.cloth.report)
        XCTAssertTrue(world.cloth.report.contains("sim=on"), world.cloth.report)
        XCTAssertTrue(world.cloth.summary.contains("lag=0f"), world.cloth.summary)
        var off = gpuConfiguration()
        off.skinColliders = false
        let without = try makeHarness(configuration: off)
        XCTAssertEqual(without.cloth.skinColliderCount, 0, "the switch builds none")
        XCTAssertEqual(without.physics.backend.bodyCount, 1 + 20)
        XCTAssertTrue(without.cloth.report.contains("hulls=0 planes=0"), without.cloth.report)
        let alone = try makeHarness(configuration: skinOnly)
        XCTAssertEqual(alone.cloth.skinColliderCount, 0, "the skin-only cloth builds no hulls on the GPU either")
        world.frames(5)
        world.cloth.detach()
        XCTAssertEqual(world.cloth.skinColliderCount, 0)
        XCTAssertEqual(world.physics.backend.bodyCount, 1 + 20, "the world is as it was")
        XCTAssertEqual(world.cloth.report, "cloth: none")
    }

    // MARK: - The fit scenarios on the GPU

    /// The hang on the GPU (`ClothFitScenarios.hang`; Jolt's
    /// `testTheShirtHangsFromTheShouldersAndTheButtonsStayRigid`): the sag
    /// grows down the shirt and is gravity's, everything within its slack,
    /// the pins on the skin, the proxy off the body, the buttons rigid, no
    /// particle inside the posed skin. Bounds `gpuBounds.hang` (measured
    /// 2026-11-03: the sag 9.4 mm, the hem 7.8 mm over the yoke's 1.3, the
    /// back-stop 1.25 mm, the clearance 2.12 mm).
    func testTheGPUShirtHangsFromTheShoulders() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        let control = try makeHarness(configuration: gpuConfiguration(), gravity: .zero)
        try ClothFitScenarios.hang(h, control: control, bounds: Self.gpuBounds.hang)
    }

    /// The idle on the GPU (`ClothFitScenarios.idle`; Jolt's
    /// `testAnIdleShirtStaysWithinItsSlackAndThePinsOnTheSkin`): within the
    /// slack, the pins on the skin, the parts at their rest errors and the
    /// cuffs where the hands are. Bounds `gpuBounds.idle` (measured
    /// 2026-11-03: the cuffs 2 mm from their targets with the hands 32 mm
    /// off their joints, no excess, the pins within 3.1e-6 m).
    func testTheGPUIdleShirtStaysWithinItsSlack() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        try ClothFitScenarios.idle(h, bounds: Self.gpuBounds.idle)
    }

    /// The sway on the GPU (`ClothFitScenarios.sway`; Jolt's
    /// `testASwayingBodyKeepsTheShirtWithinItsSlack`) on the three collision
    /// models, the penetration count per model from `swayPenetrationBound`
    /// (measured 2026-11-03: none on any model; Jolt's 0 / 0 / 4).
    func testTheGPUSwayingBodyKeepsTheShirtWithinItsSlack() throws {
        for (label, configuration, lagBound) in [("skin only", skinOnly, false), ("world", gpuConfiguration(), false), ("ragdoll and skin", ragdollAndSkin, true)] {
            var bounds = Self.gpuBounds.sway
            bounds.penetration = swayPenetrationBound[label] ?? 0
            let h = try makeHarness(configuration: configuration)
            try ClothFitScenarios.sway(h, label: label, lagBound: lagBound, bounds: bounds)
        }
    }

    /// The re-seat on the GPU (`ClothFitScenarios.reseat`): the entity's
    /// jump re-seats the shirt through the CPU hard skin while the frame's
    /// command buffer may be in flight — the case the design settles with
    /// the wait inside `hardSkin`.
    func testAPelvisJumpReseatsTheGPUShirt() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.reseat(h)
    }

    /// The sleep and the wake on the GPU (`ClothFitScenarios.sleepAndWake`
    /// and `creepWakes`): the joints alone put the GPU cloth to sleep and
    /// wake it, as on Jolt.
    func testAStillBodyPutsTheGPUClothToSleepAndAMovingJointWakesIt() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.sleepAndWake(h)
        let creeping = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.creepWakes(creeping)
    }

    /// The range on the GPU (`ClothFitScenarios.farPlayer`): out of range
    /// nothing is fed, encoded or written, and the return hard skins.
    func testAFarPlayerShutsTheGPUSlackAndStopsTheReadBack() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.farPlayer(h)
    }

    /// The arms-forward idle on the GPU (`ClothFitScenarios.armsForwardIdle`;
    /// Jolt's `testTheArmsForwardIdleKeepsTheArmholeNearItsTarget`) on the
    /// world model and the skin-only control. Measured 2026-11-03 at the
    /// default's two gathers: the armhole band's farthest particle 143.4 mm
    /// from its target, on its slack ball (Jolt's 67.0 mm was where the
    /// edges held it against an inexact clamp), the worst excess 0.000 m,
    /// 18.0 mm behind the skin at the yoke; 12 particles inside the posed
    /// skin with the hulls (yoke 2, back 4, armhole 6, 4.7 mm deep) and 18
    /// without (yoke 6, back 4, sleeves 1, armhole 7, 5.0 mm deep), where
    /// Jolt read 65 and 154 and one gather 7 and 16: the exact back-stop
    /// alone keeps the GPU shirt off the skin all but a handful, the
    /// stiffer edges of the second gather hold a few more of them where the
    /// hulls — convex, on 48 skin points — sit inside the concave skin of
    /// the back and the armhole (phase 4's gap capsules), and the hulls
    /// take a third of them away. The control is held to a dozen at least
    /// (the patches still show without the hulls) and the hulls to under
    /// three quarters of it (Jolt's two fifths at 65 / 154 is a ratio of
    /// a dozen particles here).
    func testTheGPUArmsForwardIdleKeepsTheArmholeNearItsTarget() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0) else { throw XCTSkip("the idle clip is not bundled") }
        guard let joints = ClothFixtures.skeleton, let hand = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l"),
              let pelvis = joints.jointPaths.firstIndex(of: "/root/pelvis") else { throw XCTSkip("no skeleton") }
        let handRise = (pose[hand].columns.3.y - pose[pelvis].columns.3.y) - (joints.bindModelTransforms[hand].columns.3.y - joints.bindModelTransforms[pelvis].columns.3.y)
        XCTAssertGreaterThan(handRise, 0.1, "the idle holds the hands up by \(handRise) m")
        var insideByModel: [String: Int] = [:]
        for (label, configuration) in [("skin only", skinOnly), ("world", gpuConfiguration())] {
            var bounds = Self.gpuBounds.armsForward
            bounds.penetration = label == "world" ? Self.gpuBounds.armsForward.penetration : nil
            let h = try makeHarness(configuration: configuration, pose: pose)
            let figures = try ClothFitScenarios.armsForwardIdle(h, label: label, handRise: handRise, bounds: bounds)
            insideByModel[label] = figures.inside
        }
        XCTAssertGreaterThan(insideByModel["skin only"] ?? 0, 12, "the skin-only control no longer shows the patches the hulls are for: \(insideByModel)")
        XCTAssertLessThan(Float(insideByModel["world"] ?? Int.max) / Float(max(insideByModel["skin only"] ?? 1, 1)), 0.75, "the skin's hulls take less than a quarter of the particles inside the posed skin away: \(insideByModel)")
    }

    /// The arm swing on the GPU (`ClothFitScenarios.armSwing`; Jolt's
    /// `testASwingingArmKeepsTheSleeveOnItsHull`) on the world model and the
    /// skin-only control, the hulls slerped per substep with the joints.
    /// Measured 2026-11-03 at two gathers: with the hulls no particle more
    /// than 2 mm inside the posed skin at any read frame (Jolt 9), the
    /// deepest 1.1 mm at frame 25 (Jolt 9.2), the worst excess +0.0 mm
    /// (Jolt 6.8), the sleeves 50.0 mm off the skin (Jolt 50.0); the
    /// skin-only control 3 inside at the most, 4.0 mm deep, where Jolt read
    /// 48 — the exact back-stop again. The control is held to two at least.
    func testTheGPUSwingingArmKeepsTheSleeveOnItsHull() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0), let joints = ClothFixtures.skeleton else { throw XCTSkip("the idle clip is not bundled") }
        guard let upperarm = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l"),
              let elbow = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l") else { throw XCTSkip("no left arm") }
        var readings: [(frame: Int, inside: Int, deepest: Float, excess: Float, lift: Float, elbowSpeed: Float)] = []
        for (label, configuration) in [("world", gpuConfiguration()), ("skin only", skinOnly)] {
            let h = try makeHarness(configuration: configuration)
            let run = try ClothFitScenarios.armSwing(h, label: label, pose: pose, joints: joints, upperarm: upperarm, elbow: elbow,
                                                     bounds: label == "world" ? Self.gpuBounds.swing : nil, controlInsideAtLeast: 2)
            if label == "world" { readings = run }
        }
        print("cloth gpu arm swing, world, per frame (frame inside deepest_mm excess_mm lift_mm elbow_m/s): " + readings.map { String(format: "%d %d %.1f %+.1f %.1f %.2f", $0.frame, $0.inside, -$0.deepest * 1000, $0.excess * 1000, $0.lift * 1000, $0.elbowSpeed) }.joined(separator: "; "))
    }

    // MARK: - Cost

    /// The feed, the GPU, the wait, the read-back and the shell per frame
    /// over 300 frames of the sway, medians and maxima, and the dispatch
    /// count, for the headset budget of the design's section 8 (a debug
    /// build; the release figures are the Mac host's `report` line); 300
    /// override writes (Jolt's `testTimingsOverThreeHundredFrames`, parity).
    func testGPUTimingsOverThreeHundredFrames() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        var feed: [Double] = [], gpuTime: [Double] = [], wait: [Double] = [], read: [Double] = [], bind: [Double] = [], skin: [Double] = []
        var dispatches = 0, substeps = 0
        for _ in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            let timings = h.cloth.timings
            skin.append(timings.skin); read.append(timings.readBack); bind.append(timings.bind)
            let stats = solver.stats
            feed.append(stats.feedMicroseconds); gpuTime.append(stats.gpuMilliseconds * 1000); wait.append(stats.waitMicroseconds)
            dispatches = max(dispatches, stats.dispatches); substeps = max(substeps, stats.substeps)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean %.0f us, median %.0f us, max %.0f us", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted.last ?? 0)
        }
        print("cloth gpu timing (300 frames, 100 Hz, \(h.cloth.configuration.gpuSubsteps) substeps asked, \(substeps) encoded, \(dispatches) dispatches, \(h.shirt.particles.count) particles, \(h.shirt.render?.vertexCount ?? 0) shell vertices, \(device.name)): skin \(stats(skin)); feed \(stats(feed)); gpu \(stats(gpuTime)); wait \(stats(wait)); read-back \(stats(read)); bind \(stats(bind)); \(h.cloth.summary)")
        XCTAssertEqual(h.body.overrideWrites, 300)
        XCTAssertEqual(dispatches, 3 * 16 + 1, "16 substeps at 10 ms, two gathers each, plus the stats kernel")
        XCTAssertEqual(substeps, 16)
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }
}
