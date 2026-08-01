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
        XCTAssertEqual(MemoryLayout<CoolWebStrandGPU>.stride, 32)
        XCTAssertEqual(MemoryLayout<CoolWebSplatGPU>.stride, 48)
        // 64 (viewProj) + 16 (cameraWorld) + 16 (counts) + 4*32 + 4*48
        XCTAssertEqual(MemoryLayout<CoolWebUniforms>.stride, 416)
    }

    func testSceneStateSanitizesInput() {
        let state = CoolWebSceneState.shared
        state.clear()

        let straight = (0 ..< 8).map { SIMD3<Float>(0, Float($0) * 0.1, 0) }
        setCoolWebScene(
            strands: [
                CoolWebStrandDesc(particles: straight),
                CoolWebStrandDesc(particles: [SIMD3<Float>(0, 0, 0)]), // too short
            ],
            splats: [
                CoolWebSplatDesc(center: .zero, normal: SIMD3<Float>(0, 0, 3)),
                CoolWebSplatDesc(center: .zero, normal: .zero), // degenerate
            ]
        )

        let snapshot = state.state()
        XCTAssertEqual(snapshot.strands.count, 1)
        XCTAssertEqual(snapshot.splats.count, 1)
        XCTAssertEqual(simd_length(snapshot.splats[0].normal), 1, accuracy: 1e-5)

        clearCoolWebScene()
        XCTAssertTrue(state.state().strands.isEmpty)
        XCTAssertTrue(state.state().splats.isEmpty)
    }

    func testSceneStateCapsCountsAtShaderLimits() {
        let particles = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0)]
        let manyStrands = (0 ..< 10).map { _ in CoolWebStrandDesc(particles: particles) }
        let manySplats = (0 ..< 10).map { _ in
            CoolWebSplatDesc(center: .zero, normal: SIMD3<Float>(0, 1, 0))
        }
        setCoolWebScene(strands: manyStrands, splats: manySplats)
        let snapshot = CoolWebSceneState.shared.state()
        XCTAssertLessThanOrEqual(snapshot.strands.count, CoolWebShaderLimits.maxStrands)
        XCTAssertLessThanOrEqual(snapshot.splats.count, CoolWebShaderLimits.maxSplats)
        clearCoolWebScene()
    }

    func testOversizedStrandIsTruncatedToParticleLimit() {
        let particles = (0 ..< 200).map { SIMD3<Float>(Float($0) * 0.01, 0, 0) }
        setCoolWebScene(strands: [CoolWebStrandDesc(particles: particles)])
        let snapshot = CoolWebSceneState.shared.state()
        XCTAssertEqual(
            snapshot.strands.first?.particles.count,
            CoolWebShaderLimits.strandParticles
        )
        clearCoolWebScene()
    }
}
