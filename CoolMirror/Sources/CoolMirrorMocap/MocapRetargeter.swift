//
//  MocapRetargeter.swift
//  CoolMirrorMocap
//
//  Turns captured body frames into world-space rotation deltas for a rig:
//  every mapped joint's rotation relative to the calibration pose, expressed
//  in the character's model space, mirrored like a reflection and optionally
//  turned to face the other way.
//

import Foundation
import simd

/// Which rig joint each captured joint drives.
public struct MocapRigMapping: Sendable {
    public var joints: [MocapJoint: String]
    /// Rig joint that receives the root translation (the hips).
    public var rootJoint: String
    /// Rig joints known for every captured joint, driven or not (the toes,
    /// say): the ends of the bones whose directions the retarget copies.
    /// Defaults to `joints`.
    public var referenceJoints: [MocapJoint: String]

    public init(joints: [MocapJoint: String], rootJoint: String, referenceJoints: [MocapJoint: String]? = nil) {
        self.joints = joints
        self.rootJoint = rootJoint
        self.referenceJoints = referenceJoints ?? joints
    }
}

public extension MocapJoint {
    /// The captured child whose position, with this joint's, gives the bone
    /// direction the rig copies (nil: the joint is driven by its rotation).
    var boneChild: MocapJoint? {
        switch self {
        case .spine2: .spine5
        case .spine5: .spine7
        case .spine7: .neck1
        case .neck1: .head
        case .leftShoulder: .leftArm
        case .leftArm: .leftForearm
        case .leftForearm: .leftHand
        case .leftUpLeg: .leftLeg
        case .leftLeg: .leftFoot
        case .leftFoot: .leftToes
        case .rightShoulder: .rightArm
        case .rightArm: .rightForearm
        case .rightForearm: .rightHand
        case .rightUpLeg: .rightLeg
        case .rightLeg: .rightFoot
        case .rightFoot: .rightToes
        default: nil
        }
    }

    /// Joints with no reliable bone of their own that keep their rest
    /// orientation relative to the parent bone (the hands follow the
    /// forearm).
    var followsParentBone: MocapJoint? {
        switch self {
        case .leftHand: .leftForearm
        case .rightHand: .rightForearm
        default: nil
        }
    }
}

public struct MocapRetargetOptions: Sendable, Equatable {
    /// Reflect the pose like a mirror (the user's left arm drives the
    /// character's right arm, which appears on the user's left).
    public var mirror = true
    /// Turn the captured pose half a turn about the vertical axis when the
    /// rig faces the other way than the capture space.
    public var flipFacing = false
    /// Blend of the captured pose over the animated one.
    public var weight: Float = 1
    /// Scale of the root translation (0 keeps the character in place).
    public var rootTranslationScale: Float = 1
    /// Temporal smoothing applied by `smoothed(_:at:)`.
    public var smoothing = MocapSmoothingOptions()

    public init() {}
}

public struct MocapRetargetResult: Sendable {
    public var worldRotationDeltas: [String: simd_quatf]
    public var rootTranslationDelta: simd_float3
    public var rootJoint: String
    /// The captured skeleton's joint positions relative to the calibration
    /// spot, in the character's model space (mirrored and flipped like the
    /// rotations): the character's rest origin plus these is where the
    /// captured body stands. Empty when the frame carries no positions.
    public var capturedJointPositions: [MocapJoint: simd_float3]
    public var capturedTrackedJoints: Set<MocapJoint>
}

/// Retargets frames onto a rig. Limbs and spine copy the captured bone
/// directions (a swing from the rig's rest bone direction, plus the
/// captured twist about it), so the character points its bones where the
/// user's point whatever the proportions and however the user stood at
/// calibration; that needs the rig's rest joint positions
/// (`rigRestPositions`). Joints without a bone (hips, head) and rigs
/// without rest positions use the rotation relative to the calibration
/// pose instead, so the user calibrates standing upright, facing the phone.
public final class MocapRetargeter: @unchecked Sendable {
    public var mapping: MocapRigMapping
    public var options = MocapRetargetOptions()
    /// Rest joint positions of the rig, model space, by the names used in
    /// `mapping`.
    public var rigRestPositions: [String: simd_float3] {
        get { lock.withLock { restPositions } }
        set { lock.withLock { restPositions = newValue } }
    }

    private var restPositions: [String: simd_float3] = [:]

    private var calibrationRotations: [MocapJoint: simd_quatf] = [:]
    private var calibrationRootPosition = simd_float3(0, 0, 0)
    private var calibrationRootRotation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
    private var filter = MocapPoseFilter()
    private let lock = NSLock()

    public init(mapping: MocapRigMapping) {
        self.mapping = mapping
    }

    public var isCalibrated: Bool {
        lock.withLock { !calibrationRotations.isEmpty }
    }

    /// Stores `frame` as the pose that maps onto the character's rest pose.
    public func calibrate(with frame: MocapFrame) {
        lock.withLock {
            calibrationRotations = frame.rotations
            calibrationRootPosition = frame.rootPosition
            calibrationRootRotation = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        }
    }

    public func resetCalibration() {
        lock.withLock { calibrationRotations.removeAll() }
    }

    /// `frame` smoothed against the frames fed before it (see
    /// `MocapPoseFilter`); call once per render tick with the newest frame,
    /// then retarget the result.
    public func smoothed(_ frame: MocapFrame, at time: TimeInterval) -> MocapFrame {
        let options = options.smoothing
        return lock.withLock { filter.filter(frame, at: time, options: options) }
    }

    public func resetSmoothing() {
        lock.withLock { filter.reset() }
    }

