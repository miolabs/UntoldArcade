//
//  MocapTests.swift
//  CoolMirrorTests
//

@testable import CoolMirror
import CoolMirrorMocap
import simd
import XCTest

final class MocapTests: XCTestCase {
    private func identity() -> simd_quatf { simd_quatf(angle: 0, axis: simd_float3(0, 1, 0)) }

    private func frame(sequence: UInt32 = 1, rotations: [MocapJoint: simd_quatf], root: simd_float3 = .zero) -> MocapFrame {
        var all: [MocapJoint: simd_quatf] = [:]
        for joint in MocapJoint.allCases {
            all[joint] = rotations[joint] ?? identity()
        }
        return MocapFrame(sequence: sequence, timestamp: 12.5, isTracked: true, rootPosition: root, rotations: all)
    }

    private func assertEqual(_ a: simd_quatf, _ b: simd_quatf, line: UInt = #line) {
        XCTAssertGreaterThan(abs(simd_dot(a.vector, b.vector)), 0.9999, "\(a) vs \(b)", line: line)
    }

    func testFrameRoundTripsThroughTheWireFormat() throws {
        var original = frame(sequence: 42, rotations: [.leftArm: simd_quatf(angle: 0.4, axis: simd_float3(0, 0, 1))], root: simd_float3(0.1, 1.2, -0.3))
        original.positions = [.leftFoot: simd_float3(0.1, 0.05, 0), .hips: simd_float3(0, 0.9, 0)]
        original.trackedJoints = [.hips, .leftArm]
        let data = original.encode()
        XCTAssertEqual(data.count, MocapFrame.headerSize + MocapJoint.allCases.count * MocapFrame.jointRecordSize)
        let decoded = try XCTUnwrap(MocapFrame(data: data))
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.timestamp, 12.5)
        XCTAssertTrue(decoded.isTracked)
        XCTAssertEqual(decoded.rootPosition, original.rootPosition)
        XCTAssertEqual(decoded.rotations.count, MocapJoint.allCases.count)
        assertEqual(decoded.rotations[.leftArm]!, original.rotations[.leftArm]!)
        XCTAssertEqual(decoded.positions[.leftFoot], original.positions[.leftFoot])
        XCTAssertEqual(decoded.positions[.head], .zero, "joints sent without a position decode as the origin")
        XCTAssertEqual(decoded.trackedJoints, [.hips, .leftArm])
        XCTAssertNil(MocapFrame(data: data.prefix(20)))
        XCTAssertNil(MocapFrame(data: Data([1, 2, 3, 4])))
    }

    func testEveryJointButTheRootHasAParentInTheSet() {
        for joint in MocapJoint.allCases {
            if joint == .root {
                XCTAssertNil(joint.parent)
            } else {
                XCTAssertNotNil(joint.parent, "\(joint)")
            }
        }
        XCTAssertEqual(MocapJoint.leftToes.parent, .leftFoot)
        XCTAssertEqual(MocapJoint.rightShoulder.parent, .spine7)
        XCTAssertTrue(MocapJoint.rightFoot.isLowerBody)
        XCTAssertFalse(MocapJoint.leftHand.isLowerBody)
    }

    /// Standing still with tracker noise on the feet, the filter removes
    /// most of it; a fast arm swing still gets through almost unlagged.
    func testFilterSteadiesNoiseButFollowsFastMotion() {
        var filter = MocapPoseFilter()
        var options = MocapSmoothingOptions()
        options.legCutoff = 1
        options.bodyCutoff = 2
        var generator = SystemRandomNumberGenerator()
        var lastFoot = simd_float3.zero
        var lastArm = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let dt = 1.0 / 60
        let rest = simd_float3(0.1, 0.05, 0)
        var footError: Float = 0
        var count: Float = 0
        for i in 0 ..< 240 {
            let time = Double(i) * dt
            let noise = simd_float3(
                Float.random(in: -0.02 ... 0.02, using: &generator),
                Float.random(in: -0.02 ... 0.02, using: &generator),
                Float.random(in: -0.02 ... 0.02, using: &generator)
            )
            // The arm swings 90° over the last second.
            let swing = Float(max(0, i - 180)) / 60 * (.pi / 2)
            var f = frame(sequence: UInt32(i + 1), rotations: [.leftArm: simd_quatf(angle: swing, axis: simd_float3(0, 0, 1))])
            f.positions = [.leftFoot: rest + noise]
            let out = filter.filter(f, at: time, options: options)
            lastFoot = out.positions[.leftFoot] ?? .zero
            lastArm = out.rotations[.leftArm] ?? lastArm
            if i >= 120, i < 180 {
                footError += simd_length(lastFoot - rest)
                count += 1
            }
        }
        XCTAssertLessThan(footError / count, 0.006, "2 cm noise on a still foot should shrink well below 1 cm")
        XCTAssertLessThan(abs(simd_angle(lastArm) - .pi / 2), 0.15, "a fast swing lags by less than ~9°")
    }

    func testJitterMeterAveragesRawSteps() throws {
        var meter = MocapJitterMeter()
        XCTAssertNil(meter.average())
        for i in 0 ..< 4 {
            var f = frame(sequence: UInt32(i + 1), rotations: [:], root: simd_float3(Float(i) * 0.01, 0, 0))
            f.positions = [.leftFoot: simd_float3(0, Float(i) * 0.02, 0), .rightFoot: .zero]
            meter.add(f, at: Double(i) / 30)
        }
        let a = try XCTUnwrap(meter.average())
        XCTAssertEqual(a.root, 0.01, accuracy: 1e-6)
        XCTAssertEqual(a.feet, 0.01, accuracy: 1e-6, "mean over both feet, one of them still")
        XCTAssertEqual(a.hips, 0, accuracy: 1e-6)
        XCTAssertTrue(meter.report.contains("root 10 mm"))
    }

    func testCapturedPositionsFollowTheMirrorAndFacingOptions() throws {
        let mapping = try XCTUnwrap(CoolMirrorMocapMapping.mapping(for: .spiderman))
        let retargeter = MocapRetargeter(mapping: mapping)
        var calibration = frame(rotations: [:], root: simd_float3(0, 0, 2))
        calibration.positions = [.leftHand: simd_float3(0.5, 1.4, 0)]
        retargeter.calibrate(with: calibration)
        var moved = frame(sequence: 2, rotations: [:], root: simd_float3(0.1, 0, 2))
        moved.positions = [.leftHand: simd_float3(0.5, 1.4, 0.2)]
        moved.trackedJoints = [.leftHand]

        let mirrored = try XCTUnwrap(retargeter.retarget(moved))
        let hand = try XCTUnwrap(mirrored.capturedJointPositions[.leftHand])
        XCTAssertEqual(hand.x, -0.6, accuracy: 1e-6, "root offset plus joint offset, reflected")
        XCTAssertEqual(hand.y, 1.4, accuracy: 1e-6)
        XCTAssertEqual(hand.z, 0.2, accuracy: 1e-6)
        XCTAssertEqual(mirrored.capturedTrackedJoints, [.leftHand])

        retargeter.options.mirror = false
        retargeter.options.flipFacing = true
        let flipped = try XCTUnwrap(retargeter.retarget(moved))
        let flippedHand = try XCTUnwrap(flipped.capturedJointPositions[.leftHand])
        XCTAssertEqual(flippedHand.x, -0.6, accuracy: 1e-6)
        XCTAssertEqual(flippedHand.z, -0.2, accuracy: 1e-6)
    }

    func testMirroredRetargetSwapsSidesAndReflects() throws {
        let mapping = try XCTUnwrap(CoolMirrorMocapMapping.mapping(for: .spiderman))
        XCTAssertEqual(mapping.joints[.leftArm], "mixamorig:LeftArm")
        XCTAssertEqual(mapping.joints[.rightArm], "mixamorig:RightArm")
        XCTAssertEqual(mapping.rootJoint, "mixamorig:Pelvis")

        let retargeter = MocapRetargeter(mapping: mapping)
        XCTAssertNil(retargeter.retarget(frame(rotations: [:])), "nothing before calibration")
        retargeter.calibrate(with: frame(rotations: [:], root: simd_float3(0, 1, 0)))

        let raise = simd_quatf(angle: 0.8, axis: simd_float3(0, 0, 1))
        let moved = frame(sequence: 2, rotations: [.leftArm: raise], root: simd_float3(0.2, 0.9, 0))

        // Mirror on (default): the user's left arm drives the character's right arm, reflected.
        let mirrored = try XCTUnwrap(retargeter.retarget(moved))
        assertEqual(mirrored.worldRotationDeltas["mixamorig:RightArm"]!, MocapRetargeter.reflectAcrossSagittalPlane(raise))
        assertEqual(mirrored.worldRotationDeltas["mixamorig:LeftArm"]!, identity())
        XCTAssertEqual(mirrored.rootTranslationDelta.x, -0.2, accuracy: 1e-6)
        XCTAssertEqual(mirrored.rootTranslationDelta.y, -0.1, accuracy: 1e-6)
        XCTAssertEqual(mirrored.rootJoint, "mixamorig:Pelvis")

        // Mirror off: same side, unreflected.
        retargeter.options.mirror = false
        let direct = try XCTUnwrap(retargeter.retarget(moved))
        assertEqual(direct.worldRotationDeltas["mixamorig:LeftArm"]!, raise)
        XCTAssertEqual(direct.rootTranslationDelta.x, 0.2, accuracy: 1e-6)

        // Facing flip conjugates by a half turn about Y (a Z-axis rotation flips sign).
        retargeter.options.flipFacing = true
        let flipped = try XCTUnwrap(retargeter.retarget(moved))
        assertEqual(flipped.worldRotationDeltas["mixamorig:LeftArm"]!, simd_quatf(angle: -0.8, axis: simd_float3(0, 0, 1)))
        XCTAssertEqual(flipped.rootTranslationDelta.x, -0.2, accuracy: 1e-6)

        retargeter.options.rootTranslationScale = 0
        XCTAssertEqual(try XCTUnwrap(retargeter.retarget(moved)).rootTranslationDelta, .zero)
    }

    /// With the rig's rest positions known, a limb copies the captured bone
    /// direction whatever pose the user calibrated in.
    func testBoneDirectionsDriveTheLimbsRegardlessOfCalibration() throws {
        let mapping = try XCTUnwrap(CoolMirrorMocapMapping.mapping(for: .spiderman))
        XCTAssertEqual(mapping.referenceJoints[.leftToes], "mixamorig:LeftToeBase")
        XCTAssertNil(mapping.joints[.leftToes], "toes are a bone end, not driven")

        let retargeter = MocapRetargeter(mapping: mapping)
        retargeter.options.mirror = false
        // Rig rest: T-pose, left arm along +x.
        retargeter.rigRestPositions = [
            "mixamorig:LeftArm": simd_float3(0.2, 1.4, 0),
            "mixamorig:LeftForeArm": simd_float3(0.5, 1.4, 0),
            "mixamorig:LeftHand": simd_float3(0.8, 1.4, 0),
        ]
        // Calibrated with the arm hanging down (any rotation, any direction).
        var calibration = frame(rotations: [.leftArm: simd_quatf(angle: 1.0, axis: simd_float3(0, 0, 1))])
        calibration.positions = [.leftArm: simd_float3(0.2, 1.4, 0), .leftForearm: simd_float3(0.2, 1.1, 0), .leftHand: simd_float3(0.2, 0.8, 0)]
        retargeter.calibrate(with: calibration)

        // Now the user points the upper arm straight up and the forearm forward.
        var moved = frame(sequence: 2, rotations: [.leftArm: simd_quatf(angle: 1.0, axis: simd_float3(0, 0, 1))])
        moved.positions = [.leftArm: simd_float3(0.2, 1.4, 0), .leftForearm: simd_float3(0.2, 1.7, 0), .leftHand: simd_float3(0.2, 1.7, 0.3)]
        let result = try XCTUnwrap(retargeter.retarget(moved))

        let arm = try XCTUnwrap(result.worldRotationDeltas["mixamorig:LeftArm"])
        let armDirection = arm.act(simd_float3(1, 0, 0))
        XCTAssertEqual(armDirection.y, 1, accuracy: 1e-4, "+x rest bone now points up")
        let forearm = try XCTUnwrap(result.worldRotationDeltas["mixamorig:LeftForeArm"])
        XCTAssertEqual(forearm.act(simd_float3(1, 0, 0)).z, 1, accuracy: 1e-4, "forearm points forward")
        let hand = try XCTUnwrap(result.worldRotationDeltas["mixamorig:LeftHand"])
        assertEqual(hand, forearm) // the hand follows the forearm bone

        // Mirrored: the user's left arm drives the character's right arm,
        // whose rest bone points along -x, reflected to the same up direction.
        retargeter.options.mirror = true
        retargeter.rigRestPositions["mixamorig:RightArm"] = simd_float3(-0.2, 1.4, 0)
        retargeter.rigRestPositions["mixamorig:RightForeArm"] = simd_float3(-0.5, 1.4, 0)
        let mirrored = try XCTUnwrap(retargeter.retarget(moved))
        let rightArm = try XCTUnwrap(mirrored.worldRotationDeltas["mixamorig:RightArm"])
        XCTAssertEqual(rightArm.act(simd_float3(-1, 0, 0)).y, 1, accuracy: 1e-4)
    }

    func testSwingAndTwistDecomposition() {
        let axis = simd_normalize(simd_float3(1, 2, 0))
        let twist = simd_quatf(angle: 0.7, axis: axis)
        let swing = MocapRetargeter.swing(from: axis, to: simd_float3(0, 0, 1))
        let combined = simd_normalize(swing * twist)
        assertEqual(MocapRetargeter.twist(of: combined, about: axis), twist)
        XCTAssertEqual(simd_length(swing.act(axis) - simd_float3(0, 0, 1)), 0, accuracy: 1e-5)
        let flip = MocapRetargeter.swing(from: simd_float3(0, 1, 0), to: simd_float3(0, -1, 0))
        XCTAssertEqual(simd_length(flip.act(simd_float3(0, 1, 0)) - simd_float3(0, -1, 0)), 0, accuracy: 1e-5)
    }

    func testReflectionIsAnInvolution() {
        let q = simd_quatf(angle: 1.1, axis: simd_normalize(simd_float3(0.3, 0.8, -0.5)))
        assertEqual(MocapRetargeter.reflectAcrossSagittalPlane(MocapRetargeter.reflectAcrossSagittalPlane(q)), q)
        // A rotation about the mirror plane's normal (x) survives unchanged; a
        // rotation about an in-plane axis (y) reverses.
        let aboutX = simd_quatf(angle: 0.6, axis: simd_float3(1, 0, 0))
        assertEqual(MocapRetargeter.reflectAcrossSagittalPlane(aboutX), aboutX)
        let aboutY = simd_quatf(angle: 0.6, axis: simd_float3(0, 1, 0))
        assertEqual(MocapRetargeter.reflectAcrossSagittalPlane(aboutY), aboutY.inverse)
    }
}
