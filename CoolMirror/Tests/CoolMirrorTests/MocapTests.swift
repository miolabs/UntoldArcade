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
        options.medianWindow = 1 // this test exercises a later stage
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
        XCTAssertEqual(meter.flips, 0)
        // The tracker reverses the hip axis: one flip counted.
        var flipped = frame(sequence: 9, rotations: [:], root: simd_float3(0.03, 0, 0))
        flipped.positions = [.leftUpLeg: simd_float3(-0.1, 0.95, 0), .rightUpLeg: simd_float3(0.1, 0.95, 0), .leftFoot: .zero, .rightFoot: .zero]
        var before = frame(sequence: 8, rotations: [:], root: simd_float3(0.03, 0, 0))
        before.positions = [.leftUpLeg: simd_float3(0.1, 0.95, 0), .rightUpLeg: simd_float3(-0.1, 0.95, 0), .leftFoot: .zero, .rightFoot: .zero]
        meter.add(before, at: 4 / 30)
        meter.add(flipped, at: 5 / 30)
        XCTAssertEqual(meter.flips, 1)
        XCTAssertTrue(meter.report.contains("flips 1/s"))
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

    /// The torso frame comes from positions: when the user turns 90° the
    /// hips delta is a 90° yaw, and ARKit's joint orientations play no part.
    func testTorsoFrameFollowsTheHipAxisNotTheReportedOrientations() throws {
        let mapping = try XCTUnwrap(CoolMirrorMocapMapping.mapping(for: .spiderman))
        let retargeter = MocapRetargeter(mapping: mapping)
        retargeter.options.mirror = false
        retargeter.rigRestPositions = [
            "mixamorig:Pelvis": simd_float3(0, 1, 0), "mixamorig:Spine": simd_float3(0, 1.1, 0),
            "mixamorig:Spine2": simd_float3(0, 1.25, 0), "mixamorig:Spine3": simd_float3(0, 1.4, 0),
            "mixamorig:Neck": simd_float3(0, 1.5, 0), "mixamorig:Head": simd_float3(0, 1.6, 0),
            "mixamorig:LeftUpLeg": simd_float3(0.1, 0.95, 0), "mixamorig:RightUpLeg": simd_float3(-0.1, 0.95, 0),
            "mixamorig:LeftShoulder": simd_float3(0.05, 1.45, 0), "mixamorig:RightShoulder": simd_float3(-0.05, 1.45, 0),
        ]
        let upright: [MocapJoint: simd_float3] = [
            .hips: simd_float3(0, 1, 0), .spine2: simd_float3(0, 1.25, 0), .spine5: simd_float3(0, 1.4, 0),
            .spine7: simd_float3(0, 1.5, 0), .neck1: simd_float3(0, 1.55, 0), .head: simd_float3(0, 1.65, 0),
            .leftUpLeg: simd_float3(0.1, 0.95, 0), .rightUpLeg: simd_float3(-0.1, 0.95, 0),
            .leftShoulder: simd_float3(0.05, 1.45, 0), .rightShoulder: simd_float3(-0.05, 1.45, 0),
        ]
        var calibration = frame(rotations: [:])
        calibration.positions = upright
        retargeter.calibrate(with: calibration)

        // Turned a quarter turn about y, with garbage joint orientations.
        let yaw = simd_quatf(angle: .pi / 2, axis: simd_float3(0, 1, 0))
        var turned = frame(sequence: 2, rotations: [.hips: simd_quatf(angle: 2.5, axis: simd_float3(1, 0, 0))])
        turned.positions = upright.mapValues { yaw.act($0) }
        let result = try XCTUnwrap(retargeter.retarget(turned))
        let hips = try XCTUnwrap(result.worldRotationDeltas["mixamorig:Pelvis"])
        assertEqual(hips, yaw)
        let chest = try XCTUnwrap(result.worldRotationDeltas["mixamorig:Spine3"])
        assertEqual(chest, yaw)
        let head = try XCTUnwrap(result.worldRotationDeltas["mixamorig:Head"])
        assertEqual(head, yaw) // rides on the neck
    }

    func testFilterUndoesASideSwapAndHoldsBackJumps() {
        var filter = MocapPoseFilter()
        var options = MocapSmoothingOptions()
        options.medianWindow = 1 // this test exercises a later stage
        func legs(_ left: simd_float3, _ right: simd_float3, sequence: UInt32) -> MocapFrame {
            var f = frame(sequence: sequence, rotations: [:])
            f.positions = [.leftUpLeg: left, .rightUpLeg: right, .leftFoot: left - simd_float3(0, 0.9, 0), .rightFoot: right - simd_float3(0, 0.9, 0)]
            for joint in [MocapJoint.leftLeg, .rightLeg, .leftToes, .rightToes] {
                f.positions[joint] = f.positions[joint.parent!]! - simd_float3(0, 0.05, 0)
            }
            return f
        }
        let left = simd_float3(0.1, 0.95, 0), right = simd_float3(-0.1, 0.95, 0)
        _ = filter.filter(legs(left, right, sequence: 1), at: 0, options: options)
        // The tracker relabels the legs: reversed hip axis in one frame.
        let swapped = filter.filter(legs(right, left, sequence: 2), at: 1 / 30, options: options)
        XCTAssertEqual(swapped.positions[.leftUpLeg], left)
        XCTAssertEqual(filter.swappedFrames, 1)
        // Arms are their own group: relabelled arms swap back on their own.
        func withArms(_ f: MocapFrame, leftArm: simd_float3, rightArm: simd_float3) -> MocapFrame {
            var f = f
            f.positions[.leftShoulder] = leftArm
            f.positions[.rightShoulder] = rightArm
            f.positions[.leftHand] = leftArm - simd_float3(0, 0.6, 0)
            f.positions[.rightHand] = rightArm - simd_float3(0, 0.6, 0)
            for joint in [MocapJoint.leftArm, .rightArm, .leftForearm, .rightForearm] {
                f.positions[joint] = f.positions[joint.parent!]! - simd_float3(0, 0.2, 0)
            }
            return f
        }
        let leftShoulder = simd_float3(0.2, 1.4, 0), rightShoulder = simd_float3(-0.2, 1.4, 0)
        _ = filter.filter(withArms(legs(right, left, sequence: 3), leftArm: leftShoulder, rightArm: rightShoulder), at: 2 / 30, options: options)
        let armsSwapped = filter.filter(withArms(legs(right, left, sequence: 4), leftArm: rightShoulder, rightArm: leftShoulder), at: 3 / 30, options: options)
        XCTAssertEqual(armsSwapped.positions[.leftHand], leftShoulder - simd_float3(0, 0.6, 0))
        XCTAssertEqual(armsSwapped.positions[.leftUpLeg], left, "legs untouched")
        XCTAssertEqual(filter.swappedFrames, 4, "the legs stayed relabelled for three frames, the arms for one")
        // A jump of 40 cm on a foot is held back…
        var jumpy = withArms(legs(right, left, sequence: 5), leftArm: rightShoulder, rightArm: leftShoulder)
        jumpy.positions[.leftFoot]! += simd_float3(0.4, 0, 0)
        let held = filter.filter(jumpy, at: 4 / 30, options: options)
        XCTAssertEqual(held.positions[.leftFoot], left - simd_float3(0, 0.9, 0))
        XCTAssertEqual(filter.rejectedFrames, 1)
        // …until it lasts longer than the hold, when it is taken as motion.
        _ = filter.filter({ var f = jumpy; f.sequence = 6; return f }(), at: 0.6, options: options)
        XCTAssertEqual(filter.rejectedFrames, 0)
    }

    func testPreviewFramesSplitIntoChunksAndReassemble() throws {
        let jpeg = Data((0 ..< 3000).map { UInt8($0 % 251) })
        let preview = MocapPreviewFrame(id: 7, width: 320, height: 180, jpeg: jpeg, keypoints: [.head: SIMD2(160, 20), .leftFoot: SIMD2(150, 170)])
        let chunks = preview.chunks()
        XCTAssertEqual(chunks.count, 3, "22 B of keypoints + 3000 B of picture at 1200 B per chunk")
        XCTAssertTrue(chunks.allSatisfy(MocapPreviewFrame.isChunk))
        XCTAssertFalse(MocapPreviewFrame.isChunk(frame(rotations: [:]).encode()))

        var assembler = MocapPreviewAssembler()
        // Out of order, with a stray chunk of an older frame in between.
        XCTAssertNil(assembler.add(chunks[2]))
        var old = MocapPreviewFrame(id: 6, width: 320, height: 180, jpeg: Data([1, 2, 3]), keypoints: [:])
        old.id = 6
        XCTAssertNil(assembler.add(old.chunks()[0]))
        XCTAssertNil(assembler.add(chunks[0]))
        let decoded = try XCTUnwrap(assembler.add(chunks[1]))
        XCTAssertEqual(decoded, preview)
        XCTAssertEqual(decoded.keypoints[.leftFoot], SIMD2(150, 170))
    }

    /// A foot that only wobbles is pinned and the knee re-solved for it;
    /// a real step releases it.
    func testStillFeetArePlantedAndStepsReleaseThem() {
        var filter = MocapPoseFilter()
        var options = MocapSmoothingOptions()
        options.medianWindow = 1 // this test exercises a later stage
        options.plantFeet = true
        options.bodyCutoff = 100 // no smoothing: isolate the planting
        options.legCutoff = 100
        options.rootCutoff = 100
        // A clearly bent knee (a straight leg cannot keep both bone lengths for a moved foot).
        let hip = simd_float3(0.1, 0.9, 0), knee = simd_float3(0.1, 0.5, 0.15), foot = simd_float3(0.1, 0.1, 0)
        func leg(_ footPosition: simd_float3, sequence: UInt32) -> MocapFrame {
            var f = frame(sequence: sequence, rotations: [:])
            f.positions = [.leftUpLeg: hip, .leftLeg: knee, .leftFoot: footPosition, .leftToes: footPosition + simd_float3(0, -0.05, 0.15)]
            return f
        }
        var generator = SystemRandomNumberGenerator()
        var last = foot
        for i in 0 ..< 60 {
            let wobble = simd_float3(Float.random(in: -0.015 ... 0.015, using: &generator), Float.random(in: -0.015 ... 0.015, using: &generator), 0)
            let out = filter.filter(leg(foot + wobble, sequence: UInt32(i + 1)), at: Double(i) / 60, options: options)
            last = out.positions[.leftFoot]!
        }
        XCTAssertTrue(filter.plantedFeet.contains(.leftFoot))
        XCTAssertLessThan(simd_length(last - foot), 0.01, "pinned near the mean of the wobble")
        let pinned = last
        let held = filter.filter(leg(foot + simd_float3(0.02, 0.01, 0), sequence: 61), at: 61 / 60, options: options)
        XCTAssertLessThan(simd_length(held.positions[.leftFoot]! - pinned), 0.01, "still pinned (creeping slowly)")
        let heldKnee = held.positions[.leftLeg]!
        XCTAssertEqual(simd_length(heldKnee - hip), simd_length(knee - hip), accuracy: 1e-4, "thigh length kept")
        // (the residual smoothing at a 100 Hz cut-off moves the tracked foot by a millimetre or two)
        XCTAssertEqual(simd_length(pinned - heldKnee), simd_length(foot + simd_float3(0.02, 0.01, 0) - knee), accuracy: 0.005, "shin length kept")
        // A 20 cm step (a real move, under the glitch limit) releases the
        // pin; the foot blends out toward the tracked one and reaches it
        // once the blend is over.
        let stepped = filter.filter(leg(foot + simd_float3(0.2, 0, 0), sequence: 62), at: 62 / 60, options: options)
        XCTAssertFalse(filter.plantedFeet.contains(.leftFoot))
        let releasedAt = simd_length(stepped.positions[.leftFoot]! - pinned)
        XCTAssertLessThan(releasedAt, 0.05, "no jump at release")
        let settled = filter.filter(leg(foot + simd_float3(0.2, 0, 0), sequence: 63), at: 62 / 60 + 0.3, options: options)
        XCTAssertLessThan(simd_length(settled.positions[.leftFoot]! - (foot + simd_float3(0.2, 0, 0))), 0.03, "follows the step after the blend (minus the residual smoothing)")
    }

    /// A 40° torso jump in one frame is held (the skeleton turned back
    /// about the hips) and released when the tracker comes back; a real
    /// turn at 10° per frame is followed.
    func testBodyYawJumpsAreHeldAndSlowTurnsFollow() throws {
        var filter = MocapPoseFilter()
        var options = MocapSmoothingOptions()
        options.medianWindow = 1 // this test exercises a later stage
        options.bodyCutoff = 100
        options.legCutoff = 100
        options.rootCutoff = 100
        let base: [MocapJoint: simd_float3] = [
            .hips: simd_float3(0, 0, 0), .leftUpLeg: simd_float3(0.1, -0.05, 0), .rightUpLeg: simd_float3(-0.1, -0.05, 0),
            .leftShoulder: simd_float3(0.18, 0.45, 0), .rightShoulder: simd_float3(-0.18, 0.45, 0),
            // Hand close to the body (as when it hangs): a 40° body jump
            // moves it under the arm jump limit, so only the yaw guard
            // can catch the jump.
            .rightHand: simd_float3(-0.3, 0.45, 0),
        ]
        func turned(_ yaw: Float, sequence: UInt32) -> MocapFrame {
            var f = frame(sequence: sequence, rotations: [:])
            let q = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
            f.positions = base.mapValues { q.act($0) }
            return f
        }
        for i in 0 ..< 10 {
            _ = filter.filter(turned(0, sequence: UInt32(i + 1)), at: Double(i) / 30, options: options)
        }
        // Tracker jumps 40° in one frame: held, hand stays where it was.
        let jumped = filter.filter(turned(0.7, sequence: 11), at: 10.0 / 30, options: options)
        XCTAssertTrue(filter.isYawHeld)
        let hand = try XCTUnwrap(jumped.positions[.rightHand])
        XCTAssertLessThan(simd_length(hand - base[.rightHand]!), 0.02)
        // Tracker comes back: released.
        _ = filter.filter(turned(0.05, sequence: 12), at: 11.0 / 30, options: options)
        XCTAssertFalse(filter.isYawHeld)
        // A real turn, 10° per frame, is followed.
        var last: MocapFrame?
        for i in 0 ..< 9 {
            last = filter.filter(turned(Float(i + 1) * 0.1745, sequence: UInt32(13 + i)), at: (12.0 + Double(i)) / 30, options: options)
        }
        XCTAssertFalse(filter.isYawHeld)
        let turnedHand = try XCTUnwrap(last?.positions[.rightHand])
        let expected = simd_quatf(angle: 9 * 0.1745, axis: simd_float3(0, 1, 0)).act(base[.rightHand]!)
        XCTAssertLessThan(simd_length(turnedHand - expected), 0.02)
    }

    /// The headset's rotation drives the head like a mirror: a turn to one
    /// side reads as the opposite turn in the character's space (which
    /// faces the wearer), a nod stays a nod in the same direction.
    func testHeadFollowsTheHeadsetLikeAMirror() {
        let facingWearer = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
        let reference = simd_quatf(angle: 0.2, axis: simd_float3(0, 1, 0))
        var options = MocapRetargetOptions()
        options.mirror = true

        let turn = simd_quatf(angle: 0.5, axis: simd_float3(0, 1, 0)) * reference
        let turned = CoolMirrorMocapController.headDelta(pose: turn, reference: reference, entityRotation: facingWearer, options: options)
        assertEqual(turned, simd_quatf(angle: -0.5, axis: simd_float3(0, 1, 0)))

        let nod = simd_quatf(angle: 0.3, axis: simd_float3(1, 0, 0)) * reference
        let nodded = CoolMirrorMocapController.headDelta(pose: nod, reference: reference, entityRotation: facingWearer, options: options)
        assertEqual(nodded, simd_quatf(angle: 0.3, axis: simd_float3(1, 0, 0)))

        // Mirror off: the plain rotation in the character's frame (a nod
        // about world x is a nod about -x in a frame turned half a turn).
        options.mirror = false
        let direct = CoolMirrorMocapController.headDelta(pose: nod, reference: reference, entityRotation: facingWearer, options: options)
        assertEqual(direct, simd_quatf(angle: -0.3, axis: simd_float3(1, 0, 0)))
    }

    /// A wrong detection lasting one or two frames never reaches the
    /// output with a 5-frame median; a sustained move does, two frames late.
    func testMedianDropsShortWrongDetections() {
        var filter = MocapPoseFilter()
        var options = MocapSmoothingOptions()
        options.bodyCutoff = 100
        options.legCutoff = 100
        options.rootCutoff = 100
        options.plantFeet = false
        let rest = simd_float3(0.3, 1.0, 0)
        func hand(_ p: simd_float3, sequence: UInt32) -> MocapFrame {
            var f = frame(sequence: sequence, rotations: [:])
            f.positions = [.leftHand: p]
            return f
        }
        var maxDeviation: Float = 0
        for i in 0 ..< 30 {
            // Frames 10 and 11 are wrong by 30 cm.
            let p = (i == 10 || i == 11) ? rest + simd_float3(0.3, 0, 0) : rest
            let out = filter.filter(hand(p, sequence: UInt32(i + 1)), at: Double(i) / 60, options: options)
            maxDeviation = max(maxDeviation, simd_length(out.positions[.leftHand]! - rest))
        }
        XCTAssertLessThan(maxDeviation, 0.01, "two wrong frames out of five never show")
        // A real move is followed after the median delay.
        var last = rest
        for i in 30 ..< 40 {
            last = filter.filter(hand(rest + simd_float3(0.3, 0, 0), sequence: UInt32(i + 1)), at: Double(i) / 60, options: options).positions[.leftHand]!
        }
        XCTAssertLessThan(simd_length(last - (rest + simd_float3(0.3, 0, 0))), 0.03)
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
