//
//  CoolMirrorCapeCloth.swift
//  CoolMirror
//
//  The cape's cloth topology, built from a cape mesh's rest geometry and
//  skin: pure and testable without a GPU or a physics world. Welds the
//  mesh's vertices into particles (by position and normal, so a
//  double-sided cape keeps its two layers instead of collapsing into
//  duplicate, opposite triangles that break bend constraints), drops
//  degenerate and duplicate faces, skins every particle to the current
//  joints for the starting shape, and picks the collar particles to pin.
//

import Foundation
import simd

struct CoolMirrorCapeCloth {
    struct JointFrame {
        var position: simd_float3
        var rotation: simd_quatf
    }

    struct PinBinding {
        var joint: Int
        var weight: Float
        /// Rest offset in the joint's rest frame.
        var offset: simd_float3
    }

    struct Stats: CustomStringConvertible {
        var meshVertices = 0
        var particles = 0
        var facesIn = 0
        var facesDuplicate = 0
        var facesDegenerate = 0
        var faces = 0
        var pinned = 0
        var nonManifoldEdges = 0
        var minEdge: Float = .greatestFiniteMagnitude
        var maxEdge: Float = 0

        var description: String {
            String(format: "%d mesh vertices → %d particles, %d faces (%d duplicate, %d degenerate dropped), %d pinned, %d non-manifold edges, edges %.1f–%.1f mm",
                   meshVertices, particles, faces, facesDuplicate, facesDegenerate, pinned, nonManifoldEdges, minEdge * 1000, maxEdge * 1000)
        }
    }

    /// Particle rest positions (the space of the input positions).
    var particleRest: [simd_float3]
    /// Where each particle starts, in world space (skinned to the current pose).
    var startWorld: [simd_float3]
    /// Particle of every vertex in `vertexIds`.
    var particleOfVertex: [UInt32]
    /// The mesh vertices of the cape slot (sorted).
    var vertexIds: [UInt32]
    var faces: [SIMD3<UInt32>]
    var inverseMasses: [Float]
    var pinned: [UInt32]
    var pinBindings: [[PinBinding]]
    var stats: Stats

    static let weldTolerance: Float = 1e-4
    /// Vertices closer than the tolerance still stay apart when their
    /// normals disagree by more than this (a double-sided sheet's layers).
    static let weldNormalDot: Float = 0.5
    static let degenerateArea: Float = 1e-9

