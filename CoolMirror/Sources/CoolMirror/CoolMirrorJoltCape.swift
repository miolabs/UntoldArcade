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
    private static let weldTolerance: Float = 1e-4
    /// A particle farther than this from the character is a blown-up cloth.
    private static let runawayDistance: Float = 3.0

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
        /// Particle per mesh vertex of the slot (welded).
        var particleOfVertex: [UInt32]
        var vertexIds: [UInt32]
        var faces: [SIMD3<UInt32>]
        /// Pinned particles and, per pinned particle, up to four skeleton
        /// joints with weights and the rest offset in each joint's frame.
        var pinned: [UInt32]
        var pinBindings: [[(joint: Int, weight: Float, offset: simd_float3)]]
        var particleCount: Int
    }

    private let lock = NSLock()
    private var backend: JoltPhysicsBackend?
    private var characterId: EntityID?
    private var rig: CoolMirrorCapeRig?
    private var enabled = false
    private var pieces: [Piece] = []
    private var colliders: [Collider] = []
    private var restJoints: [SkeletonRestJoint] = []
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
        let origin = getPosition(entityId: characterId)
        let rotation = getRotationQuaternion(entityId: characterId)
        // The skeleton query answers the rest transforms until the first
        // animation update: wait for joints that sit on the character.
        guard let neck = joints.first(where: { Self.matches($0.path, rig.neck) }),
              abs(neck.worldPosition.y - origin.y) > 0.6, abs(neck.worldPosition.y - origin.y) < 2.3,
              simd_length(simd_float2(neck.worldPosition.x - origin.x, neck.worldPosition.z - origin.z)) < 2.5
        else { return }

        if !built {
            build(characterId: characterId, rig: rig, backend: backend, joints: joints, origin: origin, rotation: rotation)
        }
        let (pieces, colliders, restJoints, jointIndexByName) = lock.withLock { (self.pieces, self.colliders, self.restJoints, self.jointIndexByName) }
        guard !pieces.isEmpty else { return }

        // Colliders follow the bones.
        for collider in colliders {
            guard let a = jointIndexByName[collider.from], let b = jointIndexByName[collider.to],
                  a < joints.count, b < joints.count
            else { continue }
            let (position, orientation) = Self.capsulePose(from: joints[a].worldPosition, to: joints[b].worldPosition)
            backend.setKinematicTarget(collider.body, position: position, rotation: orientation)
        }

        // The collar rides on its joints: each pinned particle is the
        // weighted sum of its rest offset carried by each joint's current
        // frame.
        for piece in pieces {
            var targets: [SIMD3<Float>] = []
            targets.reserveCapacity(piece.pinned.count)
            for bindings in piece.pinBindings {
                var target = SIMD3<Float>.zero
                var total: Float = 0
                for binding in bindings where binding.joint < joints.count {
                    let joint = joints[binding.joint]
                    target += binding.weight * (joint.worldPosition + joint.worldRotation.act(binding.offset))
                    total += binding.weight
                }
                targets.append(total > 0 ? target / total : .zero)
            }
            backend.setSoftBodyVertices(piece.body, indices: piece.pinned, worldPositions: targets)
        }

        // Read the cloth back into the mesh (model space).
        let inverseRotation = rotation.inverse
        for piece in pieces {
            var world = lock.withLock { scratchPositions }
            let read = backend.readSoftBodyVertices(piece.body, into: &world)
            guard read == piece.particleCount else { continue }
            // A runaway cloth (a bad step, a teleport) is rebuilt in the
            // current pose rather than left to blow up Jolt's broadphase.
            if world.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) || simd_length($0 - origin) > Self.runawayDistance }) {
                print("CoolMirror jolt cape: cloth ran away; rebuilding it in the current pose")
                tearDown()
                return
            }
            var normals = [SIMD3<Float>](repeating: .zero, count: piece.particleCount)
            for face in piece.faces {
                let a = world[Int(face.x)], b = world[Int(face.y)], c = world[Int(face.z)]
                let n = simd_cross(b - a, c - a)
                normals[Int(face.x)] += n
                normals[Int(face.y)] += n
                normals[Int(face.z)] += n
            }
            var positions: [simd_float3] = []
            var vertexNormals: [simd_float3] = []
            positions.reserveCapacity(piece.vertexIds.count)
            vertexNormals.reserveCapacity(piece.vertexIds.count)
            for particle in piece.particleOfVertex {
                let p = world[Int(particle)]
                positions.append(inverseRotation.act(p - origin))
                let n = normals[Int(particle)]
                vertexNormals.append(inverseRotation.act(simd_length_squared(n) > 1e-12 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)))
            }
            setEntityDeformationOverride(
                entityId: piece.slot.entity, meshIndex: piece.slot.mesh,
                indices: piece.vertexIds, positions: positions, normals: vertexNormals
            )
            lock.withLock { scratchPositions = world }
            report(world: world, origin: origin)
        }
        _ = restJoints
    }

    // MARK: - Build

    private func build(characterId: EntityID, rig: CoolMirrorCapeRig, backend: JoltPhysicsBackend, joints: [SkeletonJointPose], origin: simd_float3, rotation: simd_quatf) {
        lock.withLock { built = true }
        let restJoints = entitySkeletonRestJointPoses(entityId: characterId)
        var jointIndexByName: [String: Int] = [:]
        for (index, joint) in joints.enumerated() {
            if let name = joint.path.split(separator: "/").last {
                jointIndexByName[String(name)] = index
            }
            jointIndexByName[joint.path] = index
        }
        let collarJoints = Set([rig.neck, rig.upperChest, rig.leftClavicle, rig.rightClavicle, rig.head].compactMap { jointIndexByName[$0] })

        var pieces: [Piece] = []
        for slot in Self.capeSlots(root: characterId) {
            guard let geometry = entitySubmeshGeometry(entityId: slot.entity, meshIndex: slot.mesh, submeshIndex: slot.submesh),
                  !geometry.triangles.isEmpty
            else { continue }
            guard let piece = makePiece(
                slot: slot, geometry: geometry, backend: backend, restJoints: restJoints, joints: joints,
                collarJoints: collarJoints, origin: origin, rotation: rotation
            ) else { continue }
            pieces.append(piece)
        }

        var colliders: [Collider] = []
        // The collar pins must never sit inside a collider (their free
        // neighbours would be shoved out against fixed pins every step),
        // so the torso stops at the chest and the upper back is thin.
        let bones: [(String, String, Float)] = [
            (rig.pelvis, rig.chest, 0.11), (rig.chest, rig.neck, 0.075), (rig.neck, rig.head, 0.08),
            (rig.leftUpperArm, rig.leftForearm, 0.055), (rig.rightUpperArm, rig.rightForearm, 0.055),
            (rig.leftThigh, rig.leftCalf, 0.085), (rig.rightThigh, rig.rightCalf, 0.085),
        ]
        for (from, to, radius) in bones {
            guard let a = jointIndexByName[from], let b = jointIndexByName[to] else { continue }
            let (position, orientation) = Self.capsulePose(from: joints[a].worldPosition, to: joints[b].worldPosition)
            let length = simd_length(joints[b].worldPosition - joints[a].worldPosition)
            guard let body = backend.addKinematicCapsule(radius: radius, height: max(length + 2 * radius, 2 * radius + 0.01), position: position, rotation: orientation) else { continue }
            colliders.append(Collider(body: body, from: from, to: to, radius: radius))
        }

        lock.withLock {
            self.pieces = pieces
            self.colliders = colliders
            self.restJoints = restJoints
            self.jointIndexByName = jointIndexByName
        }
        print("CoolMirror jolt cape: \(pieces.count) cape piece(s), \(pieces.reduce(0) { $0 + $1.particleCount }) particles, \(pieces.reduce(0) { $0 + $1.pinned.count }) pinned, \(colliders.count) colliders")
    }

    /// Welds the slot's vertices into particles, builds the soft body from
    /// its triangles and binds the collar particles to their joints.
    private func makePiece(
        slot: Slot, geometry: EntitySubmeshGeometry, backend: JoltPhysicsBackend, restJoints: [SkeletonRestJoint],
        joints: [SkeletonJointPose], collarJoints: Set<Int>, origin: simd_float3, rotation: simd_quatf
    ) -> Piece? {
        // Vertices used by this slot's triangles, welded by rest position.
        let vertexIds = Array(Set(geometry.triangles)).sorted()
        var particleOfVertex: [UInt32] = []
        var particleOfMeshVertex: [UInt32: UInt32] = [:]
        var particleRest: [simd_float3] = []
        var particleSourceVertex: [Int] = []
        var buckets: [SIMD3<Int32>: [UInt32]] = [:]
        let cell: Float = 1e-3
        for id in vertexIds {
            let local = geometry.positions[Int(id)]
            let p4 = geometry.localTransform * simd_float4(local, 1)
            let p = simd_float3(p4.x, p4.y, p4.z)
            let key = SIMD3<Int32>(Int32((p.x / cell).rounded()), Int32((p.y / cell).rounded()), Int32((p.z / cell).rounded()))
            var found: UInt32?
            for candidate in buckets[key, default: []] where simd_length(particleRest[Int(candidate)] - p) <= Self.weldTolerance {
                found = candidate
                break
            }
            let particle: UInt32
            if let found {
                particle = found
            } else {
                particle = UInt32(particleRest.count)
                particleRest.append(p)
                particleSourceVertex.append(Int(id))
                buckets[key, default: []].append(particle)
            }
            particleOfMeshVertex[id] = particle
            particleOfVertex.append(particle)
        }
        var faces: [SIMD3<UInt32>] = []
        for t in stride(from: 0, to: geometry.triangles.count - 2, by: 3) {
            guard let a = particleOfMeshVertex[geometry.triangles[t]], let b = particleOfMeshVertex[geometry.triangles[t + 1]], let c = particleOfMeshVertex[geometry.triangles[t + 2]],
                  a != b, b != c, a != c
            else { continue }
            faces.append(SIMD3(a, b, c))
        }
        guard !faces.isEmpty else { return nil }

        // Every particle's skin binding: rest offsets in its joints' rest
        // frames. Used to start the cloth in the current pose (skinned on
        // the CPU) and, for the collar, to pin it to the joints.
        var inverseMasses = [Float](repeating: 1 / Self.particleMass, count: particleRest.count)
        var pinned: [UInt32] = []
        var pinBindings: [[(joint: Int, weight: Float, offset: simd_float3)]] = []
        var startWorld = particleRest.map { origin + rotation.act($0) }
        let hasSkin = geometry.jointIndices.count == geometry.positions.count && geometry.jointWeights.count == geometry.positions.count
        if hasSkin {
            for (particle, source) in particleSourceVertex.enumerated() {
                let ids = geometry.jointIndices[source]
                let weights = geometry.jointWeights[source]
                let entries: [(Int, Float)] = [(Int(ids.x), weights.x), (Int(ids.y), weights.y), (Int(ids.z), weights.z), (Int(ids.w), weights.w)]
                var bindings: [(joint: Int, weight: Float, offset: simd_float3)] = []
                for (joint, weight) in entries where weight > 1e-3 && joint < restJoints.count && joint < joints.count {
                    let rest = restJoints[joint]
                    let offset = rest.modelRotation.inverse.act(particleRest[particle] - rest.modelPosition)
                    bindings.append((joint, weight, offset))
                }
                guard !bindings.isEmpty else { continue }
                var skinned = simd_float3.zero
                var total: Float = 0
                for binding in bindings {
                    let joint = joints[binding.joint]
                    skinned += binding.weight * (joint.worldPosition + joint.worldRotation.act(binding.offset))
                    total += binding.weight
                }
                if total > 0 {
                    startWorld[particle] = skinned / total
                }
                let collar = entries.filter { collarJoints.contains($0.0) }.reduce(Float(0)) { $0 + $1.1 }
                guard collar >= Self.collarWeight else { continue }
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append(bindings)
            }
        }
        if pinned.isEmpty {
            // No skin data: pin the top tenth of the cape.
            let sorted = particleRest.indices.sorted { particleRest[$0].y > particleRest[$1].y }
            for particle in sorted.prefix(max(1, particleRest.count / 10)) {
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append([])
            }
        }

        var descriptor = JoltSoftBodyDescriptor(
            vertices: startWorld.map { $0 - origin },
            inverseMasses: inverseMasses,
            faces: faces,
            compliance: Self.stretchCompliance, shearCompliance: Self.shearCompliance, bendCompliance: Self.bendCompliance
        )
        descriptor.position = origin
        descriptor.iterations = 8
        descriptor.linearDamping = 0.6
        descriptor.vertexRadius = 0.008
        descriptor.friction = 0.5
        guard let body = backend.addSoftBody(descriptor) else {
            print("CoolMirror jolt cape: Jolt rejected the cape soft body (\(particleRest.count) particles, \(faces.count) faces)")
            return nil
        }
        return Piece(
            slot: slot, body: body, particleOfVertex: particleOfVertex, vertexIds: vertexIds, faces: faces,
            pinned: pinned, pinBindings: pinBindings, particleCount: particleRest.count
        )
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
