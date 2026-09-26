//
//  CoolMirrorJoltCape.swift
//  CoolMirror
//
//  Batman's own cape mesh as cloth: its vertices become a Jolt soft body
//  (XPBD with stretch, shear and dihedral bend constraints from the
//  triangles), the collar vertices ride on the shoulder joints, capsules
//  on the bones keep the cloth off the body, and every frame the
//  particles' positions are written over the skinned mesh through the
//  engine's deformation override. The cape keeps its authored silhouette,
//  texture and shading.
//

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// Lock-protected; `update()` runs on the render thread.
final class CoolMirrorJoltCape: @unchecked Sendable {
    /// Cloth stiffness (inverse): stretch, shear and bend.
    private static let stretchCompliance: Float = 2e-6
    private static let shearCompliance: Float = 2e-5
    private static let bendCompliance: Float = 4e-4
    private static let particleMass: Float = 0.02
    /// A vertex whose skin weight on the collar joints is at least this is
    /// pinned to them.
    private static let collarWeight: Float = 0.45
    /// A particle farther than this from the character is a blown-up cloth.
    private static let runawayDistance: Float = 3.0
    /// Ceiling on a particle's speed: a cape never needs more, and it
    /// bounds what a resolved overlap or a tracking jump can throw in.
    static let maxParticleSpeed: Float = 4.0

    private struct Slot {
        var entity: EntityID
        var mesh: Int
        var submesh: Int
    }

    private struct Collider {
        var body: JoltKinematicBody
        var from: String
        var to: String
        var radius: Float
    }

    private struct Piece {
        var slot: Slot
        var body: JoltSoftBody
        var cloth: CoolMirrorCapeCloth
    }

    private let lock = NSLock()
    private var backend: JoltPhysicsBackend?
    private var characterId: EntityID?
    private var rig: CoolMirrorCapeRig?
    private var enabled = false
    private var pieces: [Piece] = []
    private var colliders: [Collider] = []
    private var jointIndexByName: [String: Int] = [:]
    private var built = false
    private var scratchPositions: [SIMD3<Float>] = []
    private var lastReport: TimeInterval = 0

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func setBackend(_ backend: JoltPhysicsBackend?) {
        lock.withLock { self.backend = backend }
    }

