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
//  Phase 2 (2026-11-04) added the shell's two kernels and the 16k proxy:
//  the GPU shell against the CPU shell on the same frame, the drape figure
//  on both proxies (`ClothMetrics.Drape`), the fit scenarios on
//  `Zombie.cloth16k.json` with bounds of their own (`gpuBounds16k`), the
//  16k proxy at rest against the posed skin, the Jolt arm's refusal of it,
//  and the 16k cost; the hull counts were re-pinned the same day to the
//  phase-2 cook's colliders (816 planes on 438 points, where the design
//  counted 832 on 446). The budget phase (2026-11-04, closed 2026-11-10)
//  added the hull candidates' tree, the contact diffs between the
//  candidate loop and the every-hull one on six motions, the loss over the
//  chase's clips and the falls that keeps the candidates off by default,
//  the coplanar merge's enclosure, the sheet without joint paths, and the
//  two cost tests timed in rotation behind a heater frame.
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

    /// The GPU arm's fit bounds on the 16k proxy (`Zombie.cloth16k.json`,
    /// the phase-2 cook of `Docs/GPUCloth.md`: 15,979 particles, 1,848
    /// pins, 42,440 + 42,424 constraints), the same scenarios at the same
    /// 16 substeps and two gathers, measured 2026-11-04 on the M4 Max (a
    /// debug build) the day the cook landed and pinned with the 4k rows'
    /// margins. The finer shirt hangs lower, as a shirt does: the chest and
    /// the back sag 22.9 mm (9.4 at 4k) with the hem band's mean 16.7 mm
    /// over the yoke's 2.8 (7.8 over 1.3 at 4k), nothing past its slack by
    /// more than 2e-6 m in the hang or the sway, the pins within 3.2e-6 m,
    /// 1.67 mm behind the skin at the worst (1.25 at 4k; the clamp and the
    /// back-stop as exact as before), the nearest particle 1.73 mm off the
    /// surface under the shirt (2.12), nothing inside the posed skin after
    /// the hang or the sway, 0.0 mm of sag without gravity; in the
    /// arms-forward idle the armhole band's farthest particle sits ON its
    /// 150 mm slack ball (150.004 mm, where the 4k's rested 143.4 inside
    /// it), 13.2 mm behind its skinned plane, 30 particles inside the posed
    /// skin with the hulls (armhole 19, sleeves 5, chest 4, yoke 2, 4.4 mm
    /// deep; 12 at 4k) and 71 without (8.4 mm deep; 18 at 4k) — four times
    /// the particles read about twice the count, and the hulls take three
    /// fifths away; the arm swing leaves at most 9 inside at a read frame
    /// (frame 37; none at 4k), 5.2 mm deep at the worst (1.1), 0.0 mm past
    /// the slack, the sleeves 50.0 mm off the skin as at 4k. Re-pin from
    /// the printed lines when the solver or the cook changes.
    private static let gpuBounds16k = ClothFitBounds(
        hang: .init(penetration: 0, sag: 0.005, hemOverYoke: 0.005, excess: 0.001, pins: 1e-5, clearance: 0.001, inward: 0.0022, rigid: 1e-4, controlSag: 0.001),
        idle: .init(excess: 0.001, pins: 1e-5),
        sway: .init(penetration: 0, excess: 0.001, excessOverLaggingParts: 0.005, pins: 1e-5),
        dent: .init(dent: 0.02),
        armsForward: .init(penetration: 36, armhole: 0.151, excess: 0.001, inward: 0.025),
        swing: .init(inside: 12, deepest: 0.0065, excess: 0.001, lift: 0.055)
    )

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
                             pose: [simd_float4x4]? = nil, gravity: SIMD3<Float> = SIMD3(0, -9.8, 0), device: MTLDevice? = nil, sidecar: String? = nil,
                             frameDelta: Float? = nil) throws -> ClothHarness
    {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        if let sidecar, ClothFixtures.sidecar(named: sidecar) == nil { throw XCTSkip("Models/Zombie/\(sidecar) is not bundled (the phase-2 cook)") }
        let harness = ClothHarness(dt: frameDelta ?? dt, asset: asset, joints: joints, configuration: configuration, world: world, ragdoll: ragdoll, obstacles: obstacles, mesh: mesh,
                                   normals: normals, pose: pose, gravity: gravity, solver: .gpu, device: device ?? self.device, sidecar: sidecar)
        XCTAssertTrue(harness.attached, "the shirt attached")
        XCTAssertEqual(harness.cloth.activeSolver, .gpu, "the shirt is not on the GPU solver (\(harness.cloth.report))")
        if gravity != SIMD3(0, -9.8, 0) { harness.cloth.gpuSolver(ofGarment: 0)?.gravity = gravity }
        return harness
    }

    /// The harness on the phase-2 sidecar, `Zombie.cloth16k.json`, or a skip
    /// while the cook has not landed.
    private func makeHarness16k(configuration: ZombieCloth.Configuration, world: simd_float4x4 = ClothFixtures.standing, ragdoll: Bool = true,
                                pose: [simd_float4x4]? = nil, gravity: SIMD3<Float> = SIMD3(0, -9.8, 0)) throws -> ClothHarness
    {
        let h = try makeHarness(configuration: configuration, world: world, ragdoll: ragdoll, pose: pose, gravity: gravity, sidecar: ClothFixtures.sidecar16kName)
        XCTAssertGreaterThan(h.shirt.particles.count, 12000, "the harness is not on the 16k proxy (\(h.sidecarName), \(h.shirt.particles.count) particles)")
        return h
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

    /// The GPU configuration with the hull candidates on. They are an
    /// option since 2026-11-10 (`gpuHullCandidates` is off by default,
    /// the every-hull loop being the exact one), so a test that reads the
    /// candidate loop asks for it by name.
    private var withHullCandidates: ZombieCloth.Configuration {
        var configuration = gpuConfiguration()
        configuration.gpuHullCandidates = true
        return configuration
    }

    private var skinOnly: ZombieCloth.Configuration { gpuConfiguration(collisionModel: .skinOnly) }
    private var ragdollAndSkin: ZombieCloth.Configuration { gpuConfiguration(collisionModel: .ragdollAndSkin) }

    /// The shirt's GPU solver.
    private func gpu(_ h: ClothHarness) throws -> GPUClothSolver {
        try XCTUnwrap(h.cloth.gpuSolver(ofGarment: 0), "the shirt is not on the GPU solver")
    }

    /// The dispatches a frame carries beyond its substeps and the stats:
    /// the shell's two (`zcTriangleFrames` + `zcShell`, phase 2) when the
    /// garment was handed its shell, none with `gpuShell` off or on a
    /// garment without one (the cube and floor sheets).
    private func shellDispatches(_ h: ClothHarness) throws -> Int {
        try gpu(h).hasGPUShell ? 2 : 0
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
    /// 16 B and `ZCSphere` 32 B, and since phase 2 (2026-11-04) the shell's
    /// three, `ZCShellParams` 128 B, `ZCTriangleFrame` 48 and
    /// `ZCShellBinding` 48 — and `ZCLayout.mismatches()` pins every
    /// member's offset and alignment. The design's `zcTriangleFrames` and
    /// `zcShell` are the fourth and fifth kernels since phase 2.
    func testTheMetallibExposesTheKernels() throws {
        let name = RenderShaderLibraryPlatformResource.resourceName(baseName: "ZombieCloth")
        let url = try XCTUnwrap(GPUClothSolver.metallibURL, "\(name).metallib is not in the kit's Shaders resources")
        XCTAssertEqual(url.lastPathComponent, "\(name).metallib")
        let library = try device.makeLibrary(URL: url)
        let names = Set(library.functionNames)
        XCTAssertEqual(GPUClothSolver.kernelNames, ["zcPredict", "zcSolve", "zcStats", "zcTriangleFrames", "zcShell"])
        XCTAssertEqual(MemoryLayout<ZCShellParams>.stride, 128)
        XCTAssertEqual(MemoryLayout<ZCTriangleFrame>.stride, 48)
        XCTAssertEqual(MemoryLayout<ZCShellBinding>.stride, 48)
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

    /// The sidecar's eleven hulls (28 to 48 points each, 438 in all) as plane
    /// sets: every triple's plane kept when all the hull's points lie on one
    /// side of it, deduplicated at 1e-4 on the normal's components and the
    /// offset, which gives 87, 83, 82, 88, 52, 84, 82, 66, 72, 60 and 60
    /// planes for the pelvis, the three spine links, the neck, the two
    /// clavicles, the two upper arms and the two forearms — 816 in all,
    /// under the 2n - 4 bound of 832 (numpy over the sidecar as the phase-2
    /// cook of 2026-11-04 rewrote it, scratchpad tests16k/measure16k.py;
    /// the cook of 2026-11-03 had 35, 37 and 34 points on the neck and the
    /// right arm's two hulls for 66, 70 and 64 planes, 446 points and 832
    /// planes, the design's figures, and the shirt itself is unchanged).
    /// Every point of a hull reads inside all its planes within 1e-5 m, a
    /// point moved 3 mm out along a plane's normal reads outside that plane
    /// by 3 mm, the bounding sphere holds every point and is inflated by the
    /// vertex radius, and the attached solver counts the same 816.
    func testTheHullPlanesEncloseTheirPoints() throws {
        guard let colliders = ClothFixtures.asset?.colliders, colliders.count == 11 else { throw XCTSkip("the sidecar carries no skin colliders") }
        let expected = [87, 83, 82, 88, 52, 84, 82, 66, 72, 60, 60]
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
        XCTAssertEqual(total, 816, "planes in all: \(counts)")
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        XCTAssertEqual(solver.hullCount, 11)
        XCTAssertEqual(solver.planeCount, 816, "the attached solver's planes")
        XCTAssertEqual(solver.hullPlaneSets.map(\.planeCount), expected)
        print("cloth gpu hulls: \(counts) planes, \(total) in all over \(colliders.reduce(0) { $0 + $1.pointVectors.count }) points; \(h.cloth.report)")
    }

    // MARK: - The hull candidates and the coplanar merge (2026-11-04)

    /// The skeleton tree the solver reads off the sidecar's joint paths and
    /// the candidates it derives from it, on both proxies. The shirt's
    /// thirteen feed joints are the pelvis, three spine links, the neck,
    /// the two clavicles, upper arms and forearms and the two thighs, so
    /// the parents are [-1, 0, 1, 2, 3, 3, 5, 6, 3, 8, 9, 0, 0], and the
    /// eleven hulls sit on joints 0-10 in the sidecar's order (pelvis,
    /// spine 1-3, neck, clavicle l, clavicle r, upper arm l, upper arm r,
    /// forearm l, forearm r). Every pin has none; every free particle's
    /// list is sorted, duplicate-free, at most four long, and is the rule's
    /// set — the hulls of its influence joints and of their parents and
    /// children — whenever that set has four or fewer, and four of it when
    /// it has more. Measured 2026-11-04: at 4k the 3,463 free particles
    /// have 1 / 2 / 3 / 4 candidates 80 / 294 / 923 / 2,166 times, 1,249
    /// of them capped from up to 9 (a spine-link particle has the links
    /// above and below, the neck and both clavicles; one on spine 3 with a
    /// clavicle influence reaches 9); at 16k 276 / 1,332 / 3,770 / 8,753
    /// over 14,131 free particles, 5,047 capped. The cap keeps an influence
    /// joint's own hull on every particle but the few whose own hull is
    /// farther at rest than four neighbours' (printed). What the list
    /// costs in contacts is the three tests' below: nothing in the six
    /// motions the first two play, and a great deal over the chase's
    /// clips and the falls, which is why the candidates are an option and
    /// the default configuration walks every hull — held here too, on a
    /// second harness per proxy: `gpuHullCandidates` false, the solver's
    /// `walksEveryHull` true and the report's `hullCandidates=off`, where
    /// the harness that asks for the candidates reads `on`. That the
    /// four kept ARE the nearest is held too (2026-11-10, the review's
    /// gap: the count and the membership alone would pass a cap that kept
    /// any four): each qualifying hull's signed distance to the particle's
    /// rest position is taken again here, in the hull's bind frame from
    /// the sidecar's own matrices, and no kept hull may read farther than
    /// a dropped one by more than a tenth of a millimetre — the solver
    /// ranks in the attach's world frame, so the two orders agree to the
    /// float rounding of a rigid transform and not to the bit.
    func testTheHullCandidatesFollowTheSkeleton() throws {
        for (label, sidecar, expectedHistogram, expectedCapped) in [("4k", nil, [0, 80, 294, 923, 2166], 1249), ("16k", ClothFixtures.sidecar16kName, [0, 276, 1332, 3770, 8753], 5047)] {
            let h = try makeHarness(configuration: withHullCandidates, sidecar: sidecar)
            let solver = try gpu(h)
            let candidates = try XCTUnwrap(solver.hullCandidates, "\(label): no candidates were built")
            let shirt = h.shirt
            // The default configuration builds the same lists and does not
            // read them: every hull on every particle.
            let shipped = try makeHarness(configuration: gpuConfiguration(), sidecar: sidecar)
            XCTAssertFalse(ZombieCloth.Configuration().gpuHullCandidates, "the candidates are off by default")
            XCTAssertFalse(shipped.cloth.configuration.gpuHullCandidates, "\(label): the default harness asks for no candidates")
            XCTAssertTrue(try gpu(shipped).walksEveryHull, "\(label): the default configuration walks every hull")
            XCTAssertEqual(try gpu(shipped).hullCandidates?.words, candidates.words, "\(label): the lists are built the same with the option off")
            XCTAssertTrue(shipped.cloth.report.hasSuffix("hullCandidates=off"), shipped.cloth.report)
            XCTAssertTrue(shipped.cloth.summary.contains("hullCandidates=off"), shipped.cloth.summary)
            XCTAssertTrue(h.cloth.report.hasSuffix("hullCandidates=on"), h.cloth.report)
            XCTAssertTrue(h.cloth.summary.contains("hullCandidates=on"), h.cloth.summary)
            XCTAssertEqual(candidates.parents, [-1, 0, 1, 2, 3, 3, 5, 6, 3, 8, 9, 0, 0], "\(label): the tree off the joint paths")
            XCTAssertFalse(candidates.everyHull, "\(label): the shirt has joint paths")
            XCTAssertEqual(solver.hullPlaneSets.map(\.joint), [0, 1, 2, 3, 4, 5, 8, 6, 9, 7, 10], "\(label): the hulls' joints in the sidecar's order")
            XCTAssertEqual(candidates.words.count, shirt.particles.count)
            var hullsOfJoint = [[Int]](repeating: [], count: candidates.parents.count)
            for (hull, set) in solver.hullPlaneSets.enumerated() { hullsOfJoint[set.joint].append(hull) }
            var children = [[Int]](repeating: [], count: candidates.parents.count)
            for (joint, parent) in candidates.parents.enumerated() where parent >= 0 { children[parent].append(joint) }
            let inverseBind = shirt.bindMatrices.map(\.inverse)
            // The rest positions once (the asset builds the array at every
            // read) and each hull's planes as plain floats, for the few
            // million plane tests of the cap's check in a debug build.
            let restPositions = shirt.positions
            let flatPlanes: [[Float]] = solver.hullPlaneSets.map { set in set.planes.flatMap { [$0.x, $0.y, $0.z, $0.w] } }
            func restDistance(_ hull: Int, _ p: SIMD3<Float>) -> Float {
                let local = inverseBind[solver.hullPlaneSets[hull].joint] * SIMD4(p, 1)
                let x = local.x, y = local.y, z = local.z
                var worst = -Float.greatestFiniteMagnitude
                flatPlanes[hull].withUnsafeBufferPointer { planes in
                    var k = 0
                    while k < planes.count {
                        let d = planes[k] * x + planes[k + 1] * y + planes[k + 2] * z + planes[k + 3]
                        if d > worst { worst = d }
                        k += 4
                    }
                }
                return worst
            }
            var ownHullDropped = 0, pins = 0, free = 0, rankedWrong = 0, closestCall = Float.greatestFiniteMagnitude
            for i in shirt.particles.indices {
                let list = candidates.candidates(of: i)
                if shirt.maxDistance[i] == 0 {
                    pins += 1
                    XCTAssertTrue(list.isEmpty, "\(label): pin \(i) has candidates \(list)")
                    continue
                }
                free += 1
                XCTAssertFalse(list.isEmpty, "\(label): free particle \(i) has no candidate")
                XCTAssertLessThanOrEqual(list.count, zcHullCandidateCount, "\(label): particle \(i) carries \(list.count)")
                XCTAssertEqual(list, list.sorted(), "\(label): particle \(i)'s candidates are not ascending")
                XCTAssertEqual(Set(list).count, list.count, "\(label): particle \(i) names a hull twice")
                var expected = Set<Int>(), own = Set<Int>()
                for pair in shirt.influences[i] where pair[1] > 0 {
                    let joint = Int(pair[0])
                    expected.formUnion(hullsOfJoint[joint])
                    own.formUnion(hullsOfJoint[joint])
                    if candidates.parents[joint] >= 0 { expected.formUnion(hullsOfJoint[candidates.parents[joint]]) }
                    for child in children[joint] { expected.formUnion(hullsOfJoint[child]) }
                }
                if expected.count <= zcHullCandidateCount {
                    XCTAssertEqual(Set(list), expected, "\(label): particle \(i)'s candidates are not the rule's set")
                } else {
                    XCTAssertEqual(list.count, zcHullCandidateCount, "\(label): particle \(i) had \(expected.count) qualifying hulls and keeps \(list.count)")
                    XCTAssertTrue(Set(list).isSubset(of: expected), "\(label): particle \(i) keeps a hull the rule did not name")
                    if !own.isSubset(of: Set(list)) { ownHullDropped += 1 }
                    // The four kept are the four nearest at rest.
                    var farthestKept = -Float.greatestFiniteMagnitude, nearestDropped = Float.greatestFiniteMagnitude
                    for hull in expected {
                        let distance = restDistance(hull, restPositions[i])
                        if list.contains(hull) { farthestKept = max(farthestKept, distance) } else { nearestDropped = min(nearestDropped, distance) }
                    }
                    closestCall = min(closestCall, nearestDropped - farthestKept)
                    if farthestKept > nearestDropped + 1e-4 {
                        rankedWrong += 1
                        if rankedWrong <= 5 {
                            XCTFail("\(label): particle \(i) keeps a hull \(farthestKept) m from its rest position and drops one at \(nearestDropped) m (kept \(list) of \(expected.sorted()))")
                        }
                    }
                }
            }
            XCTAssertEqual(rankedWrong, 0, "\(label): \(rankedWrong) capped particles do not keep their four nearest hulls")
            XCTAssertEqual(candidates.histogram, expectedHistogram, "\(label): the candidate-count histogram")
            XCTAssertEqual(candidates.capped, expectedCapped, "\(label): the particles capped")
            XCTAssertEqual(candidates.histogram.reduce(0, +), free)
            XCTAssertEqual(candidates.particlesPerHull.count, 11)
            XCTAssertFalse(solver.walksEveryHull, "\(label): with the option on the shirt's solve walks its candidates")
            print(String(format: "cloth gpu hull candidates, %@: %d free and %d pinned particles; %@; %d particles lost an influence joint's own hull to the cap; the nearest dropped hull is %.1f mm farther at rest than the farthest kept at the closest call",
                         label, free, pins, candidates.description, ownHullDropped, closestCall * 1000))
        }
    }

    /// The candidate loop against the every-hull loop on the four harness
    /// poses the fit tests use, both proxies — the hang on the bind pose
    /// (200 frames), the sway (300), the arms-forward idle (200) and the
    /// arm swing (60, the left arm from the bind pose to the idle and held)
    /// — two harnesses per scenario driven identically, one asking for the
    /// candidates (`gpuHullCandidates` on) and one on every hull, the
    /// default, the solvers recording which hulls pushed each particle in
    /// each frame (`recordHullContacts`, `ZCHullContactsIndex`): every
    /// particle's per-frame contact set must be the same on both paths, and
    /// because both loops apply their push-outs in ascending hull order the
    /// position buffers must then be bitwise equal frame after frame, which
    /// is the stronger check and the one the every-hull reference cannot
    /// pass by accident. A lost contact would print the particle, the
    /// frame, its influences, its candidates and the hull that pushed it on
    /// the reference path. Measured 2026-11-04 none is, on either proxy in
    /// any of the four, and no particle meets more than two hulls in a
    /// frame (the armpit, a clavicle's hull and its upper arm's). The
    /// arms-forward idle and the swing are held to produce contacts at all,
    /// so the diff is not vacuous. This is a statement about these four
    /// poses and no other motion: in none of them does a sleeve meet the
    /// torso, and over the chase's clips and the falls the lists lose
    /// contacts in number
    /// (`testTheCandidateRuleLosesContactsOnTheChaseClipsAndFalls`), which
    /// is why the candidates are off by default. What the test still holds
    /// is that the two loops are one kernel wherever their contact sets
    /// agree.
    func testTheCandidateHullLoopLosesNoContact() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0), let joints = ClothFixtures.skeleton else { throw XCTSkip("the idle clip is not bundled") }
        var everyHull = gpuConfiguration()
        everyHull.gpuHullCandidates = false
        let scenarios: [(name: String, frames: Int, posed: Bool)] = [("hang", 200, false), ("sway", 300, false), ("arms forward", 200, true), ("arm swing", 60, false)]
        for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
            for scenario in scenarios {
                let a = try makeHarness(configuration: withHullCandidates, pose: scenario.posed ? pose : nil, sidecar: sidecar)
                let b = try makeHarness(configuration: everyHull, pose: scenario.posed ? pose : nil, sidecar: sidecar)
                let ga = try gpu(a), gb = try gpu(b)
                XCTAssertEqual(ga.hullCount, 11); XCTAssertEqual(gb.hullCount, 11)
                XCTAssertFalse(ga.walksEveryHull); XCTAssertTrue(gb.walksEveryHull)
                ga.recordHullContacts = true
                gb.recordHullContacts = true
                let candidates = try XCTUnwrap(ga.hullCandidates)
                let count = a.shirt.particles.count
                var perHull = [Int](repeating: 0, count: 11), contactsInAll = 0, mostOnOne = 0, differing = 0, positionFrames = 0
                var lost: [String] = []
                for frame in 0 ..< scenario.frames {
                    switch scenario.name {
                    case "sway":
                        let t = a.time + a.dt
                        let swayed = a.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
                        a.body.pose = swayed; b.body.pose = swayed
                    case "arm swing":
                        let t = min(Float(frame + 1) / 30, 1)
                        let swung = try XCTUnwrap(ClothMetrics.interpolatedPose(from: joints.bindModelTransforms, to: pose, at: t, only: { $0.contains("/clavicle_l") }))
                        a.body.pose = swung; b.body.pose = swung
                    default:
                        break
                    }
                    a.frame(); b.frame()
                    let ca = ga.hullContacts(), cb = gb.hullContacts()
                    XCTAssertEqual(ca.count, count); XCTAssertEqual(cb.count, count)
                    for i in 0 ..< count {
                        let reference = cb[i]
                        if reference != 0 {
                            contactsInAll += 1
                            mostOnOne = max(mostOnOne, reference.nonzeroBitCount)
                            for hull in 0 ..< 11 where reference & (1 << UInt32(hull)) != 0 { perHull[hull] += 1 }
                        }
                        if ca[i] != reference {
                            differing += 1
                            if lost.count < 12 {
                                lost.append("frame \(frame) particle \(i) (influences \(a.shirt.influences[i].map { "\(Int($0[0])):\($0[1])" }), candidates \(candidates.candidates(of: i))): candidates pushed by \(String(ca[i], radix: 2)), every hull by \(String(reference, radix: 2))")
                            }
                        }
                    }
                    let bytes = count * MemoryLayout<SIMD4<Float>>.stride
                    if Data(bytes: try XCTUnwrap(ga.currentPositionBuffer).contents(), count: bytes) != Data(bytes: try XCTUnwrap(gb.currentPositionBuffer).contents(), count: bytes) {
                        positionFrames += 1
                    }
                }
                XCTAssertEqual(differing, 0, "\(label), \(scenario.name): \(differing) particle-frames differ in which hulls pushed them: \(lost.joined(separator: "; "))")
                XCTAssertEqual(positionFrames, 0, "\(label), \(scenario.name): the two loops' positions differ in \(positionFrames) of \(scenario.frames) frames")
                if scenario.posed || scenario.name == "arm swing" {
                    XCTAssertGreaterThan(contactsInAll, 0, "\(label), \(scenario.name): no hull pushed any particle, so nothing was diffed")
                }
                XCTAssertEqual(a.cloth.runawayCount, 0); XCTAssertEqual(b.cloth.runawayCount, 0)
                print("cloth gpu hull contacts, \(label), \(scenario.name) (\(scenario.frames) frames): \(contactsInAll) particle-frames pushed by a hull, per hull \(perHull), at most \(mostOnOne) hulls on one particle in a frame; \(differing) differ between the candidate and the every-hull loop, positions bitwise equal in \(scenario.frames - positionFrames) of \(scenario.frames) frames; \(a.cloth.report)")
            }
        }
    }

    /// The same diff on two of the clips the chase plays, the 100STYLE walk
    /// and run (`s100_walk`, `s100_run`, a second and a half of each from
    /// the clip's first second, sampled every 10 ms the way the clip-ground
    /// test samples a clip, the root's travel kept from the sample's start
    /// so the body moves over the floor at the clip's own speed and the
    /// shirt lags it), blended in from the bind pose over thirty frames.
    /// Two harnesses per clip and proxy, driven identically, the candidates
    /// asked for on one and every hull, the default, on the other, the
    /// contact masks and the position buffers compared every frame as
    /// above; the counts are printed, and a clip that is not bundled skips
    /// its row. Measured 2026-11-10: no contact differs on either proxy and
    /// the positions are bitwise equal in every frame. The arms hang and
    /// swing beside the body in both clips and no sleeve reaches the torso
    /// (the pelvis and spine-2 hulls take no contact, spine 1 eleven at
    /// 16k). The test covers these two clips and says nothing of the rest:
    /// the Kimodo turns, the pack's clips and the knockdowns lose contacts
    /// (the test below).
    func testTheCandidateHullLoopLosesNoContactOnTheChaseClips() throws {
        guard let joints = ClothFixtures.skeleton else { throw XCTSkip("the model is not bundled") }
        var everyHull = gpuConfiguration()
        everyHull.gpuHullCandidates = false
        let blend = 30, played = 150
        var measured = 0
        for clip in ["s100_walk", "s100_run"] {
            guard var poses = try ClothFixtures.clipPoses(clip, at: { duration in (0 ..< played).map { min(1.0 + Float($0) * 0.01, duration) } }), let first = poses.first,
                  let root = joints.parentIndices.firstIndex(where: { $0 == nil }) else { continue }
            // The travel from the sample's start, not from the clip's: the
            // blend from the bind pose then stays in place.
            let start = SIMD4(first[root].columns.3.x, 0, first[root].columns.3.z, 0)
            for k in poses.indices { for j in poses[k].indices { poses[k][j].columns.3 -= start } }
            let travel = simd_distance(poses[0][root].columns.3, poses[played - 1][root].columns.3)
            for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
                let a = try makeHarness(configuration: withHullCandidates, sidecar: sidecar)
                let b = try makeHarness(configuration: everyHull, sidecar: sidecar)
                let ga = try gpu(a), gb = try gpu(b)
                XCTAssertEqual(ga.hullCount, 11); XCTAssertEqual(gb.hullCount, 11)
                XCTAssertFalse(ga.walksEveryHull); XCTAssertTrue(gb.walksEveryHull)
                ga.recordHullContacts = true
                gb.recordHullContacts = true
                let candidates = try XCTUnwrap(ga.hullCandidates)
                let count = a.shirt.particles.count
                var perHull = [Int](repeating: 0, count: 11), contactsInAll = 0, mostOnOne = 0, differing = 0, positionFrames = 0
                var lost: [String] = []
                for frame in 0 ..< blend + played {
                    let pose = frame < blend
                        ? try XCTUnwrap(ClothMetrics.interpolatedPose(from: joints.bindModelTransforms, to: poses[0], at: Float(frame + 1) / Float(blend)))
                        : poses[frame - blend]
                    a.body.pose = pose; b.body.pose = pose
                    a.frame(); b.frame()
                    let ca = ga.hullContacts(), cb = gb.hullContacts()
                    XCTAssertEqual(ca.count, count); XCTAssertEqual(cb.count, count)
                    for i in 0 ..< count {
                        let reference = cb[i]
                        if reference != 0 {
                            contactsInAll += 1
                            mostOnOne = max(mostOnOne, reference.nonzeroBitCount)
                            for hull in 0 ..< 11 where reference & (1 << UInt32(hull)) != 0 { perHull[hull] += 1 }
                        }
                        if ca[i] != reference {
                            differing += 1
                            if lost.count < 12 {
                                lost.append("frame \(frame) particle \(i) (influences \(a.shirt.influences[i].map { "\(Int($0[0])):\($0[1])" }), candidates \(candidates.candidates(of: i))): candidates pushed by \(String(ca[i], radix: 2)), every hull by \(String(reference, radix: 2))")
                            }
                        }
                    }
                    let bytes = count * MemoryLayout<SIMD4<Float>>.stride
                    if Data(bytes: try XCTUnwrap(ga.currentPositionBuffer).contents(), count: bytes) != Data(bytes: try XCTUnwrap(gb.currentPositionBuffer).contents(), count: bytes) {
                        positionFrames += 1
                    }
                }
                XCTAssertEqual(differing, 0, "\(label), \(clip): \(differing) particle-frames differ in which hulls pushed them: \(lost.joined(separator: "; "))")
                XCTAssertEqual(positionFrames, 0, "\(label), \(clip): the two loops' positions differ in \(positionFrames) of \(blend + played) frames")
                XCTAssertGreaterThan(contactsInAll, 0, "\(label), \(clip): no hull pushed any particle, so nothing was diffed")
                print(String(format: "cloth gpu hull contacts, %@, %@ (%d frames, the body travelling %.2f m): %d particle-frames pushed by a hull, per hull %@, at most %d hulls on one particle in a frame; %d differ between the candidate and the every-hull loop, positions bitwise equal in %d of %d frames; hard skins %d and %d, runaways %d and %d; %@",
                             label, clip, blend + played, travel, contactsInAll, "\(perHull)", mostOnOne, differing, blend + played - positionFrames, blend + played,
                             a.cloth.hardSkinCount, b.cloth.hardSkinCount, a.cloth.runawayCount, b.cloth.runawayCount, a.cloth.report))
                measured += 1
            }
        }
        if measured == 0 { throw XCTSkip("the 100STYLE walk and run clips are not bundled") }
    }

    /// What the candidate rule loses, pinned, and why `gpuHullCandidates`
    /// is off by default (2026-11-10). The two tests above stand on six
    /// motions — the hang, the sway, the arms-forward idle, the arm swing,
    /// the walk and the run — in none of which a sleeve meets the torso:
    /// the pelvis and spine-2 hulls take no contact in any of them. Here
    /// the every-hull loop, the shipped path, runs alone and records which
    /// hulls pushed each particle in each frame (`recordHullContacts`),
    /// and every contact is held against the rule's own list for that
    /// particle, the words the solver builds at every attach
    /// (`hullCandidates`): a contact with a hull the list does not name is
    /// one the candidate loop cannot make, so the loss is counted on the
    /// reference's own trajectory and no divergence between two runs is
    /// taken for one. The scenes: the mixed set's clips (the eight
    /// 100STYLE captures and the eighteen Kimodo gap clips), the two
    /// arm-posture takes the pose layer plays over the chase and the wall
    /// hold, a second of each at 10 ms a frame from the clip's first
    /// second (from its start when it is under two seconds long), one
    /// harness a proxy carried through them all the way the chase carries
    /// the shirt from clip to clip — the next clip's first pose blended in
    /// over twenty frames from wherever the last left the body, its travel
    /// continued from the pelvis's place; and three knockdowns, where the
    /// body is the ragdoll's and no clip's: the harness's powered ragdoll
    /// stands for thirty frames, lets go with the knockdown's shove
    /// (`ZombiePhysics.collapse(along:)`) forward, backward or sideways
    /// and falls onto the floor slab for 220 more, the parts' pose read
    /// each frame as the game reads it when the zombie is down
    /// (`readRagdollPose`, every part's weight 1, a joint without a part
    /// riding its parent at the bind offset). That is every clip the
    /// 100STYLE and mixed sets play, 29 with the arm postures and the wall
    /// hold, and three falls, about two and a half minutes on both
    /// proxies; with `COOLZOMBIE_CLOTH_ALL_CLIPS` set the list grows by
    /// the Kimodo core and the pack's clips, every clip bundled, about six
    /// minutes, the run the README's larger figures are from. A clip that
    /// is not bundled is skipped and the count printed.
    ///
    /// Measured 2026-11-10 on the suite's list: the lists lack a hull that
    /// pushed in 121,655 particle-frames at 4k (2,229 distinct
    /// particle-hull pairs; 882 in the clips, all in five Kimodo turns and
    /// runs, and 120,773 in the falls) and in 415,842 at 16k (8,646 pairs;
    /// 3,457 and 412,385). On every bundled clip, 77 with the pack: 866,205
    /// particle-frames at 4k (5,385 distinct particle-hull pairs) and
    /// 2,858,798 at 16k (21,624), the worst scenes the falls forward and
    /// sideways, the pack's `walk_6`, `walk_3`, `chase_3`, its hyper runs
    /// and `hold_3`. What is lost is arm against torso — the spine-2 hull
    /// on the upper arms' and the forearms' particles, the arms' hulls on
    /// the spine's and the pelvis's — three joints apart along the tree and
    /// more, and touching in the pose, which no step count along a tree
    /// follows: the two wider rules printed beside the rule's row (one step
    /// without the cap of four, two steps without it) lose less and still
    /// lose (674,341 and 266,275 particle-frames at 4k on every bundled
    /// clip, 2,234,011 and 894,936 at 16k). A lost contact is a sleeve or a
    /// forearm through the shirt. Asserted: the loss is above zero on both
    /// proxies. If it is ever zero the rule has become exact and the
    /// default may be reconsidered.
    func testTheCandidateRuleLosesContactsOnTheChaseClipsAndFalls() throws {
        guard let joints = ClothFixtures.skeleton, let pelvis = joints.jointPaths.firstIndex(of: "/root/pelvis") else { throw XCTSkip("the model is not bundled") }
        let blend = 20, played = 100, standing = 30, down = 220
        let wide = ProcessInfo.processInfo.environment["COOLZOMBIE_CLOTH_ALL_CLIPS"] != nil
        var seen = Set<String>()
        let names = (ZombieResources.mixedClips + ZombieResources.armPostureClips + [ZombieResources.contactClip]
            + (wide ? ZombieResources.kimodoCoreClips + ZombieResources.packClips : [])).filter { seen.insert($0).inserted }
        var clips: [(name: String, poses: [[simd_float4x4]])] = []
        for name in names {
            guard let poses = try ClothFixtures.clipPoses(name, at: { duration in
                let start: Float = duration > 2 ? 1 : 0
                return (0 ..< played).map { min(start + Float($0) * 0.01, duration) }
            }), poses.count == played else { continue }
            clips.append((name, poses))
        }
        let bindLocal = joints.bindModelTransforms.indices.map { j in
            joints.parentIndices[j].map { joints.bindModelTransforms[$0].inverse * joints.bindModelTransforms[j] } ?? joints.bindModelTransforms[j]
        }
        let falls: [(name: String, direction: SIMD3<Float>)] = [("fall forward", SIMD3(0, 0, 1)), ("fall backward", SIMD3(0, 0, -1)), ("fall sideways", SIMD3(1, 0, 0))]
        for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
            // The reference is the default configuration: every hull.
            let reference = try makeHarness(configuration: gpuConfiguration(), sidecar: sidecar)
            let solver = try gpu(reference)
            XCTAssertTrue(solver.walksEveryHull, "\(label): the default configuration walks every hull")
            solver.recordHullContacts = true
            let candidates = try XCTUnwrap(solver.hullCandidates, "\(label): no candidates were built")
            XCTAssertFalse(candidates.everyHull, "\(label): the shirt has joint paths")
            let shirt = reference.shirt
            let count = shirt.particles.count
            let hullJoint = solver.hullPlaneSets.map(\.joint)
            let hullCount = hullJoint.count
            let parents = candidates.parents
            var children = [[Int]](repeating: [], count: parents.count)
            for (joint, parent) in parents.enumerated() where parent >= 0 { children[parent].append(joint) }
            var hullsOfJoint = [[Int]](repeating: [], count: parents.count)
            for (hull, joint) in hullJoint.enumerated() { hullsOfJoint[joint].append(hull) }
            func neighbours(_ joint: Int) -> [Int] { (parents[joint] >= 0 ? [parents[joint]] : []) + children[joint] }
            func mask(of jointSet: Set<Int>) -> UInt32 {
                var bits: UInt32 = 0
                for joint in jointSet { for hull in hullsOfJoint[joint] { bits |= 1 << UInt32(hull) } }
                return bits
            }
            func jointName(_ joint: Int) -> String { shirt.jointPaths.indices.contains(joint) ? String(shirt.jointPaths[joint].split(separator: "/").last ?? "") : "\(joint)" }
            // The rule's masks as the solver packed them, and the two wider
            // rules off the same tree for the print: one step along it
            // without the cap of four, and two steps without it.
            var ruleMasks = [UInt32](repeating: 0, count: count), oneStep = ruleMasks, twoSteps = ruleMasks
            var dominant = [Int](repeating: -1, count: count)
            for i in 0 ..< count where shirt.maxDistance[i] > 0 {
                for hull in candidates.candidates(of: i) { ruleMasks[i] |= 1 << UInt32(hull) }
                var own = Set<Int>()
                for pair in shirt.influences[i] where pair[1] > 0 { own.insert(Int(pair[0])) }
                var one = own
                for joint in own { one.formUnion(neighbours(joint)) }
                var two = one
                for joint in one { two.formUnion(neighbours(joint)) }
                oneStep[i] = mask(of: one)
                twoSteps[i] = mask(of: two)
                dominant[i] = shirt.influences[i].max { $0[1] < $1[1] }.map { Int($0[0]) } ?? -1
            }
            let rules: [(name: String, masks: [UInt32])] = [("the rule", ruleMasks), ("one step, uncapped", oneStep), ("two steps, uncapped", twoSteps)]
            var lostByScene = [[String: Int]](repeating: [:], count: rules.count)
            var lostPairs = [Set<Int>](repeating: [], count: rules.count)
            var relations: [String: Int] = [:]
            var pushed = 0, frames = 0
            func account(_ contacts: [UInt32], scene: String) {
                XCTAssertEqual(contacts.count, count)
                guard contacts.count == count else { return }
                frames += 1
                for i in 0 ..< count where contacts[i] != 0 {
                    pushed += 1
                    for r in rules.indices {
                        let missing = contacts[i] & ~rules[r].masks[i]
                        guard missing != 0 else { continue }
                        lostByScene[r][scene, default: 0] += 1
                        for hull in 0 ..< hullCount where missing & (1 << UInt32(hull)) != 0 {
                            if lostPairs[r].insert(i * 32 + hull).inserted, r == 0 {
                                relations["the \(jointName(hullJoint[hull])) hull on a \(jointName(dominant[i])) particle", default: 0] += 1
                            }
                        }
                    }
                }
            }
            // The clips, carried.
            var current = joints.bindModelTransforms
            for clip in clips {
                // The clip's travel continued from where the body stands.
                let offset = SIMD4(current[pelvis].columns.3.x - clip.poses[0][pelvis].columns.3.x, 0, current[pelvis].columns.3.z - clip.poses[0][pelvis].columns.3.z, 0)
                let poses = clip.poses.map { pose in pose.map { m -> simd_float4x4 in var moved = m; moved.columns.3 += offset; return moved } }
                let from = current
                for k in 0 ..< blend + played {
                    let pose = k < blend ? try XCTUnwrap(ClothMetrics.interpolatedPose(from: from, to: poses[0], at: Float(k + 1) / Float(blend))) : poses[k - blend]
                    reference.body.pose = pose
                    reference.frame()
                    account(solver.hullContacts(), scene: clip.name)
                    current = pose
                }
            }
            let lostInClips = lostByScene[0].values.reduce(0, +)
            // The knockdowns, a fresh shirt each.
            var runaways = reference.cloth.runawayCount
            for fall in falls {
                let h = try makeHarness(configuration: gpuConfiguration(), sidecar: sidecar)
                let g = try gpu(h)
                XCTAssertTrue(g.walksEveryHull)
                g.recordHullContacts = true
                let rig = try XCTUnwrap(h.physics.rig, "the harness has no ragdoll")
                let weights = [Float](repeating: 1, count: rig.partCount)
                var lowestPelvis = Float.greatestFiniteMagnitude
                for frame in 0 ..< standing + down {
                    if frame == standing {
                        h.physics.collapse(along: fall.direction)
                        XCTAssertTrue(h.physics.isDown)
                    }
                    if frame >= standing {
                        let physics = try XCTUnwrap(h.physics.readRagdollPose(entityWorld: h.body.world, partWeights: weights))
                        var pose = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.jointPaths.count)
                        for j in pose.indices {
                            pose[j] = physics.weights[j] > 0 ? physics.transforms[j] : (joints.parentIndices[j].map { pose[$0] } ?? matrix_identity_float4x4) * bindLocal[j]
                        }
                        h.body.pose = pose
                        lowestPelvis = min(lowestPelvis, pose[pelvis].columns.3.y)
                    }
                    h.frame()
                    account(g.hullContacts(), scene: fall.name)
                }
                XCTAssertLessThan(lowestPelvis, 0.5, "\(label), \(fall.name): the body did not fall (the pelvis's lowest \(lowestPelvis) m)")
                runaways += h.cloth.runawayCount
            }
            let lost = lostByScene[0].values.reduce(0, +)
            XCTAssertGreaterThan(pushed, 0, "\(label): no hull pushed any particle, so nothing was held against the rule")
            XCTAssertGreaterThan(lost, 0, "\(label): the candidate rule lacks no contact the every-hull loop made through \(clips.count) clips and \(falls.count) knockdowns. If this is ever zero the rule has become exact and the default (`gpuHullCandidates` off) may be reconsidered")
            let worst = lostByScene[0].sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let related = relations.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(10).map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
            let wider = rules.indices.dropFirst().map { "\(rules[$0].name) \(lostByScene[$0].values.reduce(0, +)) particle-frames / \(lostPairs[$0].count) pairs" }.joined(separator: "; ")
            print("cloth gpu candidate rule, \(label), \(clips.count) of \(names.count) clips (\(blend) + \(played) frames each) and \(falls.count) knockdowns (\(standing + down) each), \(frames) frames on the every-hull loop: \(pushed) particle-frames pushed by a hull; the rule's list lacks a hull that pushed in \(lost) of them (\(lostInClips) in the clips, \(lost - lostInClips) in the knockdowns), \(lostPairs[0].count) distinct particle-hull pairs; worst scenes: \(worst); by relation (distinct pairs): \(related); wider rules off the same tree: \(wider); runaways \(runaways)")
        }
    }

    /// The coplanar merge on the sidecar's eleven hulls: planes within 3
    /// degrees and 1 mm of one another merged into the farthest-out one,
    /// which takes the brute force's 87 / 83 / 82 / 88 / 52 / 84 / 82 /
    /// 66 / 72 / 60 / 60 (816) to 73 / 75 / 75 / 72 / 44 / 72 / 72 / 63 /
    /// 64 / 58 / 56 (724), 92 planes fewer (measured 2026-11-04 in double
    /// precision, as the planes are found). Every kept plane is one the
    /// brute force found, so the merged hull contains the raw one; every
    /// hull point reads inside the merged set within 1e-5 m; the widest
    /// pair merged is reported (a group is greedy around its seed, so a
    /// removed plane can lie up to twice the tolerance from the one kept
    /// for it) and held under twice the tolerances; and the merge depth —
    /// how much deeper a particle can sink at a merged face, read at the
    /// removed planes' own face points — is 2.8 mm at the pelvis, 1.9 at
    /// spine 2, under a millimetre on the forearms and the neck, held
    /// under 3.5 mm. The attached solver carries the merged count only
    /// under `gpuPlaneMerge`, which is off by default — on a hot GPU the
    /// merge reads a few per cent on top of the candidates and about a
    /// tenth on the 16k with every hull
    /// (`testTheHullPassCostWithTheArmsForward`), not enough to grow the
    /// hulls for — and reports the raw count either way.
    func testTheCoplanarMergeKeepsTheHullPointsInside() throws {
        guard let colliders = ClothFixtures.asset?.colliders, colliders.count == 11 else { throw XCTSkip("the sidecar carries no skin colliders") }
        let rawExpected = [87, 83, 82, 88, 52, 84, 82, 66, 72, 60, 60]
        let mergedExpected = [73, 75, 75, 72, 44, 72, 72, 63, 64, 58, 56]
        var rawTotal = 0, mergedTotal = 0, worstDepth: Float = 0
        var lines: [String] = []
        for (index, collider) in colliders.enumerated() {
            let points = collider.pointVectors
            let raw = try XCTUnwrap(GPUClothSolver.HullPlaneSet(points: points, joint: index, vertexRadius: 0.003, mergePlanes: false), "\(collider.joint): no planes")
            let merged = try XCTUnwrap(GPUClothSolver.HullPlaneSet(points: points, joint: index, vertexRadius: 0.003, mergePlanes: true), "\(collider.joint): no planes")
            XCTAssertEqual(raw.planeCount, rawExpected[index], "\(collider.joint): the brute force's planes")
            XCTAssertEqual(raw.mergedPlaneCount, 0)
            XCTAssertEqual(merged.rawPlaneCount, raw.planeCount)
            XCTAssertEqual(merged.planeCount + merged.mergedPlaneCount, raw.planeCount, "\(collider.joint): the merge lost count")
            XCTAssertEqual(merged.planeCount, mergedExpected[index], "\(collider.joint): \(merged.planeCount) planes after the merge")
            let rawSet = Set(raw.planes.map { "\($0.x.bitPattern),\($0.y.bitPattern),\($0.z.bitPattern),\($0.w.bitPattern)" })
            for plane in merged.planes {
                XCTAssertTrue(rawSet.contains("\(plane.x.bitPattern),\(plane.y.bitPattern),\(plane.z.bitPattern),\(plane.w.bitPattern)"), "\(collider.joint): a merged plane is not one the brute force found")
            }
            for p in points {
                XCTAssertTrue(merged.contains(p, tolerance: 1e-5), "\(collider.joint): a hull point reads \(merged.signedDistance(to: p)) m outside the merged set")
            }
            XCTAssertLessThanOrEqual(merged.mergeMaxAngleDegrees, 6.001, "\(collider.joint): a removed plane lies \(merged.mergeMaxAngleDegrees) degrees from the plane kept for it")
            XCTAssertLessThanOrEqual(merged.mergeMaxOffset, 0.002001, "\(collider.joint): a removed plane lies \(merged.mergeMaxOffset) m from the plane kept for it")
            XCTAssertLessThan(merged.mergeDepth, 0.0035, "\(collider.joint): the merge lets a particle sink \(merged.mergeDepth) m deeper at a face")
            XCTAssertEqual(merged.boundsMin, raw.boundsMin); XCTAssertEqual(merged.boundsMax, raw.boundsMax)
            rawTotal += raw.planeCount; mergedTotal += merged.planeCount
            worstDepth = max(worstDepth, merged.mergeDepth)
            lines.append(String(format: "%@ %d -> %d (depth %.2f mm, widest pair %.2f deg / %.2f mm)", collider.joint.split(separator: "/").last.map(String.init) ?? collider.joint, raw.planeCount, merged.planeCount, merged.mergeDepth * 1000, merged.mergeMaxAngleDegrees, merged.mergeMaxOffset * 1000))
        }
        XCTAssertEqual(rawTotal, 816); XCTAssertEqual(mergedTotal, 724)
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        XCTAssertEqual(solver.rawPlaneCount, 816)
        XCTAssertEqual(solver.planeCount, h.cloth.configuration.gpuPlaneMerge ? 724 : 816, "the attached solver's planes under the default merge setting")
        print("cloth gpu plane merge: \(lines.joined(separator: "; ")); \(rawTotal) -> \(mergedTotal) planes, the deepest merged face \(String(format: "%.2f", worstDepth * 1000)) mm; attached \(solver.planeCount) of \(solver.rawPlaneCount)")
    }

    /// A GPU load run before every timed frame of the cost tests below, so
    /// each timed frame finds the GPU in the same clock state whatever was
    /// timed before it (2026-11-10). The M4 Max's GPU clocks up under load
    /// and down within milliseconds of idling, and `gpu=` follows the
    /// clock two to four to one: timed in a fixed order, a variant that
    /// always came after a 5 ms burst read 1.3 ms and the same variant
    /// after a row of light ones 3.3 ms, so a fixed order compares the
    /// neighbours as much as the variants. The heater is the heaviest
    /// frame the solver has — the finest proxy bundled, every hull on
    /// every particle, 16 substeps and two gathers, swaying so it never
    /// sleeps, about 5 ms of GPU — and with it before each timed frame the
    /// figures are a hot GPU's: the state a headset's GPU is in with the
    /// render filling most of every frame, and the lowest the Mac reads.
    /// The heater does not make the rotation flat. The frame before the
    /// heater still leaves its trace, and one variant reads about a tenth
    /// apart in two places of one rotation (2026-11-10), so a ratio
    /// between two rows is good to that and no better.
    private func makeHeater(pose: [simd_float4x4]?) throws -> ClothHarness {
        var configuration = gpuConfiguration()
        configuration.gpuHullCandidates = false
        let sidecar = ClothFixtures.sidecar(named: ClothFixtures.sidecar16kName) != nil ? ClothFixtures.sidecar16kName : nil
        return try makeHarness(configuration: configuration, pose: pose, sidecar: sidecar)
    }

    /// One heater frame: the body moved a millimetre sideways and back so
    /// the heater's shirt stays awake, then its frame, waited for.
    private func heat(_ heater: ClothHarness, base: [simd_float4x4]) throws {
        let offset = SIMD4<Float>(0.001 * sin(2 * Float.pi * (heater.time + heater.dt)), 0, 0, 0)
        heater.body.pose = base.enumerated().map { index, m in
            guard heater.joints.parentIndices[index] != nil else { return m }
            var moved = m
            moved.columns.3 += offset
            return moved
        }
        heater.frame()
        try gpu(heater).waitForAll()
    }

    /// The hull pass's cost at exactly 16 substeps with the arms forward —
    /// the pose where every hull is in play, the one the second review of
    /// phase 2 measured its 87 % from — on both proxies, five ways: the
    /// skin-only model (no hulls, the floor); every hull on every particle,
    /// the default and the shipped path; every hull with the coplanar
    /// merge; the candidates, the option; and the candidates with the
    /// merge. The five harnesses are stepped in turn, frame by frame, 300
    /// frames each, the turn rotating and a heater frame before every timed
    /// one (`makeHeater`), so the five read the GPU in the same clock
    /// state: the Mac release host at 27 substeps swings two to one between
    /// runs as the GPU clocks up and down, a single `gpu=` reading off a
    /// report line (the review's 0.49 against 3.65 ms) is one frame in
    /// whatever state the GPU was in, and the first form of this test
    /// (2026-11-04), which stepped four variants in a fixed order with no
    /// heater, read the order: every hull, always after the light skin-only
    /// frame, 4.2 ms at 16k, the candidates, always after that 4 ms burst,
    /// 1.2-1.3, and the merge, after the candidates' short frame, 2.3-2.5 —
    /// "a tenth" and "a millisecond lost", neither of them the kernel's.
    /// The lowest decile and the median of `gpu=` are printed with this
    /// run's ratios over the every-hull row, nothing pinned, because the
    /// figure is a GPU's. Measured 2026-11-10 on the M4 Max, lowest deciles
    /// (medians about twice them, the GPU still clocking inside a frame's
    /// CPU work). Five runs of the four-variant rotation the test then had,
    /// skin only / every hull / candidates / candidates and merge: 4k
    /// 0.37-0.40 / 0.88-1.14 / 0.74-0.90 / 0.72-0.87 ms, 16k 0.47-0.67 /
    /// 1.17-1.52 / 1.07-1.25 / 1.07-1.31 ms. Six runs of a six-variant
    /// rotation, which added every hull with the merge and, for that day,
    /// every hull on the phase-2 kernel's one-plane walk behind a kernel
    /// flag since removed, skin only / every hull / every hull and merge /
    /// candidates / candidates and merge: 4k 0.37-0.39 / 0.88-1.04 /
    /// 0.87-0.98 / 0.79-0.88 / 0.79-0.87 ms, 16k 0.53-0.59 / 1.48-1.59 /
    /// 1.35-1.48 / 1.21-1.31 / 1.14-1.27 ms. So the hull pass is half to
    /// two thirds of either frame with every hull. The candidates take 7 to
    /// 24 per cent off the 16k frame's lowest decile and 7 to 27 off the
    /// 4k's, run by run (a solve dispatch on this GPU is the touching
    /// lane's walk of its hull's 52-88 planes, 125 or 250 simdgroups on a
    /// GPU that holds many times that, and the candidates do not shorten
    /// that walk), and they lose contacts, which is why they are the
    /// option. The merge reads a few per cent on top of the candidates and
    /// 3 to 14 per cent under no merge on the 16k's lowest decile with
    /// every hull, and it grows a hull by up to 2.8 mm, which is why it is
    /// off. And the unrolled plane walk reads 0.86-0.90 of the one-plane
    /// walk's frame at 4k and 0.88-0.92 at 16k with every hull, place for
    /// place in the rotation: the two walks were timed in each other's
    /// places, three runs each, because a variant's place moves it about a
    /// tenth. That is the unroll's recorded gain. The static pose lets a
    /// settled shirt sleep (the 4k variants after 221-246 frames); a slept
    /// frame encodes nothing and is left out.
    func testTheHullPassCostWithTheArmsForward() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0) else { throw XCTSkip("the idle clip is not bundled") }
        var everyHull = gpuConfiguration()
        everyHull.gpuHullCandidates = false
        everyHull.gpuPlaneMerge = false
        var everyHullMerged = everyHull
        everyHullMerged.gpuPlaneMerge = true
        var candidates = withHullCandidates
        candidates.gpuPlaneMerge = false
        var candidatesMerged = withHullCandidates
        candidatesMerged.gpuPlaneMerge = true
        for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
            let variants = [("skin only", skinOnly), ("every hull (the default)", everyHull), ("every hull, merged planes", everyHullMerged),
                            ("candidates (the option)", candidates), ("candidates, merged planes", candidatesMerged)]
            var harnesses: [ClothHarness] = [], solvers: [GPUClothSolver] = []
            for (_, configuration) in variants {
                let h = try makeHarness(configuration: configuration, pose: pose, sidecar: sidecar)
                harnesses.append(h)
                solvers.append(try gpu(h))
            }
            XCTAssertTrue(solvers[1].walksEveryHull); XCTAssertFalse(solvers[3].walksEveryHull)
            let heater = try makeHeater(pose: pose)
            var gpuTime = [[Double]](repeating: [], count: variants.count)
            var substeps = [Int](repeating: 0, count: variants.count)
            for frame in 0 ..< 300 {
                // The turn rotates and the heater runs before every timed
                // frame, so each variant is read after the same burst.
                for turn in variants.indices {
                    let v = (frame + turn) % variants.count
                    try heat(heater, base: pose)
                    harnesses[v].frame()
                    let stats = solvers[v].stats
                    // A frame the cloth slept through encoded nothing (the
                    // pose is still, and a settled shirt sleeps after half
                    // a second); it is no reading of the pass.
                    guard stats.substeps > 0 else { continue }
                    gpuTime[v].append(stats.gpuMilliseconds * 1000)
                    substeps[v] = max(substeps[v], stats.substeps)
                }
            }
            var lines: [String] = []
            for v in variants.indices {
                let sorted = gpuTime[v].sorted()
                XCTAssertFalse(sorted.isEmpty, "\(label), \(variants[v].0): no frame was encoded")
                guard !sorted.isEmpty else { continue }
                lines.append(String(format: "%@ (hulls %d, planes %d, %d frames awake): gpu lowest decile %.0f us, median %.0f, mean %.0f, max %.0f", variants[v].0, solvers[v].hullCount,
                                    solvers[v].planeCount, sorted.count, sorted[sorted.count / 10], sorted[sorted.count / 2], gpuTime[v].reduce(0, +) / Double(gpuTime[v].count), sorted.last ?? 0))
                XCTAssertEqual(substeps[v], 16)
                XCTAssertEqual(harnesses[v].cloth.runawayCount, 0)
            }
            // This run's ratios on the lowest deciles and the medians: the
            // options over the default.
            func decile(_ v: Int) -> Double { let sorted = gpuTime[v].sorted(); return sorted.isEmpty ? .nan : sorted[sorted.count / 10] }
            func median(_ v: Int) -> Double { let sorted = gpuTime[v].sorted(); return sorted.isEmpty ? .nan : sorted[sorted.count / 2] }
            lines.append(String(format: "over every hull: the merge %.2f / %.2f, the candidates %.2f / %.2f, the candidates and the merge %.2f / %.2f (lowest deciles / medians)",
                                decile(2) / decile(1), median(2) / median(1), decile(3) / decile(1), median(3) / median(1), decile(4) / decile(1), median(4) / median(1)))
            print("cloth gpu hull pass, arms forward, \(label) (300 frames each, the turn rotating, a heater frame before each, 16 substeps, two gathers, \(device.name)): " + lines.joined(separator: "; "))
        }
    }

    /// The schedules gate 2 can choose between, at a headset-length frame
    /// (2026-11-10). The harness's 10 ms frame, and the hull-pass test
    /// above with it, encodes the picker's own count, and the Mac's 16.7 ms
    /// frame 27, 21, 17 and 14 where the picker says 16, 12, 10 and 8, so
    /// neither is a device frame; here a frame is 1/90 s, 11.1 ms, and
    /// `substepCount` encodes 18 substeps at the picker's 16, 14 at 12, 12
    /// at 10 and 9 at 8. (The headset's one reading, 2026-11-04, encoded 14
    /// at the picker's 16 and 21 at 24, a frame of 8.3-8.75 ms; which
    /// display rate that was is not recorded, and 11.1 ms is the longer
    /// frame and so the costlier case.) The idle clip plays at 1/90 s a
    /// frame from its first second (the arms forward, the clavicles and the
    /// upper arms on their hulls, the body breathing — the gate's own
    /// scene), 300 frames, one harness per row stepped in turn, the turn
    /// rotating and a heater frame before every timed one (`makeHeater`) so
    /// the rows read the GPU in one clock state and a hot one, on both
    /// proxies. The rows: every hull, the default, at six schedules; the
    /// candidates, the option, at the four that matter to the gate; and the
    /// headset's own row — the 4k shirt, every hull, 14 encoded substeps,
    /// two gathers, what the headset measured at 2.58 ms on the phase-2
    /// kernel — in both proxies' rotations, so each row over it is that
    /// row's cost in the device's units, the README's projection. Two
    /// things are read off each row: `gpu=`, its lowest decile and its
    /// median over the frames, and how still the shirt holds — the fastest
    /// particle of each frame (its displacement over the frame; the idle's
    /// own joints move 1-2 mm a frame, 0.1-0.2 m/s), the median and the
    /// worst of that over the last 200 frames. The second is what the Mac
    /// release sweep of the same day found the schedule turns on before the
    /// cost does: one gather and long substeps do not hold the 16k's 4.5 mm
    /// edges still (`-clothSubsteps 12 -clothGPUIterations 1` read
    /// `speed<=` 4.5-17 m/s through three of its four runs, `-clothSubsteps
    /// 8` 3.2-4.9 m/s, 10 with two gathers and 16 with one 0.40, where 12
    /// and 16 with two gathers read the idle's 0.08-0.09). Here the fastest
    /// particle is the same in every run and on either hull loop, the GPU's
    /// result being the same to the bit and the idle making no contact the
    /// candidates lack: a median of 0.07-0.10 m/s at 16, 12 and 10 substeps
    /// with two gathers and at 16 with one, and 0.58 / 0.74 m/s (16k / 4k)
    /// at 8 with two and 0.57 / 0.66 at 12 with one — the still clip is
    /// kinder than the host's idle to 10 and to one gather, and agrees with
    /// it on what jitters. Measured on the M4 Max, five runs on 2026-11-10
    /// and 11, lowest deciles: the 16k on every hull 1.26-1.34 ms at 16 x
    /// 2, 1.28-1.39 at 12 x 2, 1.11-1.18 at 10 x 2, 0.88-0.94 at 8 x 2,
    /// 0.85-0.91 at 16 x 1 and 0.66-0.70 at 12 x 1, and with the candidates
    /// 1.23-1.32 / 1.03-1.09 / 0.86-0.92 / 0.70-0.73 at 16 x 2, 12 x 2, 10
    /// x 2 and 16 x 1; the 4k 0.99-1.07, 0.92-0.96, 0.69-0.77, 0.56-0.60,
    /// 0.64-0.71 and 0.54-0.62, and 0.98-1.10 / 0.70-0.75 / 0.63-0.67 /
    /// 0.53-0.58; the headset's row 1.09-1.17 in the 16k's rotation and
    /// 0.99-1.10 in the 4k's, where the same harness elsewhere in the
    /// rotation reads 0.92-0.96, which is what a place in the rotation is
    /// worth. Printed, and the two-gather schedules at 12 and 16 substeps
    /// on every hull — the cheapest still one and the default — are held to
    /// stay under 1 m/s on both proxies; the rest are measurements, the
    /// device's to judge.
    func testTheScheduleCostAndStillnessAtTheHeadsetsFrame() throws {
        let frameDelta: Float = 1.0 / 90
        let frames = 300, settle = 100
        guard let poses = try ClothFixtures.clipPoses(ZombieResources.waitingClip, at: { duration in (0 ..< frames).map { min(1.0 + Float($0) * frameDelta, duration) } }),
              poses.count == frames else { throw XCTSkip("the idle clip is not bundled") }
        // Every hull, the default, at six schedules; the candidates, the
        // option, at the four that matter to the gate; and the headset's
        // own row, the 4k shirt on every hull at 14 encoded substeps and
        // two gathers, in both proxies' rotations.
        let schedules: [(substeps: Int, gathers: Int, held: Bool, candidates: Bool, fourK: Bool)] = [
            (16, 2, true, false, false), (12, 2, true, false, false), (10, 2, false, false, false), (8, 2, false, false, false),
            (16, 1, false, false, false), (12, 1, false, false, false),
            (16, 2, false, true, false), (12, 2, false, true, false), (10, 2, false, true, false), (16, 1, false, true, false),
            (12, 2, false, false, true),
        ]
        for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
            var harnesses: [ClothHarness] = [], solvers: [GPUClothSolver] = []
            for schedule in schedules {
                var configuration = gpuConfiguration(substeps: schedule.substeps, iterations: schedule.gathers)
                configuration.gpuHullCandidates = schedule.candidates
                let h = try makeHarness(configuration: configuration, pose: poses[0], sidecar: schedule.fourK ? nil : sidecar, frameDelta: frameDelta)
                harnesses.append(h)
                solvers.append(try gpu(h))
                XCTAssertEqual(solvers[solvers.count - 1].walksEveryHull, !schedule.candidates)
            }
            var gpuTime = [[Double]](repeating: [], count: schedules.count)
            var fastest = [[Float]](repeating: [], count: schedules.count)
            var encoded = [Int](repeating: 0, count: schedules.count)
            var before = harnesses.map(\.particles)
            let heater = try makeHeater(pose: poses[0])
            for frame in 0 ..< frames {
                // The turn rotates and the heater runs before every timed
                // frame (`makeHeater`), so each schedule is read after the
                // same burst, on a hot GPU.
                for turn in schedules.indices {
                    let v = (frame + turn) % schedules.count
                    try heat(heater, base: poses[0])
                    harnesses[v].body.pose = poses[frame]
                    harnesses[v].frame()
                    let stats = solvers[v].stats
                    gpuTime[v].append(stats.gpuMilliseconds * 1000)
                    encoded[v] = max(encoded[v], stats.substeps)
                    let now = harnesses[v].particles
                    if frame >= settle {
                        var speed: Float = 0
                        for i in now.indices { speed = max(speed, simd_distance(now[i], before[v][i]) / frameDelta) }
                        fastest[v].append(speed)
                    }
                    before[v] = now
                }
            }
            var lines: [String] = []
            for (v, schedule) in schedules.enumerated() {
                let sorted = gpuTime[v].sorted(), speeds = fastest[v].sorted()
                let median = speeds[speeds.count / 2], worst = speeds.last ?? 0
                let path = schedule.fourK ? "the headset's row, 4k, every hull" : (schedule.candidates ? "candidates (the option)" : "every hull (the default)")
                lines.append(String(format: "%d substeps x %d gathers, %@ (%d encoded, %d dispatches): gpu lowest decile %.0f us, median %.0f, max %.0f; fastest particle median %.2f m/s, worst %.2f; onClamp %.0f%%, hard skins %d, runaways %d",
                                    schedule.substeps, schedule.gathers, path, encoded[v], solvers[v].ringState.dispatches, sorted[sorted.count / 10], sorted[sorted.count / 2], sorted.last ?? 0, median, worst,
                                    solvers[v].stats.onClampShare * 100, harnesses[v].cloth.hardSkinCount, harnesses[v].cloth.runawayCount))
                XCTAssertEqual(encoded[v], GPUClothSolver.substepCount(frameDelta: frameDelta, substeps: schedule.substeps), "\(label): the substeps the 11.1 ms frame encodes at \(schedule.substeps)")
                if schedule.held {
                    XCTAssertLessThan(worst, 1, "\(label), \(schedule.substeps) substeps x \(schedule.gathers) gathers: the idle shirt's fastest particle read \(worst) m/s")
                    XCTAssertEqual(harnesses[v].cloth.runawayCount, 0)
                }
            }
            print("cloth gpu schedules at an 11.1 ms frame, the idle clip, \(label) (\(frames) frames each, the turn rotating, a heater frame before each, \(device.name)): " + lines.joined(separator: "; "))
        }
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
    /// for. The 12-substep, two-gather row is the budget phase's
    /// (2026-11-04), the cheapest schedule that holds the shirt as still as
    /// the default's sixteen (`testTheScheduleCostAndStillnessAtTheHeadsetsFrame`)
    /// and the second row of the device run: it reads mean 0.52 %, p99
    /// 2.57 %, worst 4.63 %, between the 16- and 8-substep rows as the
    /// step's square says, and is held to the 16-substep gate itself.
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
            ("raw sum 0.5, 12 substeps, 2 gathers", 12, 2, false, 0.5, 0.01, 0.03, 0.01, 0.03),
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
            XCTAssertEqual(try gpu(h).ringState.dispatches, substeps * (1 + gathers) + 1 + (try shellDispatches(h)), "\(label): the last encoded frame's dispatches")
            measured += 1
        }
        XCTAssertEqual(measured, 7)
    }

    /// The gate's rows at 16k (raw sum 0.5, 16 substeps, two gathers — the
    /// default — and four, the parser's cap), which phase 2 did not run
    /// until its first review asked why the finer shirt hung lower. The
    /// answer is here: the edges are the sidecar's 47,662 less the 5,222
    /// pin-pin ones, 42,440, and after 200 frames of the hang their
    /// residual is mean 1.37 %, p99 5.99 %, worst 15.3 % (a yoke edge of
    /// 5.2 mm) with 5,376 edges over 3 % at two gathers, and 0.73 % / 3.50 %
    /// / 8.4 % with 882 over 3 % at four (2026-11-04, the M4 Max) — the
    /// design's 1 % / 3 % NOT met at either, where the 4k meets it at two
    /// (0.40 % / 2.09 %). The solver gives back the same fraction of a
    /// violation per pass on either proxy (the mass and the compliances
    /// enter only as their product, `Configuration.particleMass`), so a
    /// mesh twice as fine is half as converged across the sheet after the
    /// same 32 passes, and that unconverged stretch is the finer shirt's
    /// extra sag (22.9 mm against 9.4 at the hang) — not a weight: the
    /// per-area mass the review proposed (12.6 mg a particle, four times
    /// stiffer per pass) read 1.03 % / 8.07 % / 28.1 % here and bridged
    /// the armpit in the arms-forward idle (100 mm behind the skin, 49.7
    /// mm inside it against 4.4), and was withdrawn the same day. Held to
    /// the measurements with the 4k rows' quarter of margin; what the 16k
    /// needs to meet the gate — gathers beyond four, or the per-pass
    /// fractions retuned for the spacing — is the owner's at gate 2, and
    /// `gpu=` on the four-gather row (3.2 ms here in debug against 2.4 at
    /// two) is the cost of the first. The budget phase's three rows
    /// (2026-11-10) are the other direction, what the cheaper schedules
    /// cost the finer shirt, since the cost line of gate 2 asks for fewer
    /// passes where its look asks for more: 12 substeps with two gathers
    /// mean 1.82 %, p99 7.90 %, worst 20.0 %, 8,408 edges over 3 %; 10
    /// with two 2.31 % / 9.93 % / 26.2 %, 11,700; 16 with one gather
    /// 2.78 % / 11.74 % / 29.5 %, 14,489, a third of the edges — the
    /// residual follows the gathers a frame gets (32, 24, 20, 16), and the
    /// one schedule here whose projection reaches under the device's
    /// 2.0 ms at all on every hull (1.65 to 2.1 ms) is the one that doubles
    /// it. Held to the measurements with the same quarter of margin.
    func testStretchResidualAtRestAt16k() throws {
        guard let shirt = ClothFixtures.sidecar(named: ClothFixtures.sidecar16kName)?.garment(named: "shirt") else { throw XCTSkip("Models/Zombie/\(ClothFixtures.sidecar16kName) is not bundled (the phase-2 cook)") }
        let edges = Self.stretchEdges(of: shirt)
        XCTAssertEqual(edges.count, 42440)
        let rest = edges.map { simd_distance(shirt.positions[$0.0], shirt.positions[$0.1]) }
        var measured = 0
        for (label, substeps, gathers, meanBound, p99Bound) in [
            ("16 substeps, 2 gathers", 16, 2, Float(0.0175), Float(0.075)),
            ("16 substeps, 4 gathers", 16, 4, 0.0095, 0.045),
            ("12 substeps, 2 gathers", 12, 2, 0.023, 0.099),
            ("10 substeps, 2 gathers", 10, 2, 0.029, 0.125),
            ("16 substeps, 1 gather", 16, 1, 0.035, 0.147),
        ] {
            let h = try makeHarness16k(configuration: gpuConfiguration(substeps: substeps, iterations: gathers))
            h.frames(200)
            let p = h.particles
            var residuals = edges.indices.map { (abs(simd_distance(p[edges[$0].0], p[edges[$0].1]) - rest[$0]) / rest[$0], $0) }
            residuals.sort { $0.0 < $1.0 }
            let mean = residuals.reduce(0) { $0 + $1.0 } / Float(residuals.count)
            let p99 = residuals[Int(Float(residuals.count - 1) * 0.99)].0
            let worst = residuals.last ?? (0, 0)
            let worstEdge = edges[worst.1]
            let over3 = residuals.reversed().prefix { $0.0 > 0.03 }.count
            print(String(format: "cloth gpu stretch residual, 16k, raw sum 0.5, %@: mean %.2f%%, p99 %.2f%%, worst %.2f%% (particles %d-%d, %@-%@, rest %.1f mm) over %d edges, %d over 3%%; the design's gate (1%% / 3%%) %@; %@",
                         label, mean * 100, p99 * 100, worst.0 * 100, worstEdge.0, worstEdge.1, ClothMetrics.regionName(slack: shirt.maxDistance[worstEdge.0]), ClothMetrics.regionName(slack: shirt.maxDistance[worstEdge.1]),
                         rest[worst.1] * 1000, edges.count, over3, mean < 0.01 && p99 < 0.03 ? "met" : "NOT met", h.cloth.report))
            XCTAssertLessThan(mean, meanBound, "\(label): the mean stretch residual at 16k is \(mean * 100)%")
            XCTAssertLessThan(p99, p99Bound, "\(label): the 99th-percentile stretch residual at 16k is \(p99 * 100)%")
            XCTAssertEqual(h.cloth.runawayCount, 0)
            measured += 1
        }
        XCTAssertEqual(measured, 5)
    }

    // MARK: - The substeps

    /// The substep count follows the frame delta (the engine's contract, no
    /// constant): the delta clamped to [1/240, 1/30] s, the substep 0.01 /
    /// `gpuSubsteps`, the count ceil(delta / substep) clamped to [1, 32] —
    /// 16 at the headset's 10 ms, 18 at 11.1 ms, 27 at the Mac's 16.7 ms, 8
    /// at 5 ms, 32 at 50 ms (a 30 fps hitch), and `gpuSubsteps` 8 gives 8
    /// at 10 ms and 14 at 16.7 ms. A frame of the harness's 10 ms encodes
    /// 16 substeps of 0.625 ms, 49 dispatches (a predict and the default's
    /// two gathers each, the stats once) plus the GPU shell's two since
    /// phase 2 (51), 17 + 2 at 8 substeps and one gather.
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
        XCTAssertEqual(solver.stats.dispatches, 49 + (try shellDispatches(h)), "16 substeps of a predict and two gathers, the stats, and the shell's two")
        XCTAssertTrue(h.cloth.report.contains("sub=16 it=2"), h.cloth.report)
        let eight = try makeHarness(configuration: gpuConfiguration(substeps: 8, iterations: 1))
        eight.frames(2)
        XCTAssertEqual(try gpu(eight).ringState.substeps, 8)
        XCTAssertEqual(try gpu(eight).stats.dispatches, 8 * 2 + 1 + (try shellDispatches(eight)), "8 substeps of a predict and one gather, the stats, and the shell's two")
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

    /// A garment without joint paths meets every hull, however many it has
    /// (2026-11-10, the review's finding). The hull candidates are a word
    /// of four, picked along the bind skeleton; a garment that names no
    /// joint paths has no skeleton to pick along, and until this day the
    /// solver still handed the kernel such a garment's words — every hull
    /// capped at the four nearest at rest — so a sheet over five hulls
    /// would have passed through whichever stood fifth at the bind pose,
    /// against what the comments promised. The solver now runs the
    /// every-hull loop for it (`walksEveryHull`) whether or not the
    /// candidates are asked for; the solver here asks for them, the
    /// default configuration walking every hull anyway. Here the cube sheet
    /// drops onto the unit cube as above, but the cube is the fifth hull:
    /// four thin slabs on the same joint hang over the sheet, 25 to 55 cm
    /// above it at the bind pose where the cube's top is 80 cm below, so
    /// they are the four nearest and the cube is the one a cap drops; the
    /// joint is then held half a metre up, the slabs are out of the
    /// sheet's way and the cube's top is at y 1.0. The sheet must land on
    /// it — the lowest particle over the cube a radius off the top, the
    /// cube's bit in the contact masks and no slab's — which it does only
    /// if the fifth hull is walked. (With the candidates' words read it
    /// falls through: the test was run once against the solver's old flag
    /// line (2026-11-10) and failed, the cube pushing nothing and the sheet 2.97 m under the origin after its two seconds.)
    func testASheetWithoutJointPathsMeetsEveryHull() throws {
        let solver = try XCTUnwrap(GPUClothSolver(device: device, configuration: withHullCandidates), "the GPU solver could not be built")
        solver.floorY = -10
        let garment = sheet(n: 20, spacing: 0.4 / 19, y: 1.3)
        XCTAssertTrue(garment.jointPaths.isEmpty, "the free sheet names no joint paths")
        func slab(y: Float) -> ClothHullSetup {
            var points: [SIMD3<Float>] = []
            for x in [Float(-0.5), 0.5] { for dy in [Float(-0.02), 0.02] { for z in [Float(-0.5), 0.5] { points.append(SIMD3(x, y + dy, z)) } } }
            return ClothHullSetup(joint: 1, points: points, friction: 0, layer: 9, world: Self.translation(SIMD3(0, 0.5, 0)))
        }
        let lifted = Self.translation(SIMD3(0, 0.5, 0))
        let hulls = [slab(y: 1.57), slab(y: 1.67), slab(y: 1.77), slab(y: 1.87), cube(world: lifted, friction: 0)]
        XCTAssertTrue(solver.build(garment, hulls: hulls), "the solver refused the sheet")
        XCTAssertEqual(solver.hullCount, 5)
        let candidates = try XCTUnwrap(solver.hullCandidates)
        XCTAssertTrue(candidates.everyHull, "a garment without joint paths has no tree to pick candidates by")
        XCTAssertEqual(candidates.candidates(of: 0), [0, 1, 2, 3], "the word holds the four slabs, the nearest at rest, and not the cube")
        XCTAssertTrue(solver.walksEveryHull, "so the kernel must walk every hull and not the word")
        solver.recordHullContacts = true
        var onCube = 0, onSlab = 0
        let p = drive(solver, frames: 200, hull: { _ in lifted }) { _, _ in
            for mask in solver.hullContacts() {
                if mask & 0b10000 != 0 { onCube += 1 }
                if mask & 0b01111 != 0 { onSlab += 1 }
            }
        }
        var lowest: Float = .greatestFiniteMagnitude, over = 0
        for q in p where abs(q.x) < 0.5 && abs(q.z) < 0.5 { over += 1; lowest = min(lowest, q.y) }
        print(String(format: "cloth gpu sheet over five hulls without joint paths: %d of 400 particles over the cube, the lowest at y %.4f (the top at 1.000); %d particle-frames pushed by the cube, the fifth hull, %d by a slab",
                     over, lowest, onCube, onSlab))
        XCTAssertGreaterThan(over, 300, "the sheet slid off the cube")
        XCTAssertEqual(lowest, 1.003, accuracy: 0.0005, "the sheet did not land on the fifth hull (the lowest particle at \(lowest))")
        XCTAssertGreaterThan(onCube, 0, "the cube pushed no particle")
        XCTAssertEqual(onSlab, 0, "a slab over the sheet pushed a particle")
        // With joint paths the same garment walks its candidates again.
        var treed = garment
        treed.jointPaths = ["/a", "/a/b"]
        XCTAssertTrue(solver.build(treed, hulls: hulls))
        XCTAssertFalse(try XCTUnwrap(solver.hullCandidates).everyHull)
        XCTAssertFalse(solver.walksEveryHull, "a garment with a tree walks its candidates when the option is on")
        let reference = try XCTUnwrap(GPUClothSolver(device: device, configuration: gpuConfiguration()))
        XCTAssertFalse(reference.walksEveryHull, "nothing is walked before the build")
        XCTAssertTrue(reference.build(treed, hulls: hulls))
        XCTAssertTrue(reference.walksEveryHull, "the default configuration walks every hull, tree or no tree")
        solver.destroy()
        reference.destroy()
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
    /// stepped frame encodes one frame of 49 dispatches (51 with the GPU
    /// shell's two, phase 2) again.
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
        XCTAssertEqual(solver.stats.dispatches, 49 + (try shellDispatches(h)))
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
    /// `hulls=` and `planes=` (816 on the cook of 2026-11-04) beside the constraints.
    func testTheSkinCollidersAreCountedOnTheGPUPath() throws {
        guard let colliders = ClothFixtures.asset?.colliders, !colliders.isEmpty else { throw XCTSkip("the sidecar carries no skin colliders") }
        let world = try makeHarness(configuration: gpuConfiguration())
        XCTAssertEqual(world.cloth.skinColliderCount, colliders.count, "every collider of the sidecar is a hull in the solver")
        XCTAssertEqual(world.physics.backend.bodyCount, 1 + 20, "the floor slab and the twenty parts: no Jolt soft body, no Jolt hulls")
        XCTAssertTrue(world.cloth.report.hasPrefix("cloth shirt[gpu]:"), world.cloth.report)
        XCTAssertTrue(world.cloth.report.contains("colliders=\(colliders.count)"), world.cloth.report)
        XCTAssertTrue(world.cloth.report.contains("hulls=11 planes=816 stretch=10425 bend=10425"), world.cloth.report)
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
        XCTAssertEqual(dispatches, 3 * 16 + 1 + (try gpu(h).hasGPUShell ? 2 : 0), "16 substeps at 10 ms, two gathers each, plus the stats kernel and the shell's two")
        XCTAssertEqual(substeps, 16)
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }

    // MARK: - Phase 2: the GPU shell

    /// The shell evaluated on the GPU (`zcTriangleFrames` + `zcShell`, phase
    /// 2 of `Docs/GPUCloth.md`) against `RenderShell.evaluate` on the cores,
    /// the same frame both ways: the frame's final particles, read back and
    /// taken into mesh space, through the CPU shell, against the solver's
    /// `shellOutput` for that frame in the same space — at the bind pose
    /// after the first frame, and in a swayed frame a second in — over all
    /// 29,402 slots of the tests' shell-only mesh, the positions within
    /// 1e-5 m and the normals within 0.05 degrees (the design's bounds:
    /// float arithmetic in another order over coordinates of a metre or
    /// two, nothing more). The override the cloth wrote that frame is the
    /// same shell (within the same bounds), the cloth counts the frame as a
    /// GPU-shell frame (`gpuShellFrames`), and the frame carries 51
    /// dispatches, the shell's two after the stats. With `gpuShell` off the
    /// cloth evaluates on the cores as in phase 1, counts no GPU-shell frame
    /// and the solver has no shell to read. Written 2026-11-04 against the
    /// solver's `hasGPUShell` / `shellOutput(meshFromWorld:)` and the cloth's
    /// `gpuShellFrames` (the design named the kernels and left the accessor
    /// to the code).
    func testTheGPUShellMatchesTheCPUShell() throws {
        let h = try makeHarness(configuration: gpuConfiguration())
        let solver = try gpu(h)
        guard solver.hasGPUShell else { throw XCTSkip("the cloth did not hand the GPU solver its shell (gpuShell \(h.cloth.configuration.gpuShell)); the CPU shell stands") }
        let shell = try XCTUnwrap(h.cloth.renderShell(ofGarment: 0))
        XCTAssertEqual(solver.shellSlotCount, shell.slotCount, "the solver's slots are not the shell's")
        XCTAssertEqual(shell.slotCount, 29402, "the tests' shell-only mesh drives one exported vertex per shell vertex")
        // The angle in double precision: in single, acos near 1 resolves no
        // finer than 0.03 degrees, which would read as a difference that
        // is not there.
        func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let u = simd_normalize(SIMD3<Double>(a)), v = simd_normalize(SIMD3<Double>(b))
            return Float(acos(min(1, max(-1, simd_dot(u, v)))) * 180 / .pi)
        }
        var compared = 0
        func compare(_ label: String) throws {
            let toMesh = h.body.world.inverse
            let particles = h.meshParticles
            let gpu = try XCTUnwrap(solver.shellOutput(meshFromWorld: toMesh), "\(label): the solver had no shell output for the frame")
            shell.evaluate(particles: particles)
            XCTAssertEqual(gpu.positions.count, shell.slotCount)
            var worstPosition: Float = 0, worstNormal: Float = 0, worstWritten: Float = 0, worstWrittenNormal: Float = 0, worstUnit: Float = 0
            for s in 0 ..< shell.slotCount {
                worstPosition = max(worstPosition, simd_distance(gpu.positions[s], shell.positions[s]))
                worstNormal = max(worstNormal, angle(gpu.normals[s], shell.normals[s]))
                worstUnit = max(worstUnit, abs(simd_length(gpu.normals[s]) - 1))
                worstWritten = max(worstWritten, simd_distance(h.body.positions[s], shell.positions[s]))
                worstWrittenNormal = max(worstWrittenNormal, angle(h.body.normals[s], shell.normals[s]))
            }
            print(String(format: "cloth gpu shell, %@: %d slots, the GPU shell within %.2e m and %.4f degrees of the CPU shell (normals within %.1e of unit); the frame's override within %.2e m and %.4f degrees; %@",
                         label, shell.slotCount, worstPosition, worstNormal, worstUnit, worstWritten, worstWrittenNormal, h.cloth.summary))
            XCTAssertLessThan(worstPosition, 1e-5, "\(label): a slot's GPU position is \(worstPosition) m off the CPU shell's")
            XCTAssertLessThan(worstNormal, 0.05, "\(label): a slot's GPU normal is \(worstNormal) degrees off the CPU shell's")
            XCTAssertLessThan(worstUnit, 1e-3, "\(label): a GPU normal is \(worstUnit) off unit length")
            XCTAssertLessThan(worstWritten, 1e-5, "\(label): the override written is \(worstWritten) m off the CPU shell")
            XCTAssertLessThan(worstWrittenNormal, 0.05, "\(label): the override's normals are \(worstWrittenNormal) degrees off the CPU shell's")
            compared += 1
        }
        h.frame()
        XCTAssertEqual(solver.stats.dispatches, 3 * 16 + 1 + 2, "16 substeps of a predict and two gathers, the stats, the triangle frames and the shell")
        XCTAssertEqual(h.cloth.gpuShellFrames, 1, "the first frame's override did not come from the GPU shell")
        try compare("bind pose, frame 1")
        for _ in 0 ..< 100 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
        }
        XCTAssertEqual(h.cloth.gpuShellFrames, 101, "a swaying frame's override did not come from the GPU shell")
        try compare("sway, frame 101")
        // The entity moved inside the frame (the game's controller does it
        // on most chase frames: `translateTo` syncs the world transform
        // eagerly between the cloth's `beginUpdate` and its `readBack`):
        // the kernels wrote the frame's begin matrix's space, the copy
        // re-expresses through the read's — a translation and a turn here,
        // so the normals' inverse-transpose is exercised too — and the
        // CPU shell on the particles taken through the read's matrix is
        // the judge; the output read through the old matrix is the same
        // shell carried by the rigid change of frame, which is the proof
        // the re-expression ran and not a copy (added 2026-11-04, review).
        let before = h.body.world
        let moved = before * Self.translation(SIMD3(0.05, 0, -0.03)) * simd_float4x4(simd_quatf(angle: 0.1, axis: SIMD3(0, 1, 0)))
        let old = try XCTUnwrap(solver.shellOutput(meshFromWorld: before.inverse))
        h.frame(beforeUpdate: { h.body.world = moved })
        XCTAssertEqual(h.cloth.gpuShellFrames, 102, "the moved frame's override did not come from the GPU shell (fell back \(h.cloth.cpuShellFallbacks) times)")
        try compare("moved inside the frame, frame 102")
        let fresh = try XCTUnwrap(solver.shellOutput(meshFromWorld: before.inverse))
        let delta = moved.inverse * before
        var worstCarried: Float = 0
        for s in 0 ..< shell.slotCount {
            let carried = delta * SIMD4(fresh.positions[s], 1)
            worstCarried = max(worstCarried, simd_distance(h.body.positions[s], SIMD3(carried.x, carried.y, carried.z)))
        }
        XCTAssertLessThan(worstCarried, 1e-5, "the re-expressed shell is \(worstCarried) m off the frame's shell carried by the change of frame")
        XCTAssertGreaterThan(simd_distance(old.positions[0], h.body.positions[0]), 0.01, "the moved frame's override is where the unmoved one's was: the re-expression did not run")
        h.body.world = before
        XCTAssertEqual(compared, 3)
        XCTAssertEqual(h.cloth.runawayCount, 0)
        // The A/B back: the CPU shell on the GPU arm.
        var cpu = gpuConfiguration()
        cpu.gpuShell = false
        let c = try makeHarness(configuration: cpu)
        c.frames(3)
        XCTAssertFalse(try gpu(c).hasGPUShell, "with gpuShell off the solver was handed a shell")
        XCTAssertEqual(c.cloth.gpuShellFrames, 0)
        XCTAssertEqual(try gpu(c).stats.dispatches, 3 * 16 + 1)
        XCTAssertNil(try gpu(c).shellOutput(meshFromWorld: c.body.world.inverse))
        XCTAssertEqual(c.body.overrideWrites, 3, "the CPU shell still writes the override")
    }

    // MARK: - Phase 2: the 16k proxy

    /// The drape figure on the 4k and the 16k proxy side by side, the hang
    /// and the sway on the GPU (`ClothMetrics.Drape`, the design's section
    /// 6 `testTheHangReportsItsFolds`): the hem band's mean absolute
    /// dihedral per edge and the band's mean absolute curvature (1/m, the
    /// resolution-free form), and the fold alternations around the hem
    /// loop through a 2 cm window, per metre of hem. Printed for the
    /// owner's gate-2 verdict and not pinned until it is in; what is held
    /// is that both proxies read (a band of edges, a closed hem loop) and
    /// that the finer proxy's hem loop is the same hem within 5 cm of
    /// length, since the two cooks cut the same shell. Each figure is
    /// printed beside the same shirt's at the sidecar's bind pose and as
    /// the change from it (`ClothMetrics.restDrape`, `Drape.against`),
    /// because the artist's hem has folds of its own that the finer loop
    /// resolves and the coarser cannot: the first day's count (12 and 26
    /// alternations, "the alternations double") was mostly that — 21 of
    /// the 16k's 22.9 per metre were there before either solver ran, read
    /// through a window that smoothed the 4k loop vertex to vertex and the
    /// 16k's over three; the fold profile is resampled at 5 mm now. Measured
    /// 2026-11-04 on the M4 Max with the resample: at rest the 4k hem band
    /// (430 particles, 1,097 interior edges, 1,108 cm^2) reads 4.67 degrees
    /// per edge, 15.53 1/m and 6 alternations on its 1.162 m loop (5.2 per
    /// metre), the 16k band (1,731 particles, 4,816 edges, 1,141 cm^2)
    /// 2.35 degrees, 16.61 1/m and 6 on 1.125 m (5.3 per metre) — the same
    /// hem on one scale, as the curvature definition promises. After the
    /// hang the 4k reads 16.45 1/m and 5.2 per metre, +0.92 1/m (+6 %) and
    /// no new alternation; the 16k 27.09 1/m and 8.8 per metre, +10.48 1/m
    /// (+63 %) and +3.5 per metre: the hang folds the finer hem and leaves
    /// the coarser as the artist drew it. After the sway +0.67 1/m and +0
    /// at 4k, +9.26 1/m (+56 %) and +5.2 per metre at 16k. The curvature
    /// rise carries the finer proxy's unconverged stretch too
    /// (`testStretchResidualAtRestAt16k`): to this solver mass and
    /// compliance are one product, and the per-area mass tried that day
    /// read +8.15 1/m (+49 %) for the same hang before it was withdrawn.
    func testTheHangReportsItsFoldsOnBothProxies() throws {
        var figures: [String: ClothMetrics.Drape] = [:], rests: [String: ClothMetrics.Drape] = [:]
        for (label, sidecar) in [("4k", nil), ("16k", ClothFixtures.sidecar16kName)] {
            let h = try makeHarness(configuration: gpuConfiguration(), sidecar: sidecar)
            h.frames(200)
            let rest = try XCTUnwrap(ClothMetrics.restDrape(of: h), "\(label): the hem band or the hem loop could not be read at the bind pose")
            print("cloth drape, rest, \(label) (\(h.shirt.particles.count) particles): \(rest)")
            let hang = try XCTUnwrap(ClothMetrics.drape(of: h), "\(label): the hem band or the hem loop could not be read")
            print("cloth drape, hang 2 s, gpu \(label) (\(h.shirt.particles.count) particles): \(hang); \(hang.against(rest))")
            for _ in 0 ..< 300 {
                let t = h.time + h.dt
                h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
                h.frame()
            }
            let sway = try XCTUnwrap(ClothMetrics.drape(of: h), "\(label): the hem band or the hem loop could not be read after the sway")
            print("cloth drape, sway 3 s, gpu \(label) (\(h.shirt.particles.count) particles): \(sway); \(sway.against(rest))")
            XCTAssertGreaterThan(hang.bandEdges, 100)
            XCTAssertTrue(hang.curvature.isFinite && sway.curvature.isFinite)
            XCTAssertEqual(h.cloth.runawayCount, 0)
            figures[label] = hang
            rests[label] = rest
        }
        if let four = figures["4k"], let sixteen = figures["16k"] {
            XCTAssertEqual(four.loopLength, sixteen.loopLength, accuracy: 0.05, "the two proxies' hem loops differ in length: \(four.loopLength) against \(sixteen.loopLength) m")
            XCTAssertGreaterThan(sixteen.bandEdges, four.bandEdges * 3, "the 16k hem band has \(sixteen.bandEdges) interior edges against the 4k's \(four.bandEdges)")
            print(String(format: "cloth drape, 4k against 16k after the hang: curvature %.2f against %.2f 1/m, alternations %.1f against %.1f per metre, mean |dihedral| %.2f against %.2f degrees per edge; from the rest pose: curvature %+.2f against %+.2f 1/m, alternations %+.1f against %+.1f per metre",
                         four.curvature, sixteen.curvature, four.alternationsPerMetre, sixteen.alternationsPerMetre, four.meanDihedralDegrees, sixteen.meanDihedralDegrees,
                         four.curvature - (rests["4k"]?.curvature ?? 0), sixteen.curvature - (rests["16k"]?.curvature ?? 0),
                         four.alternationsPerMetre - (rests["4k"]?.alternationsPerMetre ?? 0), sixteen.alternationsPerMetre - (rests["16k"]?.alternationsPerMetre ?? 0)))
        }
    }

    /// The Jolt arm refuses the 16k proxy with one printed line and builds
    /// nothing (`ZombieCloth.joltParticleLimit`, 8,000: Jolt solves its
    /// edges on one thread, so the finer proxy would be four times its
    /// 3.4 ms step), so the phase-2 A/B is Jolt at 4k against the GPU at 16k
    /// by construction, as the design has it; the body is left to its own
    /// skinning and the Jolt world holds the floor slab and the twenty parts
    /// alone. The GPU arm on the same sidecar attaches and simulates.
    func testJoltRefusesThe16kProxyAndTheGPUTakesIt() throws {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        guard let sixteen = ClothFixtures.sidecar(named: ClothFixtures.sidecar16kName) else { throw XCTSkip("Models/Zombie/\(ClothFixtures.sidecar16kName) is not bundled (the phase-2 cook)") }
        XCTAssertGreaterThan(sixteen.garment(named: "shirt")?.particles.count ?? 0, ZombieCloth.joltParticleLimit)
        let jolt = ClothHarness(dt: dt, asset: asset, joints: joints, solver: .jolt, sidecar: ClothFixtures.sidecar16kName)
        XCTAssertEqual(jolt.sidecarName, ClothFixtures.sidecar16kName)
        XCTAssertFalse(jolt.attached, "Jolt took the 16k proxy")
        XCTAssertNil(jolt.cloth.activeSolver)
        XCTAssertEqual(jolt.physics.backend.bodyCount, 1 + 20, "the floor slab and the twenty parts: no soft body, no hulls")
        jolt.frames(3)
        XCTAssertEqual(jolt.body.overrideWrites, 0, "a refused shirt wrote an override")
        XCTAssertEqual(jolt.cloth.report, "cloth: none")
        let gpu = try makeHarness16k(configuration: gpuConfiguration())
        gpu.frames(3)
        XCTAssertEqual(gpu.body.overrideWrites, 3)
        XCTAssertTrue(gpu.cloth.report.hasPrefix("cloth shirt[gpu]: \(gpu.shirt.particles.count) particles"), gpu.cloth.report)
        print("cloth 16k on Jolt: refused (\(jolt.cloth.report)); on the GPU: \(gpu.cloth.report)")
    }

    /// The game picks the sidecar by the arm the shirt will really run on
    /// (`ZombieChaseGame.clothSidecar(for:device:)`, 2026-11-04, after the
    /// review of phase 2): the 16k only for a GPU pick on a device the GPU
    /// solver can be built on (`ZombieCloth.gpuAvailable`), the 4k with a
    /// line for the Jolt arm, for a GPU pick with no device — the headset's
    /// renderer gone, a metallib missing — and for a cook not in the
    /// bundle, the default with no line when nothing is named. Until then
    /// the pick went by the configuration alone and a GPU pick that fell
    /// back to Jolt at the attach lost the shirt to `joltParticleLimit`.
    /// The cloth's own fallback is held beside it: a GPU pick with no
    /// device attaches the 4k on Jolt.
    func testTheGamePicksTheSidecarTheArmCanTake() throws {
        var gpu = gpuConfiguration()
        gpu.sidecar = ZombieClothAsset.sidecar16kName
        let noDevice = ZombieChaseGame.clothSidecar(for: gpu, device: nil)
        XCTAssertEqual(noDevice.name, ZombieClothAsset.defaultSidecarName)
        XCTAssertTrue(noDevice.line?.contains("Jolt stands in") == true, noDevice.line ?? "no line")
        XCTAssertFalse(ZombieCloth.gpuAvailable(device: nil, configuration: gpu))
        var jolt = gpu
        jolt.solver = .jolt
        let onJolt = ZombieChaseGame.clothSidecar(for: jolt, device: device)
        XCTAssertEqual(onJolt.name, ZombieClothAsset.defaultSidecarName)
        XCTAssertTrue(onJolt.line?.contains("the Jolt arm keeps") == true, onJolt.line ?? "no line")
        XCTAssertTrue(ZombieCloth.gpuAvailable(device: device, configuration: gpu), "the GPU solver cannot be built on \(device.name)")
        let onGPU = ZombieChaseGame.clothSidecar(for: gpu, device: device)
        if ZombieClothAsset.isBundled(named: ZombieClothAsset.sidecar16kName) {
            XCTAssertEqual(onGPU.name, ZombieClothAsset.sidecar16kName)
            XCTAssertNil(onGPU.line)
        } else {
            XCTAssertEqual(onGPU.name, ZombieClothAsset.defaultSidecarName)
            XCTAssertTrue(onGPU.line?.contains("not cooked yet") == true, onGPU.line ?? "no line")
        }
        let plain = ZombieChaseGame.clothSidecar(for: gpuConfiguration(), device: device)
        XCTAssertEqual(plain.name, ZombieClothAsset.defaultSidecarName)
        XCTAssertNil(plain.line)
        print("cloth sidecar choice: no device -> \(noDevice.name) (\(noDevice.line ?? "")); Jolt -> \(onJolt.name); GPU on \(device.name) -> \(onGPU.name)")
        // The cloth with the 4k and no device: Jolt stands in and attaches.
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let fallen = ClothHarness(dt: dt, asset: asset, joints: joints, configuration: gpuConfiguration(), solver: .gpu, device: nil)
        XCTAssertTrue(fallen.attached, "a GPU pick with no device did not attach the 4k on Jolt")
        XCTAssertEqual(fallen.cloth.activeSolver, .jolt)
        fallen.frames(2)
        XCTAssertEqual(fallen.body.overrideWrites, 2)
    }

    /// The 16k proxy at rest against the posed skin (the metric the fit
    /// tests read the shirt against, `ClothMetrics.penetration`): on the
    /// bind pose every one of the finer proxy's particles with skin within
    /// 5 cm reads OUTSIDE it — the cook's push-out leaves the proxy 2 mm off
    /// the body, as the 4k one's does (ZombieClothTests'
    /// `testThePosedBodyReadsTheRestShirtAsOutside`: 3,666 of 3,995 read,
    /// the nearest 2.45 mm) — so the penetration counts the 16k scenarios
    /// print start from zero at rest. The nearest particle and its region
    /// are printed; a cook whose refinement crossed the skin would show
    /// here before any scenario.
    func testThePosedSkinReadsTheRest16kShirtAsOutside() throws {
        let h = try makeHarness16k(configuration: gpuConfiguration())
        let penetration = try XCTUnwrap(ClothMetrics.penetration(of: h), "the posed skin could not be built")
        let distances = try XCTUnwrap(ClothMetrics.skinDistances(of: h))
        var nearest = (distance: Float.greatestFiniteMagnitude, index: 0)
        for (index, d) in distances.enumerated() { if let d, d < nearest.distance { nearest = (d, index) } }
        let at = h.shirt.positions[nearest.index]
        print(String(format: "cloth 16k at rest: %@; the nearest particle to the skin is %d (%@) at (%.2f,%.2f,%.2f), %.2f mm outside", penetration.description,
                     nearest.index, ClothMetrics.regionName(slack: h.shirt.maxDistance[nearest.index]), at.x, at.y, at.z, nearest.distance * 1000))
        XCTAssertGreaterThan(penetration.measured, h.shirt.particles.count * 8 / 10, "only \(penetration.measured) of \(h.shirt.particles.count) particles have skin within 5 cm")
        XCTAssertEqual(penetration.inside, 0, "\(penetration.inside) particles of the resting 16k proxy sit more than 2 mm inside the posed skin")
        XCTAssertGreaterThan(nearest.distance, 0, "particle \(nearest.index) of the resting 16k proxy reads \(nearest.distance) m: inside the skin")
    }

    /// The hang on the GPU at 16k (`ClothFitScenarios.hang`), the same
    /// scenario and figures as the 4k row, with the report's graph and
    /// plane counts printed. Bounds `gpuBounds16k.hang` (measured
    /// 2026-11-04: the sag 22.9 mm, the hem 16.7 mm over the yoke's 2.8,
    /// the back-stop 1.67 mm, the clearance 1.73 mm, none inside the posed
    /// skin). The sag and hem floors are the 4k row's 5 mm, a shirt that
    /// hangs at all, not the 18 and 10 mm first pinned on the day's
    /// measurement: the finer shirt's extra sag over the 4k's 9.4 mm is
    /// its unconverged stretch (`testStretchResidualAtRestAt16k`), a figure
    /// for gate 2 to tune and not a target to hold. The drape figure
    /// beside it, read against the rest pose: curvature +10.5 1/m (+63 %)
    /// and +3.5 fold alternations per metre of hem, where the 4k's hang
    /// adds +0.9 1/m (+6 %) and no alternation.
    func testTheGPUShirtHangsFromTheShouldersAt16k() throws {
        let h = try makeHarness16k(configuration: gpuConfiguration())
        let control = try makeHarness16k(configuration: gpuConfiguration(), gravity: .zero)
        let solver = try gpu(h)
        print("cloth gpu 16k attach: \(h.shirt.particles.count) particles, \(solver.constraintGraph?.entryCount ?? 0) CSR entries, \(solver.hullCount) hulls, \(solver.planeCount) planes; \(h.cloth.report)")
        XCTAssertEqual(solver.hullCount, 11)
        XCTAssertEqual(solver.planeCount, 816, "the colliders are the 4k file's: 816 planes on the cook of 2026-11-04")
        try ClothFitScenarios.hang(h, control: control, bounds: Self.gpuBounds16k.hang)
    }

    /// The sway on the GPU at 16k (`ClothFitScenarios.sway`) on the world
    /// model. Bounds `gpuBounds16k.sway` (measured 2026-11-04: excess
    /// 1.6e-6 m, pins 3.2e-6 m, none inside the posed skin at the last
    /// frame, the drape 25.9 1/m and 17.6 alternations per metre).
    func testTheGPUSwayingBodyKeepsTheShirtWithinItsSlackAt16k() throws {
        let h = try makeHarness16k(configuration: gpuConfiguration())
        try ClothFitScenarios.sway(h, label: "world, 16k", lagBound: false, bounds: Self.gpuBounds16k.sway)
    }

    /// The arms-forward idle on the GPU at 16k (`ClothFitScenarios.
    /// armsForwardIdle`) on the world model and the skin-only control, the
    /// posed-skin penetration counted on both. Bounds `gpuBounds16k.
    /// armsForward` (measured 2026-11-04: the band's farthest particle on
    /// its 150 mm ball, 30 inside with the hulls and 71 without, 13.2 and
    /// 16.4 mm behind the skin); the control is held to a dozen at least
    /// and the hulls to under three quarters of it, as the 4k row holds
    /// them (they take three fifths away here).
    func testTheGPUArmsForwardIdleKeepsTheArmholeNearItsTargetAt16k() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0) else { throw XCTSkip("the idle clip is not bundled") }
        guard let joints = ClothFixtures.skeleton, let hand = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l"),
              let pelvis = joints.jointPaths.firstIndex(of: "/root/pelvis") else { throw XCTSkip("no skeleton") }
        let handRise = (pose[hand].columns.3.y - pose[pelvis].columns.3.y) - (joints.bindModelTransforms[hand].columns.3.y - joints.bindModelTransforms[pelvis].columns.3.y)
        var insideByModel: [String: Int] = [:]
        for (label, configuration) in [("skin only, 16k", skinOnly), ("world, 16k", gpuConfiguration())] {
            var bounds = Self.gpuBounds16k.armsForward
            bounds.penetration = label.hasPrefix("world") ? Self.gpuBounds16k.armsForward.penetration : nil
            let h = try makeHarness16k(configuration: configuration, pose: pose)
            let figures = try ClothFitScenarios.armsForwardIdle(h, label: label, handRise: handRise, bounds: bounds)
            insideByModel[label] = figures.inside
        }
        print("cloth arms-forward idle, 16k: inside by model \(insideByModel)")
        XCTAssertGreaterThan(insideByModel["skin only, 16k"] ?? 0, 12, "the skin-only control no longer shows the patches the hulls are for: \(insideByModel)")
        XCTAssertLessThan(Float(insideByModel["world, 16k"] ?? Int.max) / Float(max(insideByModel["skin only, 16k"] ?? 1, 1)), 0.75, "the skin's hulls take less than a quarter of the particles inside the posed skin away: \(insideByModel)")
    }

    /// The arm swing on the GPU at 16k (`ClothFitScenarios.armSwing`) on
    /// the world model. Bounds `gpuBounds16k.swing` (measured 2026-11-04:
    /// at most 9 inside at frame 37 and 4 once held, 5.2 mm deep at frame
    /// 25 at particle 7878, the right armpit's armhole band, the sleeves
    /// 50.0 mm off the skin, nothing past the slack).
    func testTheGPUSwingingArmKeepsTheSleeveOnItsHullAt16k() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0), let joints = ClothFixtures.skeleton else { throw XCTSkip("the idle clip is not bundled") }
        guard let upperarm = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l"),
              let elbow = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l") else { throw XCTSkip("no left arm") }
        let h = try makeHarness16k(configuration: gpuConfiguration())
        let readings = try ClothFitScenarios.armSwing(h, label: "world, 16k", pose: pose, joints: joints, upperarm: upperarm, elbow: elbow, bounds: Self.gpuBounds16k.swing)
        print("cloth gpu arm swing, world, 16k, per frame (frame inside deepest_mm excess_mm lift_mm elbow_m/s): " + readings.map { String(format: "%d %d %.1f %+.1f %.1f %.2f", $0.frame, $0.inside, -$0.deepest * 1000, $0.excess * 1000, $0.lift * 1000, $0.elbowSpeed) }.joined(separator: "; "))
    }

    /// The cost at 16k over 300 frames of the sway (the design's section 8:
    /// about 35 MFLOP and 8 MB a substep, 1.2-1.8 ms a frame at 16
    /// substeps on the headset, under 0.1 ms more for the shell kernels; the
    /// Mac's figures here, a debug build): the feed, the GPU, the wait, the
    /// read-back and the bind, medians and maxima, and 300 override writes.
    /// Measured 2026-11-04 on the M4 Max at 51 dispatches (16 substeps of a
    /// predict and two gathers, the stats, the two shell kernels): feed
    /// 311 us median, gpu 2,557 us median and 5,868 max, wait 2,943 median,
    /// read-back 11,355 median (the debug build's copy of 15,979 particles
    /// and 29,402 slots), bind 3,543 median — against 288 / 1,658 / 2,049 /
    /// 5,673 / 2,440 at 4k the same day; and with the arms forward, where
    /// every hull is in play, the report read gpu=6.49 ms, over the
    /// design's 2.0 ms gate even on this GPU, which is the figure for the
    /// owner's cost read before any headset build.
    func testGPUTimingsOverThreeHundredFramesAt16k() throws {
        let h = try makeHarness16k(configuration: gpuConfiguration())
        let solver = try gpu(h)
        var feed: [Double] = [], gpuTime: [Double] = [], wait: [Double] = [], read: [Double] = [], bind: [Double] = []
        var dispatches = 0, substeps = 0
        for _ in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            let timings = h.cloth.timings
            read.append(timings.readBack); bind.append(timings.bind)
            let stats = solver.stats
            feed.append(stats.feedMicroseconds); gpuTime.append(stats.gpuMilliseconds * 1000); wait.append(stats.waitMicroseconds)
            dispatches = max(dispatches, stats.dispatches); substeps = max(substeps, stats.substeps)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean %.0f us, median %.0f us, max %.0f us", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted.last ?? 0)
        }
        print("cloth gpu timing 16k (300 frames, 100 Hz, \(substeps) substeps, \(dispatches) dispatches, \(h.shirt.particles.count) particles, \(solver.constraintGraph?.entryCount ?? 0) entries, \(h.shirt.render?.vertexCount ?? 0) shell vertices, gpu shell \(solver.hasGPUShell), \(device.name)): feed \(stats(feed)); gpu \(stats(gpuTime)); wait \(stats(wait)); read-back \(stats(read)); bind \(stats(bind)); \(h.cloth.summary)")
        XCTAssertEqual(h.body.overrideWrites, 300)
        XCTAssertEqual(substeps, 16)
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }
}
