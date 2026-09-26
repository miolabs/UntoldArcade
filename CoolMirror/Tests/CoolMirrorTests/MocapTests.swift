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
        let original = frame(sequence: 42, rotations: [.leftArm: simd_quatf(angle: 0.4, axis: simd_float3(0, 0, 1))], root: simd_float3(0.1, 1.2, -0.3))
        let data = original.encode()
        XCTAssertEqual(data.count, 36 + MocapJoint.allCases.count * 20)
        let decoded = try XCTUnwrap(MocapFrame(data: data))
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.timestamp, 12.5)
        XCTAssertTrue(decoded.isTracked)
        XCTAssertEqual(decoded.rootPosition, original.rootPosition)
        XCTAssertEqual(decoded.rotations.count, MocapJoint.allCases.count)
        assertEqual(decoded.rotations[.leftArm]!, original.rotations[.leftArm]!)
        XCTAssertNil(MocapFrame(data: data.prefix(20)))
        XCTAssertNil(MocapFrame(data: Data([1, 2, 3, 4])))
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
