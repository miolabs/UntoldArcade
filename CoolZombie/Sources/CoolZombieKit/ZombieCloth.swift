//
//  ZombieCloth.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os.signpost
import QuartzCore
import simd
import UntoldEngine
import UntoldJoltPhysics

/// What the cloth needs of the body wearing it. The demo's is the zombie
/// entity (`ZombieClothEntityBody`); the tests stand one in with the
/// sidecar's own particles as the mesh and an override that records what
/// it is given, so the binding and the write are proven without an engine.
public protocol ZombieClothBody: AnyObject {
    /// The rest positions of every vertex of the skinned mesh, in the space
    /// the skin matrices apply to (the mesh's), and the matrix the mesh is
    /// drawn with on top of the entity's. Nil when the mesh cannot be read.
    func meshGeometry() -> (positions: [SIMD3<Float>], localTransform: simd_float4x4)?
    /// This frame's displayed joint matrices, model space, skeleton order.
    func jointModelTransforms() -> [simd_float4x4]?
    /// The entity's model space to the world.
    func entityWorld() -> simd_float4x4
    /// Moves the body onto the path the override needs (compute skinning);
    /// false when the body did not take it, so the override would go nowhere.
    func beginOverride() -> Bool
    /// This frame's positions and normals for the given vertices, mesh space.
    func writeOverride(indices: [UInt32], positions: [SIMD3<Float>], normals: [SIMD3<Float>])
    /// Lets the mesh show its own skinning again.
    func clearOverride()
}

/// The zombie entity as the cloth's body. The mesh and the skeleton sit on
/// the entity or on the first descendant carrying both (a hierarchical
/// asset keeps them on a child); the zombie is one skinned primitive, so
/// the first mesh is the whole body.
public final class ZombieClothEntityBody: ZombieClothBody {
    public let entity: EntityID
    private var meshEntityStorage: EntityID?
    private let meshIndex = 0

    public init(entity: EntityID) {
        self.entity = entity
    }

    /// The entity holding the render and skeleton components, found once.
    public var meshEntity: EntityID? {
        if let meshEntityStorage { return meshEntityStorage }
        var stack = [entity]
        while let candidate = stack.popLast() {
            if scene.get(component: RenderComponent.self, for: candidate) != nil,
               scene.get(component: SkeletonComponent.self, for: candidate) != nil
            {
                meshEntityStorage = candidate
                return candidate
            }
            stack.append(contentsOf: getEntityChildren(parentId: candidate))
        }
        return nil
    }

    public func meshGeometry() -> (positions: [SIMD3<Float>], localTransform: simd_float4x4)? {
        guard let meshEntity, let geometry = entitySubmeshGeometry(entityId: meshEntity, meshIndex: meshIndex, submeshIndex: 0) else { return nil }
        return (geometry.positions, geometry.localTransform)
    }

    public func jointModelTransforms() -> [simd_float4x4]? {
        getJointModelTransforms(entityId: entity)
    }

    public func entityWorld() -> simd_float4x4 {
        scene.get(component: WorldTransformComponent.self, for: meshEntity ?? entity)?.space ?? matrix_identity_float4x4
    }

    public func beginOverride() -> Bool {
        setEntityDeformation(entityId: entity, skinningMode: .lbs)
        // The engine assigns the component to the skinned descendants and
        // says nothing when it cannot; the override is written to it, and
        // its write is silent too, so this is where its absence shows.
        guard let meshEntity else { return false }
        return scene.get(component: DeformationComponent.self, for: meshEntity) != nil
    }

    public func writeOverride(indices: [UInt32], positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        guard let meshEntity else { return }
        setEntityDeformationOverride(entityId: meshEntity, meshIndex: meshIndex, indices: indices, positions: positions, normals: normals)
    }

    public func clearOverride() {
        guard let meshEntity else { return }
        clearEntityDeformationOverride(entityId: meshEntity, meshIndex: meshIndex)
    }
}

