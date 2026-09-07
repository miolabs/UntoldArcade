//
//  SplatSynthesizerTests.swift
//  SplatTwinTests
//

import simd
@testable import SplatTwin
import UntoldEngine
import XCTest

final class SplatSynthesizerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SplatSynthesizerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCubeSplatsLieOnTheSurfaceAndFaceOutward() {
        let splats = SplatSynthesizer.splats(for: .cube(extent: 1.0), baseColor: SIMD3(0.8, 0.5, 0.2), spacing: 0.1)
        XCTAssertEqual(splats.count, 6 * 10 * 10, "Ten by ten per face at 10 cm spacing")
        for splat in splats {
            let onFace = (0 ..< 3).contains { abs(abs(splat.position[$0]) - 0.5) < 1e-4 }
            XCTAssertTrue(onFace, "A cube splat sits on one of the faces: \(splat.position)")
            XCTAssertLessThanOrEqual(abs(splat.position).max(), 0.5 + 0.1 * 0.15 + 1e-4, "Jitter stays in the surface")
            XCTAssertEqual(simd_length(splat.rotation.vector), 1, accuracy: 1e-4)
            XCTAssertGreaterThan(splat.scale.min(), 0)
            XCTAssertTrue(splat.color.min() >= 0 && splat.color.max() <= 1)
        }
    }

    func testSphereAndCylinderCoverTheirSurfaces() {
        let sphere = SplatSynthesizer.splats(for: .sphere(extent: 1.2), baseColor: SIMD3(repeating: 0.5), spacing: 0.05)
        XCTAssertGreaterThan(sphere.count, 1000)
        for splat in sphere {
            XCTAssertEqual(simd_length(splat.position), 0.6, accuracy: 0.05 * 0.15 + 1e-3)
        }

        let cylinder = SplatSynthesizer.splats(for: .cylinder(height: 1.2, radius: 0.45), baseColor: SIMD3(repeating: 0.5), spacing: 0.05)
        XCTAssertGreaterThan(cylinder.count, 1000)
        let box = SplatSynthesizer.Shape.cylinder(height: 1.2, radius: 0.45).boundingBox
        for splat in cylinder {
            XCTAssertTrue(simd_reduce_min(splat.position - box.min) >= -0.01 && simd_reduce_max(splat.position - box.max) <= 0.01)
        }
    }

    func testShadingBakesTheLightIn() {
        let lit = SplatSynthesizer.shaded(SIMD3(repeating: 1), normal: SplatSynthesizer.bakedLightDirection, checker: 0)
        let dark = SplatSynthesizer.shaded(SIMD3(repeating: 1), normal: -SplatSynthesizer.bakedLightDirection, checker: 0)
        XCTAssertEqual(lit.x, 1, accuracy: 1e-5, "Facing the light: full colour")
        XCTAssertEqual(dark.x, 0.38, accuracy: 1e-5, "Facing away: the ambient floor")
    }

    func testTwinFileIsWrittenOnceAndReadsBackWithTheSplatCount() throws {
        let url = try SplatSynthesizer.twinFile(for: .cube(extent: 1.0), baseColor: SIMD3(0.8, 0.5, 0.2), spacing: 0.1, name: "crate", in: temporaryDirectory)
        let firstWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let header = try UntoldGSFormat.readHeaderV3(from: url)
        XCTAssertEqual(Int(header.splatCount), 600)
        XCTAssertEqual(header.boundingBoxMin, SIMD3(-0.5, -0.5, -0.5))
        XCTAssertEqual(header.boundingBoxMax, SIMD3(0.5, 0.5, 0.5))

        let again = try SplatSynthesizer.twinFile(for: .cube(extent: 1.0), baseColor: SIMD3(0.8, 0.5, 0.2), spacing: 0.1, name: "crate", in: temporaryDirectory)
        XCTAssertEqual(again, url)
        let secondWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(firstWrite, secondWrite, "The cached file is reused")
    }
}
