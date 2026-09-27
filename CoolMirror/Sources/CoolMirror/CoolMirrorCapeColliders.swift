//
//  CoolMirrorCapeColliders.swift
//  CoolMirror
//
//  The cape's body colliders, fitted to the character's own mesh: one
//  capsule per bone segment, its axis through the segment's joints but
//  shifted sideways to where the segment's skinned vertices actually sit
//  (a belt and a back stick out behind the spine), its radius from the
//  vertices' spread around that axis. Pure and testable.
//

import Foundation
import simd

enum CoolMirrorCapeColliders {
    /// A bone segment to wrap: the capsule runs `from` → `to`. A vertex
    /// sizes the segment whose `from` joint is the nearest ancestor of
    /// the joint that owns most of it (twist and helper bones hang under
    /// the bone they belong to).
    struct Segment {
        var from: String
        var to: String
        /// The radius when the mesh gives no vertices for the segment.
        var fallbackRadius: Float
        /// Where along the bone the capsule starts (0 = at `from`): an
        /// upper arm starts below the shoulder, which the collar sits on.
        var startFraction: Float = 0
        /// Ceiling on the fitted radius: a gauntlet's fins or a boot's
        /// top must not make an arm or a foot a barrel that shoves the
        /// cape about when the limb comes near it.
        var maxRadius: Float = CoolMirrorCapeColliders.radiusRange.upperBound
    }

    /// A fitted capsule: `shift` is the axis offset in the `from` joint's
    /// rest frame, applied with the joint's current rotation.
    struct Fit {
        var from: String
        var to: String
        var fromJoint: Int
        var toJoint: Int
        var startFraction: Float
        var shift: simd_float3
        var radius: Float
        var vertices: Int
    }

    /// Radii from the mesh are clamped to this range: an outlier vertex
    /// (a glove skinned to the forearm) must not swell a limb, and a
    /// sliver of vertices must not leave a segment without a body.
    static let radiusRange: ClosedRange<Float> = 0.03 ... 0.2
    /// The vertices' radial spread that the capsule covers.
    static let radiusPercentile: Float = 0.9
    /// A capsule stays at least this far from every pinned particle.
    static let pinClearance: Float = 0.02

    /// The upper back and the shoulders (the shoulder blades the cape
    /// sank into) are wrapped too; `keep(_:awayFrom:joints:)` then
    /// shrinks them clear of the collar pins they carry, since a pinned
    /// particle inside a collider is shoved out against a pin that cannot
    /// move, every step, and the cloth explodes.
    static func segments(_ rig: CoolMirrorCapeRig) -> [Segment] {
        [
            Segment(from: rig.pelvis, to: rig.spine, fallbackRadius: 0.11),
            Segment(from: rig.spine, to: rig.chest, fallbackRadius: 0.1),
            Segment(from: rig.chest, to: rig.upperChest, fallbackRadius: 0.1),
            Segment(from: rig.leftClavicle, to: rig.leftUpperArm, fallbackRadius: 0.06),
            Segment(from: rig.rightClavicle, to: rig.rightUpperArm, fallbackRadius: 0.06),
            Segment(from: rig.leftUpperArm, to: rig.leftForearm, fallbackRadius: 0.05, startFraction: 0.35, maxRadius: 0.08),
            Segment(from: rig.rightUpperArm, to: rig.rightForearm, fallbackRadius: 0.05, startFraction: 0.35, maxRadius: 0.08),
            Segment(from: rig.leftForearm, to: rig.leftHand, fallbackRadius: 0.04, maxRadius: 0.06),
            Segment(from: rig.rightForearm, to: rig.rightHand, fallbackRadius: 0.04, maxRadius: 0.06),
            Segment(from: rig.leftThigh, to: rig.leftCalf, fallbackRadius: 0.08),
            Segment(from: rig.rightThigh, to: rig.rightCalf, fallbackRadius: 0.08),
            Segment(from: rig.leftCalf, to: rig.leftFoot, fallbackRadius: 0.06),
            Segment(from: rig.rightCalf, to: rig.rightFoot, fallbackRadius: 0.06),
            Segment(from: rig.leftFoot, to: rig.leftToe, fallbackRadius: 0.05, maxRadius: 0.12),
            Segment(from: rig.rightFoot, to: rig.rightToe, fallbackRadius: 0.05, maxRadius: 0.12),
        ]
    }

    /// Joints whose vertices size no segment: the neck, head and hands,
    /// and everything under them (a glove would swell the forearm).
    static func excludedJoints(_ rig: CoolMirrorCapeRig) -> [String] {
        [rig.neck, rig.head, rig.leftHand, rig.rightHand]
    }

