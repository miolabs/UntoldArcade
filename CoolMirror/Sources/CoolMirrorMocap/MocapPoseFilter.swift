//
//  MocapPoseFilter.swift
//  CoolMirrorMocap
//
//  Temporal smoothing of captured frames: a one-euro filter per joint
//  (adaptive low-pass: heavy smoothing while the joint is still or slow,
//  little while it moves fast, so standing feet stop shaking without the
//  arms lagging). Run at render rate with the newest frame as the target,
//  it also interpolates the phone's 30–60 Hz steps.
//

import Foundation
import simd

public struct MocapSmoothingOptions: Sendable, Equatable {
    /// Low-pass cut-off (Hz) for the upper body when still; lower = steadier
    /// and laggier.
    public var bodyCutoff: Float = 2.0
    /// Cut-off for the hips, legs and feet (and the anchor orientation).
    public var legCutoff: Float = 1.0
    /// Cut-off for the root position (where the character stands).
    public var rootCutoff: Float = 0.6
    /// How much the cut-off rises with speed (per rad/s or m/s): keeps fast
    /// motion responsive. 0 = a plain low-pass.
    public var beta: Float = 0.5
    /// Cut-off of the speed estimate used by `beta`.
    public var derivativeCutoff: Float = 1.0
    public var isEnabled = true
    /// A lower-body joint moving farther than this between two phone
    /// frames is a tracker glitch, not motion: the frame is held back for
    /// up to `glitchHold` seconds. Arms and hands get `maxArmStep`.
    public var maxJointStep: Float = 0.25
    public var maxArmStep: Float = 0.4
    public var glitchHold: TimeInterval = 0.4

    public init() {}

    /// The still cut-off for `joint`'s rotation and position.
    public func cutoff(for joint: MocapJoint) -> Float {
        joint.isLowerBody ? legCutoff : bodyCutoff
    }
}

/// Smoothing factor of a first-order low-pass with cut-off `cutoff` (Hz)
/// sampled every `dt` seconds.
func lowPassAlpha(cutoff: Float, dt: Float) -> Float {
    guard cutoff.isFinite, cutoff > 0 else { return 1 }
    let tau = 1 / (2 * Float.pi * cutoff)
    return 1 / (1 + tau / dt)
}

/// Angle (radians) between two orientations.
public func rotationAngle(between a: simd_quatf, _ b: simd_quatf) -> Float {
    let d = min(1, abs(simd_dot(a.vector, b.vector)))
    return 2 * acos(d)
}

struct OneEuroQuaternion {
    private(set) var value: simd_quatf?
    private var speed: Float = 0

    mutating func filter(_ input: simd_quatf, dt: Float, minCutoff: Float, beta: Float, derivativeCutoff: Float) -> simd_quatf {
        guard let previous = value, dt > 0 else {
            value = input
            return input
        }
        // Same hemisphere as the previous value so the slerp takes the short way.
        var target = input
        if simd_dot(previous.vector, target.vector) < 0 {
            target = simd_quatf(vector: -target.vector)
        }
        let rawSpeed = rotationAngle(between: previous, target) / dt
        let speedAlpha = lowPassAlpha(cutoff: derivativeCutoff, dt: dt)
        speed += speedAlpha * (rawSpeed - speed)
        let alpha = lowPassAlpha(cutoff: minCutoff + beta * speed, dt: dt)
        let output = simd_normalize(simd_slerp(previous, target, alpha))
        value = output
        return output
    }
}

struct OneEuroVector {
    private(set) var value: simd_float3?
    private var speed: Float = 0

    mutating func filter(_ input: simd_float3, dt: Float, minCutoff: Float, beta: Float, derivativeCutoff: Float) -> simd_float3 {
        guard let previous = value, dt > 0 else {
            value = input
            return input
        }
        let rawSpeed = simd_length(input - previous) / dt
        let speedAlpha = lowPassAlpha(cutoff: derivativeCutoff, dt: dt)
        speed += speedAlpha * (rawSpeed - speed)
        let alpha = lowPassAlpha(cutoff: minCutoff + beta * speed, dt: dt)
        let output = previous + alpha * (input - previous)
        value = output
        return output
    }
}

/// Smooths successive frames; feed it the newest frame every render tick
/// with the current time. Also undoes two ARKit body-tracking glitches
/// before smoothing: a left/right relabelling of the arms or the legs is
/// swapped back, and a frame in which a joint jumps farther than a body
/// can move is held back for a moment (see `guardGlitches`).
public struct MocapPoseFilter: Sendable {
    private var rotations: [MocapJoint: OneEuroQuaternion] = [:]
    private var positions: [MocapJoint: OneEuroVector] = [:]
    private var root = OneEuroVector()
    private var lastTime: TimeInterval?
    private var lastAccepted: MocapFrame?
    private var holdUntil: TimeInterval?
    /// Frames the glitch guard rejected since the last accepted one.
    public private(set) var rejectedFrames = 0
    /// Frames whose sides were swapped back.
    public private(set) var swappedFrames = 0

