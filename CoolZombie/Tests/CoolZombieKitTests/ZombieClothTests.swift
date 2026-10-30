//
//  ZombieClothTests.swift
//  CoolZombieKitTests
//
//  The shirt as a skinned soft body against a real Jolt world at the demo's
//  cadence (100 Hz, three sub-steps), with no engine entity: the bundled
//  sidecar's particles stand in for the mesh, the model's own skeleton
//  (read from the bundled .untold, so the ragdoll and the skin share one
//  bind pose) for the pose and the ragdoll, and a recording body for the
//  override.
//
//  The skin-following tests run the cloth on the default model,
//  `ragdollAndSkin`, with the powered ragdoll in the world: the rig's
//  capsules are fitted to this body (ZombieRagdollRig.specs) and sit a
//  particle's radius inside the shirt and the trousers, so they leave the
//  resting shirt alone where the parts sit on the pose;
//  `testTheCapsuleFitOnTheDefaultModel` measures both models per region
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

    /// The test's body: the shirt's own particles as the mesh (one exported
    /// vertex per particle), the pose the test sets, and what the cloth
    /// writes.
    private final class Body: ZombieClothBody {
        var mesh: [SIMD3<Float>]
        var pose: [simd_float4x4]
        var world: simd_float4x4
        var overrideWrites = 0
        var clears = 0
        var begins = 0
        var ends = 0
        /// Whether the body takes the deformation component (the entity
        /// path can fail to).
        var acceptsOverride = true
        var indices: [UInt32] = []
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []

        init(mesh: [SIMD3<Float>], pose: [simd_float4x4], world: simd_float4x4) {
            self.mesh = mesh
            self.pose = pose
            self.world = world
        }

        func meshGeometry() -> (positions: [SIMD3<Float>], localTransform: simd_float4x4)? { (mesh, matrix_identity_float4x4) }
        func jointModelTransforms() -> [simd_float4x4]? { pose }
        func entityWorld() -> simd_float4x4 { world }
        func beginOverride() -> Bool {
            begins += 1
            return acceptsOverride
        }
        func writeOverride(indices: [UInt32], positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
            overrideWrites += 1
            self.indices = indices
            self.positions = positions
            self.normals = normals
        }

        func clearOverride() { clears += 1 }
        func endOverride() { ends += 1 }
    }

    /// The model's skeleton as the engine reports it: joint paths, parents
    /// and the model-space bind pose.
    private static let skeleton: SkeletonJointInfo? = {
        guard let url = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold"),
              FileManager.default.fileExists(atPath: url.path),
              let asset = try? NativeFormatLoader().loadAssetSync(from: url),
              let skeleton = asset.nodes.compactMap(\.skeleton).first
        else { return nil }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        for index in skeleton.jointPaths.indices {
            let parent = skeleton.parentIndices[index].map { world[$0] } ?? matrix_identity_float4x4
            world[index] = parent * skeleton.restTransforms[index]
        }
        return SkeletonJointInfo(jointPaths: skeleton.jointPaths, parentIndices: skeleton.parentIndices, bindModelTransforms: world)
    }()

    /// The bundled sidecar, or the one `COOLZOMBIE_CLOTH_SIDECAR` names: another
    /// cook of the same export (its particles must still sit on the vertices),
    /// for an A/B of the weights or the slack in these tests.
    private static let asset: ZombieClothAsset? = {
        if let path = ProcessInfo.processInfo.environment["COOLZOMBIE_CLOTH_SIDECAR"] {
            return try? ZombieClothAsset.load(from: URL(fileURLWithPath: path))
        }
        return try? ZombieClothAsset.loadBundled()
    }()

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// The zombie stands a little off the origin and turned, so the model
    /// and world frames differ and the read-back's transform shows.
    private static let standing = translation(SIMD3(1, 0, 2)) * simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)))

    /// The demo's physics plus the cloth on the model's skeleton, the
    /// powered ragdoll placed on the bind pose, the world stepped the way a
    /// frame does.
    private final class Harness {
        let dt: Float
        let physics: ZombiePhysics
        let cloth: ZombieCloth
        let body: Body
        let joints: SkeletonJointInfo
        let shirt: ZombieClothAsset.Garment
        let attached: Bool
        var time: Float = 0

        init(dt: Float, asset: ZombieClothAsset, joints: SkeletonJointInfo, configuration: ZombieCloth.Configuration = ZombieCloth.Configuration(),
             world: simd_float4x4 = ZombieClothTests.standing, ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil,
             acceptsOverride: Bool = true, pose: [simd_float4x4]? = nil, collisionSteps: Int32 = 3)
        {
            self.dt = dt
            self.joints = joints
            shirt = asset.garment(named: "shirt")!
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            // The Mac's three sub-steps unless a test asks for the headset's two.
            settings.collisionSteps = collisionSteps
            settings.maxKinematicStep = 1.0
            settings.maxKinematicSpeed = 6.0
            settings.minContactSpeed = 0.35
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            physics = ZombiePhysics(backend: backend, configuration: ZombiePhysics.Configuration())
            physics.applyLayers()
            physics.setObstacles(obstacles, floor: 0)
            backend.step(deltaTime: dt)
            body = Body(mesh: mesh ?? shirt.positions, pose: pose ?? joints.bindModelTransforms, world: world)
            body.acceptsOverride = acceptsOverride
            if ragdoll {
                physics.attachRagdoll(entity: 1, joints: joints)
                physics.track(jointModelTransforms: body.pose, entityWorld: body.world)
            }
            cloth = ZombieCloth(asset: asset, configuration: configuration)
            attached = cloth.attach(body: body, physics: physics, jointInfo: joints)
        }

        /// The bind pose with every joint but the root moved by `offset`: the
        /// whole body sways, as it does when the pelvis does.
        func pose(offset: SIMD3<Float>) -> [simd_float4x4] {
            joints.bindModelTransforms.enumerated().map { index, m in
                guard joints.parentIndices[index] != nil else { return m }
                var moved = m
                moved.columns.3 += SIMD4(offset, 0)
                return moved
            }
        }

        /// One frame as the demo runs it: the world steps (the cloth feeds
        /// this frame's pose inside; a long frame as `subSteps` shares of
        /// the delta on the one pose, as the engine's per-frame stepping
        /// does), then the game update — `beforeUpdate` is where the game
        /// moves the entity, the ragdoll tracks the pose — and last the
        /// cloth reads back.
        func frame(playerPosition: SIMD3<Float>? = nil, subSteps: Int = 1, beforeUpdate: (() -> Void)? = nil) {
            time += dt
            for _ in 0 ..< subSteps {
                physics.backend.step(deltaTime: dt / Float(subSteps))
            }
            cloth.beginUpdate()
            beforeUpdate?()
            physics.track(jointModelTransforms: body.pose, entityWorld: body.world)
            cloth.readBack(deltaTime: dt, playerPosition: playerPosition)
        }

        func frames(_ count: Int, playerPosition: SIMD3<Float>? = nil, each: ((Float) -> Void)? = nil) {
            for _ in 0 ..< count {
                each?(time + dt)
                frame(playerPosition: playerPosition)
            }
        }

        var particles: [SIMD3<Float>] { cloth.particleWorldPositions(ofGarment: 0) }
        var targets: [SIMD3<Float>] { cloth.skinnedTargets(ofGarment: 0) }

        /// The worst particle: how far beyond its slack it sits from its
        /// skinned target (negative inside), and the worst pin's distance.
        func excess() -> (free: Float, pins: Float, finite: Bool) {
            let p = particles, t = targets
            var free: Float = -.greatestFiniteMagnitude, pins: Float = 0, finite = true
            for index in p.indices {
                let position = p[index]
                if !(position.x.isFinite && position.y.isFinite && position.z.isFinite) { finite = false; continue }
                let d = simd_distance(position, t[index])
                if shirt.maxDistance[index] == 0 { pins = max(pins, d) } else { free = max(free, d - shirt.maxDistance[index]) }
            }
            return (free, pins, finite)
        }
    }

    private func makeHarness(configuration: ZombieCloth.Configuration = ZombieCloth.Configuration(), world: simd_float4x4 = ZombieClothTests.standing,
                             ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil, pose: [simd_float4x4]? = nil,
                             collisionSteps: Int32 = 3) throws -> Harness
    {
        guard let asset = Self.asset, let joints = Self.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let harness = Harness(dt: dt, asset: asset, joints: joints, configuration: configuration, world: world, ragdoll: ragdoll, obstacles: obstacles, mesh: mesh, pose: pose,
                              collisionSteps: collisionSteps)
        XCTAssertTrue(harness.attached, "the shirt attached")
        return harness
    }

    /// The cloth on its skin alone, no collisions: the skin mechanism by itself.
    private var skinOnly: ZombieCloth.Configuration {
        var configuration = ZombieCloth.Configuration()
        configuration.collisionModel = .skinOnly
        return configuration
    }

    // MARK: - Binding and the override

    func testAttachBindsEveryParticleAndWritesAnOverrideCoveringThem() throws {
        let h = try makeHarness(configuration: skinOnly)
        XCTAssertEqual(h.cloth.garmentNames, ["shirt"])
        XCTAssertEqual(h.body.begins, 1, "the body moved to compute skinning once")
        XCTAssertEqual(h.cloth.hardSkinCount, 1, "the attach hard skinned")
        XCTAssertEqual(h.physics.backend.bodyCount, 1 + 20 + 1, "the floor slab, twenty parts and the shirt")
        h.frame()
        XCTAssertEqual(h.body.overrideWrites, 1)
        XCTAssertEqual(h.body.indices.count, h.shirt.particles.count, "one exported vertex per particle in this mesh")
        XCTAssertEqual(Set(h.body.indices), Set(0 ..< UInt32(h.shirt.particles.count)), "every particle drives its vertex")
        XCTAssertEqual(h.body.positions.count, h.body.indices.count)
        XCTAssertEqual(h.body.normals.count, h.body.indices.count)
        // The override is the particles in mesh space: back through the
        // entity's transform they are Jolt's positions; the normals are unit.
        let particles = h.particles
        let mesh = h.shirt.positions
        var worstBack: Float = 0, worstFromRest: Float = 0, worstNormal: Float = 0
        for (slot, index) in h.body.indices.enumerated() {
            let p = h.body.positions[slot]
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, "override position \(slot) is a number")
            let world = h.body.world * SIMD4(p, 1)
            worstBack = max(worstBack, simd_distance(SIMD3(world.x, world.y, world.z), particles[Int(index)]))
            worstFromRest = max(worstFromRest, simd_distance(p, mesh[Int(index)]))
            worstNormal = max(worstNormal, abs(simd_length(h.body.normals[slot]) - 1))
        }
        XCTAssertLessThan(worstBack, 1e-4, "the override is the particles in mesh space (off by \(worstBack) m)")
        XCTAssertLessThan(worstFromRest, 0.05, "on the bind pose the shirt is where the artist put it (off by \(worstFromRest) m)")
        XCTAssertLessThan(worstNormal, 1e-3, "unit normals")
        let excess = h.excess()
        XCTAssertTrue(excess.finite, "no particle is NaN")
        print("cloth attach: \(h.cloth.report)")
    }

    /// A particle off the mesh by a millimetre, a joint the skeleton lacks:
    /// nothing is built, nothing is written, the body is left as it was.
    func testAStaleSidecarLeavesTheGarmentBodySkinned() throws {
        guard let asset = Self.asset, let joints = Self.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        var mesh = asset.garment(named: "shirt")!.positions
        mesh[7].y += 0.001
        let moved = Harness(dt: dt, asset: asset, joints: joints, mesh: mesh)
        XCTAssertFalse(moved.attached, "a particle on no exported vertex refuses the garment")
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
        let missing = Harness(dt: dt, asset: asset, joints: lacking, ragdoll: false)
        XCTAssertFalse(missing.attached, "a joint the skeleton lacks refuses the garment")
        XCTAssertEqual(missing.physics.backend.bodyCount, 1)

        var off = ZombieCloth.Configuration()
        off.enabled = false
        let disabled = Harness(dt: dt, asset: asset, joints: joints, configuration: off, ragdoll: false)
        XCTAssertFalse(disabled.attached)
        XCTAssertEqual(disabled.body.begins, 0)
    }

    /// The binding passed but the body did not take the deformation
    /// component the override is written to: the soft body comes out again
    /// and nothing is written — the one failure the engine's write hides.
    func testABodyThatDoesNotTakeTheOverrideLeavesTheGarmentBodySkinned() throws {
        guard let asset = Self.asset, let joints = Self.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let refused = Harness(dt: dt, asset: asset, joints: joints, ragdoll: false, acceptsOverride: false)
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
        h.frames(200)
        let excess = h.excess()
        XCTAssertTrue(excess.finite)
        XCTAssertLessThan(excess.free, 0.005, "a particle strayed \(excess.free) m past its slack")
        XCTAssertLessThan(excess.pins, 1e-3, "a pin is \(excess.pins) m off the skin")
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

    /// On its skin alone the swaying shirt stays within its slack; on the
    /// default model the parts under it lag the swaying pose (the forearms,
    /// which carry the sleeves to the wrist, by 5 cm; the hands, which carry
    /// nothing, by 9) and push the cloth they pass through, so there the
    /// shirt strays past its slack by about a centimetre (1.1 cm, 2026-10-30)
    /// and is held to 2 cm — a fixed figure: a bound from the parts' own lag
    /// (5 cm and the particle's radius) would have passed the mannequin-sized
    /// spine capsules, which pushed the back 5 cm past its slack. The lag is
    /// printed with the figure.
    func testASwayingBodyKeepsTheShirtWithinItsSlack() throws {
        for (label, configuration, lagBound) in [("skin only", skinOnly, false), ("ragdoll and skin", ZombieCloth.Configuration(), true)] {
            let h = try makeHarness(configuration: configuration)
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
            if lagBound {
                XCTAssertLessThan(worstFree, 0.02, "\(label): a particle strayed \(worstFree) m past its slack while the parts lagged \(worstLag) m")
            } else {
                XCTAssertLessThan(worstFree, 0.005, "\(label): a particle strayed \(worstFree) m past its slack during the sway")
            }
            XCTAssertLessThan(worstPins, 1e-3, "\(label): a pin came \(worstPins) m off the skin during the sway")
            XCTAssertEqual(h.cloth.runawayCount, 0)
            print("cloth sway 3 s, \(label): worst excess \(worstFree) m, pins \(worstPins) m, parts lag up to \(worstLag) m (\(laggingPart)); \(h.cloth.report)")
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
        h.frames(100)
        let before = h.cloth.hardSkinCount
        // The entity jumps half a metre in the game update, as a reset or a
        // floor snap does: the ragdoll re-seats and the shirt with it.
        h.frame {
            h.body.world = Self.translation(SIMD3(0.5, 0, 0)) * h.body.world
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
            worstFromRest = max(worstFromRest, simd_distance(h.body.positions[slot], h.shirt.positions[Int(index)]))
        }
        XCTAssertLessThan(worstFromRest, 0.01, "the override stayed on the shirt (off by \(worstFromRest) m)")
        XCTAssertEqual(h.cloth.runawayCount, 0)
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
        h.physics.backend.didAddBody(entity: 500, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: 0.06), friction: 0.4, restitution: 0.1),
            mass: 0.2, layer: h.physics.configuration.ballLayer,
            position: aim + SIMD3(0, 0.01, 0.6), linearVelocity: SIMD3(0, 0, -5)
        ))
        var deepest: Float = 0
        for _ in 0 ..< 60 {
            h.frame()
            let p = h.particles, t = h.targets
            for index in near {
                deepest = max(deepest, simd_distance(p[index], t[index]) - before[index])
            }
        }
        XCTAssertGreaterThan(deepest, 0.02, "the ball dented the shirt by \(deepest) m")
        XCTAssertTrue(h.excess().finite)
        XCTAssertEqual(h.cloth.runawayCount, 0)
        print("cloth ball: dent \(deepest) m")
    }

    // MARK: - Sleep and range

    /// The shirt dropped onto its skin by the attach takes about a second to
    /// come to rest inside its slack; half a second of rest after that and
    /// the cloth sleeps.
    func testAStillBodyPutsTheClothToSleepAndAMovingJointWakesIt() throws {
        let h = try makeHarness(configuration: skinOnly)
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

    /// Asleep, nothing moves the shirt's particles any more (the body is
    /// out of Jolt's step, on a layer the parts do not meet), so the joints
    /// alone can wake it — and a body creeping under the threshold every
    /// frame never would, while its frozen override drifted off it. A
    /// sleeping cloth measures the joints from where they stood when it
    /// fell asleep as well: 0.4 mm a frame wakes it on the third frame.
    func testAJointCreepingUnderTheThresholdWakesTheSleepingCloth() throws {
        let h = try makeHarness(configuration: skinOnly)
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
        var configuration = ZombieCloth.Configuration()
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
        h.physics.backend.didAddBody(entity: 500, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: 0.06), friction: 0.4, restitution: 0.1),
            mass: 0.2, layer: h.physics.configuration.ballLayer,
            position: aim + SIMD3(0, 0.01, 0.6), linearVelocity: SIMD3(0, 0, -5)
        ))
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
        func regions(_ h: Harness) -> [String: Float] {
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

    // MARK: - The armhole in the chase's idle

    /// The pose of a bundled clip at a time, model space, sampled the way the
    /// clip-ground test samples it (translation and rotation keys interpolated
    /// on the rest transforms, parents first).
    private func clipPose(_ name: String, at time: Float) throws -> [simd_float4x4]? {
        guard let base = ZombieResources.baseURL, let joints = Self.skeleton else { return nil }
        let url = base.appendingPathComponent("Animations/\(name)/\(name).untold")
        guard FileManager.default.fileExists(atPath: url.path),
              let skeleton = try NativeFormatLoader().loadAssetSync(from: base.appendingPathComponent("Models/Zombie/Zombie.untold")).nodes.compactMap(\.skeleton).first,
              let clip = try NativeFormatLoader().loadAssetSync(from: url).animationClips.first else { return nil }
        let channels = Dictionary(uniqueKeysWithValues: clip.channels.map { ($0.jointPath, $0) })
        func value(_ keys: [RuntimeTranslationKeyframe]) -> SIMD3<Float>? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                return simd_mix(a.value, b.value, SIMD3(repeating: (time - a.time) / max(b.time - a.time, 1e-6)))
            }
            return keys.last!.value
        }
        func rotation(_ keys: [RuntimeRotationKeyframe]) -> simd_quatf? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return simd_normalize(simd_quatf(vector: first.value)) }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                return simd_slerp(simd_normalize(simd_quatf(vector: a.value)), simd_normalize(simd_quatf(vector: b.value)), (time - a.time) / max(b.time - a.time, 1e-6))
            }
            return simd_normalize(simd_quatf(vector: keys.last!.value))
        }
        var locals = skeleton.restTransforms
        for index in joints.jointPaths.indices {
            guard let channel = channels[joints.jointPaths[index]] else { continue }
            let rest = skeleton.restTransforms[index]
            var translation = simd_float3(rest.columns.3.x, rest.columns.3.y, rest.columns.3.z)
            var basis = simd_float3x3(
                simd_float3(rest.columns.0.x, rest.columns.0.y, rest.columns.0.z),
                simd_float3(rest.columns.1.x, rest.columns.1.y, rest.columns.1.z),
                simd_float3(rest.columns.2.x, rest.columns.2.y, rest.columns.2.z))
            if let t = value(channel.translations) { translation = t }
            if let q = rotation(channel.rotations) { basis = simd_float3x3(q) }
            locals[index] = simd_float4x4(simd_float4(basis.columns.0, 0), simd_float4(basis.columns.1, 0), simd_float4(basis.columns.2, 0), simd_float4(translation, 1))
        }
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: locals.count)
        for index in locals.indices {
            let parent = joints.parentIndices[index].map { model[$0] } ?? matrix_identity_float4x4
            model[index] = parent * locals[index]
        }
        return model
    }

    /// The chase's waiting idle holds the arms out in front. Skinned with the
    /// artist's weights, the shirt's armhole edges stretched to twenty times
    /// their length there, and the cloth, keeping its rest lengths, sat 13 cm
    /// from its skinned target under each arm whatever the solver did (the
    /// Mac readout's `target<=0.139m@(-0.18,1.25,-0.15)`; in this pose, with
    /// the fitted capsules, 16.3 cm). The lever is the weights: graded across
    /// the seams over 16 passes it was 9.4 cm, and with two hundred more over
    /// the 12 cm around the armhole (`grade_weight_seams`) it is 5.2 cm, at
    /// the yoke (2026-10-30). That is pinned here with the figure printed:
    /// the farthest particle under 7 cm from its target and no more than 4 cm
    /// past its slack. The capsules play no part: on the skin alone, with no
    /// part in the world to push anything, the figure is the same to a
    /// millimetre (9.44 against 9.43 cm before the deeper blur), and the test
    /// runs both models and holds them within a centimetre of each other. What
    /// remains is the targets': the sleeve's underside hangs between an arm
    /// that moved 40 cm and a flank that did not, the skinning stretches those
    /// edges and the cloth will not, so the particle rests short of a target
    /// it can reach (3-4 cm clear of the arm's capsule). A wider or deeper
    /// blur turns back up (6.7 cm at 300 passes over 11 cm, 7.1 at 400 over
    /// 12), and 13 cm or more puts arm weight within 20 cm of the pelvis; the
    /// 4 cm asked of this round is not reached by the sidecar's weights.
    func testTheArmsForwardIdleKeepsTheArmholeNearItsTarget() throws {
        guard let pose = try clipPose(ZombieResources.waitingClip, at: 1.0) else { throw XCTSkip("the idle clip is not bundled") }
        guard let joints = Self.skeleton, let hand = joints.jointPaths.firstIndex(of: "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l"),
              let pelvis = joints.jointPaths.firstIndex(of: "/root/pelvis") else { throw XCTSkip("no skeleton") }
        // The hands hang beside the hips in the bind pose and are held out in
        // the idle: they rise, and they leave the pelvis's side.
        let handRise = (pose[hand].columns.3.y - pose[pelvis].columns.3.y) - (joints.bindModelTransforms[hand].columns.3.y - joints.bindModelTransforms[pelvis].columns.3.y)
        print(String(format: "cloth arms-forward idle: pelvis (%.2f,%.2f,%.2f), hand (%.2f,%.2f,%.2f); bind hand (%.2f,%.2f,%.2f)",
                     pose[pelvis].columns.3.x, pose[pelvis].columns.3.y, pose[pelvis].columns.3.z, pose[hand].columns.3.x, pose[hand].columns.3.y, pose[hand].columns.3.z,
                     joints.bindModelTransforms[hand].columns.3.x, joints.bindModelTransforms[hand].columns.3.y, joints.bindModelTransforms[hand].columns.3.z))
        XCTAssertGreaterThan(handRise, 0.1, "the idle holds the hands up by \(handRise) m")
        var farthest: [String: Float] = [:]
        for (label, configuration) in [("skin only", skinOnly), ("ragdoll and skin", ZombieCloth.Configuration())] {
            let h = try makeHarness(configuration: configuration, pose: pose)
            h.frames(200)
            let p = h.particles, t = h.targets
            var worst: Float = 0, worstIndex = 0
            for index in p.indices {
                let d = simd_distance(p[index], t[index])
                if d > worst { worst = d; worstIndex = index }
            }
            let worstAt = h.shirt.positions[worstIndex], worstSlack = h.shirt.maxDistance[worstIndex]
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
            let excess = h.excess()
            print(String(format: "cloth arms-forward idle, %@: hands rise %.2f m; farthest particle %.3f m from its target (slack %.3f) at rest (%.2f,%.2f,%.2f), its target %+.3f m from the %@ capsule's surface; worst excess %.3f m, pins %.4f m; %@",
                         label, handRise, worst, worstSlack, worstAt.x, worstAt.y, worstAt.z, targetDepth, rig.partNames[nearest], excess.free, excess.pins, h.cloth.report))
            XCTAssertTrue(excess.finite)
            XCTAssertEqual(h.cloth.runawayCount, 0)
            XCTAssertLessThan(worst, 0.07, "\(label): a particle sits \(worst) m from its target in the arms-forward idle, at \(worstAt) on the shirt")
            XCTAssertLessThan(excess.free, 0.04, "\(label): a particle strayed \(excess.free) m past its slack in the arms-forward idle")
            farthest[label] = worst
        }
        XCTAssertEqual(farthest["skin only"] ?? 0, farthest["ragdoll and skin"] ?? 1, accuracy: 0.01, "the capsules change the arms-forward figure: \(farthest)")
    }

    // MARK: - Cost

    /// The skin feed and the read-back per frame over 300 frames of sway,
    /// and the step interval, printed for the headset budget.
    func testTimingsOverThreeHundredFrames() throws {
        let h = try makeHarness()
        var skin: [Double] = [], read: [Double] = [], step: [Double] = []
        for _ in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            let timings = h.cloth.timings
            skin.append(timings.skin)
            read.append(timings.readBack)
            step.append(timings.step)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean %.0f us, median %.0f us, max %.0f us", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted.last ?? 0)
        }
        print("cloth timing (300 frames, 100 Hz, 3 sub-steps, \(h.cloth.configuration.iterationsPerStep) iterations, \(h.shirt.particles.count) particles): skin \(stats(skin)); read-back \(stats(read)); step \(stats(step))")
        XCTAssertEqual(h.body.overrideWrites, 300)
    }

    // MARK: - The hosts' launch arguments

    /// `-cloth` and `-clothIterations` as both hosts parse them: the
    /// defaults hold through no arguments, an unknown model, a count that
    /// is not one and a flag with no value.
    func testTheLaunchArgumentsSetTheClothConfiguration() {
        let defaults = ZombieCloth.Configuration()
        var configuration = defaults
        configuration.apply(launchArguments: [])
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.collisionModel, .ragdollAndSkin)
        XCTAssertEqual(configuration.iterationsPerStep, 2, "the default is two iterations")
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
        configuration = defaults
        configuration.apply(launchArguments: ["-cloth", "wool", "-clothIterations", "0"])
        XCTAssertTrue(configuration.enabled, "an unknown model changes nothing")
        XCTAssertEqual(configuration.collisionModel, .ragdollAndSkin)
        XCTAssertEqual(configuration.iterationsPerStep, 2, "zero iterations is not a count")
        configuration.apply(launchArguments: ["-clothIterations", "many", "-cloth"])
        XCTAssertEqual(configuration.iterationsPerStep, 2, "nor is a word")
        XCTAssertTrue(configuration.enabled, "a flag with no value is ignored")
    }
}