    /// Fits the segments to a mesh at rest: `positions` in the space of
    /// `restJoints` (world, the character's transform applied), skinned
    /// by `jointIndices`/`jointWeights` (skeleton indices; `parents` the
    /// skeleton's parent of each joint). A segment whose joints the
    /// skeleton lacks is skipped. With `back` (the side the cape hangs
    /// on), the capsule stays on the bone and its radius is the extent of
    /// the vertices within 45° of that side: the surface the cape touches,
    /// not the average of a wide belt with a deep chest.
    static func fit(
        _ segments: [Segment], excluding excluded: [String], positions: [simd_float3], jointIndices: [simd_ushort4], jointWeights: [simd_float4],
        restJoints: [CoolMirrorCapeCloth.JointFrame], parents: [Int?], jointIndexByName: [String: Int], back: simd_float3? = nil
    ) -> [Fit] {
        // Which segment a joint sizes: the nearest ancestor (itself
        // included) that starts a segment, unless an excluded joint
        // comes first.
        var segmentOfStart: [Int: Int] = [:]
        for (index, segment) in segments.enumerated() {
            if let joint = jointIndexByName[segment.from] { segmentOfStart[joint] = index }
        }
        let excludedJoints = Set(excluded.compactMap { jointIndexByName[$0] })
        var segmentOfJoint: [Int: Int?] = [:]
        func segment(of joint: Int) -> Int? {
            if let known = segmentOfJoint[joint] { return known }
            var current: Int? = joint
            var result: Int?
            var visited = 0
            while let j = current, visited < parents.count {
                visited += 1
                if excludedJoints.contains(j) { break }
                if let index = segmentOfStart[j] {
                    result = index
                    break
                }
                current = j < parents.count ? parents[j] : nil
            }
            segmentOfJoint[joint] = result
            return result
        }

        // Every vertex goes to the segment of the joint that owns most of it.
        var verticesOfSegment = [[simd_float3]](repeating: [], count: segments.count)
        if jointIndices.count == positions.count, jointWeights.count == positions.count {
            for (vertex, p) in positions.enumerated() {
                let ids = jointIndices[vertex], w = jointWeights[vertex]
                var owner = Int(ids.x), best = w.x
                if w.y > best { owner = Int(ids.y); best = w.y }
                if w.z > best { owner = Int(ids.z); best = w.z }
                if w.w > best { owner = Int(ids.w) }
                if let index = segment(of: owner) {
                    verticesOfSegment[index].append(p)
                }
            }
        }
        var fits: [Fit] = []
        for (index, segment) in segments.enumerated() {
            guard let a = jointIndexByName[segment.from], let b = jointIndexByName[segment.to],
                  a < restJoints.count, b < restJoints.count
            else { continue }
            let start = restJoints[a].position, end = restJoints[b].position
            let axis = end - start
            let lengthSquared = simd_length_squared(axis)
            guard lengthSquared > 1e-6 else { continue }
            let vertices = verticesOfSegment[index]
            var fit = Fit(from: segment.from, to: segment.to, fromJoint: a, toJoint: b, startFraction: segment.startFraction, shift: .zero, radius: segment.fallbackRadius, vertices: vertices.count)
            if vertices.count >= 24 {
                // Sideways offsets of the vertices from the axis; the
                // capsule's axis moves to their mean, its radius covers
                // most of their spread around it.
                let offsets = vertices.map { p -> simd_float3 in
                    let d = p - start
                    return d - axis * (simd_dot(d, axis) / lengthSquared)
                }
                var mean = simd_float3.zero
                var spread: [Float]
                let band = back.map { back in offsets.filter { simd_length_squared($0) > 1e-8 && simd_dot(simd_normalize($0), back) >= 0.7071 } } ?? []
                if band.count >= 24 {
                    spread = band.map { simd_length($0) }
                } else {
                    mean = offsets.reduce(simd_float3.zero, +) / Float(offsets.count)
                    spread = offsets.map { simd_length($0 - mean) }
                }
                spread.sort()
                let index = min(spread.count - 1, Int(Float(spread.count - 1) * radiusPercentile))
                fit.radius = min(spread[index].clamped(to: radiusRange), segment.maxRadius)
                fit.shift = restJoints[a].rotation.inverse.act(mean)
            }
            fits.append(fit)
        }
        return fits
    }

    /// The fitted capsules for the current joints.
    static func capsules(_ fits: [Fit], joints: [CoolMirrorCapeCloth.JointFrame]) -> [CoolMirrorCapeCloth.Capsule] {
        fits.compactMap { fit in
            guard fit.fromJoint < joints.count, fit.toJoint < joints.count else { return nil }
            let shift = joints[fit.fromJoint].rotation.act(fit.shift)
            let from = joints[fit.fromJoint].position + shift, to = joints[fit.toJoint].position + shift
            return .init(start: from + (to - from) * fit.startFraction, end: to, radius: fit.radius)
        }
    }

    /// Shrinks every capsule that would hold one of `points` (the pinned
    /// particles at rest): a pinned particle inside a collider has its
    /// free neighbours shoved out against a pin that cannot move, every
    /// step, and the cloth explodes.
    static func keep(_ fits: inout [Fit], awayFrom points: [simd_float3], joints: [CoolMirrorCapeCloth.JointFrame]) {
        for (index, capsule) in zip(fits.indices, capsules(fits, joints: joints)) {
            let axis = capsule.end - capsule.start
            let lengthSquared = max(simd_length_squared(axis), 1e-8)
            var nearest: Float = .greatestFiniteMagnitude
            for p in points {
                let t = simd_clamp(simd_dot(p - capsule.start, axis) / lengthSquared, 0, 1)
                nearest = min(nearest, simd_length(p - (capsule.start + axis * t)))
            }
            let allowed = nearest - pinClearance
            if allowed < fits[index].radius {
                fits[index].radius = max(allowed, radiusRange.lowerBound)
            }
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
