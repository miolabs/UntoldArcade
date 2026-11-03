//
//  ZombieClothJoltSolver.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import UntoldJoltPhysics

/// The Jolt arm of the seam: the garment as a Jolt soft body skinned to
/// the skeleton (`JoltSoftBodyDescriptor` with the sidecar's slack and
/// back-stop per particle) and the skin's hulls as kinematic convex hulls
/// on `skinColliderLayer`, moved with their joints every feed. The code is
/// what `ZombieCloth` did directly until 2026-11-03, moved here call for
/// call so the 28 cloth tests pass unchanged behind the protocol: the
/// soft body is built, fed, read, rested and removed exactly as before, the
/// hulls teleported and then targeted at every feed as before, and nothing
/// of the frame's order changed. Jolt steps the body inside `backend.step`,
/// so `beginFrame` has nothing to do here and the balls it is handed are
/// ignored: on this arm the balls are Jolt bodies the layer matrix lets
/// through to the cloth. Frame thread only.
final class JoltClothSolver: ClothSolver {
    /// One of the skin's colliders in the world (`ZombieClothAsset.Collider`):
    /// a kinematic convex hull on the feed joint it follows.
    private struct SkinCollider {
        let body: JoltKinematicBody
        /// An index into the feed's joint arrays.
        let joint: Int
    }

    private let physics: ZombiePhysics
    private var soft: JoltSoftBody?
    /// The skin's hulls, moved with their joints every feed (`moveHulls`).
    private var skinColliders: [SkinCollider] = []
    /// The engine layer the soft body sits on now (`setResting`), so the
    /// layer is set only when it changes.
    private var layer: UInt32?

    init(physics: ZombiePhysics) {
        self.physics = physics
    }

    var particleCount: Int { soft?.vertexCount ?? 0 }
    var hullCount: Int { skinColliders.count }
    var stats: ClothSolverStats { ClothSolverStats() }

    /// The soft body from the setup — the bind-pose particles relative to
    /// the origin, the constraints from the faces with the distance bend,
    /// never put to sleep by Jolt itself (Jolt never wakes a body for its
    /// skin; the sleep rule is the cloth's) — and then the hulls, each at
    /// its joint's world transform at the build (the bind pose when the
    /// body has no pose yet; the attach's hard skin moves them at once),
    /// frictionless. A hull Jolt refuses (not a hull, fewer than four
    /// points) is skipped and the cloth counts it from `hullCount`. False,
    /// and nothing built, when Jolt refuses the soft body.
    func build(_ garment: ClothGarmentSetup, hulls: [ClothHullSetup]) -> Bool {
        let count = garment.bindPositions.count
        var descriptor = JoltSoftBodyDescriptor(
            vertices: garment.bindPositions,
            inverseMasses: garment.inverseMasses,
            faces: garment.faces,
            compliance: garment.stretchCompliance, shearCompliance: garment.shearCompliance, bendCompliance: garment.bendCompliance
        )
        descriptor.bendType = .distance
        descriptor.position = garment.origin
        descriptor.layer = garment.layer
        descriptor.iterations = garment.iterations
        descriptor.linearDamping = garment.linearDamping
        descriptor.vertexRadius = garment.vertexRadius
        descriptor.friction = garment.friction
        descriptor.maxLinearVelocity = garment.maxLinearVelocity
        // Jolt never wakes a body for its skin; the sleep rule is ours.
        descriptor.allowSleeping = false
        descriptor.oneWayAgainstRagdolls = garment.oneWayAgainstRagdolls
        // The back-stop lies behind the face; for the particles whose faces
        // point at the body (the rolled cuffs, the inside of the collar)
        // that is away from it, so they get none (the setup's infinity).
        descriptor.skin = JoltSoftBodySkin(bindJointWorldMatrices: garment.bindJointWorld, vertices: (0 ..< count).map { index in
            var vertex = JoltSoftBodySkinnedVertex(
                vertex: UInt32(index),
                influences: garment.influences[index].map { JoltSoftBodySkinInfluence(joint: $0.joint, weight: $0.weight) },
                maxDistance: garment.maxDistance[index]
            )
            vertex.backstopDistance = garment.backstop[index]
            return vertex
        })
        guard let body = physics.backend.addSoftBody(descriptor) else { return false }
        soft = body
        for hull in hulls {
            let frame = Self.frame(of: hull.world)
            guard let kinematic = physics.backend.addKinematicConvexHull(
                points: hull.points, position: frame.position, rotation: frame.rotation, friction: hull.friction, layer: hull.layer
            ) else { continue }
            skinColliders.append(SkinCollider(body: kinematic, joint: hull.joint))
        }
        return true
    }

