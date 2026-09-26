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

    public init(joints: [MocapJoint: String], rootJoint: String) {
        self.joints = joints
        self.rootJoint = rootJoint
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

    public init() {}
}

public struct MocapRetargetResult: Sendable {
    public var worldRotationDeltas: [String: simd_quatf]
    public var rootTranslationDelta: simd_float3
    public var rootJoint: String
}

/// Retargets frames relative to a calibration pose captured while the user
/// stands in the character's rest pose.
public final class MocapRetargeter: @unchecked Sendable {
    public var mapping: MocapRigMapping
    public var options = MocapRetargetOptions()

    private var calibrationRotations: [MocapJoint: simd_quatf] = [:]
    private var calibrationRootPosition = simd_float3(0, 0, 0)
    private var calibrationRootRotation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
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

    /// Nil until calibrated.
    public func retarget(_ frame: MocapFrame) -> MocapRetargetResult? {
        let (calibration, calibrationPosition, calibrationRoot) = lock.withLock {
            (calibrationRotations, calibrationRootPosition, calibrationRootRotation)
        }
        guard !calibration.isEmpty else { return nil }
        let options = options
        let facing = options.flipFacing ? simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)) : nil

        var deltas: [String: simd_quatf] = [:]
        for (captured, rigJoint) in mapping.joints {
            // With the mirror on, the character's joint takes the delta of the
            // user's opposite joint, reflected across the sagittal plane.
            let source = options.mirror ? captured.mirrored : captured
            guard let current = frame.rotations[source], let reference = calibration[source] else { continue }
            var delta = simd_normalize(current * reference.inverse)
            if options.mirror {
                delta = Self.reflectAcrossSagittalPlane(delta)
            }
            if let facing {
                delta = simd_normalize(facing * delta * facing.inverse)
            }
            deltas[rigJoint] = delta
        }

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

        return MocapRetargetResult(worldRotationDeltas: deltas, rootTranslationDelta: translation, rootJoint: mapping.rootJoint)
    }

    /// The rotation reflected across the x = 0 plane: the axis loses its x
    /// component's sign and the angle flips, so as a quaternion (x, y, z, w)
    /// becomes (x, -y, -z, w).
    public static func reflectAcrossSagittalPlane(_ rotation: simd_quatf) -> simd_quatf {
        let v = rotation.vector
        return simd_quatf(vector: simd_float4(v.x, -v.y, -v.z, v.w))
    }
}
