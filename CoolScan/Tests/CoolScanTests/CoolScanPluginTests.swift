@testable import CoolScan
import simd
import UntoldEngine
import XCTest

final class CoolScanPluginTests: XCTestCase {
    func testManifestUsesContractIdentifier() {
        let plugin = CoolScanPlugin()
        XCTAssertEqual(plugin.manifest.id, CoolScanPluginContract.pluginID)
    }

    func testPluginProvidesTheRenderExtension() {
        let extensions = CoolScanPlugin().makeRenderExtensions()
        XCTAssertEqual(extensions.count, 1)
        XCTAssertEqual(extensions.first?.id, CoolScanPluginContract.extensionID)
    }

    func testContractIdentifiersAreNamespacedByPluginID() {
        let prefix = CoolScanPluginContract.pluginID + "."
        XCTAssertTrue(CoolScanPluginContract.extensionID.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.shaderLibraryID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.toonPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.toonArgumentLayoutID.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.surfacePassID.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.comicPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.pixelPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.sketchPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.edgePipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.screenPassID.hasPrefix(prefix))
        XCTAssertTrue(CoolScanPluginContract.scratchTextureID.rawValue.hasPrefix(prefix))
    }

    func testBundledMetallibExistsForCurrentPlatform() {
        XCTAssertNotNil(CoolScanPlugin.bundledMetallibURL)
    }

    /// Guards the hand-maintained mirror of CoolScanShaderTypes.h. If either
    /// file changes shape, this fails before the GPU reads garbage.
    func testShaderABIStrideMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<CoolScanToonUniforms>.stride, 48)
        XCTAssertEqual(MemoryLayout<CoolScanScreenUniforms>.stride, 32)
    }

    func testStyleStateRoundTrip() {
        let previousStyle = getCoolScanStyle()
        defer { setCoolScanStyle(previousStyle) }

        for style in CoolScanStyle.allCases {
            setCoolScanStyle(style)
            XCTAssertEqual(getCoolScanStyle(), style)
        }
    }

    func testLightDirectionIsNormalizedAndRejectsDegenerate() {
        setCoolScanLightDirection(SIMD3<Float>(0, -3, 0))
        var snapshot = CoolScanStyleState.shared.snapshot()
        XCTAssertEqual(simd_length(snapshot.lightDirection), 1, accuracy: 1e-5)

        let before = snapshot.lightDirection
        setCoolScanLightDirection(.zero) // degenerate → ignored
        snapshot = CoolScanStyleState.shared.snapshot()
        XCTAssertEqual(snapshot.lightDirection, before)
    }
}
