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
    /// up to `glitchHold` seconds.
    public var maxJointStep: Float = 0.25
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
/// before smoothing: a left/right swap (the hip axis reverses between two
/// frames, faster than anyone can turn) is swapped back, and a frame in
/// which a lower-body joint jumps implausibly is held back for a moment.
public struct MocapPoseFilter: Sendable {
    private var rotations: [MocapJoint: OneEuroQuaternion] = [:]
    private var positions: [MocapJoint: OneEuroVector] = [:]
    private var root = OneEuroVector()
    private var lastTime: TimeInterval?
    private var lastAccepted: MocapFrame?
    private var lastLateral: simd_float3?
    private var sidesSwapped = false
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
        lastLateral = nil
        sidesSwapped = false
        holdUntil = nil
        rejectedFrames = 0
        swappedFrames = 0
    }

    /// The hip axis (left → right thigh) in world space.
    private static func lateral(of frame: MocapFrame) -> simd_float3? {
        guard let l = frame.positions[.leftUpLeg], let r = frame.positions[.rightUpLeg] else { return nil }
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let d = anchor.act(r - l)
        return simd_length_squared(d) > 1e-6 ? simd_normalize(d) : nil
    }

    /// `frame` with every left joint's data on the right and vice versa.
    public static func swappingSides(_ frame: MocapFrame) -> MocapFrame {
        var swapped = frame
        swapped.rotations = Dictionary(uniqueKeysWithValues: frame.rotations.map { ($0.key.mirrored, $0.value) })
        swapped.positions = Dictionary(uniqueKeysWithValues: frame.positions.map { ($0.key.mirrored, $0.value) })
        swapped.trackedJoints = Set(frame.trackedJoints.map(\.mirrored))
        return swapped
    }

    /// Side-swap undo and jump rejection: the frame to smooth, or the last
    /// accepted one while a glitch is held back.
    private mutating func guardGlitches(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) -> MocapFrame {
        guard let previous = lastAccepted, frame.sequence != previous.sequence else {
            if lastAccepted == nil {
                lastAccepted = frame
                lastLateral = Self.lateral(of: frame)
            }
            return lastAccepted ?? frame
        }
        var candidate = sidesSwapped ? Self.swappingSides(frame) : frame
        if let lateral = Self.lateral(of: candidate), let last = lastLateral {
            if simd_dot(lateral, last) < -0.5 {
                // Reversed in one frame: the tracker swapped the legs.
                sidesSwapped.toggle()
                candidate = Self.swappingSides(candidate)
                swappedFrames += 1
            }
        }
        var jump: Float = 0
        for joint in MocapJoint.allCases where joint.isLowerBody {
            if let a = candidate.positions[joint], let b = previous.positions[joint] {
                jump = max(jump, simd_length(a - b))
            }
        }
        if jump > options.maxJointStep {
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
        lastLateral = Self.lateral(of: candidate) ?? lastLateral
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
    }

    private var previous: MocapFrame?
    private var samples: [Sample] = []
    private let window: TimeInterval = 1

    public init() {}

    public mutating func reset() {
        previous = nil
        samples.removeAll()
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
        samples.append(Sample(time: time, root: root, feet: feetCount > 0 ? feet / feetCount : 0, hips: hips))
        samples.removeAll { time - $0.time > window }
    }

    /// Mean step per frame over the window, or nil without two frames.
    public func average() -> Sample? {
        guard !samples.isEmpty else { return nil }
        let n = Float(samples.count)
        return Sample(
            time: samples.last!.time,
            root: samples.reduce(0) { $0 + $1.root } / n,
            feet: samples.reduce(0) { $0 + $1.feet } / n,
            hips: samples.reduce(0) { $0 + $1.hips } / n
        )
    }

    /// e.g. "raw step/frame: root 4 mm · feet 9 mm · hips 0.6°"
    public var report: String {
        guard let a = average() else { return "raw step/frame: —" }
        return String(
            format: "raw step/frame: root %.0f mm · feet %.0f mm · hips %.1f°",
            a.root * 1000, a.feet * 1000, a.hips * 180 / .pi
        )
    }
}