    public init() {}

    public mutating func reset() {
        rotations.removeAll()
        positions.removeAll()
        root = OneEuroVector()
        lastTime = nil
        lastAccepted = nil
        holdUntil = nil
        rejectedFrames = 0
        swappedFrames = 0
    }

    /// A side of the body ARKit can relabel on its own: the arms (with the
    /// shoulders) or the legs.
    public enum SideGroup: CaseIterable, Sendable {
        case arms, legs

        public var joints: [MocapJoint] {
            switch self {
            case .arms: [.leftShoulder, .leftArm, .leftForearm, .leftHand, .rightShoulder, .rightArm, .rightForearm, .rightHand]
            case .legs: [.leftUpLeg, .leftLeg, .leftFoot, .leftToes, .rightUpLeg, .rightLeg, .rightFoot, .rightToes]
            }
        }
    }

    /// `frame` with the group's left joints' data on the right and vice versa.
    public static func swappingSides(_ frame: MocapFrame, group: SideGroup) -> MocapFrame {
        var swapped = frame
        for joint in group.joints {
            swapped.rotations[joint] = frame.rotations[joint.mirrored]
            swapped.positions[joint] = frame.positions[joint.mirrored]
            if frame.trackedJoints.contains(joint.mirrored) {
                swapped.trackedJoints.insert(joint)
            } else {
                swapped.trackedJoints.remove(joint)
            }
        }
        return swapped
    }

    /// World-space position of a joint.
    private static func world(_ joint: MocapJoint, in frame: MocapFrame) -> simd_float3? {
        guard let p = frame.positions[joint] else { return nil }
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        return anchor.act(p) + frame.rootPosition
    }

    /// Mean world distance of the group's joints between two frames.
    private static func distance(_ a: MocapFrame, _ b: MocapFrame, group: SideGroup) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for joint in group.joints {
            guard let pa = world(joint, in: a), let pb = world(joint, in: b) else { continue }
            sum += simd_length(pa - pb)
            count += 1
        }
        return count > 0 ? sum / count : 0
    }

    /// Side-swap undo and jump rejection. Motion is continuous, so of the
    /// two readings of each limb group — as delivered, or with left and
    /// right exchanged — the one nearer the previous accepted frame is
    /// the true one; that undoes ARKit's relabelling without any state.
    /// What still jumps farther than a body can move in one frame is a
    /// glitch and the previous frame stands in for it, for up to
    /// `glitchHold` seconds.
    private mutating func guardGlitches(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) -> MocapFrame {
        guard let previous = lastAccepted, frame.sequence != previous.sequence else {
            if lastAccepted == nil {
                lastAccepted = frame
            }
            return lastAccepted ?? frame
        }
        var candidate = frame
        for group in SideGroup.allCases where group.joints.allSatisfy({ frame.positions[$0] != nil && previous.positions[$0] != nil }) {
            let swapped = Self.swappingSides(candidate, group: group)
            if Self.distance(swapped, previous, group: group) < Self.distance(candidate, previous, group: group) {
                candidate = swapped
                swappedFrames += 1
            }
        }
        var jump: Float = 0
        for joint in MocapJoint.allCases {
            guard let a = Self.world(joint, in: candidate), let b = Self.world(joint, in: previous) else { continue }
            let limit = joint.isLowerBody ? options.maxJointStep : options.maxArmStep
            jump = max(jump, simd_length(a - b) / limit)
        }
        if jump > 1 {
            if let holdUntil, time >= holdUntil {
                // Held long enough: this is real motion after all.
                self.holdUntil = nil
            } else {
                if holdUntil == nil {
                    holdUntil = time + options.glitchHold
                }
                rejectedFrames += 1
                return previous
            }
        } else {
            holdUntil = nil
        }
        rejectedFrames = 0
        lastAccepted = candidate
        return candidate
    }

    /// The smoothed frame; untracked frames pass through untouched.
    public mutating func filter(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) -> MocapFrame {
        guard options.isEnabled, frame.isTracked else { return frame }
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.25))
        lastTime = time
        let frame = guardGlitches(frame, at: time, options: options)

        var output = frame
        for (joint, rotation) in frame.rotations {
            output.rotations[joint] = rotations[joint, default: OneEuroQuaternion()].filter(
                rotation, dt: dt, minCutoff: options.cutoff(for: joint), beta: options.beta, derivativeCutoff: options.derivativeCutoff
            )
        }
        for (joint, position) in frame.positions {
            output.positions[joint] = positions[joint, default: OneEuroVector()].filter(
                position, dt: dt, minCutoff: options.cutoff(for: joint), beta: options.beta, derivativeCutoff: options.derivativeCutoff
            )
        }
        output.rootPosition = root.filter(
            frame.rootPosition, dt: dt, minCutoff: options.rootCutoff, beta: options.beta, derivativeCutoff: options.derivativeCutoff
        )
        return output
    }
}

