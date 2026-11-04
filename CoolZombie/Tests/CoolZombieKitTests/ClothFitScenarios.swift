//
//  ClothFitScenarios.swift
//  CoolZombieKitTests
//
//  The fit scenarios the cloth tests run — the hang, the idle, the sway, the
//  re-seat, the dent, the three sleep tests, the range, the arms-forward
//  idle and the arm swing — as functions of a `ClothHarness` and the bounds
//  the caller pins, hoisted out of ZombieClothTests on 2026-11-03 so the
//  GPU solver of `Docs/GPUCloth.md` is judged by the same scenarios, the
//  same figures printed, with bounds measured on its own run. The bodies are
//  the Jolt tests' of that date, moved and not changed except that each
//  literal bound became a field of `ClothFitBounds`; `ClothFitBounds.jolt`
//  holds the Jolt literals, so the Jolt tests print and assert exactly what
//  they did.
//

@testable import CoolZombieKit
import simd
@testable import UntoldEngine
import XCTest

/// The bounds a scenario holds a solver to, metres unless named otherwise;
/// `jolt` is the Jolt tests' literals (ZombieClothTests documents each
/// figure), and the GPU twin pins its own from its measurement.
struct ClothFitBounds {
    struct Hang {
        /// Particles more than 2 mm inside the posed skin after the hang.
        var penetration: Int
        /// The chest and the back sag at least this below their targets.
        var sag: Float
        /// The hem band's mean sag over the yoke's by at least this.
        var hemOverYoke: Float
        /// A chest or back particle past its slack.
        var excess: Float
        /// A pin off the skin.
        var pins: Float
        /// The nearest particle with a back-stop to the surface under the shirt.
        var clearance: Float
        /// A particle behind its skinned plane along the skin's normal.
        var inward: Float
        /// A button or a bit off where its triangle's rotation carries it.
        var rigid: Float
        /// The sag without gravity (the control).
        var controlSag: Float
    }

    struct Idle {
        var excess: Float
        var pins: Float
    }

    struct Sway {
        /// Particles more than 2 mm inside the posed skin at the sway's end.
        var penetration: Int
        /// A particle past its slack, on the models whose parts do not push it.
        var excess: Float
        /// The same over the lagging ragdoll parts.
        var excessOverLaggingParts: Float
        var pins: Float
    }

    struct Dent {
        /// What the ball adds to the chest's distance from its targets.
        var dent: Float
    }

    struct ArmsForward {
        /// Particles more than 2 mm inside the posed skin; nil on a model
        /// the test does not hold (the skin-only control).
        var penetration: Int?
        /// The armhole band's farthest particle from its target.
        var armhole: Float
        /// A particle past its slack (not held on the ragdoll model).
        var excess: Float
        /// A particle behind its skinned plane.
        var inward: Float
    }

    struct Swing {
        /// Particles more than 2 mm inside the posed skin in any read frame.
        var inside: Int
        /// The deepest particle inside the posed skin.
        var deepest: Float
        /// A particle past its slack during the swing.
        var excess: Float
        /// The sleeves' farthest particle off the skin.
        var lift: Float
    }

    var hang: Hang
    var idle: Idle
    var sway: Sway
    var dent: Dent
    var armsForward: ArmsForward
    var swing: Swing

    /// The Jolt tests' literals, as pinned before the hoist (2026-11-03):
    /// the sway's and the arms-forward idle's penetration counts are per
    /// collision model and set by the caller.
    static let jolt = ClothFitBounds(
        hang: Hang(penetration: 0, sag: 0.005, hemOverYoke: 0.005, excess: 0.005, pins: 1e-3, clearance: 0.001, inward: 0.005, rigid: 1e-4, controlSag: 0.002),
        idle: Idle(excess: 0.005, pins: 1e-3),
        sway: Sway(penetration: 0, excess: 0.005, excessOverLaggingParts: 0.02, pins: 1e-3),
        dent: Dent(dent: 0.02),
        armsForward: ArmsForward(penetration: 90, armhole: 0.16, excess: 0.015, inward: 0.04),
        swing: Swing(inside: 35, deepest: 0.018, excess: 0.012, lift: 0.055)
    )
}

