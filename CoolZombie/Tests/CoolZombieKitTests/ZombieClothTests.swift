//
//  ZombieClothTests.swift
//  CoolZombieKitTests
//
//  The shirt as a skinned soft body against a real Jolt world at the demo's
//  cadence (100 Hz, three sub-steps), with no engine entity: the bundled
//  sidecar's shell rest positions stand in for the mesh (one exported
//  vertex per shell vertex, with the exported normal at it; the proxy is
//  not in the export) — or the whole export where a test wants every
//  split copy — the model's own skeleton (read from the bundled .untold,
//  so the ragdoll and the skin share one bind pose) for the pose and the
//  ragdoll, and a recording body for the override.
//
//  The skin-following tests run the cloth with the powered ragdoll in
//  the world under each model: the default, `skinAndWorld`, never meets
//  the parts (the shirt's body is its skin), `ragdollAndSkin` does, for
//  the A/B — the rig's capsules are fitted to this body
//  (ZombieRagdollRig.specs), but stand centimetres outside the skin at
//  the torso, which is why they are no longer the shirt's colliders;
//  `testTheCapsuleFitOnTheDefaultModel` measures the models per region
//  and holds the default to the slack. (Sized for the old mannequin, the
//  spine capsules reached 7 cm through the back of this shirt and pushed
//  the particles there 5 cm past their slack, jittering against the skin.)
//  Where a part does not sit on the pose — the tracking motors leave the
//  forearms a centimetre and the hands three off their joints at rest, and
//  the chain lags a swaying pose by up to a decimetre — the shirt is where
//  the part puts it, and those tests hold the shirt to the parts and the
//  parts to their figures.
//  The pair the controller makes with the cloth stays closed in both
//  models; opened, a debug Jolt asserts in CharacterVirtual's collide
//  against the soft body.
//