    func setCharacter(_ id: EntityID?, character: CoolMirrorCharacter?) {
        tearDown()
        lock.withLock {
            characterId = id
            rig = character.flatMap { CoolMirrorCapeRig.rig(for: $0) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = lock.withLock { () -> Bool in
            let was = self.enabled
            self.enabled = enabled
            return was
        }
        if wasEnabled, !enabled {
            tearDown()
        }
    }

    /// Render-thread step: builds the cloth once the skeleton is live, then
    /// moves the collar and the colliders and writes the cloth back.
    func update(deltaTime _: Float) {
        let (enabled, characterId, rig, backend, built) = lock.withLock {
            (self.enabled, self.characterId, self.rig, self.backend, self.built)
        }
        guard enabled, let characterId, let rig, let backend else { return }
        let joints = entitySkeletonJointPoses(entityId: characterId)
        guard !joints.isEmpty else { return }
        // A glitched joint must not reach the physics world: a non-finite
        // pin or collider target poisons Jolt's broadphase and crashes it.
        guard joints.allSatisfy({ $0.worldPosition.x.isFinite && $0.worldPosition.y.isFinite && $0.worldPosition.z.isFinite && $0.worldRotation.vector.x.isFinite && $0.worldRotation.vector.w.isFinite }) else { return }
        let origin = getPosition(entityId: characterId)
        let rotation = getRotationQuaternion(entityId: characterId)
        let scale = getScale(entityId: characterId)
        // The character's transform (uniform scale composes after skinning):
        // rest data goes to world through it, particles come back through
        // its inverse.
        var modelToWorld = simd_float4x4(rotation)
        modelToWorld.columns.0 *= scale.x
        modelToWorld.columns.1 *= scale.y
        modelToWorld.columns.2 *= scale.z
        modelToWorld.columns.3 = simd_float4(origin, 1)
        let worldToModel = simd_inverse(modelToWorld)
        // The skeleton query answers the rest transforms until the first
        // animation update: wait for joints that sit on the character.
        guard let neck = joints.first(where: { Self.matches($0.path, rig.neck) }),
              abs(neck.worldPosition.y - origin.y) > 0.6, abs(neck.worldPosition.y - origin.y) < 2.3,
              simd_length(simd_float2(neck.worldPosition.x - origin.x, neck.worldPosition.z - origin.z)) < 2.5
        else { return }

        if !built {
            build(characterId: characterId, rig: rig, backend: backend, joints: joints, modelToWorld: modelToWorld, rotation: rotation)
        }
        let (pieces, colliders, jointIndexByName) = lock.withLock { (self.pieces, self.colliders, self.jointIndexByName) }
        guard !pieces.isEmpty else { return }

        // Colliders follow the bones.
        for collider in colliders {
            guard let a = jointIndexByName[collider.from], let b = jointIndexByName[collider.to],
                  a < joints.count, b < joints.count
            else { continue }
            let (position, orientation) = Self.capsulePose(from: joints[a].worldPosition, to: joints[b].worldPosition)
            backend.setKinematicTarget(collider.body, position: position, rotation: orientation)
        }

        // The collar rides on its joints.
        let frames = joints.map { CoolMirrorCapeCloth.JointFrame(position: $0.worldPosition, rotation: $0.worldRotation) }
        for piece in pieces {
            backend.setSoftBodyVertices(piece.body, indices: piece.cloth.pinned, worldPositions: piece.cloth.pinTargets(joints: frames))
        }

        // Read the cloth back into the mesh (model space).
        for piece in pieces {
            var world = lock.withLock { scratchPositions }
            let read = backend.readSoftBodyVertices(piece.body, into: &world)
            guard read == piece.cloth.particleRest.count else { continue }
            // A runaway cloth (a bad step, a teleport) is rebuilt in the
            // current pose rather than left to blow up Jolt's broadphase.
            if world.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) || simd_length($0 - origin) > Self.runawayDistance }) {
                print("CoolMirror jolt cape: cloth ran away; rebuilding it in the current pose")
                tearDown()
                return
            }
            var normals = [SIMD3<Float>](repeating: .zero, count: piece.cloth.particleRest.count)
            for face in piece.cloth.faces {
                let a = world[Int(face.x)], b = world[Int(face.y)], c = world[Int(face.z)]
                let n = simd_cross(b - a, c - a)
                normals[Int(face.x)] += n
                normals[Int(face.y)] += n
                normals[Int(face.z)] += n
            }
            var positions: [simd_float3] = []
            var vertexNormals: [simd_float3] = []
            positions.reserveCapacity(piece.cloth.vertexIds.count)
            vertexNormals.reserveCapacity(piece.cloth.vertexIds.count)
            for particle in piece.cloth.particleOfVertex {
                let p = worldToModel * simd_float4(world[Int(particle)], 1)
                positions.append(simd_float3(p.x, p.y, p.z))
                let n = normals[Int(particle)]
                vertexNormals.append(rotation.inverse.act(simd_length_squared(n) > 1e-12 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)))
            }
            setEntityDeformationOverride(
                entityId: piece.slot.entity, meshIndex: piece.slot.mesh,
                indices: piece.cloth.vertexIds, positions: positions, normals: vertexNormals
            )
            lock.withLock { scratchPositions = world }
            report(world: world, origin: origin)
        }
    }

    // MARK: - Build

    private func build(characterId: EntityID, rig: CoolMirrorCapeRig, backend: JoltPhysicsBackend, joints: [SkeletonJointPose], modelToWorld: simd_float4x4, rotation: simd_quatf) {
        lock.withLock { built = true }
        // Rest joints in world space (the entity's transform applied).
        let restJoints: [CoolMirrorCapeCloth.JointFrame] = entitySkeletonRestJointPoses(entityId: characterId).map { joint in
            let p = modelToWorld * simd_float4(joint.modelPosition, 1)
            return .init(position: simd_float3(p.x, p.y, p.z), rotation: simd_normalize(rotation * joint.modelRotation))
        }
        var jointIndexByName: [String: Int] = [:]
        for (index, joint) in joints.enumerated() {
            if let name = joint.path.split(separator: "/").last {
                jointIndexByName[String(name)] = index
            }
            jointIndexByName[joint.path] = index
        }
        let collarJoints = Set([rig.neck, rig.upperChest, rig.leftClavicle, rig.rightClavicle, rig.head].compactMap { jointIndexByName[$0] })

        let startCapsules = Self.capsules(rig, joints: joints, jointIndexByName: jointIndexByName)
        var pieces: [Piece] = []
        for slot in Self.capeSlots(root: characterId) {
            guard let geometry = entitySubmeshGeometry(entityId: slot.entity, meshIndex: slot.mesh, submeshIndex: slot.submesh),
                  !geometry.triangles.isEmpty
            else { continue }
            guard let piece = makePiece(
                slot: slot, geometry: geometry, backend: backend, restJoints: restJoints, joints: joints,
                collarJoints: collarJoints, modelToWorld: modelToWorld, startCapsules: startCapsules
            ) else { continue }
            pieces.append(piece)
        }

        var colliders: [Collider] = []
        for (from, to, radius) in Self.bones(rig) {
            guard let a = jointIndexByName[from], let b = jointIndexByName[to] else { continue }
            let (position, orientation) = Self.capsulePose(from: joints[a].worldPosition, to: joints[b].worldPosition)
            let length = simd_length(joints[b].worldPosition - joints[a].worldPosition)
            guard let body = backend.addKinematicCapsule(radius: radius, height: max(length + 2 * radius, 2 * radius + 0.01), position: position, rotation: orientation) else { continue }
            colliders.append(Collider(body: body, from: from, to: to, radius: radius))
        }

        lock.withLock {
            self.pieces = pieces
            self.colliders = colliders
            self.jointIndexByName = jointIndexByName
        }
        print("CoolMirror jolt cape: \(pieces.count) cape piece(s), \(pieces.reduce(0) { $0 + $1.cloth.particleRest.count }) particles, \(pieces.reduce(0) { $0 + $1.cloth.pinned.count }) pinned, \(colliders.count) colliders")
    }

    /// Builds the slot's cloth (see `CoolMirrorCapeCloth`) and its soft body.
    private func makePiece(
        slot: Slot, geometry: EntitySubmeshGeometry, backend: JoltPhysicsBackend, restJoints: [CoolMirrorCapeCloth.JointFrame],
        joints: [SkeletonJointPose], collarJoints: Set<Int>, modelToWorld: simd_float4x4, startCapsules: [CoolMirrorCapeCloth.Capsule]
    ) -> Piece? {
        // Rest vertices in world space, like the rest joints.
        let toWorld = modelToWorld * geometry.localTransform
        let positions = geometry.positions.map { p -> simd_float3 in
            let m = toWorld * simd_float4(p, 1)
            return simd_float3(m.x, m.y, m.z)
        }
        var cloth = CoolMirrorCapeCloth(
            positions: positions, normals: geometry.normals, triangles: geometry.triangles,
            jointIndices: geometry.jointIndices, jointWeights: geometry.jointWeights,
            restJoints: restJoints,
            joints: joints.map { .init(position: $0.worldPosition, rotation: $0.worldRotation) },
            collarJoints: collarJoints, collarWeight: Self.collarWeight,
            particleMass: Self.particleMass
        )
        print("CoolMirror jolt cape: \(cloth.stats)")
        guard !cloth.faces.isEmpty else { return nil }
        cloth.pushStartOut(of: startCapsules, margin: 0.012)

        let origin = simd_float3(modelToWorld.columns.3.x, modelToWorld.columns.3.y, modelToWorld.columns.3.z)
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cloth.startWorld.map { $0 - origin },
            inverseMasses: cloth.inverseMasses,
            faces: cloth.faces,
            compliance: Self.stretchCompliance, shearCompliance: Self.shearCompliance, bendCompliance: Self.bendCompliance
        )
        descriptor.position = origin
        // 4 iterations and 2 Jolt sub-steps hold (the headless scenario
        // sweeps this) at a third of the solver cost of 8 × 3; the damping
        // keeps the cape from swinging on every tracker wobble.
        descriptor.iterations = 4
        descriptor.linearDamping = 2.0
        descriptor.vertexRadius = 0.008
        descriptor.friction = 0.5
        descriptor.maxLinearVelocity = Self.maxParticleSpeed
        // Dihedral bends diverge under a moving collar (the headless cape
        // test shows 3.7 m of fling in a second, at any iteration count);
        // distance bends hold at 4 iterations.
        descriptor.bendType = .distance
        guard let body = backend.addSoftBody(descriptor) else {
            print("CoolMirror jolt cape: Jolt rejected the cape soft body (\(cloth.particleRest.count) particles, \(cloth.faces.count) faces)")
            return nil
        }
        return Piece(slot: slot, body: body, cloth: cloth)
    }

    private func tearDown() {
        let (backend, pieces, colliders) = lock.withLock { () -> (JoltPhysicsBackend?, [Piece], [Collider]) in
            let state = (self.backend, self.pieces, self.colliders)
            self.pieces = []
            self.colliders = []
            built = false
            return state
        }
        for piece in pieces {
            backend?.removeSoftBody(piece.body)
            clearEntityDeformationOverride(entityId: piece.slot.entity, meshIndex: piece.slot.mesh)
        }
        for collider in colliders {
            backend?.removeKinematicBody(collider.body)
        }
    }

    // MARK: - Helpers

    /// Body colliders. No collider may reach the collar: a pinned particle
    /// inside one has its free neighbours shoved out against a pin that
    /// cannot move, every step, and the cloth explodes (the headless cape
    /// test reproduces it). So nothing above the chest — the collar pins
    /// hold the cape to the upper back and neck themselves — and every
    /// capsule stays inside the body the cape rests on.
    static func bones(_ rig: CoolMirrorCapeRig) -> [(from: String, to: String, radius: Float)] {
        [
            (rig.pelvis, rig.chest, 0.09),
            (rig.leftUpperArm, rig.leftForearm, 0.05), (rig.rightUpperArm, rig.rightForearm, 0.05),
            (rig.leftThigh, rig.leftCalf, 0.08), (rig.rightThigh, rig.rightCalf, 0.08),
        ]
    }

    /// The capsules for the current joints, world space.
    static func capsules(_ rig: CoolMirrorCapeRig, joints: [SkeletonJointPose], jointIndexByName: [String: Int]) -> [CoolMirrorCapeCloth.Capsule] {
        bones(rig).compactMap { bone in
            guard let a = jointIndexByName[bone.from], let b = jointIndexByName[bone.to], a < joints.count, b < joints.count else { return nil }
            return .init(start: joints[a].worldPosition, end: joints[b].worldPosition, radius: bone.radius)
        }
    }

    private static func capsulePose(from a: simd_float3, to b: simd_float3) -> (simd_float3, simd_quatf) {
        let axis = b - a
        let length = simd_length(axis)
        guard length > 1e-5 else { return ((a + b) * 0.5, simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))) }
        let direction = axis / length
        let up = simd_float3(0, 1, 0)
        let rotation: simd_quatf
        if simd_dot(up, direction) < -0.9999 {
            rotation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            rotation = simd_normalize(simd_quatf(from: up, to: direction))
        }
        return ((a + b) * 0.5, rotation)
    }

    private static func matches(_ path: String, _ name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }

    /// The cape's material slots anywhere in the character hierarchy: the
    /// meshes or textures named after it.
    private static func capeSlots(root: EntityID) -> [Slot] {
        var slots: [Slot] = []
        var pending = [root]
        while let entity = pending.first {
            pending.removeFirst()
            pending.append(contentsOf: getEntityChildren(parentId: entity))
            for (mesh, meshName) in getEntityMeshNames(entityId: entity).enumerated() {
                let meshIsCape = meshName.localizedCaseInsensitiveContains("cape")
                for submesh in 0 ..< getEntitySubmeshCount(entityId: entity, meshIndex: mesh) {
                    let texture = getMaterialBaseColorTextureName(entityId: entity, meshIndex: mesh, submeshIndex: submesh) ?? ""
                    if meshIsCape || texture.localizedCaseInsensitiveContains("cape") {
                        slots.append(Slot(entity: entity, mesh: mesh, submesh: submesh))
                    }
                }
            }
        }
        return slots
    }

    private func report(world: [SIMD3<Float>], origin: simd_float3) {
        let now = Date().timeIntervalSinceReferenceDate
        guard lock.withLock({ () -> Bool in
            guard now - lastReport >= 2 else { return false }
            lastReport = now
            return true
        }) else { return }
        var farthest: Float = 0
        var nonFinite = 0
        for p in world {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                nonFinite += 1
                continue
            }
            farthest = max(farthest, simd_length(p - origin))
        }
        print(String(format: "CoolMirror jolt cape: farthest particle %.2f m from the character origin, %d non-finite", farthest, nonFinite))
    }
}
