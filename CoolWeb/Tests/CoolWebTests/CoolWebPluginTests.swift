@testable import CoolWeb
import simd
import UntoldEngine
import XCTest

final class CoolWebPluginTests: XCTestCase {
    func testManifestUsesContractIdentifier() {
        let plugin = CoolWebPlugin()
        XCTAssertEqual(plugin.manifest.id, CoolWebPluginContract.pluginID)
    }

    func testPluginProvidesTheRenderExtension() {
        let extensions = CoolWebPlugin().makeRenderExtensions()
        XCTAssertEqual(extensions.count, 1)
        XCTAssertEqual(extensions.first?.id, CoolWebPluginContract.extensionID)
    }

    func testContractIdentifiersAreNamespacedByPluginID() {
        let prefix = CoolWebPluginContract.pluginID + "."
        XCTAssertTrue(CoolWebPluginContract.extensionID.hasPrefix(prefix))
        XCTAssertTrue(CoolWebPluginContract.shaderLibraryID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolWebPluginContract.strandPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolWebPluginContract.occlusionPipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolWebPluginContract.scenePassID.hasPrefix(prefix))
    }

    func testBundledMetallibExistsForCurrentPlatform() {
        XCTAssertNotNil(CoolWebPlugin.bundledMetallibURL)
    }

    /// Guards the hand-maintained mirror of CoolWebShaderTypes.h. If either
    /// file changes shape, this fails before the GPU reads garbage.
    func testShaderABIStrideMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<CoolWebSegmentGPU>.stride, 48)
        XCTAssertEqual(MemoryLayout<CoolWebSplatGPU>.stride, 48)
        XCTAssertEqual(MemoryLayout<CoolWebGloveVertexGPU>.stride, 64)
        // 64 (viewProj) + 16 (cameraWorld) + 16 (counts) + 4*48 (splats)
        XCTAssertEqual(MemoryLayout<CoolWebUniforms>.stride, 288)
    }

    func testSceneStateSanitizesInput() {
        let state = CoolWebSceneState.shared
        state.clear()
        setCoolWebSplatsEnabled(true)
        defer { setCoolWebSplatsEnabled(false) }

        setCoolWebScene(
            segments: [
                CoolWebSegmentDesc(a: .zero, b: SIMD3<Float>(0, 1, 0)),
                CoolWebSegmentDesc(a: .zero, b: .zero, opacity: 0), // invisible
            ],
            splats: [
                CoolWebSplatDesc(center: .zero, normal: SIMD3<Float>(0, 0, 3)),
                CoolWebSplatDesc(center: .zero, normal: .zero), // degenerate
            ]
        )

        let snapshot = state.state()
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.splats.count, 1)
        XCTAssertEqual(simd_length(snapshot.splats[0].normal), 1, accuracy: 1e-5)

        clearCoolWebScene()
        XCTAssertTrue(state.state().segments.isEmpty)
        XCTAssertTrue(state.state().splats.isEmpty)
    }

    func testSceneStateCapsCountsAtShaderLimits() {
        setCoolWebSplatsEnabled(true)
        defer { setCoolWebSplatsEnabled(false) }
        let manySegments = (0 ..< CoolWebShaderLimits.maxSegments + 100).map { i in
            CoolWebSegmentDesc(
                a: SIMD3<Float>(Float(i), 0, 0),
                b: SIMD3<Float>(Float(i), 1, 0)
            )
        }
        let manySplats = (0 ..< 10).map { _ in
            CoolWebSplatDesc(center: .zero, normal: SIMD3<Float>(0, 1, 0))
        }
        setCoolWebScene(segments: manySegments, splats: manySplats)
        let snapshot = CoolWebSceneState.shared.state()
        XCTAssertLessThanOrEqual(snapshot.segments.count, CoolWebShaderLimits.maxSegments)
        XCTAssertLessThanOrEqual(snapshot.splats.count, CoolWebShaderLimits.maxSplats)
        clearCoolWebScene()
    }

    func testSplatsAreDroppedWhileDisabled() {
        setCoolWebSplatsEnabled(false)
        setCoolWebScene(
            segments: [CoolWebSegmentDesc(a: .zero, b: SIMD3<Float>(0, 1, 0))],
            splats: [CoolWebSplatDesc(center: .zero, normal: SIMD3<Float>(0, 0, 1))]
        )
        XCTAssertTrue(
            CoolWebSceneState.shared.state().splats.isEmpty,
            "disabled impact splats must not reach the renderer"
        )
        clearCoolWebScene()
    }

    func testTensionHeatmapFlagSurvivesSceneUpdatesAndClear() {
        setCoolWebTensionHeatmap(true)
        setCoolWebScene(segments: [
            CoolWebSegmentDesc(a: .zero, b: SIMD3<Float>(0, 1, 0)),
        ])
        XCTAssertTrue(CoolWebSceneState.shared.state().tensionHeatmap)
        clearCoolWebScene()
        XCTAssertTrue(
            CoolWebSceneState.shared.state().tensionHeatmap,
            "clear() drops geometry, not the debug toggle"
        )
        setCoolWebTensionHeatmap(false)
        XCTAssertFalse(CoolWebSceneState.shared.state().tensionHeatmap)
    }
}