@testable import CoolZombieKit
import simd
@testable import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class ZombieClothTests: XCTestCase {
    private let dt: Float = 0.01

    /// How many proxy particles may sit more than 2 mm inside the POSED skin
    /// — the body the animation's pose skins, which is what the headset
    /// draws under the shirt (`penetration(of:)`) — at the end of the hang,
    /// the sway and the arms-forward idle, per collision model. The headset
    /// showed skin through the sleeves and the shoulders during the
    /// animations and none at the T-pose (2026-10-31): the back-stop stands
    /// for the skin only where a particle sits near its skinned target, and
    /// with the arms raised the targets spread and a particle 15 cm from
    /// its target has a stop that is not the arm under it. The skin's
    /// colliders (`ZombieClothAsset.colliders`, eleven kinematic hulls on the
    /// joints) are the answer, and the skin-only model, which builds none,
    /// is the control: it reads what the back-stop alone leaves, 163
    /// particles inside in the arms-forward idle — armhole band 124, sleeves
    /// 28, yoke 11 — the deepest 34.7 mm into the upper arm (the same figure
    /// without the hulls on every model), 0 in the hang and the sway. The
    /// bounds are the measurement WITH the hulls (the cook of 2026-11-02:
    /// eleven hulls with the bend inset and the garment margin, the cloth at
    /// 1e-2 stretch, 2e-2 shear, 0.3 bend compliance, 3 mm particles) and a
    /// few particles of margin — the simulation is deterministic and every
    /// run prints the same count: the hang 0; the sway 0 on the skin alone
    /// and meeting the world, 2 over the ragdoll (the lagging forearm part
    /// pushes two cuff particles 3 mm into the posed skin, as that test
    /// documents); the arms-forward idle 65 meeting the world (yoke 1,
    /// sleeves 4, armhole band 60; the deepest 19.8 mm at particle 1142, at
    /// rest (-0.20,1.27,-0.10), the front of the right armpit) and 66 over
    /// the ragdoll (4 and 62, 19.6 mm), the skin alone 154 — the cuff roll
    /// pinned whole (2026-11-03) took the sleeves' share from 18 to 4. What the hulls leave is where no hull
    /// rigid on its bone can follow the skin: the armpits and the shoulder
    /// caps, 68 degrees of swing on blended skin, and the armpit's hollow
    /// in particular, which the upper arm's hull may not fill — filled, it
    /// stood 11 mm through the resting shirt and pushed it off the body
    /// before the arm had moved (the cook before the garment margin read
    /// 61 here, sleeves 6, and 3.2 mm of push at the back without gravity).
    /// The arms themselves are clear. Held to the measurement and a few
    /// particles; and the hulls must take at least two fifths of the
    /// control's count away (they take well over half).
    private let hangPenetrationBound = 0
    private let swayPenetrationBound: [String: Int] = ["skin only": 0, "world": 0, "ragdoll and skin": 4]
    /// Per model; the skin-only run is the control, held above the world's.
    private let armsForwardPenetrationBound: [String: Int] = ["world": 90, "ragdoll and skin": 90]

    private func makeHarness(configuration: ZombieCloth.Configuration = ZombieCloth.Configuration(), world: simd_float4x4 = ClothFixtures.standing,
                             ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil, normals: [SIMD3<Float>]? = nil,
                             pose: [simd_float4x4]? = nil, collisionSteps: Int32 = 3, gravity: SIMD3<Float> = SIMD3(0, -9.8, 0)) throws -> ClothHarness
    {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let harness = ClothHarness(dt: dt, asset: asset, joints: joints, configuration: configuration, world: world, ragdoll: ragdoll, obstacles: obstacles, mesh: mesh,
                                   normals: normals, pose: pose, collisionSteps: collisionSteps, gravity: gravity)
        XCTAssertTrue(harness.attached, "the shirt attached")
        return harness
    }

    /// The cloth on its skin alone, no collisions: the skin mechanism by itself.
    private var skinOnly: ZombieCloth.Configuration {
        var configuration = ZombieCloth.Configuration()
        configuration.collisionModel = .skinOnly
        return configuration
    }

    /// The cloth meeting the ragdoll's parts too (the A/B model).
    private var ragdollAndSkin: ZombieCloth.Configuration {
        var configuration = ZombieCloth.Configuration()
        configuration.collisionModel = .ragdollAndSkin
        return configuration
    }

    // MARK: - Binding and the override

    /// The override covers the shell's exported vertices — one per shell
    /// vertex in this mesh, 29,402 of them, not the proxy's 3,995 — and what
    /// it writes is the shell evaluated from the particles by the sidecar's
    /// binding, not the particles themselves: back in the world each vertex
    /// is its triangle's barycentric point plus its rest offset in the
    /// triangle's frame (the inner layer a millimetre behind the proxy, the
    /// buttons a centimetre in front), and its normal the vertex's own
    /// exported normal turned with the frame, unit.
    func testAttachBindsTheShellAndWritesAnOverrideCoveringIt() throws {
        let h = try makeHarness(configuration: skinOnly)
        let render = try XCTUnwrap(h.shirt.render, "the shirt has a render binding")
        XCTAssertEqual(h.cloth.garmentNames, ["shirt"])
        XCTAssertEqual(h.body.begins, 1, "the body moved to compute skinning once")
        XCTAssertEqual(h.cloth.hardSkinCount, 1, "the attach hard skinned")
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20 + 1, "the floor slab, twenty parts and the shirt")
        h.frame()
        XCTAssertEqual(h.body.overrideWrites, 1)
        XCTAssertEqual(h.body.indices.count, render.vertexCount, "one exported vertex per shell vertex in this mesh")
        XCTAssertNotEqual(h.body.indices.count, h.shirt.particles.count, "the proxy is not what is drawn")
        XCTAssertEqual(Set(h.body.indices), Set(0 ..< UInt32(render.vertexCount)), "every shell vertex drives its vertex")
        XCTAssertEqual(h.body.positions.count, h.body.indices.count)
        XCTAssertEqual(h.body.normals.count, h.body.indices.count)
        let expected = h.shell(from: h.particles)
        let mesh = h.body.mesh, offsets = render.offsetVectors
        var worstBack: Float = 0, worstFromRest: Float = 0, worstNormal: Float = 0, worstNormalAngle: Float = 0, offsetSeen: Float = 0
        for (slot, index) in h.body.indices.enumerated() {
            let p = h.body.positions[slot], n = h.body.normals[slot]
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, "override position \(slot) is a number")
            let world = h.body.world * SIMD4(p, 1)
            worstBack = max(worstBack, simd_distance(SIMD3(world.x, world.y, world.z), expected.positions[Int(index)]))
            worstFromRest = max(worstFromRest, simd_distance(p, mesh[Int(index)]))
            worstNormal = max(worstNormal, abs(simd_length(n) - 1))
            let rotation = simd_float3x3(SIMD3(h.body.world.columns.0.x, h.body.world.columns.0.y, h.body.world.columns.0.z),
                                         SIMD3(h.body.world.columns.1.x, h.body.world.columns.1.y, h.body.world.columns.1.z),
                                         SIMD3(h.body.world.columns.2.x, h.body.world.columns.2.y, h.body.world.columns.2.z))
            worstNormalAngle = max(worstNormalAngle, acos(min(1, simd_dot(simd_normalize(rotation * n), simd_normalize(expected.normals[Int(index)])))) * 180 / .pi)
            offsetSeen = max(offsetSeen, simd_length(offsets[Int(index)]))
        }
        XCTAssertLessThan(worstBack, 1e-4, "the override is the shell evaluated from the particles (off by \(worstBack) m)")
        XCTAssertLessThan(worstNormalAngle, 0.5, "and its normals are the binding's (off by \(worstNormalAngle) degrees)")
        XCTAssertGreaterThan(offsetSeen, 0.005, "the shell has vertices off the proxy (the inner layer, the buttons): the binding is not the particles")
        XCTAssertLessThan(worstFromRest, 0.05, "on the bind pose the shirt is where the artist put it (off by \(worstFromRest) m)")
        XCTAssertLessThan(worstNormal, 1e-3, "unit normals")
        let excess = h.excess()
        XCTAssertTrue(excess.finite, "no particle is NaN")
        print("cloth attach: \(h.cloth.report)")
    }

    /// At the bind pose the shell evaluates to the exported mesh itself. With
    /// the whole export as the body (71k vertices, the shell's among them),
    /// every exported vertex the cloth drives comes back at its exported
    /// position within a tenth of a millimetre and with its own exported
    /// normal within a tenth of a degree — the copies the exporter split on
    /// the artist's sharp edges included, which share a position and differ
    /// in normal by 5° to 180° (179.9° at the widest, a cuff roll; a
    /// thousand of them: the cuff rolls, the placket's edge, the collar's
    /// creases), so the cloth on draws the creases the cloth off draws; the
    /// sidecar's one normal per shell vertex lit them flat (2026-10-31).
    /// Then one frame, hard skinned on the bind pose: the override written
    /// is that mesh within a millimetre.
    func testAtTheBindPoseTheShellIsTheExportedMeshSplitCopiesIncluded() throws {
        guard let exported = ClothFixtures.exported else { throw XCTSkip("Models/Zombie is not bundled") }
        let h = try makeHarness(configuration: skinOnly, mesh: exported.positions, normals: exported.normals)
        let render = try XCTUnwrap(h.shirt.render)
        let shell = try XCTUnwrap(h.cloth.renderShell(ofGarment: 0))
        h.frame()
        let indices = h.body.indices.map { Int($0) }
        XCTAssertEqual(indices.count, shell.slotCount)
        XCTAssertGreaterThan(indices.count, render.vertexCount, "the exporter split some shell vertices into copies")
        XCTAssertLessThan(indices.count, exported.positions.count, "the override covers the shell, not the body")
        func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
        }
        var worstWritten: Float = 0, worstWrittenNormal: Float = 0
        for (slot, index) in indices.enumerated() {
            worstWritten = max(worstWritten, simd_distance(h.body.positions[slot], exported.positions[index]))
            worstWrittenNormal = max(worstWrittenNormal, angle(h.body.normals[slot], exported.normals[index]))
        }
        shell.evaluate(particles: h.shirt.positions)
        var worstPosition: Float = 0, worstNormal: Float = 0
        for (slot, index) in indices.enumerated() {
            worstPosition = max(worstPosition, simd_distance(shell.positions[slot], exported.positions[index]))
            worstNormal = max(worstNormal, angle(shell.normals[slot], exported.normals[index]))
        }
        // The split copies: driven vertices that share a position with another
        // and point another way.
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for index in indices {
            let p = exported.positions[index]
            grid[SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down))), default: []].append(index)
        }
        var split = 0, widest: Float = 0, widestAt = SIMD3<Float>.zero
        for index in indices {
            let p = exported.positions[index]
            let k = SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down)))
            var apart: Float = 0
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                for other in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where other != index && simd_distance(exported.positions[other], p) <= ZombieCloth.bindTolerance {
                    apart = max(apart, angle(exported.normals[other], exported.normals[index]))
                }
            } } }
            if apart > 5 { split += 1; if apart > widest { widest = apart; widestAt = p } }
        }
        print(String(format: "cloth at the bind pose: %d exported shell vertices driven for %d shell vertices, %d of them split copies with normals up to %.1f° apart (the widest pair at (%.2f,%.2f,%.2f)); the shell evaluates to the export within %.4f mm and %.3f°, the first frame's override within %.3f mm and %.2f°",
                     indices.count, render.vertexCount, split, widest, widestAt.x, widestAt.y, widestAt.z, worstPosition * 1000, worstNormal, worstWritten * 1000, worstWrittenNormal))
        XCTAssertGreaterThan(split, 1000, "the sharp edges' split copies were not found")
        XCTAssertLessThan(worstPosition, 1e-4, "a driven vertex evaluates \(worstPosition) m off its exported position at the bind pose")
        XCTAssertLessThan(worstNormal, 0.1, "a driven vertex's normal evaluates \(worstNormal)° off its exported normal at the bind pose")
        XCTAssertLessThan(worstWritten, 1e-3, "the first frame's override is \(worstWritten) m off the export")
        XCTAssertLessThan(worstWrittenNormal, 1, "the first frame's normals are \(worstWrittenNormal)° off the export")
    }

    /// The shell sits with the proxy: every shell vertex, rebuilt from the
    /// simulated particles, lies within its triangle's slack of where it
    /// would be rebuilt from the skinned targets — the particles stray no
    /// farther than their slack, the frame turns the rest offset by at most
    /// twice its length — on the idle, two seconds in.
    func testTheIdleShellSitsWithinSlackAndOffsetOfItsSkinnedTargets() throws {
        let h = try makeHarness()
        h.frames(200)
        let render = try XCTUnwrap(h.shirt.render)
        let fromParticles = h.shell(from: h.particles), fromTargets = h.shell(from: h.targets)
        let offsets = render.offsetVectors
        var worst: Float = 0, worstMargin: Float = 0, worstAt = 0
        for v in 0 ..< render.vertexCount {
            let t = h.shirt.triangles[render.triangle[v]]
            let slack = t.map { h.shirt.maxDistance[$0] }.max()!
            let d = simd_distance(fromParticles.positions[v], fromTargets.positions[v])
            let margin = d - (slack + 2 * simd_length(offsets[v]) + 0.005)
            if margin > worstMargin { worstMargin = margin; worstAt = v }
            worst = max(worst, d)
        }
        print(String(format: "cloth shell on the idle: farthest shell vertex %.3f m from its skinned rebuild; worst over slack + offset %+.4f m at shell vertex %d", worst, worstMargin, worstAt))
        XCTAssertLessThanOrEqual(worstMargin, 0, "shell vertex \(worstAt) sits \(worstMargin) m beyond its triangle's slack and its offset")
    }

    /// The slack schedule hangs the shirt from its shoulders instead of
    /// pasting it on as a second skin: the collar band and the cuffs are
    /// hard skinned, the yoke held to 7 cm, the chest 9 cm, the back
    /// 10, the hem band 12. After two seconds of gravity on the idle the
    /// chest and the back sag below their skinned targets by a centimetre
    /// or more somewhere, the sag grows down the shirt — the hem band's
    /// mean sag is more than the yoke's, which is held to its centimetre —
    /// and it is gravity's: the same two seconds without gravity sag under
    /// two millimetres (the control). Everything stays within its slack, the
    /// collar band and the cuffs stay on the skin, and the proxy stays off
    /// the body kept under the shirt: no particle with a back-stop comes
    /// within a millimetre of the surface under the shirt — the body, the
    /// trousers and the shoes of the export, which stands in this bind pose
    /// — where the push-out left the proxy 2 mm off it at rest (2.0 mm
    /// after the two seconds, at a sleeve particle over the forearm; the
    /// stop starts 1 mm behind the skinned position, so a millimetre is
    /// what it promises). How far a particle sits behind its skinned
    /// position along the skin's normal, which is what Jolt's stop
    /// measures, is printed and bounded at 5 mm rather than the stop's one:
    /// Jolt applies the stop before the edge constraints in every
    /// iteration, so the edges have the last word, and the plane through
    /// the target is not the curved forearm — at the right cuff, where the
    /// hand part rests 3 cm off its joint and pushes the sleeve above the
    /// pinned cuff band, a particle 3.4 mm off the body reads 3.1 mm behind
    /// its target (2026-10-31). And the buttons stay rigid: every vertex of one
    /// rides the single proxy triangle nearest its centre, so the island
    /// turns as that triangle's frame turns, which the test takes from the
    /// particles itself and applies to the island's rest shape: within a
    /// tenth of a millimetre of what the game wrote. The sag's bound sits
    /// half a millimetre under the measured 1.05 cm, and that is a margin
    /// only because the harness is deterministic: a fixed 10 ms step from
    /// the bind pose with nothing random in it, the same calls in the same
    /// order on one build, which is Jolt's condition for the same result
    /// (`Docs/Architecture.md`, deterministic simulation), and every suite
    /// prints the same figures to the last digit (0.0105 m, 3.14 mm and
    /// 2.04 mm in each of the runs of 2026-10-31); the sag is printed to a
    /// tenth of a millimetre so the margin can be read off the log. The
    /// posed-skin metric (`penetration(of:)`) reads the same surface signed
    /// and every particle, the pins and the body-facing ones too: at the
    /// bind pose no particle is more than 2 mm inside the skin, with or
    /// without the skin colliders (3,631 of the 3,995 have skin within 5 cm
    /// to read against; the hem hangs over the culled skin under the
    /// trousers and the loose back stands off it; 2026-11-02); held to
    /// `hangPenetrationBound`, none.
    func testTheShirtHangsFromTheShouldersAndTheButtonsStayRigid() throws {
        var bounds = ClothFitBounds.jolt.hang
        bounds.penetration = hangPenetrationBound
        let h = try makeHarness()
        let control = try makeHarness(gravity: .zero)
        try ClothFitScenarios.hang(h, control: control, bounds: bounds)
    }

    /// A shell vertex off the mesh by a millimetre, a joint the skeleton
    /// lacks: nothing is built, nothing is written, the body is left as it was.
    func testAStaleSidecarLeavesTheGarmentBodySkinned() throws {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        var mesh = asset.garment(named: "shirt")!.render!.restPositionVectors
        mesh[7].y += 0.001
        let moved = ClothHarness(dt: dt, asset: asset, joints: joints, mesh: mesh)
        XCTAssertFalse(moved.attached, "a shell vertex on no exported vertex refuses the garment")
        XCTAssertFalse(moved.cloth.isAttached)
        XCTAssertEqual(moved.body.begins, 0, "the body was not moved to compute skinning")
        XCTAssertEqual(moved.physics.backend.bodyCount, 1 + 20, "no soft body was added")
        moved.frame()
        XCTAssertEqual(moved.body.overrideWrites, 0)
        XCTAssertEqual(moved.cloth.report, "cloth: none")

        let lacking = SkeletonJointInfo(
            jointPaths: joints.jointPaths.map { $0 == "/root/pelvis/spine_01/spine_02/spine_03/neck_01" ? "/root/pelvis/spine_01/spine_02/spine_03/neck" : $0 },
            parentIndices: joints.parentIndices, bindModelTransforms: joints.bindModelTransforms
        )
        let missing = ClothHarness(dt: dt, asset: asset, joints: lacking, ragdoll: false)
        XCTAssertFalse(missing.attached, "a joint the skeleton lacks refuses the garment")
        XCTAssertEqual(missing.physics.backend.bodyCount, 1)

        var off = ZombieCloth.Configuration()
        off.enabled = false
        let disabled = ClothHarness(dt: dt, asset: asset, joints: joints, configuration: off, ragdoll: false)
        XCTAssertFalse(disabled.attached)
        XCTAssertEqual(disabled.body.begins, 0)
    }

    /// The binding passed but the body did not take the deformation
    /// component the override is written to: the soft body comes out again
    /// and nothing is written — the one failure the engine's write hides.
    func testABodyThatDoesNotTakeTheOverrideLeavesTheGarmentBodySkinned() throws {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let refused = ClothHarness(dt: dt, asset: asset, joints: joints, ragdoll: false, acceptsOverride: false)
        XCTAssertFalse(refused.attached, "a body without the component refuses the garment")
        XCTAssertFalse(refused.cloth.isAttached)
        XCTAssertEqual(refused.body.begins, 1, "the body was asked once")
        XCTAssertEqual(refused.physics.backend.bodyCount, 1, "the soft body was removed again")
        refused.frame()
        XCTAssertEqual(refused.body.overrideWrites, 0)
        XCTAssertEqual(refused.cloth.report, "cloth: none")
    }

    /// Detached, the body is as it was before the cloth: the soft body out
    /// of the world, the hooks off, the override cleared and the body back
    /// on its own skinning — the compute path was the override's price, and
    /// the pickers' Off reads that price against the frame.
    func testDetachReturnsTheBodyToItsOwnSkinning() throws {
        let h = try makeHarness(configuration: skinOnly)
        h.frames(5)
        let writes = h.body.overrideWrites, feeds = h.cloth.skinFeedCount
        XCTAssertEqual(h.body.begins, 1)
        XCTAssertEqual(h.body.ends, 0)
        h.cloth.detach()
        XCTAssertFalse(h.cloth.isAttached)
        XCTAssertEqual(h.cloth.report, "cloth: none")
        XCTAssertEqual(h.body.clears, 1, "the override is cleared")
        XCTAssertEqual(h.body.ends, 1, "and the body is back on its own skinning")
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20, "the soft body is out of the world")
        h.frames(5)
        XCTAssertEqual(h.body.overrideWrites, writes, "nothing is written after the detach")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "and the step no longer feeds the skin")
    }

    // MARK: - Following the skin

    /// On the default model: the fitted capsules under the shirt leave it on
    /// its skin — except at the cuffs, which sit where the forearm part puts
    /// them. The tracking motors (60 Hz springs; ZombiePhysics) hold the
    /// powered chain a little off the animation even at rest, each joint a
    /// fraction of a degree to a degree and a half of swing, adding up along
    /// the chain: after two seconds on the bind pose the spine's top link is
    /// 6 mm off its joint, the head 2.3 cm, the forearms 1.5 cm and the hands
    /// 3.2 cm (2026-10-30; twice the motor frequency quarters it, a torque
    /// limit sixteen times higher changes nothing, so it is the springs'
    /// stiffness and not a cone or a limit — the swing errors are nowhere
    /// near one). The forearm's capsule ends at the wrist, so the cuff is
    /// pushed by the hand part's displacement: the cuffs' farthest particle
    /// from its target is held to that plus the particle's radius, and the
    /// rest errors are pinned per part, so a drive that drifts shows here
    /// rather than as a slack widened in the asset (the cuffs' slack was
    /// opened from 1 cm to 3 cm for this: with 1 cm they sat 1.2 cm past it).
    func testAnIdleShirtStaysWithinItsSlackAndThePinsOnTheSkin() throws {
        let h = try makeHarness()
        try ClothFitScenarios.idle(h, bounds: ClothFitBounds.jolt.idle)
    }

    /// On its skin alone the swaying shirt stays within its slack; on the
    /// default model the parts under it lag the swaying pose (the forearms,
    /// which carry the sleeves to the wrist, by 5 cm; the hands, which carry
    /// nothing, by 9) and push the cloth they pass through, so there the
    /// shirt strays past its slack by about a centimetre (1.1 cm, 2026-10-30)
    /// and is held to 2 cm — a fixed figure: a bound from the parts' own lag
    /// (5 cm and the particle's radius) would have passed the mannequin-sized
    /// spine capsules, which pushed the back 5 cm past its slack. The lag is
    /// printed with the figure. At the last frame the proxy is read against
    /// the skin the swayed pose draws (`penetration(of:)`): no particle is
    /// more than 2 mm inside it on the skin alone or meeting the world (the
    /// hulls in the world), and over the ragdoll two sleeve particles are,
    /// 3.1 mm at the deepest (particle 3919, at rest (0.45,0.98,-0.07), the
    /// left cuff; three particles and 5.7 mm before the hulls), pushed by
    /// the lagging forearm part (2026-11-02); held to `swayPenetrationBound`
    /// per model.
    func testASwayingBodyKeepsTheShirtWithinItsSlack() throws {
        for (label, configuration, lagBound) in [("skin only", skinOnly, false), ("world", ZombieCloth.Configuration(), false), ("ragdoll and skin", ragdollAndSkin, true)] {
            var bounds = ClothFitBounds.jolt.sway
            bounds.penetration = swayPenetrationBound[label] ?? 0
            let h = try makeHarness(configuration: configuration)
            try ClothFitScenarios.sway(h, label: label, lagBound: lagBound, bounds: bounds)
        }
    }

    /// The headset steps its Jolt world twice per 10 ms frame
    /// (`ZombiePhysics.Configuration.collisionSteps` 2 in the visionOS
    /// host; this harness, like the Mac, runs three), and the Mac's
    /// two-sub-step measurements split a 16.7 ms frame into 8.3 ms
    /// sub-steps — past the motors' 8 ms bound — so they say what the step
    /// costs and nothing about the fit. The device's own cadence, 5 ms
    /// sub-steps at 100 Hz, on the default model: the idle shirt and the
    /// pins within the slack, the parts at rest within the idle test's
    /// bounds, and the sway within the ragdoll model's 2 cm.
    func testTheDeviceTwoSubStepsKeepTheShirtWithinItsSlack() throws {
        let idle = try makeHarness(collisionSteps: 2)
        idle.frames(200)
        let excess = idle.excess()
        XCTAssertTrue(excess.finite)
        XCTAssertLessThan(excess.free, 0.005, "two sub-steps: a particle strayed \(excess.free) m past its slack at rest")
        XCTAssertLessThan(excess.pins, 1e-3, "two sub-steps: a pin is \(excess.pins) m off the skin")
        XCTAssertEqual(idle.cloth.skinMultiplier, 1)
        let errors = idle.physics.trackingErrors(jointModelTransforms: idle.body.pose, entityWorld: idle.body.world)
        let bounds: [(prefix: String, bound: Float)] = [("pelvis", 0.001), ("spine", 0.01), ("neck", 0.02), ("head", 0.03), ("clavicle", 0.02), ("upperarm", 0.02),
                                                         ("lowerarm", 0.02), ("hand", 0.04), ("thigh", 0.005), ("calf", 0.005), ("foot", 0.005)]
        for error in errors.sorted(by: { $0.part < $1.part }) {
            let bound = try XCTUnwrap(bounds.first { error.part.hasPrefix($0.prefix) }?.bound, error.part)
            XCTAssertLessThan(error.distance, bound, "two sub-steps: \(error.part) rests \(error.distance) m off its joint")
        }
        print("cloth idle 2 s, two sub-steps: worst excess \(excess.free) m, pins \(excess.pins) m; rest errors "
            + errors.sorted { $0.distance > $1.distance }.prefix(4).map { String(format: "%@ %.3f", $0.part, $0.distance) }.joined(separator: ", ")
            + "; \(idle.cloth.report)")

        let sway = try makeHarness(collisionSteps: 2)
        var worstFree: Float = -1, worstPins: Float = 0, worstLag: Float = 0
        var laggingPart = ""
        for frame in 0 ..< 300 {
            let t = sway.time + sway.dt
            sway.body.pose = sway.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            sway.frame()
            if frame % 10 == 9 {
                let excess = sway.excess()
                XCTAssertTrue(excess.finite, "two sub-steps, frame \(frame): a particle is NaN")
                worstFree = max(worstFree, excess.free)
                worstPins = max(worstPins, excess.pins)
                if let lag = sway.physics.trackingError(jointModelTransforms: sway.body.pose, entityWorld: sway.body.world), lag.distance > worstLag {
                    worstLag = lag.distance; laggingPart = lag.part
                }
            }
        }
        XCTAssertLessThan(worstFree, 0.02, "two sub-steps: a particle strayed \(worstFree) m past its slack while the parts lagged \(worstLag) m")
        XCTAssertLessThan(worstPins, 1e-3, "two sub-steps: a pin came \(worstPins) m off the skin during the sway")
        XCTAssertEqual(sway.cloth.runawayCount, 0)
        print("cloth sway 3 s, two sub-steps: worst excess \(worstFree) m, pins \(worstPins) m, parts lag up to \(worstLag) m (\(laggingPart)); \(sway.cloth.report)")
    }

    func testAPelvisJumpReseatsTheShirtOnTheNewPose() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.reseat(h)
    }

    // MARK: - Layers

    /// A patch of cloth on the cloth layer over the sandbox's wall (a room
    /// box): standing, it falls through onto the floor slab; down, it lands
    /// on the wall. A real collapse flips the state and a stand-up flips it
    /// back, and the shirt hard skins on the stand-up.
    func testCollapseOpensTheRoomToTheClothAndStandUpReseatsIt() throws {
        let wall = NavObstacle(center: simd_float3(3, 0.75, 3), size: simd_float3(3.2, 1.5, 0.2))
        let h = try makeHarness(configuration: skinOnly, obstacles: [wall])
        func patch() -> JoltSoftBodyDescriptor {
            var descriptor = JoltSoftBodyDescriptor(
                vertices: [SIMD3(0, 0, 0), SIMD3(0.05, 0, 0), SIMD3(0, 0, 0.05), SIMD3(0.05, 0, 0.05)],
                inverseMasses: [100, 100, 100, 100], faces: [SIMD3(0, 2, 1), SIMD3(1, 2, 3)],
                compliance: 1e-6, shearCompliance: 1e-5, bendCompliance: 1e-3
            )
            descriptor.position = SIMD3(3, 2.0, 3)
            descriptor.layer = h.physics.configuration.clothLayer
            descriptor.vertexRadius = 0.01
            descriptor.allowSleeping = false
            return descriptor
        }
        func lowest(_ body: JoltSoftBody) -> Float {
            var p: [SIMD3<Float>] = []
            h.physics.backend.readSoftBodyVertices(body, into: &p)
            return p.map(\.y).min() ?? .nan
        }
        let standing = try XCTUnwrap(h.physics.backend.addSoftBody(patch()))
        h.frames(200)
        XCTAssertFalse(h.physics.isDown)
        XCTAssertEqual(lowest(standing), 0.01, accuracy: 0.03, "standing, the patch fell through the wall onto the floor")
        h.physics.backend.removeSoftBody(standing)

        // A hard hit: the body lets go and lies on the furniture.
        h.physics.collapse(along: SIMD3(0, 0, 1))
        XCTAssertTrue(h.physics.isDown)
        let fallen = try XCTUnwrap(h.physics.backend.addSoftBody(patch()))
        for _ in 0 ..< 200 {
            h.physics.backend.step(deltaTime: dt)
            h.cloth.readBack(deltaTime: dt, playerPosition: nil)
        }
        XCTAssertEqual(lowest(fallen), 1.51, accuracy: 0.03, "down, the patch landed on the wall")
        XCTAssertTrue(h.excess().finite, "the shirt rode the fall")
        h.physics.backend.removeSoftBody(fallen)

        // Back up: the matrix stands with it and the shirt is re-seated.
        let hardSkins = h.cloth.hardSkinCount
        h.physics.standUp(jointModelTransforms: h.body.pose, entityWorld: h.body.world)
        XCTAssertFalse(h.physics.isDown)
        XCTAssertGreaterThan(h.cloth.hardSkinCount, hardSkins, "the stand-up hard skinned the shirt")
        h.frame()
        var worst: Float = 0
        for (p, t) in zip(h.particles, h.targets) { worst = max(worst, simd_distance(p, t)) }
        XCTAssertLessThan(worst, 1e-3, "on the pose again (worst \(worst) m)")
        let risen = try XCTUnwrap(h.physics.backend.addSoftBody(patch()))
        h.frames(200)
        XCTAssertEqual(lowest(risen), 0.01, accuracy: 0.03, "standing again, the patch falls through the wall")
    }

    /// The controller is the body's own and stands inside the shirt; moved
    /// through it, back and forth, it leaves the particles alone (the matrix
    /// test in ZombiePhysicsTests pins the pair closed; opened, a debug Jolt
    /// asserts in CharacterVirtual against the soft body, so the pair is
    /// never opened here either). No ragdoll in this world, so nothing else
    /// moves the particles.
    func testTheCharacterControllerWalksThroughTheShirt() throws {
        let h = try makeHarness(world: matrix_identity_float4x4, ragdoll: false)
        h.frames(150)
        let settled = h.particles
        // The controller walks in from a metre to the side, through the
        // torso and out the other side, 1 m/s, then back.
        h.physics.attachCharacter(entity: 1, at: SIMD3(-1.0, 0, -0.14))
        XCTAssertTrue(h.physics.hasCharacter)
        var position = SIMD3<Float>(-1.0, 0, -0.14)
        for frame in 0 ..< 400 {
            let direction: Float = frame < 200 ? 1 : -1
            position = h.physics.resolve(target: position + SIMD3(direction * 0.01, 0, 0), deltaTime: dt)
            h.frame()
        }
        XCTAssertEqual(position.x, -1.0, accuracy: 0.02, "the controller went through and came back")
        let after = h.particles
        var worst: Float = 0
        for (a, b) in zip(settled, after) { worst = max(worst, simd_distance(a, b)) }
        XCTAssertTrue(h.excess().finite)
        XCTAssertLessThan(worst, 0.001, "the controller moved the shirt by \(worst) m")
        print("cloth controller sweep: particles moved \(worst) m")
    }

    /// A 0.2 kg ball at 5 m/s into the chest dents the shirt by more than
    /// 2 cm (the slack there is 3 cm).
    func testAThrownBallDentsTheShirt() throws {
        let h = try makeHarness(world: matrix_identity_float4x4)
        try ClothFitScenarios.dent(h, bounds: ClothFitBounds.jolt.dent)
    }

    // MARK: - Sleep and range

    /// The shirt dropped onto its skin by the attach takes about a second to
    /// come to rest inside its slack; half a second of rest after that and
    /// the cloth sleeps.
    func testAStillBodyPutsTheClothToSleepAndAMovingJointWakesIt() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.sleepAndWake(h)
    }

    /// Asleep, nothing moves the shirt's particles any more (the body is
    /// out of Jolt's step, on a layer the parts do not meet), so the joints
    /// alone can wake it — and a body creeping under the threshold every
    /// frame never would, while its frozen override drifted off it. A
    /// sleeping cloth measures the joints from where they stood when it
    /// fell asleep as well: 0.4 mm a frame wakes it on the third frame.
    func testAJointCreepingUnderTheThresholdWakesTheSleepingCloth() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.creepWakes(h)
    }

    /// With the ragdoll's parts inside the shirt, Jolt alone would wake the
    /// sleeping body every step (an awake rigid body in a sleeping soft
    /// body's bounds activates it): the resting layer closes the parts out,
    /// so the sleep holds over the powered ragdoll — the headset's case —
    /// and the body comes back on its own layer when the joints move. The
    /// particles are taken out of the rule here (an infinite speed
    /// threshold), so the joints alone decide: over the resting parts the
    /// cuffs never go still by the 2 cm/s rule — the forearms and hands hang
    /// a finger's width off their joints and keep the cuff particles moving
    /// at 3 to 8 cm/s once settled (`testTheCapsuleFitOnTheDefaultModel`
    /// has the fit) — so the rule as configured sleeps the shirt on its
    /// skin alone, out of range, or once the parts themselves sleep.
    func testTheSleepHoldsOverThePoweredRagdoll() throws {
        // On the model that meets the parts: the default never does, awake
        // or asleep, so only this one can tell that the resting layer
        // closes them out.
        var configuration = ragdollAndSkin
        configuration.particleSpeedThreshold = .greatestFiniteMagnitude
        let h = try makeHarness(configuration: configuration)
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body over the ragdoll: asleep (\(h.cloth.report))")
        XCTAssertFalse(h.cloth.isSoftBodyActive(ofGarment: 0), "the body is asleep in Jolt")
        let resting = h.particles
        // The body is put back to sleep at every frame's end, so its state
        // after a frame says nothing of what Jolt did in the step; the
        // wakes Jolt gave it are counted as they are undone.
        let wakes = h.cloth.joltWakeCount
        h.frames(100)
        XCTAssertEqual(h.cloth.joltWakeCount, wakes, "the parts inside the shirt never woke it in Jolt (\(h.cloth.joltWakeCount - wakes) wakes in 100 frames)")
        XCTAssertEqual(h.particles, resting, "and not a particle moved")
        XCTAssertTrue(h.cloth.isAsleep)
        h.body.pose = h.pose(offset: SIMD3(0.01, 0, 0))
        h.frame()
        XCTAssertFalse(h.cloth.isAsleep)
        XCTAssertTrue(h.cloth.isSoftBodyActive(ofGarment: 0), "a moving joint wakes it")
        h.frames(50)
        XCTAssertLessThan(h.excess().free, 0.01, "and it follows the parts within its slack again")
        print("cloth sleep over the ragdoll: \(h.cloth.report)")
    }

    /// Nothing but the ball touches the shirt: the joints never move, so
    /// only the particles can say the cloth is no longer still. Asleep,
    /// the positions are still read, and the hit wakes it; the override
    /// follows the dent instead of freezing on the last frame before it.
    func testABallThroughASleepingShirtWakesIt() throws {
        let h = try makeHarness(world: matrix_identity_float4x4, ragdoll: false)
        try ClothFitScenarios.ballWakesTheSleeper(h)
    }

    /// A frame longer than a step runs as several sub-steps on one displayed
    /// pose; a body that moves every frame never reads as still, however
    /// many sub-steps the frame took. The particles are taken out of the
    /// rule here (an infinite speed threshold), so the joints alone decide.
    func testASubSteppedFrameCountsTheJointsMotion() throws {
        var configuration = skinOnly
        configuration.particleSpeedThreshold = .greatestFiniteMagnitude
        let h = try makeHarness(configuration: configuration)
        h.frames(50)
        var offset = SIMD3<Float>.zero
        for frame in 0 ..< 100 {
            offset.x += 0.002
            h.body.pose = h.pose(offset: offset)
            h.frame(subSteps: 2)
            XCTAssertFalse(h.cloth.isAsleep, "frame \(frame): a body moving 2 mm a frame read as asleep")
        }
        XCTAssertEqual(h.body.overrideWrites, 150, "every frame was written")
        XCTAssertLessThan(h.excess().free, 0.005)
    }

    func testAFarPlayerShutsTheSlackAndStopsTheReadBack() throws {
        let h = try makeHarness(configuration: skinOnly)
        try ClothFitScenarios.farPlayer(h)
    }

    // MARK: - The collision model

    /// The A/B the configuration offers, measured on the model as it is, per
    /// region of the shirt: on its skin alone the idle shirt stays within its
    /// slack everywhere, and with the ragdoll's parts colliding it does too,
    /// since the capsules are fitted inside the body and a particle's radius
    /// under the shirt and the trousers (ZombieRagdollRigTests holds them to
    /// 2 mm on the export). Sized for the old mannequin, the torso
    /// capsules reached through the back and pushed its particles 5 cm past
    /// their slack; the regions are printed so a refit shows where it bites.
    func testTheCapsuleFitOnTheDefaultModel() throws {
        func regions(_ h: ClothHarness) -> [String: Float] {
            let p = h.particles, t = h.targets
            var worst: [String: Float] = [:]
            var at: [String: SIMD3<Float>] = [:]
            for index in p.indices where h.shirt.maxDistance[index] > 0 {
                let rest = h.shirt.positions[index]
                // The sleeves reach the wrists beside the hips, so they are told
                // by their reach to the side before the hem is told by its height.
                let region = abs(rest.x) > 0.2 ? "sleeves" : (rest.y < 1.0 ? "hem" : (rest.z < -0.17 ? "back" : "front"))
                let excess = simd_distance(p[index], t[index]) - h.shirt.maxDistance[index]
                if excess > (worst[region] ?? -1) { worst[region] = excess; at[region] = rest }
            }
            // Which capsule the worst particle of each region rests against,
            // on the parts as the simulation has them.
            var against: [String: String] = [:]
            if let rig = h.physics.rig, let physicsPose = h.physics.readRagdollPose(entityWorld: h.body.world, partWeights: Array(repeating: 1, count: rig.partCount)) {
                let partPose = rig.partWorldTransforms(jointModelTransforms: physicsPose.transforms, entityWorld: h.body.world)
                for (region, rest) in at {
                    let index = h.shirt.positions.firstIndex(of: rest)!
                    let particle = p[index]
                    var best = ("", Float.greatestFiniteMagnitude)
                    for part in 0 ..< rig.partCount {
                        let m = partPose[part]
                        let origin = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                        let rotation = simd_quatf(simd_float3x3(simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)), simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)), simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))))
                        let capsule = rig.localCapsules[part]
                        let a = origin + rotation.act(capsule.from), axis = rotation.act(capsule.to - capsule.from)
                        let s = min(max(simd_dot(particle - a, axis) / max(simd_length_squared(axis), 1e-9), 0), 1)
                        let d = simd_distance(particle, a + axis * s) - capsule.radius
                        if d < best.1 { best = (rig.partNames[part], d) }
                    }
                    against[region] = String(format: "%@ %+.3f", best.0, best.1)
                }
            }
            print("  worst per region at rest: " + at.sorted { $0.key < $1.key }.map { String(format: "%@ (%.2f,%.2f,%.2f) slack %.3f, nearest capsule %@", $0.key, $0.value.x, $0.value.y, $0.value.z, h.shirt.maxDistance[h.shirt.positions.firstIndex(of: $0.value)!], against[$0.key] ?? "-") }.joined(separator: "; "))
            let errors = h.physics.trackingErrors(jointModelTransforms: h.body.pose, entityWorld: h.body.world)
            print("  ragdoll tracking errors: " + errors.map { String(format: "%@ %.3f", $0.part, $0.distance) }.joined(separator: ", "))
            return worst
        }
        func describe(_ regions: [String: Float]) -> String {
            regions.sorted { $0.key < $1.key }.map { String(format: "%@ %+.3f m", $0.key, $0.value) }.joined(separator: ", ")
        }
        let alone = try makeHarness(configuration: skinOnly)
        alone.frames(100)
        let aloneExcess = alone.excess()
        XCTAssertTrue(aloneExcess.finite)
        XCTAssertLessThan(aloneExcess.free, 0.005)
        print("cloth fit, skin only: worst excess \(aloneExcess.free) m; \(describe(regions(alone)))")

        let colliding = try makeHarness()
        colliding.frames(100)
        let collidingExcess = colliding.excess()
        XCTAssertTrue(collidingExcess.finite, "the colliding shirt is finite")
        XCTAssertEqual(colliding.cloth.runawayCount, 0)
        let collidingRegions = regions(colliding)
        print("cloth fit, ragdoll and skin: worst excess \(collidingExcess.free) m; \(describe(collidingRegions)); \(colliding.cloth.report)")
        XCTAssertEqual(Set(collidingRegions.keys), ["back", "front", "hem", "sleeves"])
        for (region, excess) in collidingRegions {
            XCTAssertLessThan(excess, 0.005, "the capsules push the shirt's \(region) \(excess) m past its slack")
        }
        XCTAssertLessThan(collidingExcess.free, 0.005, "the capsules push the shirt \(collidingExcess.free) m past its slack")
    }

    // MARK: - The skin's colliders

    /// The sidecar's hulls (`ZombieClothAsset.colliders`) stand in the world
    /// while the shirt is attached — one kinematic body per collider on the
    /// models that meet anything, the default and the ragdoll A/B — and none
    /// on the skin alone, whose cloth sits on the inert layer and meets
    /// nothing, nor with `skinColliders` off; the report counts them
    /// (`colliders=`); a detach takes them out with the soft body, and the
    /// world is as it was before the cloth.
    func testTheSkinCollidersStandWithTheShirtAndGoWithIt() throws {
        guard let asset = ClothFixtures.asset, let colliders = asset.colliders, !colliders.isEmpty else { throw XCTSkip("the sidecar carries no skin colliders") }
        let world = try makeHarness()
        XCTAssertEqual(world.cloth.skinColliderCount, colliders.count, "every collider of the sidecar is in the world on the default model")
        XCTAssertEqual(world.physics.backend.bodyCount, 1 + 20 + 1 + colliders.count, "the floor slab, twenty parts, the shirt and the hulls")
        XCTAssertTrue(world.cloth.report.contains("colliders=\(colliders.count)"), world.cloth.report)
        let ragdoll = try makeHarness(configuration: ragdollAndSkin)
        XCTAssertEqual(ragdoll.cloth.skinColliderCount, colliders.count, "the A/B model keeps the hulls")
        let alone = try makeHarness(configuration: skinOnly)
        XCTAssertEqual(alone.cloth.skinColliderCount, 0, "the skin-only cloth meets nothing, so no hull is built")
        XCTAssertEqual(alone.physics.backend.bodyCount, 1 + 20 + 1)
        XCTAssertTrue(alone.cloth.report.contains("colliders=0"), alone.cloth.report)
        var off = ZombieCloth.Configuration()
        off.skinColliders = false
        let without = try makeHarness(configuration: off)
        XCTAssertEqual(without.cloth.skinColliderCount, 0, "the switch builds none")
        XCTAssertEqual(without.physics.backend.bodyCount, 1 + 20 + 1)
        world.frames(10)
        world.cloth.detach()
        XCTAssertEqual(world.cloth.skinColliderCount, 0, "the detach removed the hulls")
        XCTAssertEqual(world.physics.backend.bodyCount, 1 + 20, "the soft body and the hulls are out of the world")
    }

    /// A collider on a joint the skeleton lacks — a sidecar cooked against
    /// another rig — is skipped and named once; the rest stand and the
    /// attach is not refused.
    func testASkinColliderOnAJointTheSkeletonLacksIsSkipped() throws {
        guard var asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton, let colliders = asset.colliders, !colliders.isEmpty else { throw XCTSkip("the sidecar carries no skin colliders") }
        var stale = colliders
        stale[0].joint = "/root/pelvis/no_such_bone"
        asset.colliders = stale
        let h = ClothHarness(dt: dt, asset: asset, joints: joints)
        XCTAssertTrue(h.attached, "the shirt attached without the stale collider")
        XCTAssertEqual(h.cloth.skinColliderCount, colliders.count - 1, "the stale collider alone was skipped")
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20 + 1 + colliders.count - 1)
        h.frames(5)
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }

    // MARK: - The armhole in the chase's idle

    /// The chase's waiting idle holds the arms out in front. Skinned with the
    /// artist's weights, the shirt's armhole edges stretched to twenty times
    /// their length there, and the cloth, keeping its rest lengths, sat 13 cm
    /// from its skinned target under each arm whatever the solver did (the
    /// Mac readout's `target<=0.139m@(-0.18,1.25,-0.15)`; in this pose, with
    /// the fitted capsules, 16.3 cm). The lever is the weights: graded across
    /// the seams over 16 passes it was 9.4 cm, and with two hundred more over
    /// the 12 cm around the armhole (`grade_weight_seams`) it was 5.2 cm, at
    /// the yoke, on the 3 cm of slack the shirt then had (2026-10-30); on
    /// the schedule the armhole band's farthest particle rests 6.7 cm from
    /// its target and the worst anywhere 2.7 cm past its slack
    /// (2026-10-31). That is pinned here with the figures printed:
    /// the armhole band's farthest particle (the band has the schedule's
    /// 6 cm) under 7 cm from its target and no particle more than 4 cm past
    /// its slack — the shirt's farthest particle overall is printed too, but
    /// with the chest, the back and the hem band on 8 to 12 cm of slack a
    /// hanging particle legitimately rests 10 cm from its target (the hem
    /// band's, 2026-10-31), which is the slack doing its work, not the
    /// armhole. The capsules play no part: on the skin alone, with no
    /// part in the world to push anything, the figure is the same to a
    /// millimetre (9.44 against 9.43 cm before the deeper blur), and the test
    /// runs both models and holds them within a centimetre of each other. The
    /// back-stop yields here the way the slack does: Jolt applies the edge
    /// constraints after the skin constraints in every iteration, so where
    /// the stretched skin's targets conflict with the rest lengths the stiff
    /// edges have the last word and a particle can end up behind its target
    /// (1.9 cm in this pose, on the back; 3 mm on the idle, at the cuff,
    /// where the particle is still 3.4 mm off the body — the hang test
    /// measures that clearance itself) — printed, and bounded like the
    /// excess past the slack. What
    /// remains is the targets': the sleeve's underside hangs between an arm
    /// that moved 40 cm and a flank that did not, the skinning stretches those
    /// edges and the cloth will not, so the particle rests short of a target
    /// it can reach (3-4 cm clear of the arm's capsule). A wider or deeper
    /// blur turns back up (6.7 cm at 300 passes over 11 cm, 7.1 at 400 over
    /// 12), and 13 cm or more puts arm weight within 20 cm of the pelvis; the
    /// 4 cm asked of this round is not reached by the sidecar's weights.
    /// The armhole bound sits 3 mm over the measured 6.70 cm (6.67 on the
    /// skin alone), and that is a margin only because the harness is
    /// deterministic: a fixed 10 ms step on one pose with nothing random in
    /// it, the same calls in the same order on one build, which is Jolt's
    /// condition for the same result (`Docs/Architecture.md`, deterministic
    /// simulation), and every suite prints the same 0.0670 / 0.0667 m and
    /// 18.55 / 18.68 mm to the last digit (each of the runs of 2026-10-31);
    /// the armhole figure is printed to a tenth of a millimetre so the
    /// margin can be read off the log. And the proxy against the SKIN this
    /// pose draws (`penetration(of:)`: the body skinned onto the pose, the
    /// particles more than 2 mm inside it): without the skin colliders the
    /// headset's patches show here as 163 particles inside — the armhole
    /// band 124, the sleeves 28, the yoke 11 — the deepest 34.7 mm into the
    /// upper arm (particle 236, at rest (-0.21,1.41,-0.08), the top of the
    /// left armhole), the same figures on the skin alone and meeting the
    /// world (the capsules are no colliders there) and 171 over the
    /// ragdoll (2026-10-31). The back-stop cannot see this: its plane stands
    /// at the skinned target, up to 15 cm from the particle. The skin's
    /// hulls can: on the models that build them the count is held to
    /// `armsForwardPenetrationBound` (its doc has the figures), and the
    /// skin-only run, which builds none, is the control the hulls must at
    /// least halve.
    func testTheArmsForwardIdleKeepsTheArmholeNearItsTarget() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0) else { throw XCTSkip("the idle clip is not bundled") }
        guard let joints = ClothFixtures.skeleton, let hand = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l"),
              let pelvis = joints.jointPaths.firstIndex(of: "/root/pelvis") else { throw XCTSkip("no skeleton") }
        // The hands hang beside the hips in the bind pose and are held out in
        // the idle: they rise, and they leave the pelvis's side.
        let handRise = (pose[hand].columns.3.y - pose[pelvis].columns.3.y) - (joints.bindModelTransforms[hand].columns.3.y - joints.bindModelTransforms[pelvis].columns.3.y)
        print(String(format: "cloth arms-forward idle: pelvis (%.2f,%.2f,%.2f), hand (%.2f,%.2f,%.2f); bind hand (%.2f,%.2f,%.2f)",
                     pose[pelvis].columns.3.x, pose[pelvis].columns.3.y, pose[pelvis].columns.3.z, pose[hand].columns.3.x, pose[hand].columns.3.y, pose[hand].columns.3.z,
                     joints.bindModelTransforms[hand].columns.3.x, joints.bindModelTransforms[hand].columns.3.y, joints.bindModelTransforms[hand].columns.3.z))
        XCTAssertGreaterThan(handRise, 0.1, "the idle holds the hands up by \(handRise) m")
        var farthest: [String: Float] = [:]
        var insideByModel: [String: Int] = [:]
        for (label, configuration) in [("skin only", skinOnly), ("world", ZombieCloth.Configuration()), ("ragdoll and skin", ragdollAndSkin)] {
            var bounds = ClothFitBounds.jolt.armsForward
            bounds.penetration = armsForwardPenetrationBound[label]
            let h = try makeHarness(configuration: configuration, pose: pose)
            let figures = try ClothFitScenarios.armsForwardIdle(h, label: label, handRise: handRise, bounds: bounds)
            insideByModel[label] = figures.inside
            farthest[label] = figures.armhole
        }
        XCTAssertEqual(farthest["skin only"] ?? 0, farthest["ragdoll and skin"] ?? 1, accuracy: 0.01, "the capsules change the arms-forward armhole figure: \(farthest)")
        // The control: the back-stop alone leaves the headset's patches (163
        // particles inside), and the hulls take half of them away
        // (65 against 154, 2026-11-03, the cuff roll pinned whole; 83 against 163 before): held to two fifths.
        XCTAssertGreaterThan(insideByModel["skin only"] ?? 0, 100, "the skin-only control no longer shows the patches the hulls are for: \(insideByModel)")
        XCTAssertLessThan(Float(insideByModel["world"] ?? Int.max) / Float(max(insideByModel["skin only"] ?? 1, 1)), 0.6, "the skin's hulls take less than two fifths of the particles inside the posed skin away: \(insideByModel)")
    }

    /// The left arm swung from the bind pose to the chase's arms-forward
    /// idle over 30 frames (74 degrees at the upper arm, the elbow at
    /// 1.56 m/s; the rest of the body stands) and held 30 more, the proxy
    /// read against the skin each pose draws every other frame: the hulls
    /// move with the joints by teleport-and-target each step
    /// (`moveSkinColliders`), so the hull stands where the skin's targets
    /// stand for the whole step, and they are frictionless. Measured
    /// 2026-11-03 on the default model, with the cuff roll pinned whole:
    /// during the swing at most 9 particles more than 2 mm inside the posed
    /// skin (frame 29, the end of the swing), the deepest 9.2 mm; held,
    /// 13-14 inside, 14.2 mm deep (particle 1468, the armhole, the right
    /// armpit); the worst excess past the slack 6.8 mm; the sleeves'
    /// farthest particle 50.0 mm off the skin (48.2 on the skin alone: the
    /// hulls lift the sleeve no farther than the fabric swings by itself).
    /// The skin-only control reads 48 inside at the swing's end and 46-51
    /// held, 31.0 mm deep. (Before the cuffs were pinned whole, the same
    /// day: 21 and 26-28 inside, 62-65 on the skin alone — the free sleeve
    /// end under the roll was most of the sleeve's share.) Bounds: the
    /// measurement of the earlier cook and a margin of a few particles and
    /// a millimetre, so they hold both. The
    /// pre-fix variants (targeted moves, friction 0.5) were not measured
    /// against this test: their runs were cut short when the round closed.
    func testASwingingArmKeepsTheSleeveOnItsHull() throws {
        guard let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0), let joints = ClothFixtures.skeleton else { throw XCTSkip("the idle clip is not bundled") }
        guard let upperarm = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l"),
              let elbow = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l") else { throw XCTSkip("no left arm") }
        var readings: [(frame: Int, inside: Int, deepest: Float, excess: Float, lift: Float, elbowSpeed: Float)] = []
        for (label, configuration) in [("world", ZombieCloth.Configuration()), ("skin only", skinOnly)] {
            let h = try makeHarness(configuration: configuration)
            let run = try ClothFitScenarios.armSwing(h, label: label, pose: pose, joints: joints, upperarm: upperarm, elbow: elbow, bounds: label == "world" ? ClothFitBounds.jolt.swing : nil)
            if label == "world" { readings = run }
        }
        print("cloth arm swing, world, per frame (frame inside deepest_mm excess_mm lift_mm elbow_m/s): " + readings.map { String(format: "%d %d %.1f %+.1f %.1f %.2f", $0.frame, $0.inside, -$0.deepest * 1000, $0.excess * 1000, $0.lift * 1000, $0.elbowSpeed) }.joined(separator: "; "))
    }

    // MARK: - The posed skin

    /// The metric the skin-following tests read the shirt against — the body
    /// the animation's pose skins, which is what the headset draws under the
    /// shirt, not the ragdoll's capsules — checked on the pose it can be
    /// checked on. The export's own skin on its vertices (four joints and
    /// four weights each, the engine's blend as `DeformationCompute.metal`
    /// does it) against the skeleton's bind pose gives the export back at
    /// the bind pose, every one of the 38,798 body vertices within 0.0004 mm;
    /// the skeleton's bind transforms are the rest chain the harness builds
    /// (within 4e-7), so the body skins against the bind the cloth skins
    /// against; the skin is the export's largest piece off the shell and
    /// the trousers (27,010 triangles; the next, an eye, 9,320; 50 pieces);
    /// and the proxy at rest reads OUTSIDE that surface everywhere it can
    /// read it — 3,666 of the 3,995 particles have skin within 5 cm, the
    /// nearest 2.45 mm outside (particle 1130, the armhole band, at rest
    /// (-0.20,1.24,-0.17)), the push-out having left the proxy 2 mm off the
    /// body — so the export's winding puts the geometric normals outward and
    /// the sign the metric takes from them is the right way round
    /// (`bodyWindingSign`). Read against everything under the shirt instead,
    /// the trousers and the belt loops included, the flanks at the waist read
    /// 8-20 mm "inside" at rest, which is why the skin is a piece and not
    /// the whole (2026-10-31). On the arms-forward idle's pose, the skin
    /// around the left wrist goes where the hand joint goes: the 104
    /// vertices within 4 cm of the bind wrist end within 3.9 cm of the posed
    /// one, a metre away (a joint map or an inverse bind the wrong way round
    /// sends them metres off).
    func testThePosedBodyReadsTheRestShirtAsOutside() throws {
        guard let asset = ClothFixtures.asset, let joints = ClothFixtures.skeleton, let exported = ClothFixtures.exported, let isShell = ClothFixtures.exportedIsShell, let skin = ClothFixtures.exportedSkin else {
            throw XCTSkip("Models/Zombie is not bundled")
        }
        let shirt = try XCTUnwrap(asset.garment(named: "shirt"))
        var bindOff: Float = 0
        XCTAssertEqual(skin.bindTransforms.count, joints.bindModelTransforms.count)
        for (engine, chain) in zip(skin.bindTransforms, joints.bindModelTransforms) {
            for c in 0 ..< 4 { bindOff = max(bindOff, simd_reduce_max(simd_abs(engine[c] - chain[c]))) }
        }
        XCTAssertLessThan(bindOff, 1e-4, "the skeleton's bind transforms differ from the rest chain by \(bindOff)")
        let posed = try XCTUnwrap(ClothMetrics.posedBody(joints.bindModelTransforms), "the body could not be skinned")
        var worstBody: Float = 0, bodyVertices = 0, unweighted = 0
        for v in posed.indices where !isShell[v] {
            bodyVertices += 1
            if skin.weights[v].sum() <= 1e-4 { unweighted += 1 }
            worstBody = max(worstBody, simd_distance(posed[v], exported.positions[v]))
        }
        XCTAssertGreaterThan(bodyVertices, 10000, "the body was not found in the export")
        XCTAssertLessThan(worstBody, 1e-4, "a body vertex skinned onto the bind pose is \(worstBody) m off the export")
        let body = try XCTUnwrap(ClothMetrics.BodySurface(positions: posed, triangles: ClothFixtures.skinTriangles))
        var nearest: Float = .greatestFiniteMagnitude, nearestAt = 0, unread = 0, inside = 0
        for (index, p) in shirt.positions.enumerated() {
            guard let d = body.signedDistance(to: p) else { unread += 1; continue }
            if d < nearest { nearest = d; nearestAt = index }
            if d < 0 { inside += 1 }
        }
        let nearestRest = shirt.positions[nearestAt]
        let pieces = try XCTUnwrap(ClothFixtures.offShellPieces)
        print(String(format: "cloth posed skin at the bind pose: %d body vertices (%d without weight) skinned back within %.4f mm of the export, bind transforms within %.2e of the rest chain; the skin is the largest of %d pieces off the shell and the trousers, %d triangles (the next %d); %d of %d particles have skin within 5 cm, %d read inside, the nearest %.2f mm outside at particle %d (%@) at rest (%.2f,%.2f,%.2f)",
                     bodyVertices, unweighted, worstBody * 1000, bindOff, pieces.count, pieces[0].count, pieces.count > 1 ? pieces[1].count : 0, shirt.positions.count - unread, shirt.positions.count, inside, nearest * 1000, nearestAt, ClothMetrics.regionName(slack: shirt.maxDistance[nearestAt]), nearestRest.x, nearestRest.y, nearestRest.z))
        XCTAssertGreaterThan(pieces[0].count, 20000, "the body is not the largest piece off the shell and the trousers (\(pieces.prefix(3).map(\.count)))")
        XCTAssertGreaterThan(shirt.positions.count - unread, 3000, "only \(shirt.positions.count - unread) particles have skin within 5 cm at the bind pose")
        XCTAssertEqual(inside, 0, "\(inside) particles read inside the skin at rest")
        XCTAssertGreaterThanOrEqual(nearest, 0.0015, "particle \(nearestAt) reads \(nearest) m from the skin at rest: inside it, or the export's winding is inverted (bodyWindingSign)")
        // And a real pose moves the skin with its joints.
        if let pose = try ClothFixtures.clipPose(ZombieResources.waitingClip, at: 1.0),
           let hand = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l")
        {
            let armsForward = try XCTUnwrap(ClothMetrics.posedBody(pose))
            let bindWrist = SIMD3(joints.bindModelTransforms[hand].columns.3.x, joints.bindModelTransforms[hand].columns.3.y, joints.bindModelTransforms[hand].columns.3.z)
            let posedWrist = SIMD3(pose[hand].columns.3.x, pose[hand].columns.3.y, pose[hand].columns.3.z)
            var wristVertices = 0, farthest: Float = 0, moved: Float = 0
            for v in armsForward.indices where !isShell[v] && simd_distance(exported.positions[v], bindWrist) < 0.04 {
                wristVertices += 1
                farthest = max(farthest, simd_distance(armsForward[v], posedWrist))
                moved = max(moved, simd_distance(armsForward[v], exported.positions[v]))
            }
            print(String(format: "cloth posed skin, arms-forward idle: the wrist moved %.3f m, %d skin vertices within 4 cm of it at rest end within %.3f m of it, having moved up to %.3f m", simd_distance(bindWrist, posedWrist), wristVertices, farthest, moved))
            XCTAssertGreaterThan(wristVertices, 100, "the wrist's skin was not found")
            XCTAssertGreaterThan(simd_distance(bindWrist, posedWrist), 0.1, "the idle does not move the wrist")
            XCTAssertLessThan(farthest, 0.06, "the skin around the wrist ends \(farthest) m from the posed wrist: the body does not follow its joints")
        }
    }

    // MARK: - Cost

    /// The skin feed, the read-back and, inside it, the shell's evaluation
    /// per frame over 300 frames of sway, and the step interval, printed for
    /// the headset budget (a debug build: the release figures are the Mac
    /// sandbox's, in the README).
    func testTimingsOverThreeHundredFrames() throws {
        let h = try makeHarness()
        var skin: [Double] = [], read: [Double] = [], bind: [Double] = [], step: [Double] = []
        for _ in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            let timings = h.cloth.timings
            skin.append(timings.skin)
            read.append(timings.readBack)
            bind.append(timings.bind)
            step.append(timings.step)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean %.0f us, median %.0f us, max %.0f us", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted.last ?? 0)
        }
        print("cloth timing (300 frames, 100 Hz, 3 sub-steps, \(h.cloth.configuration.iterationsPerStep) iterations, \(h.shirt.particles.count) particles, \(h.shirt.render?.vertexCount ?? 0) shell vertices): skin \(stats(skin)); read-back \(stats(read)); bind \(stats(bind)); step \(stats(step))")
        XCTAssertEqual(h.body.overrideWrites, 300)
    }

    // MARK: - The hosts' launch arguments

    /// `-cloth` and `-clothIterations` as both hosts parse them: the
    /// defaults hold through no arguments, an unknown model, a count that
    /// is not one and a flag with no value. The defaults themselves are
    /// pinned too — the material the headset round of 2026-10-31 settled
    /// on (a few percent of in-plane give, air drag, a 3 mm particle
    /// against the skin's hulls, which are on by default), since the fit
    /// tests measure against them; and since 2026-11-03 the solver switch
    /// and the GPU arm's knobs of `Docs/GPUCloth.md` — Jolt by default
    /// until the design's gate 2 flips it, 16 substeps, one gather, the
    /// raw-sum relaxation at 0.5, Jolt's damping, frictionless hulls, the
    /// read waiting for the frame, the bundled sidecar — each flag with its
    /// bounds, and a bad value leaving the knob as it was.
    func testTheLaunchArgumentsSetTheClothConfiguration() {
        let defaults = ZombieCloth.Configuration()
        XCTAssertTrue(defaults.skinColliders, "the skin's hulls are built by default")
        XCTAssertEqual(defaults.skinColliderFriction, 0, "the hulls are frictionless: Jolt's soft body brakes against a kinematic collider in the world frame, and the sleeve must go with the arm")
        XCTAssertEqual(defaults.friction, 0.5, "the cloth's own friction, against the world and the balls")
        XCTAssertEqual(defaults.vertexRadius, 0.003, "the particle's radius against the hulls: 2 mm of push-out plus the hull's millimetre of inset")
        XCTAssertEqual(defaults.stretchCompliance, 1e-2, "the edges give a few percent under the shirt's weight")
        XCTAssertEqual(defaults.shearCompliance, 2e-2)
        XCTAssertEqual(defaults.bendCompliance, 0.3)
        XCTAssertEqual(defaults.linearDamping, 4, "the air's drag")
        XCTAssertEqual(defaults.iterationsPerStep, 4)
        var configuration = defaults
        configuration.apply(launchArguments: [])
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.collisionModel, .skinAndWorld, "the default meets the world, not the ragdoll's parts")
        XCTAssertEqual(configuration.iterationsPerStep, 4, "the default is four iterations")
        configuration.apply(launchArguments: ["-play", "-cloth", "off"])
        XCTAssertFalse(configuration.enabled)
        configuration = defaults
        configuration.apply(launchArguments: ["-cloth", "skin", "-clothIterations", "3"])
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.collisionModel, .skinOnly)
        XCTAssertEqual(configuration.iterationsPerStep, 3)
        configuration.apply(launchArguments: ["-cloth", "ragdoll"])
        XCTAssertEqual(configuration.collisionModel, .ragdollAndSkin)
        XCTAssertEqual(configuration.iterationsPerStep, 3, "the model alone changed")
        configuration.apply(launchArguments: ["-cloth", "world"])
        XCTAssertEqual(configuration.collisionModel, .skinAndWorld)
        configuration = defaults
        configuration.apply(launchArguments: ["-cloth", "wool", "-clothIterations", "0"])
        XCTAssertTrue(configuration.enabled, "an unknown model changes nothing")
        XCTAssertEqual(configuration.collisionModel, .skinAndWorld)
        XCTAssertEqual(configuration.iterationsPerStep, 4, "zero iterations is not a count")
        configuration.apply(launchArguments: ["-clothIterations", "many", "-cloth"])
        XCTAssertEqual(configuration.iterationsPerStep, 4, "nor is a word")
        XCTAssertTrue(configuration.enabled, "a flag with no value is ignored")
        // The skin's hulls, for the A/B on the headset.
        configuration = defaults
        configuration.apply(launchArguments: ["-clothColliders", "off"])
        XCTAssertFalse(configuration.skinColliders, "-clothColliders off runs the back-stop alone")
        configuration.apply(launchArguments: ["-clothColliders", "on"])
        XCTAssertTrue(configuration.skinColliders)
        configuration.apply(launchArguments: ["-clothColliders", "maybe"])
        XCTAssertTrue(configuration.skinColliders, "an unknown value leaves the hulls as they were")
        configuration.apply(launchArguments: ["-clothColliders"])
        XCTAssertTrue(configuration.skinColliders, "a flag with no value is ignored")
        // The tether experiment: how much of the shirt's look is the slack.
        configuration = defaults
        XCTAssertEqual(defaults.slackScale, 1, "the schedule stands by default")
        configuration.apply(launchArguments: ["-clothSlack", "3"])
        XCTAssertEqual(configuration.slackScale, 3, "-clothSlack 3 triples every free particle's slack")
        configuration.apply(launchArguments: ["-clothSlack", "0"])
        XCTAssertEqual(configuration.slackScale, 3, "a scale of nought would pin the whole shirt; ignored")
        configuration.apply(launchArguments: ["-clothSlack", "loose"])
        XCTAssertEqual(configuration.slackScale, 3, "an unknown value leaves the scale as it was")
        // The solver and the GPU arm's knobs: the defaults of the design.
        XCTAssertEqual(defaults.solver, .jolt, "Jolt holds the shirt until gate 2")
        XCTAssertEqual(defaults.gpuSubsteps, 16, "0.625 ms substeps at the headset's 10 ms")
        XCTAssertEqual(defaults.gpuIterations, 2, "two gathers per substep, the residual test's verdict of 2026-11-03")
        XCTAssertEqual(defaults.gpuRelaxation, 0.5, "CoolCloth's factor on the raw sum")
        XCTAssertFalse(defaults.gpuAveragedJacobi, "the raw sum, not the average")
        XCTAssertNil(defaults.gpuDamping, "nil is Jolt's linearDamping, so the first A/B is like for like")
        XCTAssertEqual(defaults.gpuHullFriction, 0, "frictionless hulls, as on Jolt")
        XCTAssertTrue(defaults.gpuWait, "the read waits for the frame's command buffer")
        XCTAssertNil(defaults.sidecar, "the bundled sidecar")
        configuration = defaults
        configuration.apply(launchArguments: [])
        XCTAssertEqual(configuration.solver, .jolt)
        XCTAssertEqual(configuration.gpuSubsteps, 16)
        configuration.apply(launchArguments: ["-clothSolver", "gpu", "-clothSubsteps", "8", "-clothGPUIterations", "2", "-clothRelaxation", "1.5",
                                              "-clothAveragedJacobi", "on", "-clothGPUDamping", "1", "-clothHullFriction", "0.2", "-clothGPUWait", "off",
                                              "-clothSidecar", "Zombie.cloth16k"])
        XCTAssertEqual(configuration.solver, .gpu, "-clothSolver gpu picks the GPU arm")
        XCTAssertEqual(configuration.gpuSubsteps, 8)
        XCTAssertEqual(configuration.gpuIterations, 2)
        XCTAssertEqual(configuration.gpuRelaxation, 1.5)
        XCTAssertTrue(configuration.gpuAveragedJacobi)
        XCTAssertEqual(configuration.gpuDamping, 1)
        XCTAssertEqual(configuration.gpuHullFriction, 0.2)
        XCTAssertFalse(configuration.gpuWait)
        XCTAssertEqual(configuration.sidecar, "Zombie.cloth16k")
        XCTAssertEqual(configuration.collisionModel, .skinAndWorld, "the model is orthogonal to the solver")
        XCTAssertEqual(configuration.iterationsPerStep, 4, "and so are Jolt's iterations")
        configuration.apply(launchArguments: ["-clothSolver", "jolt", "-clothAveragedJacobi", "off", "-clothGPUWait", "on", "-clothGPUDamping", "0", "-clothHullFriction", "0"])
        XCTAssertEqual(configuration.solver, .jolt)
        XCTAssertFalse(configuration.gpuAveragedJacobi)
        XCTAssertTrue(configuration.gpuWait)
        XCTAssertEqual(configuration.gpuDamping, 0, "nought is a damping (no drag), unlike nil")
        XCTAssertEqual(configuration.gpuHullFriction, 0)
        XCTAssertEqual(configuration.gpuSubsteps, 8, "the other knobs stayed")
        // The bounds: the substeps 1 to 32, the gathers 1 to 4.
        configuration.apply(launchArguments: ["-clothSubsteps", "32", "-clothGPUIterations", "4"])
        XCTAssertEqual(configuration.gpuSubsteps, 32)
        XCTAssertEqual(configuration.gpuIterations, 4)
        configuration.apply(launchArguments: ["-clothSubsteps", "1", "-clothGPUIterations", "1"])
        XCTAssertEqual(configuration.gpuSubsteps, 1)
        XCTAssertEqual(configuration.gpuIterations, 1)
        configuration.apply(launchArguments: ["-clothSubsteps", "33", "-clothGPUIterations", "5"])
        XCTAssertEqual(configuration.gpuSubsteps, 1, "33 substeps is past the cap; ignored")
        XCTAssertEqual(configuration.gpuIterations, 1, "five gathers is past the cap; ignored")
        configuration.apply(launchArguments: ["-clothSubsteps", "0", "-clothGPUIterations", "0"])
        XCTAssertEqual(configuration.gpuSubsteps, 1, "nought substeps is not a count")
        XCTAssertEqual(configuration.gpuIterations, 1, "nor nought gathers")
        // The bad values: a word, a negative, nought where it would divide
        // by it, an infinity, an unknown switch value, a flag with no value
        // or with the next flag for one.
        configuration = defaults
        configuration.apply(launchArguments: ["-clothSolver", "cpu", "-clothSubsteps", "many", "-clothGPUIterations", "two", "-clothRelaxation", "0",
                                              "-clothAveragedJacobi", "maybe", "-clothGPUDamping", "-1", "-clothHullFriction", "-0.5", "-clothGPUWait", "later",
                                              "-clothSidecar", "-play"])
        XCTAssertEqual(configuration.solver, .jolt, "an unknown solver changes nothing")
        XCTAssertEqual(configuration.gpuSubsteps, 16, "a word is not a count")
        XCTAssertEqual(configuration.gpuIterations, 2, "a word is not a count; the default's two gathers stay")
        XCTAssertEqual(configuration.gpuRelaxation, 0.5, "a relaxation of nought would freeze the edges; ignored")
        XCTAssertFalse(configuration.gpuAveragedJacobi, "an unknown value leaves the form as it was")
        XCTAssertNil(configuration.gpuDamping, "a negative damping is not one")
        XCTAssertEqual(configuration.gpuHullFriction, 0, "nor a negative friction")
        XCTAssertTrue(configuration.gpuWait, "an unknown value leaves the wait as it was")
        XCTAssertNil(configuration.sidecar, "the next flag is not a sidecar's name")
        configuration.apply(launchArguments: ["-clothRelaxation", "-0.5", "-clothGPUDamping", "inf", "-clothHullFriction", "nan"])
        XCTAssertEqual(configuration.gpuRelaxation, 0.5, "a negative relaxation would undo the corrections; ignored")
        XCTAssertNil(configuration.gpuDamping, "an infinity is not a damping")
        XCTAssertEqual(configuration.gpuHullFriction, 0, "nor is not-a-number a friction")
        configuration.apply(launchArguments: ["-clothSolver", "-clothSubsteps", "-clothGPUIterations", "-clothRelaxation", "-clothAveragedJacobi",
                                              "-clothGPUDamping", "-clothHullFriction", "-clothGPUWait", "-clothSidecar"])
        XCTAssertEqual(configuration.solver, .jolt, "a flag with no value is ignored")
        XCTAssertEqual(configuration.gpuSubsteps, 16)
        XCTAssertEqual(configuration.gpuIterations, 2)
        XCTAssertEqual(configuration.gpuRelaxation, 0.5)
        XCTAssertFalse(configuration.gpuAveragedJacobi)
        XCTAssertNil(configuration.gpuDamping)
        XCTAssertEqual(configuration.gpuHullFriction, 0)
        XCTAssertTrue(configuration.gpuWait)
        XCTAssertNil(configuration.sidecar)
    }

    // MARK: - The solver switch

    /// `Configuration.solver` set to `gpu` before phase 1 of
    /// `Docs/GPUCloth.md` has a `GPUClothSolver` to build: the attach says
    /// once that Jolt stands in and then builds what the default builds —
    /// the Jolt soft body and the sidecar's eleven hulls — so the hosts'
    /// Solver pickers and `-clothSolver gpu` are safe to flip today, and the
    /// world holds the floor slab, the twenty parts, the shirt and the hulls
    /// exactly as on the Jolt arm; the configuration keeps the pick (nothing
    /// in the report names the solver until phase 1's `[gpu]` tag), and the
    /// shirt simulates and writes its override as before. Phase 1 turns this
    /// into the design's `testTheGPUSolverIsRefusedWithoutADevice`: the same
    /// attach, with no Metal device to build the GPU solver on.
    func testTheGPUPickStandsOnJoltUntilTheGPUSolverIsBuilt() throws {
        guard let colliders = ClothFixtures.asset?.colliders, !colliders.isEmpty else { throw XCTSkip("the sidecar carries no skin colliders") }
        var gpu = ZombieCloth.Configuration()
        gpu.solver = .gpu
        let h = try makeHarness(configuration: gpu)
        XCTAssertTrue(h.cloth.isAttached, "the GPU pick attaches on Jolt")
        XCTAssertEqual(h.cloth.configuration.solver, .gpu, "the pick is kept; only the solver built is Jolt's")
        XCTAssertEqual(h.cloth.skinColliderCount, colliders.count, "the stand-in builds the hulls as the default does")
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20 + 1 + colliders.count, "the floor slab, twenty parts, the shirt and the hulls, as on the Jolt arm")
        XCTAssertTrue(h.cloth.report.contains("colliders=\(colliders.count)"), h.cloth.report)
        XCTAssertTrue(h.cloth.report.contains("sim=on"), h.cloth.report)
        let writes = h.body.overrideWrites
        h.frames(5)
        XCTAssertGreaterThan(h.body.overrideWrites, writes, "the shirt simulates and writes its override as before")
        XCTAssertEqual(h.cloth.runawayCount, 0)
    }
}