/// Measures how much the raw capture moves from one phone frame to the
/// next, before any smoothing: with the user standing still that is pure
/// tracker noise, the number that says whether ARKit itself is the
/// problem. Averages over the last second.
public struct MocapJitterMeter: Sendable {
    public struct Sample: Sendable, Equatable {
        public var time: TimeInterval
        /// Root position step (m).
        public var root: Float
        /// Mean foot position step (m), in anchor space.
        public var feet: Float
        /// Hips orientation step (rad).
        public var hips: Float
        /// Whether the hip or shoulder axis reversed since the previous
        /// frame: the tracker changed its mind about the facing or the sides.
        public var flipped: Bool
    }

    private var previous: MocapFrame?
    private var samples: [Sample] = []
    private let window: TimeInterval = 1
    /// Since the last reset: tracked frames seen and how many flipped.
    public private(set) var totalFrames = 0
    public private(set) var totalFlips = 0

    public init() {}

    public mutating func reset() {
        previous = nil
        samples.removeAll()
        totalFrames = 0
        totalFlips = 0
    }

    /// Records the step from the previous raw frame to `frame`.
    public mutating func add(_ frame: MocapFrame, at time: TimeInterval) {
        defer { previous = frame }
        guard frame.isTracked, let previous, previous.isTracked, frame.sequence != previous.sequence else { return }
        let root = simd_length(frame.rootPosition - previous.rootPosition)
        var feet: Float = 0
        var feetCount: Float = 0
        for joint in [MocapJoint.leftFoot, .rightFoot] {
            if let a = frame.positions[joint], let b = previous.positions[joint] {
                feet += simd_length(a - b)
                feetCount += 1
            }
        }
        var hips: Float = 0
        if let a = frame.rotations[.hips], let b = previous.rotations[.hips] {
            hips = rotationAngle(between: a, b)
        }
        var flipped = false
        for (left, right) in [(MocapJoint.leftUpLeg, MocapJoint.rightUpLeg), (.leftShoulder, .rightShoulder)] {
            if let a = Self.axis(frame, left, right), let b = Self.axis(previous, left, right), simd_dot(a, b) < -0.5 {
                flipped = true
            }
        }
        samples.append(Sample(time: time, root: root, feet: feetCount > 0 ? feet / feetCount : 0, hips: hips, flipped: flipped))
        samples.removeAll { time - $0.time > window }
        totalFrames += 1
        if flipped {
            totalFlips += 1
        }
    }

    /// e.g. "flips 12 in 1340 frames (0.9%)" since the last reset.
    public var totals: String {
        guard totalFrames > 0 else { return "no tracked frames yet" }
        return String(format: "flips %d in %d frames (%.1f%%)", totalFlips, totalFrames, 100 * Float(totalFlips) / Float(totalFrames))
    }

    /// World-space left → right axis between two joints.
    private static func axis(_ frame: MocapFrame, _ left: MocapJoint, _ right: MocapJoint) -> simd_float3? {
        guard let l = frame.positions[left], let r = frame.positions[right] else { return nil }
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let d = anchor.act(r - l)
        return simd_length_squared(d) > 1e-6 ? simd_normalize(d) : nil
    }

    /// Frames in the window whose facing or sides reversed.
    public var flips: Int {
        samples.filter(\.flipped).count
    }

    /// Mean step per frame over the window, or nil without two frames.
    public func average() -> Sample? {
        guard !samples.isEmpty else { return nil }
        let n = Float(samples.count)
        return Sample(
            time: samples.last!.time,
            root: samples.reduce(0) { $0 + $1.root } / n,
            feet: samples.reduce(0) { $0 + $1.feet } / n,
            hips: samples.reduce(0) { $0 + $1.hips } / n,
            flipped: false
        )
    }

    /// e.g. "raw step/frame: root 4 mm · feet 9 mm · hips 0.6° · flips 2/s"
    public var report: String {
        guard let a = average() else { return "raw step/frame: —" }
        return String(
            format: "raw step/frame: root %.0f mm · feet %.0f mm · hips %.1f° · flips %d/s",
            a.root * 1000, a.feet * 1000, a.hips * 180 / .pi, flips
        )
    }
}
