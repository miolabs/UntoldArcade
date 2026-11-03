//
//  ZombieClothSolver.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd

/// The seam between the cloth and whatever solves its particles. The
/// shirt's pipeline — the shell bound to the proxy, the vertex grid, the
/// joints placed every frame, the ramp and the hard skin, the range, the
/// sleep and the runaway, the report — is a thousand lines of `ZombieCloth`
/// that never touch the solver, and the solver itself was fourteen calls
/// into the Jolt backend: `addSoftBody`, `removeSoftBody`, `skinSoftBody`,
/// `setSoftBodySkin`, `readSoftBodyVertices` (twice), `isSoftBodyActive`,
/// `setSoftBodyActive`, `setSoftBodyLayer`, `addKinematicConvexHull`,
/// `setKinematicTransform`, `setKinematicTarget` and `removeKinematicBody`.
/// Those fourteen calls are this protocol, so a second solver — the GPU
/// XPBD one of `Docs/GPUCloth.md`, which the owner chose on 2026-11-03
/// after three headset rounds read the Jolt shirt as paper — can stand
/// behind the same thousand lines and the two can be A/B'd on the same
/// proxy, the same schedule, the same hulls and the same tests, switched
/// by `ZombieCloth.Configuration.solver`. A sibling `ZombieGPUCloth`
/// would have copied the thousand lines and let the two arms drift; an
/// abstraction in the Jolt plugin would have cost a plugin PR and a pin
/// before a line of GPU code existed. The seam sits inside `ZombieCloth`
/// instead, and `JoltClothSolver` carries the fourteen calls verbatim.
///
/// What each call stands for in the frame: `build` is the attach — the
/// proxy at the bind pose, relative to the entity's origin, plus the skin's
/// hulls — and `destroy` the detach; `feed` is `willStep`, inside the
/// physics step before the world advances, with this frame's joints, the
/// slack in force and the frame's delta; `hardSkin` is the attach, a
/// re-seat, the LOD's return or a runaway: every particle onto its skinned
/// position at rest; `beginFrame` is the top of the game update, after
/// Jolt has stepped (the balls it hands over are this frame's), which is
/// where the GPU solver encodes and commits and the Jolt one does nothing,
/// since Jolt stepped the body inside `backend.step`; `readPositions` is
/// the read-back at the game update's end, world space, where the GPU
/// solver waits for its command buffer once; `setResting` is the sleep
/// and the range, the body put to sleep on a layer nothing awake meets;
/// `isActive` is whether the solver is simulating the body (false while it
/// rests); and `stats` is the diagnostics line's solver-side figures, zeros
/// on Jolt. Frame thread only, like `ZombieCloth`.
public protocol ClothSolver: AnyObject {
    /// The garment into the solver at the bind pose, with its hulls; false
    /// when the solver refuses it (the cloth then prints why and leaves the
    /// garment body-skinned). A hull the solver refuses is skipped, not a
    /// refusal of the garment: `hullCount` says how many stand.
    func build(_ garment: ClothGarmentSetup, hulls: [ClothHullSetup]) -> Bool
    /// Everything `build` put in the world, out of it.
    func destroy()
    /// The particles the solver holds (0 before `build`, after `destroy`).
    var particleCount: Int { get }
    /// The skin's hulls standing in the solver's world.
    var hullCount: Int { get }
    /// Inside the physics step, before the world advances: this frame's
    /// joints into the skin, the hulls onto them, the slack for the step.
    func feed(_ feed: ClothFeed)
    /// Every particle onto its skinned position at rest and the slack shut:
    /// `feed` with `hard` and a multiplier of nought on the Jolt arm; on the
    /// GPU a CPU write of the position, previous and velocity buffers after
    /// a wait for anything in flight.
    func hardSkin(_ feed: ClothFeed)
    /// The top of the game update, after the physics step: the frame's
    /// work is encoded and committed here on the GPU, with the balls as
    /// spheres (the Jolt solver ignores them: its balls are Jolt bodies the
    /// layer matrix lets through).
    func beginFrame(spheres: [ClothSphere])
    /// The particles now, world space, into `positions` (resized to fit);
    /// the count read. The GPU solver waits for the frame's command buffer
    /// here, once.
    func readPositions(into positions: inout [SIMD3<Float>]) -> Int
    /// The particles and their face normals, for a garment drawn as its
    /// proxy (no shell; the trousers, phase 5).
    func readPositionsAndNormals(into positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>]) -> Int
    /// Asleep or out of range the body rests: nothing is solved, and on
    /// Jolt it sleeps on `layer`, where only the balls (resting) or nothing
    /// (inert) meets it. Awake it simulates on its model's layer. Called at
    /// the end of every frame, so a solver repeats nothing it already holds.
    func setResting(_ resting: Bool, layer: ClothRestLayer)
    /// Whether the solver is simulating the body: false while it rests, and
    /// true again when something woke it — a feed, or on Jolt a ball
    /// reaching a resting shirt, which the cloth counts.
    var isActive: Bool { get }
    /// The solver's own figures for the diagnostics line.
    var stats: ClothSolverStats { get }
}