/// The zombie's shirt as a Jolt soft body skinned to the skeleton, worn
/// over the powered ragdoll. The artist's shirt is in the exported mesh,
/// body-skinned like the rest; the cloth sidecar (`ZombieClothAsset`)
/// carries the same shirt as a particle proxy. At the reveal every
/// particle is bound to the exported vertices at its position, the proxy
/// becomes a soft body whose particles Jolt keeps within their slack of
/// where the skin puts them (and outside a back-stop behind the skin, the
/// body), and every frame the particles are read back and written over
/// the deformation pass's output for the vertices they drive — so the
/// shirt is the body's own skinning plus whatever the simulation adds:
/// swing, drape, a ball's dent, a hand dragging it.
///
/// The frame runs: the animation composes this frame's pose; the physics
/// step begins and `willStep` feeds that pose's joints to the skin (the
/// pose the body is drawn with — the step runs before the game update and
/// the override is written in it); Jolt steps; the game update sets the
/// ragdoll's pose on the mesh and last calls `readBack`, which reads the
/// particles, turns them into mesh space and writes the override the
/// deformation pass applies after the skinning, before the draws. The body
/// moves to compute skinning for that (`setEntityDeformation(.lbs)`); it
/// was vertex-shader skinned before, and that is the price of the override.
///
/// Whenever the body is put somewhere at once rather than moved — the
/// ragdoll re-seated on a pelvis jump or a stand-up, a reset, the bind-pose
/// inspection entered or left, the first frame — the cloth hard skins: every
/// particle onto its skinned position at rest, the slack then opening from
/// nothing over `rampDuration`. In the bind pose the slack stays shut until
/// the parts have reached the pose, so the shirt does not flail while the
/// body catches up. A still body (no joint moved, no particle moving) puts
/// the cloth to sleep after `sleepAfter`: no feed, no override, the last
/// override stays, until a joint moves or something moves the particles —
/// asleep, only their positions are read each frame, so a ball through a
/// sleeping shirt wakes it rather than denting Jolt's shirt under a frozen
/// one. Beyond `lodDistance` from the player the slack is shut and the
/// override cleared: the shirt is the body's skinning again, Jolt keeps the
/// particles on the skin for the return, and a far body that stands still
/// sleeps on its joints alone, so it stops feeding too. The joints' motion
/// is a frame's: a long frame runs as several sub-steps on one displayed
/// pose, and they are measured against the last frame, not each other.
/// Frame thread only, like `ZombiePhysics`.
public final class ZombieCloth: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// What the cloth collides with. `ragdollAndSkin` puts it on the
        /// cloth layer: the ragdoll's parts push it (one way), the balls
        /// dent it, the floor and the fallen body's furniture stop it.
        /// `skinOnly` puts it on a layer nothing meets: the skin's slack and
        /// back-stop alone shape it — the A/B that tells what the collisions
        /// cost and what they add.
        public enum CollisionModel: String, Sendable {
            case ragdollAndSkin
            case skinOnly
        }

        /// Off: the garments stay body-skinned and nothing is built.
        public var enabled = true
        /// The sidecar garments to simulate. The trousers are in the sidecar
        /// too and come in a later phase.
        public var garments: [String] = ["shirt"]
        public var collisionModel: CollisionModel = .ragdollAndSkin
        /// Jolt solver iterations per step; the demo steps at the display
        /// rate with three sub-steps.
        public var iterationsPerStep: UInt32 = 3
        /// Per particle, in kilograms: 50 mg makes the 4,000-particle shirt
        /// 0.2 kg.
        public var particleMass: Float = 0.00005
        /// Inverse stiffness of the edges, the shear and the (distance)
        /// bends, in m/N.
        public var stretchCompliance: Float = 1e-6
        public var shearCompliance: Float = 1e-5
        public var bendCompliance: Float = 5e-4
        /// Collision radius of a particle.
        public var vertexRadius: Float = 0.01
        public var linearDamping: Float = 2.5
        /// Ceiling on a particle's speed, m/s: bounds what a yanked pin or a
        /// resolved overlap can put into the body.
        public var maxLinearVelocity: Float = 4
        public var friction: Float = 0.5
        /// The ragdoll's parts push the cloth and the cloth never pushes
        /// them back.
        public var oneWayAgainstRagdolls = true
        /// After a hard skin the slack opens from nothing to the sidecar's
        /// over this long, so the particles ease off the skin.
        public var rampDuration: Float = 0.25
        /// The cloth sleeps once no joint has moved `jointMotionThreshold`
        /// metres in a frame and no particle faster than
        /// `particleSpeedThreshold` for `sleepAfter` seconds; asleep, the
        /// particles' positions are still read, and one faster than the
        /// threshold wakes it.
        public var sleepAfter: Float = 0.5
        public var jointMotionThreshold: Float = 0.001
        public var particleSpeedThreshold: Float = 0.02
        /// Farther than this from the player the slack is shut and nothing
        /// is read back or written; the simulation shows again once the
        /// player is back within `lodDistance - lodHysteresis`, so a player
        /// standing at the line does not flip it every frame.
        public var lodDistance: Float = 4
        public var lodHysteresis: Float = 0.5
        /// In the bind-pose inspection the slack stays shut until the
        /// ragdoll's worst part is within this of the pose.
        public var tposeTrackingThreshold: Float = 0.03
        /// A particle farther than this from the pelvis has run away (as
        /// has one that is not a number): the body is hard skinned.
        public var runawayDistance: Float = 2
        public init() {}
    }

    /// A particle binds to the exported vertices within this of its
    /// position: the exporter splits vertices on UV seams, several per
    /// particle, and nothing else lies within a fifth of a millimetre.
    static let bindTolerance: Float = 0.0002

    /// One garment's soft body and its binding to the mesh.
    private final class Garment {
        let name: String
        let soft: JoltSoftBody
        /// The particles at the bind pose, world space of the attach, and
        /// as the sidecar has them (model space), for the report.
        let bindWorld: [SIMD3<Float>]
        let restPositions: [SIMD3<Float>]
        let maxDistance: [Float]
        let pinCount: Int
        /// Sidecar joint -> skeleton joint.
        let skeletonJoints: [Int]
        /// Per sidecar joint, the inverse of the bind pose the body was
        /// created with (world space of the attach): the skin matrix is this
        /// frame's joint times it.
        let inverseBindWorld: [simd_float4x4]
        let influences: [[JoltSoftBodySkinInfluence]]
        /// The sidecar joint that is the pelvis (the runaway reference).
        let pelvisJoint: Int
        /// The override entries each particle drives, into the cloth's
        /// combined arrays.
        let overrideRanges: [Range<Int>]
        var jointWorld: [simd_float4x4]
        /// The last frame's joints, snapshotted at this frame's first
        /// placement: what the frame's motion is measured against, and the
        /// report's target motion.
        var previousJointWorld: [simd_float4x4]
        var previousJointPositions: [SIMD3<Float>]
        var worldPositions: [SIMD3<Float>] = []
        var worldNormals: [SIMD3<Float>] = []
        var previousWorldPositions: [SIMD3<Float>] = []

        init(name: String, soft: JoltSoftBody, bindWorld: [SIMD3<Float>], restPositions: [SIMD3<Float>], maxDistance: [Float], skeletonJoints: [Int],
             inverseBindWorld: [simd_float4x4], influences: [[JoltSoftBodySkinInfluence]], pelvisJoint: Int, overrideRanges: [Range<Int>])
        {
            self.name = name
            self.soft = soft
            self.bindWorld = bindWorld
            self.restPositions = restPositions
            self.maxDistance = maxDistance
            pinCount = maxDistance.filter { $0 == 0 }.count
            self.skeletonJoints = skeletonJoints
            self.inverseBindWorld = inverseBindWorld
            self.influences = influences
            self.pelvisJoint = pelvisJoint
            self.overrideRanges = overrideRanges
            jointWorld = Array(repeating: matrix_identity_float4x4, count: skeletonJoints.count)
            previousJointWorld = jointWorld
            previousJointPositions = Array(repeating: .zero, count: skeletonJoints.count)
        }

        var pelvisWorld: SIMD3<Float> {
            let c = jointWorld[pelvisJoint].columns.3
            return SIMD3(c.x, c.y, c.z)
        }

        /// Where the skin puts every particle for the joints last fed (or
        /// the feed before): the bridge's blend, done on the CPU (the report
        /// and the tests).
        func skinnedTargets(previous: Bool = false) -> [SIMD3<Float>] {
            let skin = zip(previous ? previousJointWorld : jointWorld, inverseBindWorld).map { $0 * $1 }
            return bindWorld.indices.map { index in
                let p = SIMD4<Float>(bindWorld[index], 1)
                var target = SIMD3<Float>.zero
                for influence in influences[index] {
                    let moved = skin[Int(influence.joint)] * p
                    target += influence.weight * SIMD3(moved.x, moved.y, moved.z)
                }
                return target
            }
        }
    }

    /// The exported vertices hashed into millimetre cells, for the binding.
    private struct VertexGrid {
        private let cell: Float = 0.001
        private var cells: [SIMD3<Int32>: [Int]] = [:]
        private let positions: [SIMD3<Float>]

        init(_ positions: [SIMD3<Float>]) {
            self.positions = positions
            for (index, p) in positions.enumerated() {
                cells[key(p), default: []].append(index)
            }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
        }

        /// The vertices within `distance` of `p`.
        func vertices(within distance: Float, of p: SIMD3<Float>) -> [Int] {
            let k = key(p)
            var found: [Int] = []
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                for index in cells[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(positions[index], p) <= distance {
                    found.append(index)
                }
            } } }
            return found
        }
    }

    public let configuration: Configuration
    private let asset: ZombieClothAsset
    private var body: (any ZombieClothBody)?
    private var physics: ZombiePhysics?
    private var jointInfo: SkeletonJointInfo?
    private var garments: [Garment] = []
    /// The mesh's own matrix on top of the entity's (identity for the
    /// zombie), folded into every model-to-world.
    private var localTransform = matrix_identity_float4x4
    private var previousWillStep: ((Float) -> Void)?
    private var previousDidReseat: (() -> Void)?
    /// Every garment's vertices in one write: the engine keeps one override
    /// per mesh, and the garments share the body's.
    private var overrideIndices: [UInt32] = []
    private var overridePositions: [SIMD3<Float>] = []
    private var overrideNormals: [SIMD3<Float>] = []

    private var pendingHardSkin = false
    /// The slack's share after the last hard skin, 0 to 1.
    private var ramp: Float = 1
    private var inBindPose = false
    private var bindPoseReached = false
    private var playerDistance: Float = 0
    private var lodActive = false
    private var asleep = false
    private var stillTime: Float = 0
    /// Whether a joint has moved this frame (`placeJoints`, ORed over the
    /// frame's sub-steps; `endFrame` starts it over).
    private var jointsMoved = true
    /// Whether this frame has placed its joints yet: the first placement
    /// snapshots the last frame's as the frame's reference.
    private var frameOpen = false
    private var maxParticleSpeed: Float = 0

    private var skinMicroseconds: Double = 0
    private var readBackMicroseconds: Double = 0
    private var worldMicroseconds: Double = 0
    private var willStepEnded: CFTimeInterval = 0
    private var updateBegan: CFTimeInterval = 0
    private let signpostLog = OSLog(subsystem: "com.untoldengine.coolzombie", category: "cloth")

    /// The sidecar's garments and how to run them.
    public init(asset: ZombieClothAsset, configuration: Configuration = Configuration()) {
        self.asset = asset
        self.configuration = configuration
    }

    // MARK: - Attach and detach

    /// Whether a garment is simulating.
    public var isAttached: Bool { !garments.isEmpty }
    /// The slack multiplier in force: 0 right after a hard skin, out of
    /// range or in a bind pose the parts have not reached; 1 settled.
    public private(set) var skinMultiplier: Float = 1
    /// Whether the sleep rule holds: nothing fed, read or written.
    public var isAsleep: Bool { asleep }
    /// Whether the player is beyond `lodDistance`.
    public var isBeyondRange: Bool { lodActive }
    /// Hard skins since the attach (the attach's own included), runaways
    /// caught, skin feeds from inside the step, and override writes.
    public private(set) var hardSkinCount = 0
    public private(set) var runawayCount = 0
    public private(set) var skinFeedCount = 0
    public private(set) var overrideWriteCount = 0

    /// Builds the garments on `entityId` — the zombie, revealed and with the
    /// ragdoll placed — in `physics`'s world. False when nothing attached.
    @discardableResult
    public func attach(entityId: EntityID, physics: ZombiePhysics, jointInfo: SkeletonJointInfo) -> Bool {
        attach(body: ZombieClothEntityBody(entity: entityId), physics: physics, jointInfo: jointInfo)
    }

    /// Binds every configured garment to the body's mesh and puts its soft
    /// body in the world at the bind pose, hard skinned onto this frame's
    /// pose before anything steps. A garment whose particles do not all sit
    /// on exported vertices, whose joints the skeleton lacks or whose counts
    /// disagree with the mesh is left alone — logged once and body-skinned
    /// as before — rather than driven wrong, and so is every garment when
    /// the body does not take the override. Frame thread, between steps.
    @discardableResult
    public func attach(body: any ZombieClothBody, physics: ZombiePhysics, jointInfo: SkeletonJointInfo) -> Bool {
        guard configuration.enabled, !isAttached else { return isAttached }
        guard let geometry = body.meshGeometry() else {
            print("CoolZombie: cloth: the mesh cannot be read; the garments stay body-skinned")
            return false
        }
        localTransform = geometry.localTransform
        let meshToWorld = body.entityWorld() * localTransform
        let grid = VertexGrid(geometry.positions)
        var built: [Garment] = []
        var indices: [UInt32] = []
        for name in configuration.garments {
            guard let garment = asset.garment(named: name) else {
                print("CoolZombie: cloth: the sidecar has no garment named \(name)")
                continue
            }
            if let garment = bind(garment, grid: grid, jointInfo: jointInfo, physics: physics, meshToWorld: meshToWorld, indices: &indices)
            {
                built.append(garment)
            }
        }
        guard !built.isEmpty else { return false }
        // The override needs the body on compute skinning; a body that did
        // not take it would show the skin alone over a simulating shirt.
        guard body.beginOverride() else {
            for garment in built { physics.backend.removeSoftBody(garment.soft) }
            print("CoolZombie: cloth: the body did not take the deformation component; the garments stay body-skinned")
            return false
        }
        garments = built
        overrideIndices = indices
        overridePositions = Array(repeating: .zero, count: indices.count)
        overrideNormals = Array(repeating: SIMD3<Float>(0, 1, 0), count: indices.count)
        self.body = body
        self.physics = physics
        self.jointInfo = jointInfo
        // The hooks, over whatever was there: the skin feed inside the step,
        // the re-seat from the ragdoll.
        previousWillStep = physics.backend.willStep
        physics.backend.willStep = { [weak self, previous = previousWillStep] deltaTime in
            previous?(deltaTime)
            self?.willStep(deltaTime: deltaTime)
        }
        previousDidReseat = physics.didReseat
        physics.didReseat = { [weak self, previous = previousDidReseat] in
            previous?()
            self?.requestHardSkin()
        }
        asleep = false
        stillTime = 0
        frameOpen = false
        jointsMoved = true
        lodActive = false
        inBindPose = false
        hardSkinCount = 0
        runawayCount = 0
        skinFeedCount = 0
        overrideWriteCount = 0
        // Onto the displayed pose before the first step; the next feed is
        // hard too, so the pose the step then runs on is a resting one. The
        // attach pose is the first frame's reference (the report would
        // otherwise measure the first frame's motion from the identity).
        hardSkinNow()
        snapshotJoints()
        frameOpen = false
        pendingHardSkin = true
        return true
    }

    /// Fails closed: nil, and one line, for anything that would drive the
    /// garment wrong — a particle on no exported vertex (a stale sidecar,
    /// another export), a joint the skeleton lacks, counts that disagree.
    private func bind(_ garment: ZombieClothAsset.Garment, grid: VertexGrid, jointInfo: SkeletonJointInfo,
                      physics: ZombiePhysics, meshToWorld: simd_float4x4, indices: inout [UInt32]) -> Garment?
    {
        let count = garment.particles.count
        func refuse(_ reason: String) -> Garment? {
            print("CoolZombie: cloth \(garment.name): \(reason); it stays body-skinned")
            return nil
        }
        guard count > 0 else { return refuse("no particles") }
        guard garment.influences.count == count, garment.maxDistance.count == count,
              garment.bindJointWorldMatrices.count == garment.jointPaths.count, !garment.jointPaths.isEmpty
        else { return refuse("its counts disagree") }
        var skeletonJoints: [Int] = []
        for path in garment.jointPaths {
            guard let index = jointInfo.jointPaths.firstIndex(of: path) else { return refuse("the skeleton has no joint \(path)") }
            skeletonJoints.append(index)
        }
        guard let pelvisJoint = garment.jointPaths.firstIndex(where: { $0.hasSuffix("/pelvis") }) else { return refuse("no pelvis among its joints") }

        // Every particle onto the exported vertices at its position.
        let positions = garment.positions
        var garmentIndices: [UInt32] = []
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(count)
        var unmatched = 0
        let base = indices.count
        for p in positions {
            let matches = grid.vertices(within: Self.bindTolerance, of: p)
            if matches.isEmpty { unmatched += 1 }
            let start = base + garmentIndices.count
            garmentIndices.append(contentsOf: matches.map { UInt32($0) })
            ranges.append(start ..< base + garmentIndices.count)
        }
        guard unmatched == 0 else { return refuse("\(unmatched) of \(count) particles sit on no exported vertex") }

        var faces: [SIMD3<UInt32>] = []
        faces.reserveCapacity(garment.triangles.count)
        for t in garment.triangles {
            guard t.count == 3, t.allSatisfy({ $0 >= 0 && $0 < count }) else { return refuse("a triangle indexes outside the particles") }
            faces.append(SIMD3(UInt32(t[0]), UInt32(t[1]), UInt32(t[2])))
        }
        var influences: [[JoltSoftBodySkinInfluence]] = []
        influences.reserveCapacity(count)
        for pairs in garment.influences {
            guard (1 ... 4).contains(pairs.count) else { return refuse("a particle is pulled by \(pairs.count) joints") }
            var list: [JoltSoftBodySkinInfluence] = []
            for pair in pairs {
                guard pair.count == 2, let joint = Int(exactly: pair[0]), joint >= 0, joint < garment.jointPaths.count else { return refuse("an influence names no joint") }
                list.append(JoltSoftBodySkinInfluence(joint: UInt32(joint), weight: pair[1]))
            }
            influences.append(list)
        }

        // The body at the bind pose, in the world: vertices relative to the
        // entity's origin, the bind matrices in the same frame.
        let origin = SIMD3(meshToWorld.columns.3.x, meshToWorld.columns.3.y, meshToWorld.columns.3.z)
        let bindWorld = positions.map { p -> SIMD3<Float> in
            let w = meshToWorld * SIMD4(p, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        let bindJointWorld = garment.bindMatrices.map { meshToWorld * $0 }
        var descriptor = JoltSoftBodyDescriptor(
            vertices: bindWorld.map { $0 - origin },
            inverseMasses: garment.maxDistance.map { $0 == 0 ? 0 : 1 / configuration.particleMass },
            faces: faces,
            compliance: configuration.stretchCompliance, shearCompliance: configuration.shearCompliance, bendCompliance: configuration.bendCompliance
        )
        descriptor.bendType = .distance
        descriptor.position = origin
        descriptor.layer = configuration.collisionModel == .skinOnly ? physics.configuration.inertLayer : physics.configuration.clothLayer
        descriptor.iterations = configuration.iterationsPerStep
        descriptor.linearDamping = configuration.linearDamping
        descriptor.vertexRadius = configuration.vertexRadius
        descriptor.friction = configuration.friction
        descriptor.maxLinearVelocity = configuration.maxLinearVelocity
        // Jolt never wakes a body for its skin; the sleep rule is ours.
        descriptor.allowSleeping = false
        descriptor.oneWayAgainstRagdolls = configuration.oneWayAgainstRagdolls
        // The back-stop lies behind the face; for the particles whose faces
        // point at the body (the rolled cuffs, the inside of the collar)
        // that is away from it, so they get none.
        let bodyFacing = Set(garment.bodyFacingParticles)
        descriptor.skin = JoltSoftBodySkin(bindJointWorldMatrices: bindJointWorld, vertices: (0 ..< count).map { index in
            var vertex = JoltSoftBodySkinnedVertex(vertex: UInt32(index), influences: influences[index], maxDistance: garment.maxDistance[index])
            vertex.backstopDistance = bodyFacing.contains(index) ? .greatestFiniteMagnitude : garment.backstop
            return vertex
        })
        guard let soft = physics.backend.addSoftBody(descriptor) else { return refuse("Jolt refused the soft body") }
        indices.append(contentsOf: garmentIndices)
        return Garment(
            name: garment.name, soft: soft, bindWorld: bindWorld, restPositions: positions, maxDistance: garment.maxDistance, skeletonJoints: skeletonJoints,
            inverseBindWorld: bindJointWorld.map(\.inverse), influences: influences, pelvisJoint: pelvisJoint, overrideRanges: ranges
        )
    }

    /// Removes the soft bodies, the hooks and the override. The hooks go
    /// back to what they were at the attach: the cloth is the last to chain
    /// onto `willStep` and `didReseat` (nothing else in the demo chains),
    /// so a link added after it would come off with it. Frame thread.
    public func detach() {
        guard let physics else { return }
        for garment in garments { physics.backend.removeSoftBody(garment.soft) }
        garments = []
        physics.backend.willStep = previousWillStep
        physics.didReseat = previousDidReseat
        previousWillStep = nil
        previousDidReseat = nil
        body?.clearOverride()
        body = nil
        self.physics = nil
        jointInfo = nil
        overrideIndices = []
        overridePositions = []
        overrideNormals = []
        pendingHardSkin = false
        ramp = 1
        skinMultiplier = 1
    }

    // MARK: - Events

    /// Every particle onto its skinned position at rest, now and again at
    /// the next step (whose pose may already differ), the slack opening from
    /// nothing after it; and awake. For the re-seats, the resets and the
    /// inspection changes. Frame thread, between steps.
    public func requestHardSkin() {
        pendingHardSkin = true
        asleep = false
        stillTime = 0
        if isAttached { hardSkinNow() }
    }

    /// The bind-pose inspection entered (`true`) or left: a hard skin either
    /// way, and while in it the slack stays shut until the parts have
    /// reached the pose.
    public func setInspectionBindPose(_ inspecting: Bool) {
        inBindPose = inspecting
        bindPoseReached = false
        requestHardSkin()
    }

    /// The top of the game update, right after the physics step: what lies
    /// between `willStep`'s end and here is Jolt's step and the
    /// coordinator's read-back, reported as the step time.
    public func beginUpdate() {
        updateBegan = CACurrentMediaTime()
    }

    // MARK: - Per frame

    /// This frame's joints into every garment's frame, and whether any of
    /// them has moved since the last frame. A frame longer than a step runs
    /// as several sub-steps, each calling this with the same displayed pose,
    /// so the frame's first call keeps the last frame's joints as the
    /// reference and every call compares against those, never against the
    /// last sub-step.
    private func placeJoints(_ model: [simd_float4x4], meshToWorld: simd_float4x4) -> Bool {
        if !frameOpen {
            frameOpen = true
            snapshotJoints()
        }
        var moved = false
        for garment in garments {
            for (k, joint) in garment.skeletonJoints.enumerated() where joint < model.count {
                let m = meshToWorld * model[joint]
                garment.jointWorld[k] = m
                let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                if simd_distance(p, garment.previousJointPositions[k]) >= configuration.jointMotionThreshold { moved = true }
            }
        }
        return moved
    }

    /// The joints as placed become the reference the next placements are
    /// measured against.
    private func snapshotJoints() {
        for garment in garments {
            for k in garment.jointWorld.indices {
                let m = garment.jointWorld[k]
                garment.previousJointWorld[k] = m
                garment.previousJointPositions[k] = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            }
        }
    }

    /// The frame's end (`readBack`, whatever it did): the next placement
    /// opens a new frame, and the motion flag starts over.
    private func endFrame() {
        frameOpen = false
        jointsMoved = false
    }

    private func hardSkinNow() {
        guard let body, let physics, let model = body.jointModelTransforms() else { return }
        _ = placeJoints(model, meshToWorld: body.entityWorld() * localTransform)
        for garment in garments {
            physics.backend.skinSoftBody(garment.soft, jointWorldMatrices: garment.jointWorld, hardSkinAll: true)
            physics.backend.setSoftBodySkin(garment.soft, maxDistanceMultiplier: 0)
        }
        ramp = 0
        skinMultiplier = 0
        hardSkinCount += 1
    }

    /// Inside the physics step, before Jolt runs: this frame's displayed
    /// pose into the skin, the slack for the step.
    private func willStep(deltaTime: Float) {
        guard let body, let physics, !garments.isEmpty, let model = body.jointModelTransforms() else { return }
        let started = CACurrentMediaTime()
        let signpost = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "cloth.skin", signpostID: signpost)
        defer {
            os_signpost(.end, log: signpostLog, name: "cloth.skin", signpostID: signpost)
            willStepEnded = CACurrentMediaTime()
            skinMicroseconds = (willStepEnded - started) * 1e6
        }
        let world = body.entityWorld()
        if placeJoints(model, meshToWorld: world * localTransform) { jointsMoved = true }
        if jointsMoved, asleep {
            asleep = false
            stillTime = 0
        }
        // Asleep, Jolt keeps the last feed: the joints have not moved.
        guard !asleep || pendingHardSkin else { return }
        let hard = pendingHardSkin
        pendingHardSkin = false
        if hard {
            ramp = 0
            hardSkinCount += 1
        } else {
            ramp = min(ramp + deltaTime / max(configuration.rampDuration, 1e-3), 1)
        }
        for garment in garments {
            physics.backend.skinSoftBody(garment.soft, jointWorldMatrices: garment.jointWorld, hardSkinAll: hard)
        }
        skinFeedCount += 1
        // The slack: the ramp's share, shut out of range and in a bind pose
        // the parts have not reached.
        var multiplier = ramp
        if lodActive { multiplier = 0 }
        if inBindPose, let jointInfo {
            if !bindPoseReached {
                let error = physics.trackingError(jointModelTransforms: jointInfo.bindModelTransforms, entityWorld: world)?.distance ?? 0
                bindPoseReached = error < configuration.tposeTrackingThreshold
            }
            if !bindPoseReached { multiplier = 0 }
        }
        skinMultiplier = multiplier
        for garment in garments {
            physics.backend.setSoftBodySkin(garment.soft, maxDistanceMultiplier: multiplier)
        }
    }

    /// The end of the game update: the particles off Jolt, into mesh space,
    /// over the vertices they drive. `playerPosition` sets the range for the
    /// next frame. Frame thread, between steps.
    public func readBack(deltaTime: Float, playerPosition: SIMD3<Float>?) {
        guard let body, !garments.isEmpty else { return }
        defer { endFrame() }
        let started = CACurrentMediaTime()
        if willStepEnded > 0 {
            worldMicroseconds = ((updateBegan > willStepEnded ? updateBegan : started) - willStepEnded) * 1e6
        }
        if let playerPosition, let first = garments.first {
            playerDistance = simd_distance(first.pelvisWorld, playerPosition)
        } else {
            playerDistance = 0
        }
        let far = lodActive
            ? playerDistance > configuration.lodDistance - configuration.lodHysteresis
            : playerDistance > configuration.lodDistance
        if far != lodActive {
            lodActive = far
            if far {
                // The body's own skinning shows; Jolt keeps the particles on
                // the skin meanwhile.
                body.clearOverride()
            } else {
                requestHardSkin()
            }
        }
        if far {
            // Nothing is read out of range, so the joints alone say whether
            // the body is still: a far body standing still stops feeding too.
            readBackMicroseconds = 0
            accumulateStillness(deltaTime: deltaTime, particlesStill: true)
            return
        }
        if asleep {
            // The joints have not moved, but something else may have moved
            // the particles — a ball through the hem — and the override on
            // screen would freeze while Jolt's shirt deforms: the positions
            // alone are read, and a particle on the move wakes the cloth.
            let speed = sampleParticleSpeed(deltaTime: deltaTime)
            guard speed >= configuration.particleSpeedThreshold else {
                readBackMicroseconds = (CACurrentMediaTime() - started) * 1e6
                return
            }
            asleep = false
            stillTime = 0
        }
        let signpost = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "cloth.readBack", signpostID: signpost)
        defer {
            os_signpost(.end, log: signpostLog, name: "cloth.readBack", signpostID: signpost)
            readBackMicroseconds = (CACurrentMediaTime() - started) * 1e6
        }
        let meshToWorld = body.entityWorld() * localTransform
        if let runaway = expandOverride(toMesh: meshToWorld.inverse, deltaTime: deltaTime) {
            runawayCount += 1
            print("CoolZombie: cloth runaway #\(runawayCount) (\(runaway)): hard skin")
            hardSkinNow()
            pendingHardSkin = true
            _ = expandOverride(toMesh: meshToWorld.inverse, deltaTime: 0)
        }
        body.writeOverride(indices: overrideIndices, positions: overridePositions, normals: overrideNormals)
        overrideWriteCount += 1
        accumulateStillness(deltaTime: deltaTime, particlesStill: maxParticleSpeed < configuration.particleSpeedThreshold)
    }

    /// The sleep rule: no joint moved this frame and the particles still,
    /// for `sleepAfter` in a row.
    private func accumulateStillness(deltaTime: Float, particlesStill: Bool) {
        if !jointsMoved, particlesStill {
            stillTime += max(deltaTime, 0)
            if stillTime >= configuration.sleepAfter { asleep = true }
        } else {
            stillTime = 0
        }
    }

    /// The fastest particle since the last read, from the positions alone
    /// (no normals, nothing expanded or written): the sleeping shirt's wake
    /// test. A particle that is not a number counts as infinitely fast, so
    /// the full read that follows catches it.
    private func sampleParticleSpeed(deltaTime: Float) -> Float {
        guard let physics, deltaTime > 0 else { return 0 }
        var maxSpeed: Float = 0
        for garment in garments {
            let read = physics.backend.readSoftBodyVertices(garment.soft, into: &garment.worldPositions)
            guard garment.previousWorldPositions.count == read else {
                garment.previousWorldPositions = garment.worldPositions
                continue
            }
            for index in 0 ..< read {
                let p = garment.worldPositions[index]
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return .infinity }
                maxSpeed = max(maxSpeed, simd_distance(p, garment.previousWorldPositions[index]) / deltaTime)
                garment.previousWorldPositions[index] = p
            }
        }
        maxParticleSpeed = maxSpeed
        return maxSpeed
    }

    /// Reads every garment and fills the override arrays, mesh space; the
    /// reason, when a particle has run away (nothing is filled then).
    private func expandOverride(toMesh: simd_float4x4, deltaTime: Float) -> String? {
        guard let physics else { return nil }
        // Normals turn by the inverse transpose of the position transform.
        let m = toMesh
        let normalMatrix = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        ).inverse.transpose
        var maxSpeed: Float = 0
        for garment in garments {
            let read = physics.backend.readSoftBodyVertices(garment.soft, into: &garment.worldPositions, normals: &garment.worldNormals)
            guard read == garment.bindWorld.count else { return "\(garment.name) read \(read) of \(garment.bindWorld.count) particles" }
            let pelvis = garment.pelvisWorld
            let hasPrevious = garment.previousWorldPositions.count == read
            for index in 0 ..< read {
                let p = garment.worldPositions[index]
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return "\(garment.name) particle \(index) is not a number" }
                let away = simd_distance(p, pelvis)
                guard away <= configuration.runawayDistance else { return String(format: "%@ particle %d is %.2f m from the pelvis", garment.name, index, away) }
                if hasPrevious, deltaTime > 0 {
                    maxSpeed = max(maxSpeed, simd_distance(p, garment.previousWorldPositions[index]) / deltaTime)
                }
            }
            if !hasPrevious { garment.previousWorldPositions = garment.worldPositions }
            for index in 0 ..< read {
                let p = garment.worldPositions[index]
                garment.previousWorldPositions[index] = p
                let local = toMesh * SIMD4(p, 1)
                let n = normalMatrix * garment.worldNormals[index]
                let length = simd_length(n)
                let normal = length > 1e-6 ? n / length : SIMD3<Float>(0, 1, 0)
                for slot in garment.overrideRanges[index] {
                    overridePositions[slot] = SIMD3(local.x, local.y, local.z)
                    overrideNormals[slot] = normal
                }
            }
        }
        maxParticleSpeed = maxSpeed
        return nil
    }

    // MARK: - Diagnostics

    /// One line on the simulation: the garments, their particles and pins,
    /// the slack in force, the sleep and range state, the microseconds of
    /// the skin feed and the read-back, the step interval (`willStep`'s end
    /// to the game update's start: Jolt's step and the coordinator's
    /// read-back), the farthest particle from its skinned target (with
    /// where it sits on the garment at rest, model space) and the fastest,
    /// how far the skinned targets moved over the last frame (what the
    /// cloth had to follow), and the hard skins, runaways and writes so far.
    /// It skins every particle on the CPU twice for the two distances, so
    /// it is for a once-a-second print; a readout refreshed every frame
    /// takes `summary`.
    public var report: String {
        guard isAttached else { return "cloth: none" }
        let names = garments.map(\.name).joined(separator: "+")
        let particles = garments.reduce(0) { $0 + $1.bindWorld.count }
        let pins = garments.reduce(0) { $0 + $1.pinCount }
        // The particles were last read while awake and in range; asleep or
        // out of range the figure would compare a stale read with fresh joints.
        var farthest = "—"
        var targetMotion: Float = 0
        if !asleep, !lodActive {
            var worst: Float = 0
            var at = SIMD3<Float>.zero
            for garment in garments where garment.worldPositions.count == garment.bindWorld.count {
                let targets = garment.skinnedTargets()
                let before = garment.skinnedTargets(previous: true)
                for index in targets.indices {
                    let distance = simd_distance(garment.worldPositions[index], targets[index])
                    if distance > worst {
                        worst = distance
                        at = garment.restPositions[index]
                    }
                    targetMotion = max(targetMotion, simd_distance(targets[index], before[index]))
                }
            }
            farthest = String(format: "%.3fm@(%.2f,%.2f,%.2f)", worst, at.x, at.y, at.z)
        }
        let state = (asleep ? "asleep" : "awake") + (lodActive ? " out of range" : "")
        return String(
            format: "cloth %@: %d particles (%d pins) mult=%.2f %@ skin=%.0fus read=%.0fus step=%.0fus target<=%@ speed<=%.2fm/s targetsMoved=%.3fm hard=%d runaway=%d writes=%d",
            names, particles, pins, skinMultiplier, state, skinMicroseconds, readBackMicroseconds, worldMicroseconds, farthest, maxParticleSpeed, targetMotion,
            hardSkinCount, runawayCount, overrideWriteCount
        )
    }

    /// The short form of `report` for a readout refreshed every frame (the
    /// headset's footnote): the garments and particles, the slack in force,
    /// the state, the three timings and the counters, and no pass over the
    /// particles.
    public var summary: String {
        guard isAttached else { return "cloth: none" }
        let names = garments.map(\.name).joined(separator: "+")
        let particles = garments.reduce(0) { $0 + $1.bindWorld.count }
        let state = (asleep ? "asleep" : "awake") + (lodActive ? " out of range" : "")
        return String(
            format: "cloth %@: %d particles mult=%.2f %@ skin=%.0fus read=%.0fus step=%.0fus hard=%d runaway=%d writes=%d",
            names, particles, skinMultiplier, state, skinMicroseconds, readBackMicroseconds, worldMicroseconds,
            hardSkinCount, runawayCount, overrideWriteCount
        )
    }

    /// The last frame's timings, microseconds (the tests print them).
    public var timings: (skin: Double, readBack: Double, step: Double) {
        (skinMicroseconds, readBackMicroseconds, worldMicroseconds)
    }

    /// The garments by name, for the tests and the report.
    public var garmentNames: [String] { garments.map(\.name) }

    /// The slack per particle of a garment, as built.
    func maxDistances(ofGarment index: Int) -> [Float] {
        garments.indices.contains(index) ? garments[index].maxDistance : []
    }

    /// The particles of a garment as Jolt has them now, world space.
    func particleWorldPositions(ofGarment index: Int) -> [SIMD3<Float>] {
        guard garments.indices.contains(index), let physics else { return [] }
        var positions: [SIMD3<Float>] = []
        physics.backend.readSoftBodyVertices(garments[index].soft, into: &positions)
        return positions
    }

    /// Where the skin puts a garment's particles for the joints last fed,
    /// world space.
    func skinnedTargets(ofGarment index: Int) -> [SIMD3<Float>] {
        garments.indices.contains(index) ? garments[index].skinnedTargets() : []
    }
}