    /// `positions`/`normals`/`jointIndices`/`jointWeights` are per mesh
    /// vertex at rest; `triangles` index them; `restJoints` are the
    /// skeleton's rest frames in the same space as `positions`, `joints`
    /// its current frames in the space the cloth simulates in (world);
    /// `collarJoints` the joints a pinned vertex must be skinned to by at
    /// least `collarWeight`. Rest data in world units (the entity's
    /// transform applied) keeps the pin offsets in metres.
    init(
        positions: [simd_float3], normals: [simd_float3], triangles: [UInt32],
        jointIndices: [simd_ushort4], jointWeights: [simd_float4],
        restJoints: [JointFrame], joints: [JointFrame], collarJoints: Set<Int>, collarWeight: Float,
        particleMass: Float
    ) {
        var stats = Stats()
        stats.meshVertices = positions.count
        let vertexIds = Array(Set(triangles)).sorted()

        // Weld.
        var particleOfMeshVertex: [UInt32: UInt32] = [:]
        var particleRest: [simd_float3] = []
        var particleNormal: [simd_float3] = []
        var particleSource: [Int] = []
        var buckets: [SIMD3<Int32>: [UInt32]] = [:]
        let cell: Float = 1e-3
        var particleOfVertex: [UInt32] = []
        particleOfVertex.reserveCapacity(vertexIds.count)
        for id in vertexIds {
            let p = positions[Int(id)]
            let n = id < normals.count ? normals[Int(id)] : simd_float3(0, 0, 1)
            let key = SIMD3<Int32>(Int32((p.x / cell).rounded()), Int32((p.y / cell).rounded()), Int32((p.z / cell).rounded()))
            var found: UInt32?
            for candidate in buckets[key, default: []]
                where simd_length(particleRest[Int(candidate)] - p) <= Self.weldTolerance
                && simd_dot(particleNormal[Int(candidate)], n) >= Self.weldNormalDot
            {
                found = candidate
                break
            }
            let particle: UInt32
            if let found {
                particle = found
            } else {
                particle = UInt32(particleRest.count)
                particleRest.append(p)
                particleNormal.append(n)
                particleSource.append(Int(id))
                buckets[key, default: []].append(particle)
            }
            particleOfMeshVertex[id] = particle
            particleOfVertex.append(particle)
        }
        stats.particles = particleRest.count

        // Faces: welded, without degenerate or duplicate ones.
        var faces: [SIMD3<UInt32>] = []
        var seen = Set<SIMD3<UInt32>>()
        var edgeUse: [SIMD2<UInt32>: Int] = [:]
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            stats.facesIn += 1
            guard let a = particleOfMeshVertex[triangles[t]], let b = particleOfMeshVertex[triangles[t + 1]], let c = particleOfMeshVertex[triangles[t + 2]] else { continue }
            guard a != b, b != c, a != c else {
                stats.facesDegenerate += 1
                continue
            }
            let area = simd_length(simd_cross(particleRest[Int(b)] - particleRest[Int(a)], particleRest[Int(c)] - particleRest[Int(a)])) * 0.5
            guard area > Self.degenerateArea else {
                stats.facesDegenerate += 1
                continue
            }
            let key = SIMD3<UInt32>([a, b, c].sorted())
            guard seen.insert(key).inserted else {
                stats.facesDuplicate += 1
                continue
            }
            faces.append(SIMD3(a, b, c))
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let e = SIMD2<UInt32>(min(u, v), max(u, v))
                edgeUse[e, default: 0] += 1
                let length = simd_length(particleRest[Int(u)] - particleRest[Int(v)])
                stats.minEdge = min(stats.minEdge, length)
                stats.maxEdge = max(stats.maxEdge, length)
            }
        }
        stats.faces = faces.count
        stats.nonManifoldEdges = edgeUse.values.filter { $0 > 2 }.count

        // Skin: start shape and collar pins.
        var inverseMasses = [Float](repeating: 1 / particleMass, count: particleRest.count)
        var startWorld = particleRest
        var pinned: [UInt32] = []
        var pinBindings: [[PinBinding]] = []
        let hasSkin = jointIndices.count == positions.count && jointWeights.count == positions.count
        if hasSkin {
            for (particle, source) in particleSource.enumerated() {
                let ids = jointIndices[source]
                let weights = jointWeights[source]
                let entries: [(Int, Float)] = [(Int(ids.x), weights.x), (Int(ids.y), weights.y), (Int(ids.z), weights.z), (Int(ids.w), weights.w)]
                var bindings: [PinBinding] = []
                for (joint, weight) in entries where weight > 1e-3 && joint < restJoints.count && joint < joints.count {
                    let rest = restJoints[joint]
                    bindings.append(PinBinding(joint: joint, weight: weight, offset: rest.rotation.inverse.act(particleRest[particle] - rest.position)))
                }
                guard !bindings.isEmpty else { continue }
                var skinned = simd_float3.zero
                var total: Float = 0
                for binding in bindings {
                    let joint = joints[binding.joint]
                    skinned += binding.weight * (joint.position + joint.rotation.act(binding.offset))
                    total += binding.weight
                }
                if total > 0 {
                    startWorld[particle] = skinned / total
                }
                let collar = entries.filter { collarJoints.contains($0.0) }.reduce(Float(0)) { $0 + $1.1 }
                guard collar >= collarWeight else { continue }
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append(bindings)
            }
        }
        if pinned.isEmpty {
            let sorted = particleRest.indices.sorted { particleRest[$0].y > particleRest[$1].y }
            for particle in sorted.prefix(max(1, particleRest.count / 10)) {
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append([])
            }
        }
        stats.pinned = pinned.count

        self.particleRest = particleRest
        self.startWorld = startWorld
        self.particleOfVertex = particleOfVertex
        self.vertexIds = vertexIds
        self.faces = faces
        self.inverseMasses = inverseMasses
        self.pinned = pinned
        self.pinBindings = pinBindings
        self.stats = stats
    }

    /// A capsule collider the cloth must start outside of.
    struct Capsule {
        var start: simd_float3
        var end: simd_float3
        var radius: Float
    }

    /// Moves every free starting position out of the capsules (plus a
    /// margin): an overlap at creation is resolved by Jolt in one step
    /// with a huge velocity, which is what threw the cape across the room.
    mutating func pushStartOut(of capsules: [Capsule], margin: Float) {
        let pinnedSet = Set(pinned)
        for particle in startWorld.indices where !pinnedSet.contains(UInt32(particle)) {
            var p = startWorld[particle]
            for capsule in capsules {
                let axis = capsule.end - capsule.start
                let lengthSquared = max(simd_length_squared(axis), 1e-8)
                let t = simd_clamp(simd_dot(p - capsule.start, axis) / lengthSquared, 0, 1)
                let closest = capsule.start + axis * t
                let d = p - closest
                let distance = simd_length(d)
                let wanted = capsule.radius + margin
                if distance < wanted {
                    p = distance > 1e-6 ? closest + d / distance * wanted : closest + simd_float3(0, 0, -wanted)
                }
            }
            startWorld[particle] = p
        }
    }

    /// World targets of the pinned particles for the current joints.
    func pinTargets(joints: [JointFrame]) -> [simd_float3] {
        pinBindings.map { bindings in
            var target = simd_float3.zero
            var total: Float = 0
            for binding in bindings where binding.joint < joints.count {
                let joint = joints[binding.joint]
                target += binding.weight * (joint.position + joint.rotation.act(binding.offset))
                total += binding.weight
            }
            return total > 0 ? target / total : .zero
        }
    }
}