/// The scenarios, each on a harness the caller built (so the configuration,
/// the solver, the device, the world and the pose are the caller's) and
/// printing the figures the Jolt tests print.
enum ClothFitScenarios {
    /// The hang (`testTheShirtHangsFromTheShouldersAndTheButtonsStayRigid`):
    /// `h` after its attach, run for two seconds on the bind pose, and
    /// `control` the same harness without gravity; the figures printed are
    /// the Jolt test's, and the bounds the caller's.
    static func hang(_ h: ClothHarness, control: ClothHarness, bounds: ClothFitBounds.Hang) throws {
        h.frames(200)
        let p = h.particles, t = h.targets
        var sag: Float = -1, sagAt = SIMD3<Float>.zero, excess: Float = -1, pinned: Float = 0, chestBack = 0, pins = 0
        var sagSum: [Float: Float] = [:], sagCount: [Float: Int] = [:]
        for index in p.indices {
            let slack = h.shirt.maxDistance[index]
            let d = simd_distance(p[index], t[index])
            let drop = t[index].y - p[index].y
            sagSum[slack, default: 0] += drop
            sagCount[slack, default: 0] += 1
            if slack == 0 {
                pins += 1; pinned = max(pinned, d)
            } else if slack == 0.09 || slack == 0.10 {
                chestBack += 1
                excess = max(excess, d - slack)
                if drop > sag { sag = drop; sagAt = h.shirt.positions[index] }
            }
        }
        XCTAssertGreaterThan(chestBack, 500, "the chest and the back were not found")
        XCTAssertGreaterThan(pins, 300, "the collar band and the cuffs were not found")
        func mean(_ slack: Float) -> Float { (sagSum[slack] ?? 0) / Float(max(sagCount[slack] ?? 1, 1)) }
        let regions = [(Float(0.07), "yoke"), (0.15, "armhole"), (0.09, "chest"), (0.10, "back"), (0.12, "hem")]
        let means = regions.map { String(format: "%@ %.1f mm", $0.1, mean($0.0) * 1000) }.joined(separator: ", ")
        let worstInward = h.worstInward(), inward = worstInward.depth
        // The buttons and the bits: each island carried by its triangle's
        // rotation (the frame now against the frame at rest, both from the
        // particles), applied to its rest shape about its centroid; mesh space.
        let shell = try XCTUnwrap(h.cloth.renderShell(ofGarment: 0))
        let render = try XCTUnwrap(h.shirt.render)
        let slot = h.slotOfVertex, rest = h.body.mesh, restParticles = h.shirt.positions
        let meshParticles = h.meshParticles
        // The particle farthest behind its target: where it is on the shirt
        // and how far it and its target really are from the surface under
        // the shirt (this is the bind pose, where the export stands).
        let inwardAt = h.shirt.positions[worstInward.index]
        let inwardBody = ClothMetrics.distanceToBody(meshParticles[worstInward.index]), inwardTargetBody = ClothMetrics.distanceToBody(inwardAt)
        print(String(format: "cloth hang 2 s, farthest behind the skin: particle %d (slack %.3f) at rest (%.2f,%.2f,%.2f), %.2f mm behind its target along the skin's normal, dropped %.1f mm; now %.2f mm from the surface under the shirt, its target %.2f mm",
                     worstInward.index, h.shirt.maxDistance[worstInward.index], inwardAt.x, inwardAt.y, inwardAt.z, inward * 1000, (t[worstInward.index].y - p[worstInward.index].y) * 1000,
                     (inwardBody?.distance ?? .nan) * 1000, (inwardTargetBody?.distance ?? .nan) * 1000))
        // The clearance itself: the nearest any particle with a back-stop
        // comes to the surface under the shirt, and where.
        let bodyFacing = Set(h.shirt.bodyFacingParticles)
        var clearance: Float = .greatestFiniteMagnitude, clearanceAt = 0, restClearance: Float = .greatestFiniteMagnitude
        for index in p.indices where h.shirt.maxDistance[index] > 0 && !bodyFacing.contains(index) {
            if let near = ClothMetrics.distanceToBody(meshParticles[index]), near.distance < clearance { clearance = near.distance; clearanceAt = index }
            if let near = ClothMetrics.distanceToBody(h.shirt.positions[index]) { restClearance = min(restClearance, near.distance) }
        }
        let clearanceRest = h.shirt.positions[clearanceAt]
        print(String(format: "cloth hang 2 s, clearance: the nearest particle to the surface under the shirt is %d (slack %.3f) at rest (%.2f,%.2f,%.2f), %.2f mm off it (%.2f mm at rest); %.2f mm behind its target along the skin's normal",
                     clearanceAt, h.shirt.maxDistance[clearanceAt], clearanceRest.x, clearanceRest.y, clearanceRest.z, clearance * 1000, restClearance * 1000,
                     simd_dot(t[clearanceAt] - p[clearanceAt], h.targetNormals()[clearanceAt]) * 1000))
        // The same surface signed, every particle (the pins and the
        // body-facing ones too), as the posed-skin metric reads it.
        let penetration = try XCTUnwrap(ClothMetrics.penetration(of: h), "the posed skin could not be built")
        print("cloth hang 2 s, \(penetration)")
        XCTAssertLessThanOrEqual(penetration.inside, bounds.penetration, "\(penetration.inside) particles sit more than 2 mm inside the posed skin after the hang (deepest \(-penetration.deepest * 1000) mm)")
        var worstRigid: Float = 0, islands = 0
        for island in shell.rigidIslands {
            islands += 1
            let tri = h.shirt.triangles[render.triangle[island.lowerBound]]
            let now = ClothHarness.frame(meshParticles[tri[0]], meshParticles[tri[1]], meshParticles[tri[2]])
            let bind = ClothHarness.frame(restParticles[tri[0]], restParticles[tri[1]], restParticles[tri[2]])
            let rotation = simd_float3x3(now.e1, now.n, now.t) * simd_float3x3(bind.e1, bind.n, bind.t).transpose
            let vertices = Array(island)
            let restCentroid = vertices.reduce(SIMD3<Float>.zero) { $0 + rest[$1] } / Float(vertices.count)
            let nowCentroid = vertices.reduce(SIMD3<Float>.zero) { $0 + h.body.positions[slot[$1]!] } / Float(vertices.count)
            for v in vertices {
                let carried = nowCentroid + rotation * (rest[v] - restCentroid)
                worstRigid = max(worstRigid, simd_distance(carried, h.body.positions[slot[v]!]))
            }
        }
        print(String(format: "cloth hang 2 s: chest and back sag up to %.4f m at rest (%.2f,%.2f,%.2f), mean sag by region %@, worst excess %+.4f m; %d pins within %.5f m; farthest behind the skin %.2f mm; %d rigid islands carried by their triangles within %.5f m; %@",
                     sag, sagAt.x, sagAt.y, sagAt.z, means, excess, pins, pinned, inward * 1000, islands, worstRigid, h.cloth.report))
        // Solved to rest lengths (four iterations), the chest falls only as
        // far as the fabric between it and the yoke allows, 9 mm; two
        // under-converged iterations stretched it past a centimetre.
        XCTAssertGreaterThanOrEqual(sag, bounds.sag, "the chest and the back sag only \(sag) m: the shirt does not hang")
        XCTAssertGreaterThan(mean(0.12), mean(0.07) + bounds.hemOverYoke, "the hem band sags \(mean(0.12)) m on average against the yoke's \(mean(0.07)): the sag does not grow down the shirt")
        XCTAssertLessThan(excess, bounds.excess, "a chest or back particle strayed \(excess) m past its slack")
        XCTAssertLessThan(pinned, bounds.pins, "a collar or cuff particle is \(pinned) m off the skin")
        XCTAssertGreaterThan(clearance, bounds.clearance, "particle \(clearanceAt) sits \(clearance) m from the surface under the shirt: into the skin")
        XCTAssertLessThan(inward, bounds.inward, "a particle sits \(inward) m behind its skinned position along the skin's normal")
        XCTAssertEqual(islands, 21, "seven buttons and fourteen bits of thread")
        XCTAssertLessThan(worstRigid, bounds.rigid, "a button or a bit is \(worstRigid) m off where its triangle's rotation carries it")
        // The drape figure (`ClothMetrics.Drape`, design section 6): the hem
        // band's folds as a number beside the owner's read, printed for both
        // solvers and either proxy, pinned once the gate-2 verdict is in.
        let drape = try XCTUnwrap(ClothMetrics.drape(of: h), "the hem band or the hem loop could not be read")
        XCTAssertGreaterThan(drape.bandEdges, 100, "the hem band has \(drape.bandEdges) interior edges")
        XCTAssertTrue(drape.curvature.isFinite && drape.loopLength > 0.5, "the drape figure is not a number: \(drape)")
        let restDrape = ClothMetrics.restDrape(of: h)
        print("cloth drape, hang 2 s, \(h.sidecarName) (\(h.shirt.particles.count) particles, \(h.cloth.activeSolver.map { "\($0)" } ?? "no solver")): \(drape); \(restDrape.map { drape.against($0) } ?? "no rest figure")")

        control.frames(200)
        let cp = control.particles, ct = control.targets
        var controlSag: Float = -1
        // The chest, the back and the buttoned front (the schedule's 0.09,
        // 0.10 and 0.005; until 2026-11-02 the filter read 0.08, which no
        // region has, so the control saw the back alone and a hull pushing
        // the chest or the placket at rest would have passed unseen).
        var controlRegion = ""
        for index in cp.indices where [Float(0.09), 0.10, 0.005].contains(control.shirt.maxDistance[index]) {
            let drop = ct[index].y - cp[index].y
            if drop > controlSag { controlSag = drop; controlRegion = ClothMetrics.regionName(slack: control.shirt.maxDistance[index]) }
        }
        print(String(format: "cloth hang 2 s without gravity: chest, back and placket sag up to %.4f m (%@); %@", controlSag, controlRegion, control.cloth.report))
        XCTAssertLessThan(controlSag, bounds.controlSag, "without gravity the chest, the back or the placket (\(controlRegion)) sags \(controlSag) m: the sag above is not gravity's")
    }