/// One joint's pull on a particle: `joint` indexes the feed's joint arrays
/// (the garment's sidecar joints, thirteen on the shirt), `weight` its
/// share; one to four per particle, 2.60 on average on the shirt.
public struct ClothInfluence: Sendable {
    public var joint: UInt32
    public var weight: Float

    public init(joint: UInt32, weight: Float) {
        self.joint = joint
        self.weight = weight
    }
}

/// A garment as the solver builds it: the proxy at the bind pose, in the
/// world of the attach and relative to the entity's origin (the solver's
/// frame; the targets, the hulls, the floor and the balls then need no
/// change of space, and a particle's world position is the buffer plus the
/// origin), its faces, which the constraints are built from, the skin that
/// pulls it and the material it is solved with. Every per-particle array
/// has `bindPositions.count` entries.
public struct ClothGarmentSetup: Sendable {
    public var name: String
    /// The entity's origin in the world at the attach.
    public var origin: SIMD3<Float>
    /// The particles at the bind pose, relative to `origin`.
    public var bindPositions: [SIMD3<Float>]
    /// The proxy's triangles, wound counter-clockwise seen from outside:
    /// their normal is the skin's, and the back-stop lies behind it.
    public var faces: [SIMD3<UInt32>]
    /// 0 for a pin, 1 over the particle's mass otherwise (20,000 1/kg at
    /// the shirt's 50 mg).
    public var inverseMasses: [Float]
    public var influences: [[ClothInfluence]]
    /// How far each particle may stray from its skinned position, metres,
    /// the slack scale already applied; 0 is a pin.
    public var maxDistance: [Float]
    /// How far behind its skinned plane each particle may sit (1 mm on the
    /// shirt), or `.greatestFiniteMagnitude` for one of the `bodyFacing`
    /// particles, whose stop would lie away from the body.
    public var backstop: [Float]
    /// The particles whose faces point at the body (the rolled cuffs, the
    /// collar's inside; 148 on the shirt), which get no back-stop.
    public var bodyFacing: Set<Int>
    /// The joints' world transforms at the bind pose, one per feed joint:
    /// the skin matrix of a frame is its joint world times the inverse of
    /// this, which a solver takes once at the build.
    public var bindJointWorld: [simd_float4x4]
    /// Inverse stiffness of the edges, the shear and the bends, m/N
    /// (`ZombieCloth.Configuration`).
    public var stretchCompliance: Float
    public var shearCompliance: Float
    public var bendCompliance: Float
    /// The air's drag on the fabric, 1/s.
    public var linearDamping: Float
    /// Ceiling on a particle's speed, m/s.
    public var maxLinearVelocity: Float
    /// A particle's collision radius against the hulls and the world.
    public var vertexRadius: Float
    /// The cloth's friction against the world and the balls.
    public var friction: Float
    /// Jolt's solver iterations per step (its small steps); the GPU arm
    /// takes `gpuSubsteps` and `gpuIterations` from its configuration.
    public var iterations: UInt32
    /// The ragdoll's parts push the cloth and are never pushed back.
    public var oneWayAgainstRagdolls: Bool
    /// The engine collision layer the awake, in-range body is built on.
    public var layer: UInt32

    public init(name: String, origin: SIMD3<Float>, bindPositions: [SIMD3<Float>], faces: [SIMD3<UInt32>], inverseMasses: [Float],
                influences: [[ClothInfluence]], maxDistance: [Float], backstop: [Float], bodyFacing: Set<Int>, bindJointWorld: [simd_float4x4],
                stretchCompliance: Float, shearCompliance: Float, bendCompliance: Float, linearDamping: Float, maxLinearVelocity: Float,
                vertexRadius: Float, friction: Float, iterations: UInt32, oneWayAgainstRagdolls: Bool, layer: UInt32)
    {
        self.name = name
        self.origin = origin
        self.bindPositions = bindPositions
        self.faces = faces
        self.inverseMasses = inverseMasses
        self.influences = influences
        self.maxDistance = maxDistance
        self.backstop = backstop
        self.bodyFacing = bodyFacing
        self.bindJointWorld = bindJointWorld
        self.stretchCompliance = stretchCompliance
        self.shearCompliance = shearCompliance
        self.bendCompliance = bendCompliance
        self.linearDamping = linearDamping
        self.maxLinearVelocity = maxLinearVelocity
        self.vertexRadius = vertexRadius
        self.friction = friction
        self.iterations = iterations
        self.oneWayAgainstRagdolls = oneWayAgainstRagdolls
        self.layer = layer
    }
}