    /// The soft body and then the hulls out of the world.
    func destroy() {
        if let soft { physics.backend.removeSoftBody(soft) }
        soft = nil
        for collider in skinColliders { physics.backend.removeKinematicBody(collider.body) }
        skinColliders = []
        layer = nil
    }

    /// The hulls onto this frame's joints, where the skin's targets will
    /// stand for the step; then the joints into the skin (a hard feed puts
    /// every particle on its target at rest), then the slack for the step.
    /// The feed wakes a resting body in Jolt.
    func feed(_ feed: ClothFeed) {
        guard let soft else { return }
        moveHulls(feed.jointWorld)
        physics.backend.skinSoftBody(soft, jointWorldMatrices: feed.jointWorld, hardSkinAll: feed.hard)
        physics.backend.setSoftBodySkin(soft, maxDistanceMultiplier: feed.multiplier)
    }

    /// On Jolt a hard skin is a feed: the cloth hands one with `hard` set
    /// and the multiplier at nought, and the body's skin puts every
    /// particle on its target at rest.
    func hardSkin(_ feed: ClothFeed) {
        self.feed(feed)
    }

    /// Nothing: Jolt stepped the body inside `backend.step`, and its balls
    /// are the Jolt bodies on the ball layer.
    func beginFrame(spheres _: [ClothSphere]) {}

    func readPositions(into positions: inout [SIMD3<Float>]) -> Int {
        guard let soft else { return 0 }
        return physics.backend.readSoftBodyVertices(soft, into: &positions)
    }

    func readPositionsAndNormals(into positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>]) -> Int {
        guard let soft else { return 0 }
        return physics.backend.readSoftBodyVertices(soft, into: &positions, normals: &normals)
    }

    /// The body onto `layer` when it changes (the layer matrix then decides
    /// what meets it from the next step), and asleep or awake in Jolt:
    /// asleep, the step skips it altogether — no solve, no collision, no
    /// skinning — which is where the shirt's cost was.
    func setResting(_ resting: Bool, layer: ClothRestLayer) {
        guard let soft else { return }
        if layer.layer != self.layer {
            self.layer = layer.layer
            physics.backend.setSoftBodyLayer(soft, layer.layer)
        }
        physics.backend.setSoftBodyActive(soft, !resting)
    }

    var isActive: Bool {
        guard let soft else { return false }
        return physics.backend.isSoftBodyActive(soft)
    }

    /// Every hull onto its joint in `joints` (the feed's order): put there
    /// at once (`setKinematicTransform`) and then targeted there too
    /// (`setKinematicTarget`, a move of nothing over the step, which sets
    /// the body's velocity to nought — a teleport alone keeps the velocity
    /// of the last move, and the body would drift on through the step).
    /// Not moved as a kinematic target over the step, which the first
    /// version did on the idea that the move carried the arm's velocity
    /// into the fabric: Jolt's soft body never reads a kinematic collider's
    /// velocity (`ZombieCloth.Configuration.skinColliderFriction`), and a
    /// target is reached over the WHOLE step while the skin feed is
    /// complete after the first of the three collision steps (the targets
    /// interpolate previous to current over the first soft-body update's
    /// iterations alone), so a targeted hull trailed the skin by up to two
    /// thirds of the frame's joint motion — at the idle's 0.2-0.5 m/s and a
    /// 16.7 ms frame, 5.6 mm behind in the first collision step — and a
    /// hull a millimetre inside the skin stood proud on the trailing side
    /// of a moving arm. Teleported, it stands at this frame's pose for all
    /// three collision steps, where the skin's targets are; a hard skin
    /// needs nothing more. A resting cloth is not fed, so its hulls stand
    /// where the last feed left them: their layer meets no resting cloth,
    /// and the feed that wakes it moves them before the step.
    private func moveHulls(_ joints: [simd_float4x4]) {
        guard !skinColliders.isEmpty else { return }
        for collider in skinColliders where collider.joint < joints.count {
            let frame = Self.frame(of: joints[collider.joint])
            physics.backend.setKinematicTransform(collider.body, position: frame.position, rotation: frame.rotation)
            physics.backend.setKinematicTarget(collider.body, position: frame.position, rotation: frame.rotation)
        }
    }

    /// A joint's world transform as a rigid frame for Jolt: its translation
    /// and the rotation of its normalized axes (a scaled joint would
    /// otherwise skew the quaternion).
    private static func frame(of m: simd_float4x4) -> (position: SIMD3<Float>, rotation: simd_quatf) {
        let rotation = simd_quatf(simd_float3x3(
            columns: (
                simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            )
        ))
        return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), simd_normalize(rotation))
    }
}
