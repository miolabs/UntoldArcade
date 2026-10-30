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
//  The skin-following tests run the cloth on `skinOnly` with the powered
//  ragdoll in the world: on `ragdollAndSkin` the rig's torso capsules, sized
//  for the old model, reach 2-8 cm through the back of this shirt (the
//  spine_03 capsule, radius 0.14 at z -0.19, ends at z -0.33; the shirt's
//  back is at -0.25) and push the particles there off their skin, which
//  `testTheCapsuleFitOnTheDefaultModel` measures and prints. The pair the
//  controller makes with the cloth stays closed in both models; opened, a
//  debug Jolt asserts in CharacterVirtual's collide against the soft body.
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

    private static let asset: ZombieClothAsset? = try? ZombieClothAsset.loadBundled()

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
             acceptsOverride: Bool = true)
        {
            self.dt = dt
            self.joints = joints
            shirt = asset.garment(named: "shirt")!
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            settings.collisionSteps = 3
            settings.maxKinematicStep = 1.0
            settings.maxKinematicSpeed = 6.0
            settings.minContactSpeed = 0.35
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            physics = ZombiePhysics(backend: backend, configuration: ZombiePhysics.Configuration())
            physics.applyLayers()
            physics.setObstacles(obstacles, floor: 0)
            backend.step(deltaTime: dt)
            body = Body(mesh: mesh ?? shirt.positions, pose: joints.bindModelTransforms, world: world)
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
                             ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil) throws -> Harness
    {
        guard let asset = Self.asset, let joints = Self.skeleton else { throw XCTSkip("Models/Zombie is not bundled") }
        let harness = Harness(dt: dt, asset: asset, joints: joints, configuration: configuration, world: world, ragdoll: ragdoll, obstacles: obstacles, mesh: mesh)
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

    // MARK: - Following the skin

    func testAnIdleShirtStaysWithinItsSlackAndThePinsOnTheSkin() throws {
        let h = try makeHarness(configuration: skinOnly)
        h.frames(200)
        let excess = h.excess()
        XCTAssertTrue(excess.finite)
        XCTAssertLessThan(excess.free, 0.005, "a particle strayed \(excess.free) m past its slack")
        XCTAssertLessThan(excess.pins, 1e-3, "a pin is \(excess.pins) m off the skin")
        XCTAssertEqual(h.cloth.skinMultiplier, 1, "the ramp is over")
        print("cloth idle 2 s: \(h.cloth.report)")
    }

    func testASwayingBodyKeepsTheShirtWithinItsSlack() throws {
        let h = try makeHarness(configuration: skinOnly)
        var worstFree: Float = -1, worstPins: Float = 0
        for frame in 0 ..< 300 {
            let t = h.time + h.dt
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * t), 0, 0))
            h.frame()
            if frame % 10 == 9 {
                let excess = h.excess()
                XCTAssertTrue(excess.finite, "frame \(frame): a particle is NaN")
                worstFree = max(worstFree, excess.free)
                worstPins = max(worstPins, excess.pins)
            }
        }
        XCTAssertLessThan(worstFree, 0.005, "a particle strayed \(worstFree) m past its slack during the sway")
        XCTAssertLessThan(worstPins, 1e-3, "a pin came \(worstPins) m off the skin during the sway")
        XCTAssertEqual(h.cloth.runawayCount, 0)
        print("cloth sway 3 s: worst excess \(worstFree) m, pins \(worstPins) m; \(h.cloth.report)")
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
        h.frames(250)
        XCTAssertTrue(h.cloth.isAsleep, "a still body for 2.5 s: asleep (\(h.cloth.report))")
        let writes = h.body.overrideWrites, feeds = h.cloth.skinFeedCount
        XCTAssertLessThan(writes, 250, "the writes stopped before the 2.5 s were up")
        h.frames(50)
        XCTAssertEqual(h.body.overrideWrites, writes, "asleep, nothing is written")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "nor fed")
        // A centimetre of motion wakes it.
        h.body.pose = h.pose(offset: SIMD3(0.01, 0, 0))
        h.frame()
        XCTAssertFalse(h.cloth.isAsleep)
        XCTAssertEqual(h.body.overrideWrites, writes + 1, "awake, the override is written again")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds + 1, "and the skin is fed again")
        h.frames(20)
        XCTAssertEqual(h.body.overrideWrites, writes + 21)
        XCTAssertLessThan(h.excess().free, 0.005)
        print("cloth sleep: asleep after \(writes) frames; \(h.cloth.report)")
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
        let writes = h.body.overrideWrites
        h.frames(50, playerPosition: far)
        XCTAssertEqual(h.body.overrideWrites, writes, "nothing is read back out of range")
        var worst: Float = 0
        for (p, t) in zip(h.particles, h.targets) { worst = max(worst, simd_distance(p, t)) }
        XCTAssertLessThan(worst, 1e-3, "the particles ride on the skin meanwhile (worst \(worst) m)")
        // Far and still for longer than the sleep rule asks: the feed stops
        // too, on the joints alone (nothing is read out of range).
        XCTAssertTrue(h.cloth.isAsleep, "far and still, the cloth sleeps (\(h.cloth.report))")
        let feeds = h.cloth.skinFeedCount
        h.frames(20, playerPosition: far)
        XCTAssertEqual(h.cloth.skinFeedCount, feeds, "asleep out of range, nothing is fed")
        // Far and moving: awake, fed every step, still nothing written.
        for _ in 0 ..< 60 {
            h.body.pose = h.pose(offset: SIMD3(0.1 * sin(2 * Float.pi * h.time), 0, 0))
            h.frame(playerPosition: far)
        }
        XCTAssertFalse(h.cloth.isAsleep, "a far body that moves stays awake")
        XCTAssertEqual(h.cloth.skinFeedCount, feeds + 60, "and is fed every step")
        XCTAssertEqual(h.body.overrideWrites, writes, "but nothing is written out of range")
        h.body.pose = h.joints.bindModelTransforms
        // Back in range: the override returns and the slack opens again.
        h.frames(50, playerPosition: near)
        XCTAssertFalse(h.cloth.isBeyondRange)
        XCTAssertGreaterThan(h.body.overrideWrites, writes)
        XCTAssertEqual(h.cloth.skinMultiplier, 1)
    }

    // MARK: - The collision model

    /// The A/B the configuration offers, measured on the model as it is: on
    /// its skin alone the idle shirt stays within its slack everywhere; with
    /// the ragdoll's parts colliding, the particles the torso capsules reach
    /// through (the back, mostly) are pushed off their skin by the capsules'
    /// overshoot, printed per region for the rig's tuning.
    func testTheCapsuleFitOnTheDefaultModel() throws {
        func regions(_ h: Harness) -> String {
            let p = h.particles, t = h.targets
            var worst: [String: Float] = [:]
            for index in p.indices where h.shirt.maxDistance[index] > 0 {
                let rest = h.shirt.positions[index]
                let region = rest.y < 1.0 ? "hem" : (abs(rest.x) > 0.2 ? "sleeves" : (rest.z < -0.17 ? "back" : "front"))
                worst[region] = max(worst[region] ?? -1, simd_distance(p[index], t[index]) - h.shirt.maxDistance[index])
            }
            return worst.sorted { $0.key < $1.key }.map { String(format: "%@ %+.3f m", $0.key, $0.value) }.joined(separator: ", ")
        }
        let alone = try makeHarness(configuration: skinOnly)
        alone.frames(100)
        let aloneExcess = alone.excess()
        XCTAssertTrue(aloneExcess.finite)
        XCTAssertLessThan(aloneExcess.free, 0.005)
        print("cloth fit, skin only: worst excess \(aloneExcess.free) m; \(regions(alone))")

        let colliding = try makeHarness()
        colliding.frames(100)
        let collidingExcess = colliding.excess()
        XCTAssertTrue(collidingExcess.finite, "the colliding shirt is finite")
        XCTAssertEqual(colliding.cloth.runawayCount, 0)
        XCTAssertLessThan(collidingExcess.free, 0.1, "the capsules push the shirt \(collidingExcess.free) m past its slack")
        print("cloth fit, ragdoll and skin: worst excess \(collidingExcess.free) m; \(regions(colliding)); \(colliding.cloth.report)")
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
        print("cloth timing (300 frames, 100 Hz, 3 sub-steps, \(h.shirt.particles.count) particles): skin \(stats(skin)); read-back \(stats(read)); step \(stats(step))")
        XCTAssertEqual(h.body.overrideWrites, 300)
    }
}