/// One of the skin's hulls (`ZombieClothAsset.Collider`): a convex hull on
/// a joint the garment is skinned to, moved with that joint every feed.
public struct ClothHullSetup: Sendable {
    /// The joint the hull follows, an index into the feed's joint arrays:
    /// the eleven hulls' joints — the pelvis, the three spine links, the
    /// neck, the clavicles, the upper and the lower arms — are all among
    /// the shirt's thirteen.
    public var joint: Int
    /// The hull's points in the joint's frame, 32 to 48 per hull.
    public var points: [SIMD3<Float>]
    /// The hull's friction against the cloth (`skinColliderFriction`, 0).
    public var friction: Float
    /// The engine collision layer the hull stands on (`skinColliderLayer`).
    public var layer: UInt32
    /// The joint's world transform at the build: where the hull stands
    /// until the first feed moves it.
    public var world: simd_float4x4

    public init(joint: Int, points: [SIMD3<Float>], friction: Float, layer: UInt32, world: simd_float4x4) {
        self.joint = joint
        self.points = points
        self.friction = friction
        self.layer = layer
        self.world = world
    }
}

/// What a feed hands the solver: this frame's joints and the last frame's
/// (the GPU solver slerps between them per substep so the skinned target
/// moves continuously inside the frame; Jolt interpolates on its own over
/// the first collision step), the slack multiplier in force (0 right after
/// a hard skin, out of range or in an unreached bind pose, 1 settled), the
/// frame's delta and whether the feed is a hard skin.
public struct ClothFeed: Sendable {
    /// The feed joints' world transforms, in the order of
    /// `ClothGarmentSetup.bindJointWorld`.
    public var jointWorld: [simd_float4x4]
    /// The same joints as fed last frame.
    public var previousJointWorld: [simd_float4x4]
    public var multiplier: Float
    public var deltaTime: Float
    public var hard: Bool

    public init(jointWorld: [simd_float4x4], previousJointWorld: [simd_float4x4], multiplier: Float, deltaTime: Float, hard: Bool) {
        self.jointWorld = jointWorld
        self.previousJointWorld = previousJointWorld
        self.multiplier = multiplier
        self.deltaTime = deltaTime
        self.hard = hard
    }
}

/// A ball as the GPU solver collides with it: its centre and velocity
/// after this frame's physics step (the kernel backs the centre along the
/// velocity to each substep's time), its radius.
public struct ClothSphere: Sendable {
    public var center: SIMD3<Float>
    public var radius: Float
    public var velocity: SIMD3<Float>

    public init(center: SIMD3<Float>, radius: Float, velocity: SIMD3<Float>) {
        self.center = center
        self.radius = radius
        self.velocity = velocity
    }
}

/// Where a body sits by the cloth's state, each with the engine collision
/// layer the Jolt arm puts it on: awake and in range on its model's layer
/// (the cloth layer, the one that meets the parts too, or the inert one
/// under `skinOnly`); asleep in range on the resting layer, which only the
/// balls meet, so a ball can wake it and a part inside the shirt cannot;
/// out of range, or any resting skin-only cloth, on the inert layer, where
/// nothing reaches it.
public enum ClothRestLayer: Sendable, Equatable {
    case awake(UInt32)
    case resting(UInt32)
    case inert(UInt32)

    /// The engine layer number.
    public var layer: UInt32 {
        switch self {
        case let .awake(layer), let .resting(layer), let .inert(layer): return layer
        }
    }
}

/// The solver's own figures for the diagnostics line (`gpu=`, `wait=`,
/// `lag=`, `onClamp=`): zeros on the Jolt arm, whose cost sits inside the
/// world's step and is read as `step=` instead.
public struct ClothSolverStats: Sendable {
    /// The GPU's time on the frame's command buffer, milliseconds.
    public var gpuMilliseconds: Double = 0
    /// What the first read waited for that buffer, microseconds.
    public var waitMicroseconds: Double = 0
    /// 0 when the read waits for this frame's work, 1 when it takes the
    /// last completed frame's (`-clothGPUWait off`).
    public var lagFrames: Int = 0
    /// Kernel dispatches this frame (none asleep or out of range).
    public var dispatches: Int = 0
    /// The share of free particles sitting on their slack ball at the
    /// frame's end, 0 to 1: whether the look is bounded by the schedule or
    /// by the solver.
    public var onClampShare: Float = 0
    /// The particles' bounds at the frame's end, world space.
    public var boundsMin: SIMD3<Float> = .zero
    public var boundsMax: SIMD3<Float> = .zero

    public init() {}
}