    /// The idle (`testAnIdleShirtStaysWithinItsSlackAndThePinsOnTheSkin`):
    /// two seconds on the bind pose over the powered ragdoll, the parts'
    /// rest errors held to their figures and the cuffs to the hands'.
    static func idle(_ h: ClothHarness, bounds fit: ClothFitBounds.Idle) throws {
        h.frames(200)
        let excess = h.excess()
        XCTAssertTrue(excess.finite)
        XCTAssertLessThan(excess.free, fit.excess, "a particle strayed \(excess.free) m past its slack")
        XCTAssertLessThan(excess.pins, fit.pins, "a pin is \(excess.pins) m off the skin")
        XCTAssertEqual(h.cloth.skinMultiplier, 1, "the ramp is over")
        // The parts' rest errors, and the cuffs (the sleeves' last 8 cm, by
        // their rest position: the wrists hang at |x| 0.48) against the hands'.
        let errors = Dictionary(uniqueKeysWithValues: h.physics.trackingErrors(jointModelTransforms: h.body.pose, entityWorld: h.body.world).map { ($0.part, $0.distance) })
        let bounds: [(prefix: String, bound: Float)] = [("pelvis", 0.001), ("spine", 0.01), ("neck", 0.02), ("head", 0.03), ("clavicle", 0.02), ("upperarm", 0.02),
                                                         ("lowerarm", 0.02), ("hand", 0.04), ("thigh", 0.005), ("calf", 0.005), ("foot", 0.005)]
        for (part, error) in errors.sorted(by: { $0.key < $1.key }) {
            let bound = try XCTUnwrap(bounds.first { part.hasPrefix($0.prefix) }?.bound, part)
            XCTAssertLessThan(error, bound, "\(part) rests \(error) m off its joint")
        }
        let handError = max(errors["hand_l"] ?? 0, errors["hand_r"] ?? 0)
        let p = h.particles, t = h.targets
        var cuff: Float = 0, cuffAt = SIMD3<Float>.zero, cuffs = 0
        for index in p.indices where abs(h.shirt.positions[index].x) > 0.40 {
            cuffs += 1
            let d = simd_distance(p[index], t[index])
            if d > cuff { cuff = d; cuffAt = h.shirt.positions[index] }
        }
        XCTAssertGreaterThan(cuffs, 50, "the cuffs were not found")
        print(String(format: "cloth idle 2 s: cuffs' farthest particle %.3f m from its target at rest (%.2f,%.2f,%.2f), hands %.3f m off their joints; rest errors %@; %@",
                     cuff, cuffAt.x, cuffAt.y, cuffAt.z, handError, errors.sorted { $0.value > $1.value }.prefix(6).map { String(format: "%@ %.3f", $0.key, $0.value) }.joined(separator: ", "), h.cloth.report))
        XCTAssertLessThan(cuff, handError + h.cloth.configuration.vertexRadius, "a cuff particle sits \(cuff) m from its target while the hands rest \(handError) m off their joints")
    }