    /// Nil until calibrated.
    public func retarget(_ frame: MocapFrame) -> MocapRetargetResult? {
        let (calibration, calibrationPosition, calibrationRoot, restPositions) = lock.withLock {
            (calibrationRotations, calibrationRootPosition, calibrationRootRotation, self.restPositions)
        }
        guard !calibration.isEmpty else { return nil }
        let options = options
        let facing = options.flipFacing ? simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)) : nil

        // Root motion relative to the calibration spot, in the calibrated
        // body's frame so walking toward the phone moves the character the
        // same way regardless of where the session's world axes point.
        var translation = calibrationRoot.inverse.act(frame.rootPosition - calibrationPosition)
        if options.mirror {
            translation.x = -translation.x
        }
        if let facing {
            translation = facing.act(translation)
        }
        translation *= options.rootTranslationScale

        // The captured skeleton in the same space as the translation: anchor
        // space → world → calibrated body frame, then mirrored and flipped.
        let anchorRotation = frame.rotations[.root] ?? calibrationRoot
        var captured: [MocapJoint: simd_float3] = [:]
        for (joint, position) in frame.positions {
            var p = calibrationRoot.inverse.act(anchorRotation.act(position) + frame.rootPosition - calibrationPosition)
            if options.mirror {
                p.x = -p.x
            }
            if let facing {
                p = facing.act(p)
            }
            captured[joint] = p
        }

        /// Rotation of a captured joint relative to its calibration, in the
        /// character's space. With the mirror on, the character's joint takes
        /// the delta of the user's opposite joint, reflected across the
        /// sagittal plane.
        func rotationDelta(_ captured: MocapJoint) -> simd_quatf? {
            let source = options.mirror ? captured.mirrored : captured
            guard let current = frame.rotations[source], let reference = calibration[source] else { return nil }
            var delta = simd_normalize(current * reference.inverse)
            if options.mirror {
                delta = Self.reflectAcrossSagittalPlane(delta)
            }
            if let facing {
                delta = simd_normalize(facing * delta * facing.inverse)
            }
            return delta
        }

        /// Bone directions: rig rest direction → captured direction.
        func restDirection(_ joint: MocapJoint) -> simd_float3? {
            guard let child = joint.boneChild,
                  let rigJoint = mapping.referenceJoints[joint], let rigChild = mapping.referenceJoints[child],
                  let a = restPositions[rigJoint], let b = restPositions[rigChild]
            else { return nil }
            let d = b - a
            return simd_length_squared(d) > 1e-8 ? simd_normalize(d) : nil
        }
        func capturedDirection(_ joint: MocapJoint) -> simd_float3? {
            let source = options.mirror ? joint.mirrored : joint
            guard let child = source.boneChild, let a = captured[source], let b = captured[child] else { return nil }
            let d = b - a
            return simd_length_squared(d) > 1e-8 ? simd_normalize(d) : nil
        }
        var swings: [MocapJoint: simd_quatf] = [:]
        var restDirections: [MocapJoint: simd_float3] = [:]
        for joint in mapping.referenceJoints.keys {
            guard let rest = restDirection(joint), let target = capturedDirection(joint) else { continue }
            swings[joint] = Self.swing(from: rest, to: target)
            restDirections[joint] = rest
        }

        var deltas: [String: simd_quatf] = [:]
        for (captured, rigJoint) in mapping.joints {
            if let swing = swings[captured], let rest = restDirections[captured] {
                // Bone-direction joint: the captured twist about the bone
                // rides on the swing.
                let twist = rotationDelta(captured).map { Self.twist(of: $0, about: rest) } ?? simd_quatf(angle: 0, axis: rest)
                deltas[rigJoint] = simd_normalize(swing * twist)
            } else if let parent = captured.followsParentBone, let swing = swings[parent] {
                deltas[rigJoint] = swing
            } else if let delta = rotationDelta(captured) {
                deltas[rigJoint] = delta
            }
        }

        return MocapRetargetResult(
            worldRotationDeltas: deltas, rootTranslationDelta: translation, rootJoint: mapping.rootJoint,
            capturedJointPositions: captured, capturedTrackedJoints: frame.trackedJoints
        )
    }

    /// The shortest rotation taking unit vector `from` onto unit vector `to`.
    public static func swing(from: simd_float3, to: simd_float3) -> simd_quatf {
        if simd_dot(from, to) < -0.9999 {
            // Opposite directions: half a turn about any perpendicular axis.
            let helper = abs(from.x) < 0.9 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
            return simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(from, helper)))
        }
        return simd_normalize(simd_quatf(from: from, to: to))
    }

    /// The part of `rotation` that turns about `axis` (swing–twist
    /// decomposition, twist first).
    public static func twist(of rotation: simd_quatf, about axis: simd_float3) -> simd_quatf {
        let projected = simd_dot(rotation.imag, axis) * axis
        let twist = simd_quatf(ix: projected.x, iy: projected.y, iz: projected.z, r: rotation.real)
        let length = twist.length
        guard length > 1e-6 else { return simd_quatf(angle: 0, axis: axis) }
        return twist / length
    }

    /// The rotation reflected across the x = 0 plane: the axis loses its x
    /// component's sign and the angle flips, so as a quaternion (x, y, z, w)
    /// becomes (x, -y, -z, w).
    public static func reflectAcrossSagittalPlane(_ rotation: simd_quatf) -> simd_quatf {
        let v = rotation.vector
        return simd_quatf(vector: simd_float4(v.x, -v.y, -v.z, v.w))
    }
}