    /// The sway (`testASwayingBodyKeepsTheShirtWithinItsSlack`), one
    /// collision model: three seconds of the whole body swaying 10 cm side
    /// to side at 1 Hz, the excess read every tenth frame, the proxy
    /// against the posed skin at the last; `lagBound` is the ragdoll
    /// model's, whose parts lag the pose and push the cloth past its slack.
    static func sway(_ h: ClothHarness, label: String, lagBound: Bool, bounds: ClothFitBounds.Sway) throws {
        var worstFree: Float = -1, worstPins: Float = 0, worstLag: Float = 0
        var laggingPart = ""
        for frame in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            if frame % 10 == 9 {
                let excess = h.excess()
                XCTAssertTrue(excess.finite, "\(label), frame \(frame): a particle is NaN")
                worstFree = max(worstFree, excess.free)
                worstPins = max(worstPins, excess.pins)
                if let lag = h.physics.trackingError(jointModelTransforms: h.body.pose, entityWorld: h.body.world), lag.distance > worstLag {
                    worstLag = lag.distance; laggingPart = lag.part
                }
            }
        }
        let penetration = try XCTUnwrap(ClothMetrics.penetration(of: h), "\(label): the posed skin could not be built")
        print("cloth sway 3 s, \(label), at the last frame: \(penetration)")
        XCTAssertLessThanOrEqual(penetration.inside, bounds.penetration, "\(label): \(penetration.inside) particles sit more than 2 mm inside the posed skin at the end of the sway (deepest \(-penetration.deepest * 1000) mm)")
        if lagBound {
            XCTAssertLessThan(worstFree, bounds.excessOverLaggingParts, "\(label): a particle strayed \(worstFree) m past its slack while the parts lagged \(worstLag) m")
        } else {
            XCTAssertLessThan(worstFree, bounds.excess, "\(label): a particle strayed \(worstFree) m past its slack during the sway")
        }
        XCTAssertLessThan(worstPins, bounds.pins, "\(label): a pin came \(worstPins) m off the skin during the sway")
        XCTAssertEqual(h.cloth.runawayCount, 0)
        print("cloth sway 3 s, \(label): worst excess \(worstFree) m, pins \(worstPins) m, parts lag up to \(worstLag) m (\(laggingPart)); \(h.cloth.report)")
        // The drape figure at the sway's last frame (see the hang).
        if let drape = ClothMetrics.drape(of: h) {
            let restDrape = ClothMetrics.restDrape(of: h)
            print("cloth drape, sway 3 s, \(label), \(h.sidecarName) (\(h.shirt.particles.count) particles, \(h.cloth.activeSolver.map { "\($0)" } ?? "no solver")): \(drape); \(restDrape.map { drape.against($0) } ?? "no rest figure")")
        } else {
            XCTFail("\(label): the hem band or the hem loop could not be read for the drape figure")
        }
    }

    /// The re-seat (`testAPelvisJumpReseatsTheShirtOnTheNewPose`): a
    /// second on the pose, then the entity jumps half a metre in the game
    /// update and every particle is on its target, through the step after.
    static func reseat(_ h: ClothHarness) throws {
        h.frames(100)
        let before = h.cloth.hardSkinCount
        // The entity jumps half a metre in the game update, as a reset or a
        // floor snap does: the ragdoll re-seats and the shirt with it.
        h.frame {
            h.body.world = ClothFixtures.translation(SIMD3(0.5, 0, 0)) * h.body.world
        }
        XCTAssertGreaterThan(h.cloth.hardSkinCount, before, "the re-seat hard skinned the shirt")
        var worst: Float = 0
        for (p, t) in zip(h.particles, h.targets) { worst = max(worst, simd_distance(p, t)) }
        XCTAssertLessThan(worst, 1e-3, "right after the jump every particle is on its target (worst \(worst) m)")
        XCTAssertEqual(h.cloth.skinMultiplier, 0)
        // And through the step that follows, which hard skins once more.
        h.frame()
        worst = 0
        for (p, t) in zip(h.particles, h.targets) { worst = max(worst, simd_distance(p, t)) }
        XCTAssertLessThan(worst, 1e-3, "after one step every particle is still on its target (worst \(worst) m)")
        // The override moved with it: in mesh space it is still the shirt.
        var worstFromRest: Float = 0
        for (slot, index) in h.body.indices.enumerated() {
            worstFromRest = max(worstFromRest, simd_distance(h.body.positions[slot], h.body.mesh[Int(index)]))
        }
        XCTAssertLessThan(worstFromRest, 0.01, "the override stayed on the shirt (off by \(worstFromRest) m)")
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }

    /// The dent (`testAThrownBallDentsTheShirt`): a 0.2 kg ball at 5 m/s
    /// into the settled chest, the dent read as what the ball adds to the
    /// particles' distance from their targets over the next 60 frames.
    static func dent(_ h: ClothHarness, bounds: ClothFitBounds.Dent) throws {
        h.frames(100)
        // The front of the chest, left of the buttons: the particle around
        // (0.12, 1.25) with the largest z, and the ball comes down +z.
        let front = h.shirt.positions.indices
            .filter { abs(h.shirt.positions[$0].x - 0.12) < 0.03 && abs(h.shirt.positions[$0].y - 1.25) < 0.03 }
            .max { h.shirt.positions[$0].z < h.shirt.positions[$1].z }
        let aim = h.shirt.positions[try XCTUnwrap(front)]
        // The particles the ball can reach, and how far each already sat
        // from its target: the dent is what the ball adds.
        let near = h.shirt.positions.indices.filter { simd_distance(h.shirt.positions[$0], aim) < 0.08 && h.shirt.maxDistance[$0] > 0 }
        XCTAssertGreaterThan(near.count, 10)
        let before = zip(h.particles, h.targets).map { simd_distance($0, $1) }
        h.addBall(entity: 500, radius: 0.06, mass: 0.2, position: aim + SIMD3(0, 0.01, 0.6), velocity: SIMD3(0, 0, -5))
        var deepest: Float = 0
        for _ in 0 ..< 60 {
            h.frame()
            let p = h.particles, t = h.targets
            for index in near {
                deepest = max(deepest, simd_distance(p[index], t[index]) - before[index])
            }
        }
        XCTAssertGreaterThan(deepest, bounds.dent, "the ball dented the shirt by \(deepest) m")
        XCTAssertTrue(h.excess().finite)
        XCTAssertEqual(h.cloth.runawayCount, 0)
        print("cloth ball: dent \(deepest) m")
    }

    /// The sleep (`testAStillBodyPutsTheClothToSleepAndAMovingJointWakesIt`):
    /// a still body for 2.5 s puts the cloth to sleep and its body out of
    /// the solver's step, and a centimetre of joint motion wakes both.
    static func sleepAndWake(_ h: ClothHarness) throws {
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "awake, Jolt has the body")
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body for 2.5 s: asleep (\(h.cloth.report))")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "and the body is asleep in Jolt: the step skips it")
        let writes = h.body.overrideWrites, feeds = h.cloth.skinFeedCount
        XCTAssertLessThan(writes, 250, "the writes stopped before the 2.5 s were up")
        let resting = h.particles
        h.frames(50)
        XCTAssertEqual(h.body.overrideWrites, writes, "asleep, nothing is written")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "nor fed")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "nothing woke the body")
        XCTAssertEqual(h.particles, resting, "and not a particle moved")
        // A centimetre of motion wakes it.
        h.body.pose = h.pose(offset: SIMD3(0.01, 0, 0))
        h.frame()
        XCTAssertFalse(h.cloth.isAsleep)
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "awake, Jolt has the body again")
        XCTAssertEqual(h.body.overrideWrites, writes + 1, "awake, the override is written again")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds + 1, "and the skin is fed again")
        h.frames(20)
        XCTAssertEqual(h.body.overrideWrites, writes + 21)
        XCTAssertLessThan(h.excess().free, 0.005)
        print("cloth sleep: asleep after \(writes) frames; \(h.cloth.report)")
    }

    /// The creep (`testAJointCreepingUnderTheThresholdWakesTheSleepingCloth`):
    /// asleep, 0.4 mm of joint motion a frame wakes the cloth by the third
    /// frame, measured from where it fell asleep.
    static func creepWakes(_ h: ClothHarness) throws {
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body for 2.5 s: asleep (\(h.cloth.report))")
        let writes = h.body.overrideWrites
        var offset = SIMD3<Float>.zero
        var wokeAfter: Int?
        for frame in 0 ..< 30 {
            offset.x += 0.0004
            h.body.pose = h.pose(offset: offset)
            h.frame()
            if wokeAfter == nil, !h.cloth.isAsleep { wokeAfter = frame + 1 }
        }
        let woke = try XCTUnwrap(wokeAfter, "a body creeping 0.4 mm a frame never woke the cloth")
        XCTAssertLessThanOrEqual(woke, 3, "the cloth woke after \(woke) frames of 0.4 mm: 1 mm from where it fell asleep")
        XCTAssertFalse(h.cloth.isAsleep, "and stays awake while the body moves")
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "Jolt has the body again")
        XCTAssertEqual(h.body.overrideWrites, writes + 30 - (woke - 1), "the override was written from the wake on")
        XCTAssertLessThan(h.excess().free, 0.005)
        print("cloth creep: woke after \(woke) frames of 0.4 mm; \(h.cloth.report)")
    }

    /// The ball through the sleeper (`testABallThroughASleepingShirtWakesIt`):
    /// nothing but the ball touches the sleeping shirt, so only the
    /// particles can say it is no longer still, and the override follows
    /// the dent instead of freezing on the frame before it.
    static func ballWakesTheSleeper(_ h: ClothHarness) throws {
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body for 2.5 s: asleep (\(h.cloth.report))")
        let writes = h.body.overrideWrites, feeds = h.cloth.skinFeedCount
        h.frames(20)
        XCTAssertEqual(h.body.overrideWrites, writes, "asleep, nothing is written")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "the body sleeps in Jolt, on the layer the balls meet")
        let front = h.shirt.positions.indices
            .filter { abs(h.shirt.positions[$0].x - 0.12) < 0.03 && abs(h.shirt.positions[$0].y - 1.25) < 0.03 }
            .max { h.shirt.positions[$0].z < h.shirt.positions[$1].z }
        let aim = h.shirt.positions[try XCTUnwrap(front)]
        h.addBall(entity: 500, radius: 0.06, mass: 0.2, position: aim + SIMD3(0, 0.01, 0.6), velocity: SIMD3(0, 0, -5))
        var wokeAfter: Int?
        for frame in 0 ..< 60 {
            h.frame()
            if !h.cloth.isAsleep { wokeAfter = frame; break }
        }
        XCTAssertNotNil(wokeAfter, "the ball woke the sleeping shirt")
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "Jolt woke the body for the ball, and the cloth keeps it awake")
        XCTAssertGreaterThan(h.body.overrideWrites, writes, "and the override follows it again")
        // The wake is the read-back's, after the frame's step: the feed
        // resumes with the next step.
        h.frames(10)
        XCTAssertGreaterThan(h.cloth.skinFeedCount, feeds, "and the skin is fed again")
        XCTAssertTrue(h.excess().finite)
        print("cloth wake by ball: after \(wokeAfter ?? -1) frames; \(h.cloth.report)")
    }

    /// The range (`testAFarPlayerShutsTheSlackAndStopsTheReadBack`): a
    /// player five metres off shuts the slack, stops the feed, the solve and
    /// the write, and the return hard skins the shirt onto the pose.
    static func farPlayer(_ h: ClothHarness) throws {
        let pelvis = h.body.world * h.joints.bindModelTransforms[h.joints.jointPaths.firstIndex(of: "/root/pelvis")!].columns.3
        let near = SIMD3(pelvis.x, pelvis.y, pelvis.z) + SIMD3(1, 0, 0)
        let far = SIMD3(pelvis.x, pelvis.y, pelvis.z) + SIMD3(5, 0, 0)
        h.frames(100, playerPosition: near)
        XCTAssertFalse(h.cloth.isBeyondRange)
        XCTAssertEqual(h.body.clears, 0)
        h.frames(10, playerPosition: far)
        XCTAssertTrue(h.cloth.isBeyondRange)
        XCTAssertEqual(h.cloth.skinMultiplier, 0, "out of range the slack is shut")
        XCTAssertEqual(h.body.clears, 1, "and the body's own skinning shows")
        let writes = h.body.overrideWrites, feeds = h.cloth.skinFeedCount, wakes = h.cloth.joltWakeCount
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "out of range the body sleeps in Jolt")
        let resting = h.particles
        h.frames(50, playerPosition: far)
        XCTAssertEqual(h.body.overrideWrites, writes, "nothing is read back out of range")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "nor fed: a feed would wake the body")
        XCTAssertEqual(h.particles, resting, "the particles stay where the range closed on them")
        // Far and still for longer than the sleep rule asks: the cloth
        // sleeps on the joints alone (nothing is read out of range).
        XCTAssertTrue(h.cloth.isAsleep, "far and still, the cloth sleeps (\(h.cloth.report))")
        // Far and moving: awake by the rule, yet nothing fed, solved or
        // written — the return hard skins the body onto the pose.
        for _ in 0 ..< 60 {
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * h.time), 0, 0))
            h.frame(playerPosition: far)
        }
        XCTAssertFalse(h.cloth.isAsleep, "a far body that moves is awake by the rule")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "but nothing is fed out of range")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "and the body stays asleep in Jolt")
        XCTAssertEqual(h.cloth.joltWakeCount, wakes, "nothing on the inert layer woke it in Jolt either")
        XCTAssertEqual(h.body.overrideWrites, writes, "and nothing is written")
        h.body.pose = h.joints.bindModelTransforms
        // Back in range: a hard skin onto the pose, the override returns
        // and the slack opens again.
        let hardSkins = h.cloth.hardSkinCount
        h.frames(50, playerPosition: near)
        XCTAssertFalse(h.cloth.isBeyondRange)
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "back in range, Jolt has the body again")
        XCTAssertGreaterThan(h.cloth.hardSkinCount, hardSkins, "the return hard skinned the shirt")
        XCTAssertGreaterThan(h.body.overrideWrites, writes)
        XCTAssertEqual(h.cloth.skinMultiplier, 1)
        XCTAssertLessThan(h.excess().free, 0.005, "and the shirt sits within its slack of the pose")
    }

    /// The arms-forward idle (`testTheArmsForwardIdleKeepsTheArmholeNearItsTarget`),
    /// one collision model: two seconds on the chase's waiting pose, the
    /// armhole band's farthest particle, the excess, the depth behind the
    /// skin and the proxy against the posed skin, as the Jolt test prints
    /// them; returns the armhole figure and the count inside the skin for
    /// the caller's cross-model checks. `handRise` is the pose's, printed.
    static func armsForwardIdle(_ h: ClothHarness, label: String, handRise: Float, bounds: ClothFitBounds.ArmsForward) throws -> (armhole: Float, inside: Int) {
        h.frames(200)
        let p = h.particles, t = h.targets
        var worst: Float = 0, worstIndex = 0, worstArmhole: Float = 0, worstArmholeIndex = 0
        for index in p.indices {
            let d = simd_distance(p[index], t[index])
            if d > worst { worst = d; worstIndex = index }
            if h.shirt.maxDistance[index] == 0.15, d > worstArmhole { worstArmhole = d; worstArmholeIndex = index }
        }
        let worstAt = h.shirt.positions[worstIndex], worstSlack = h.shirt.maxDistance[worstIndex], armholeAt = h.shirt.positions[worstArmholeIndex]
        // Where the worst particle's target lies against the ragdoll: inside
        // a capsule, the skin itself is where the cloth cannot go.
        let rig = try XCTUnwrap(h.physics.rig)
        let partPose = rig.partWorldTransforms(jointModelTransforms: h.body.pose, entityWorld: h.body.world)
        let nearest = rig.nearestPart(to: t[worstIndex], partWorldTransforms: partPose)
        let m = partPose[nearest]
        let origin = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let rotation = simd_quatf(simd_float3x3(simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)), simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)), simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))))
        let capsule = rig.localCapsules[nearest]
        let a = origin + rotation.act(capsule.from), axis = rotation.act(capsule.to - capsule.from)
        let s = min(max(simd_dot(t[worstIndex] - a, axis) / max(simd_length_squared(axis), 1e-9), 0), 1)
        let targetDepth = simd_distance(t[worstIndex], a + axis * s) - capsule.radius
        let excess = h.excess(), worstInward = h.worstInward(), inward = worstInward.depth, inwardAt = h.shirt.positions[worstInward.index]
        // The particles farthest past their own slack, with the region's slack and
        // where they sit on the shirt: what the schedule has to cover.
        let beyond = p.indices.filter { h.shirt.maxDistance[$0] > 0 }.map { ($0, simd_distance(p[$0], t[$0]) - h.shirt.maxDistance[$0]) }
            .sorted { $0.1 > $1.1 }.prefix(6)
        print("cloth arms-forward idle, \(label): past their slack " + beyond.map { String(format: "%+.3f (slack %.3f at %.2f,%.2f,%.2f)", $0.1, h.shirt.maxDistance[$0.0], h.shirt.positions[$0.0].x, h.shirt.positions[$0.0].y, h.shirt.positions[$0.0].z) }.joined(separator: "; "))
        print(String(format: "cloth arms-forward idle, %@: hands rise %.2f m; farthest particle %.3f m from its target (slack %.3f) at rest (%.2f,%.2f,%.2f), its target %+.3f m from the %@ capsule's surface; armhole band farthest %.4f m at rest (%.2f,%.2f,%.2f); worst excess %.3f m, pins %.4f m, farthest behind the skin %.2f mm (slack %.3f, at rest (%.2f,%.2f,%.2f)); %@",
                     label, handRise, worst, worstSlack, worstAt.x, worstAt.y, worstAt.z, targetDepth, rig.partNames[nearest], worstArmhole, armholeAt.x, armholeAt.y, armholeAt.z, excess.free, excess.pins, inward * 1000,
                     h.shirt.maxDistance[worstInward.index], inwardAt.x, inwardAt.y, inwardAt.z, h.cloth.report))
        // The proxy against the body this pose skins — the surface the
        // headset draws under the shirt, where the back-stop no longer
        // stands for it.
        let penetration = try XCTUnwrap(ClothMetrics.penetration(of: h), "\(label): the posed skin could not be built")
        print("cloth arms-forward idle, \(label), \(penetration)")
        if let bound = bounds.penetration {
            XCTAssertLessThanOrEqual(penetration.inside, bound, "\(label): \(penetration.inside) particles sit more than 2 mm inside the posed skin in the arms-forward idle (deepest \(-penetration.deepest * 1000) mm)")
        }
        XCTAssertTrue(excess.finite)
        XCTAssertEqual(h.cloth.runawayCount, 0)
        // The schedule covers the armpit's stretch all but a centimetre: a
        // particle past its slack is one the clamp pulls back every pass
        // while the edges pull it out — the fight the headset showed at
        // 5.5 cm. The cloth settles farther the looser the region around
        // it (the band's farthest particle went 11.5, 13.0, 14.0, 15.5 cm
        // as the band widened and the sleeves and the yoke opened), so the
        // slack is set where that settling has all but stopped, and the
        // centimetre of touch left under the arm is below what shows.
        // With the skin's hulls the slack is a soft ceiling: a hull
        // pushes the armpit's particles 10 mm past it here (37.7 mm
        // before the clavicles had hulls of their own; 2026-11-02), and
        // Jolt's clamp pulls them back toward the target every sub-step
        // while the hull pushes them out again — the hull has the last
        // word, since the collision pass runs after the skin constraints
        // — which is accepted: the skin under the particle is where the
        // fabric must not go, the slack where it should not wander, and
        // where the two disagree the body wins by a centimetre at the
        // armpit, the readout's `excess` figure. The bound is that
        // centimetre and a half's margin, not a loosened schedule: a band
        // loosened to 16 cm would settle farther everywhere (the figures
        // above), for a centimetre the hull overrides anyway.
        XCTAssertLessThan(worstArmhole, bounds.armhole, "\(label): an armhole-band particle sits \(worstArmhole) m from its target in the arms-forward idle, at \(armholeAt) on the shirt: the band's slack does not cover the stretch")
        // The model that meets the parts is the A/B: the capsules stand outside the
        // skin at the chest and push the buttoned front 5 cm off its 5 mm, which is
        // the fight it is kept to show; the figure is printed above.
        if label != "ragdoll and skin" {
            XCTAssertLessThan(excess.free, bounds.excess, "\(label): a particle strayed \(excess.free) m past its slack in the arms-forward idle")
        }
        XCTAssertLessThan(inward, bounds.inward, "\(label): a particle sits \(inward) m behind its skinned position in the arms-forward idle")
        return (worstArmhole, penetration.inside)
    }

    /// The arm swing (`testASwingingArmKeepsTheSleeveOnItsHull`), one
    /// collision model: the left arm from the bind pose to the arms-forward
    /// idle over 30 frames and held 30 more, the proxy read against the
    /// posed skin every other frame; `bounds` nil is the skin-only control,
    /// which must show the patches the hulls are for: more than
    /// `controlInsideAtLeast` particles inside at some frame (Jolt's 50; the
    /// GPU's exact back-stop leaves a handful). Returns the per-frame
    /// readings the Jolt test prints for the world model.
    static func armSwing(_ h: ClothHarness, label: String, pose: [simd_float4x4], joints: SkeletonJointInfo, upperarm: Int, elbow: Int, bounds: ClothFitBounds.Swing?,
                         controlInsideAtLeast: Int = 50) throws
        -> [(frame: Int, inside: Int, deepest: Float, excess: Float, lift: Float, elbowSpeed: Float)]
    {
        let swing = 30, hold = 30
        let sleeves = Set<Float>([0.11, 0.15])
        var readings: [(frame: Int, inside: Int, deepest: Float, excess: Float, lift: Float, elbowSpeed: Float)] = []
        var worstInside = (count: 0, frame: 0), deepest = (depth: Float(0), frame: 0, index: 0), worstExcess = (excess: Float(-1), frame: 0)
        var worstLift = (lift: Float(0), frame: 0, index: 0), heldLift: Float = 0, heldInside = 0, maxElbowSpeed: Float = 0
        var previousElbow = SIMD3(joints.bindModelTransforms[elbow].columns.3.x, joints.bindModelTransforms[elbow].columns.3.y, joints.bindModelTransforms[elbow].columns.3.z)
        for frame in 0 ..< swing + hold {
            let t = min(Float(frame + 1) / Float(swing), 1)
            h.body.pose = try XCTUnwrap(ClothMetrics.interpolatedPose(from: joints.bindModelTransforms, to: pose, at: t, only: { $0.contains("/clavicle_l") }))
            let e = SIMD3(h.body.pose[elbow].columns.3.x, h.body.pose[elbow].columns.3.y, h.body.pose[elbow].columns.3.z)
            let elbowSpeed = simd_distance(e, previousElbow) / h.dt
            previousElbow = e
            maxElbowSpeed = max(maxElbowSpeed, elbowSpeed)
            h.frame()
            guard frame % 2 == 1 || frame == swing - 1 || frame % 10 == 9 || frame == swing + hold - 1 else { continue }
            let d = try XCTUnwrap(ClothMetrics.skinDistances(of: h), "\(label), frame \(frame): the posed skin could not be built")
            var inside = 0, frameDeepest = (depth: Float(0), index: 0), lift = (lift: Float(0), index: 0)
            for index in d.indices {
                guard let distance = d[index] else { continue }
                if distance < -0.002 { inside += 1 }
                if distance < frameDeepest.depth { frameDeepest = (distance, index) }
                if sleeves.contains(h.shirt.maxDistance[index]), distance > lift.lift { lift = (distance, index) }
            }
            let excess = h.excess()
            XCTAssertTrue(excess.finite, "\(label), frame \(frame): a particle is NaN")
            if inside > worstInside.count { worstInside = (inside, frame) }
            if frameDeepest.depth < deepest.depth { deepest = (frameDeepest.depth, frame, frameDeepest.index) }
            if excess.free > worstExcess.excess { worstExcess = (excess.free, frame) }
            if lift.lift > worstLift.lift { worstLift = (lift.lift, frame, lift.index) }
            if frame == swing + hold - 1 { heldLift = lift.lift; heldInside = inside }
            readings.append((frame, inside, frameDeepest.depth, excess.free, lift.lift, elbowSpeed))
            if frame % 5 == 4 || frame == swing - 1 || frame == swing + hold - 1 {
                print(String(format: "cloth arm swing, %@, frame %d (t %.2f, elbow %.2f m/s): %d particles more than 2 mm inside the posed skin, deepest %.1f mm at particle %d (%@), worst excess %+.1f mm, sleeves' farthest particle %.1f mm off the skin (particle %d, %@)",
                             label, frame, t, elbowSpeed, inside, -frameDeepest.depth * 1000, frameDeepest.index, ClothMetrics.regionName(slack: h.shirt.maxDistance[frameDeepest.index]), excess.free * 1000,
                             lift.lift * 1000, lift.index, ClothMetrics.regionName(slack: h.shirt.maxDistance[lift.index])))
            }
        }
        let upperarmSwing = acos(min(max(simd_dot(simd_normalize(SIMD3(joints.bindModelTransforms[upperarm].columns.1.x, joints.bindModelTransforms[upperarm].columns.1.y, joints.bindModelTransforms[upperarm].columns.1.z)),
                                                  simd_normalize(SIMD3(pose[upperarm].columns.1.x, pose[upperarm].columns.1.y, pose[upperarm].columns.1.z))), -1), 1)) * 180 / .pi
        print(String(format: "cloth arm swing, %@: the upper arm swings %.0f degrees over %d frames, the elbow up to %.2f m/s; most inside %d at frame %d, deepest %.1f mm at frame %d (particle %d, %@, at rest (%.2f,%.2f,%.2f)), worst excess %+.1f mm at frame %d, sleeves lifted up to %.1f mm off the skin at frame %d (particle %d) and %.1f mm once held, %d inside once held; %@",
                     label, upperarmSwing, swing, maxElbowSpeed, worstInside.count, worstInside.frame, -deepest.depth * 1000, deepest.frame, deepest.index, ClothMetrics.regionName(slack: h.shirt.maxDistance[deepest.index]),
                     h.shirt.positions[deepest.index].x, h.shirt.positions[deepest.index].y, h.shirt.positions[deepest.index].z, worstExcess.excess * 1000, worstExcess.frame, worstLift.lift * 1000, worstLift.frame, worstLift.index, heldLift * 1000, heldInside, h.cloth.report))
        XCTAssertEqual(h.cloth.runawayCount, 0)
        if let bounds {
            XCTAssertLessThanOrEqual(worstInside.count, bounds.inside, "\(worstInside.count) particles more than 2 mm inside the posed skin while the arm swings against its hull (frame \(worstInside.frame))")
            XCTAssertGreaterThan(-deepest.depth, 0, "nothing read")
            XCTAssertLessThan(-deepest.depth, bounds.deepest, "a particle sits \(-deepest.depth) m inside the posed skin during the swing")
            XCTAssertLessThan(worstExcess.excess, bounds.excess, "a particle strayed \(worstExcess.excess) m past its slack during the swing")
            XCTAssertLessThan(worstLift.lift, bounds.lift, "the sleeves lifted \(worstLift.lift) m off the skin during the swing")
        } else {
            XCTAssertGreaterThan(worstInside.count, controlInsideAtLeast, "the skin-only control no longer shows the patches the hulls are for")
        }
        return readings
    }
}
