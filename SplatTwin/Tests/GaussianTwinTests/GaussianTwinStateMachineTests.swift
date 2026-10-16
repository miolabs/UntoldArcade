//
//  GaussianTwinStateMachineTests.swift
//  GaussianTwinTests
//

import Foundation
import simd
import UntoldEngine
import XCTest

/// The swap's state machine and distance rule, and the component's registration.
@MainActor
final class GaussianTwinStateMachineTests: XCTestCase {
    override func tearDown() async throws {
        // Leave the engine's globals as we found them for the next test in the process.
        CameraSystem.shared.activeCamera = nil
        GaussianTwinSystem.shared.splatRenderingAvailableOverride = nil
        GaussianTwinSystem.shared.resetSceneLinkAdoption()
        destroyAllEntities()
        try await super.tearDown()
    }

    private func step(
        _ state: GaussianTwinState,
        progress: Float = 0,
        wantsSwap: Bool = true,
        resident: Bool = true,
        loadFailed: Bool = false,
        deltaTime: Float = 0.05,
        duration: Float = 0.25
    ) -> GaussianTwinStep {
        gaussianTwinStep(
            state: state,
            progress: progress,
            wantsSwap: wantsSwap,
            payloadResident: resident,
            loadFailed: loadFailed,
            deltaTime: deltaTime,
            duration: duration
        )
    }

    // MARK: - State machine

    func testArmedWaitsUntilTheSwapIsWanted() {
        XCTAssertEqual(step(.armed, wantsSwap: false), GaussianTwinStep(state: .armed, progress: 0))
        XCTAssertEqual(step(.armed, resident: false), GaussianTwinStep(state: .loading, progress: 0), "Not resident: load first")
        XCTAssertEqual(step(.armed, resident: true), GaussianTwinStep(state: .crossFading, progress: 0), "Resident: fade at once")
        XCTAssertEqual(step(.armed, resident: false, loadFailed: true), GaussianTwinStep(state: .armed, progress: 0), "A failed load does not retry")
    }

    func testLoadingChangesNothingUntilThePayloadIsResident() {
        XCTAssertEqual(step(.loading, resident: false), GaussianTwinStep(state: .loading, progress: 0))
        XCTAssertEqual(step(.loading, resident: true), GaussianTwinStep(state: .crossFading, progress: 0))
        XCTAssertEqual(step(.loading, wantsSwap: false, resident: true), GaussianTwinStep(state: .armed, progress: 0), "Camera left meanwhile: stay on the mesh, keep the payload")
        XCTAssertEqual(step(.loading, resident: false, loadFailed: true), GaussianTwinStep(state: .armed, progress: 0))
    }

    func testCrossFadeRunsOverTheDurationAndEndsSwapped() {
        var current = step(.crossFading, progress: 0, deltaTime: 0.1, duration: 0.25)
        XCTAssertEqual(current.state, .crossFading)
        XCTAssertEqual(current.progress, 0.4, accuracy: 1e-5)
        current = step(.crossFading, progress: current.progress, deltaTime: 0.1, duration: 0.25)
        XCTAssertEqual(current.progress, 0.8, accuracy: 1e-5)
        current = step(.crossFading, progress: current.progress, deltaTime: 0.1, duration: 0.25)
        XCTAssertEqual(current, GaussianTwinStep(state: .swapped, progress: 1))
        XCTAssertEqual(step(.swapped), GaussianTwinStep(state: .swapped, progress: 1))
    }

    func testRevertMirrorsTheFadeAndCanTurnAroundMidway() {
        XCTAssertEqual(step(.swapped, wantsSwap: false), GaussianTwinStep(state: .reverting, progress: 0))
        // Turning around keeps the on-screen blend where it is: 30% faded in becomes 70% reverted.
        XCTAssertEqual(step(.crossFading, progress: 0.3, wantsSwap: false), GaussianTwinStep(state: .reverting, progress: 0.7))
        XCTAssertEqual(step(.reverting, progress: 0.7, wantsSwap: true), GaussianTwinStep(state: .crossFading, progress: 0.3))
        var current = step(.reverting, progress: 0.9, wantsSwap: false, deltaTime: 0.1, duration: 0.25)
        XCTAssertEqual(current, GaussianTwinStep(state: .armed, progress: 0), "The reverse fade ends armed")
        current = step(.reverting, progress: 0, wantsSwap: false, deltaTime: 0.05, duration: 0.25)
        XCTAssertEqual(current.state, .reverting)
        XCTAssertEqual(current.progress, 0.2, accuracy: 1e-5)
    }

    /// The splat can go away under a running swap (an app dropped it, memory pressure). Every
    /// state that shows or fades it falls back to the plain mesh at once, never a colour-off
    /// mesh with nothing in its place.
    func testLosingThePayloadUnderARunningSwapFallsBackToTheMesh() {
        XCTAssertEqual(step(.crossFading, progress: 0.5, resident: false), GaussianTwinStep(state: .armed, progress: 0))
        XCTAssertEqual(step(.swapped, progress: 1, resident: false), GaussianTwinStep(state: .armed, progress: 0))
        XCTAssertEqual(step(.reverting, progress: 0.5, resident: false), GaussianTwinStep(state: .armed, progress: 0))
        XCTAssertEqual(step(.swapped, wantsSwap: false, resident: false), GaussianTwinStep(state: .armed, progress: 0))
        // And with the camera still near, the next tick loads again.
        XCTAssertEqual(step(.armed, resident: false), GaussianTwinStep(state: .loading, progress: 0))
    }

    func testAZeroDurationDoesNotDivideByZero() {
        XCTAssertEqual(step(.crossFading, deltaTime: 0.016, duration: 0), GaussianTwinStep(state: .swapped, progress: 1))
    }

    // MARK: - Distance rule and opacity mapping

    func testSwapDistanceWithHysteresis() {
        let options = GaussianTwinOptions(swapDistanceMeters: 10, hysteresisMeters: 2)
        XCTAssertTrue(gaussianTwinWantsSwap(distance: 9, options: options, state: .armed))
        XCTAssertFalse(gaussianTwinWantsSwap(distance: 11, options: options, state: .armed), "Arming needs the inner threshold")
        XCTAssertTrue(gaussianTwinWantsSwap(distance: 11, options: options, state: .swapped), "Swapped holds through the band")
        XCTAssertTrue(gaussianTwinWantsSwap(distance: 11, options: options, state: .loading))
        XCTAssertFalse(gaussianTwinWantsSwap(distance: 12.5, options: options, state: .swapped), "Beyond the band it reverts")
        XCTAssertFalse(gaussianTwinWantsSwap(distance: 11, options: options, state: .reverting), "Re-swapping mid-revert needs the inner threshold again")

        let always = GaussianTwinOptions(swapDistanceMeters: 0)
        XCTAssertTrue(gaussianTwinWantsSwap(distance: 1000, options: always, state: .armed))
    }

    func testSplatOpacityFollowsTheState() {
        XCTAssertEqual(gaussianTwinSplatOpacity(state: .armed, progress: 0.5), 0)
        XCTAssertEqual(gaussianTwinSplatOpacity(state: .loading, progress: 0.5), 0)
        XCTAssertEqual(gaussianTwinSplatOpacity(state: .crossFading, progress: 0.25), 0.25)
        XCTAssertEqual(gaussianTwinSplatOpacity(state: .swapped, progress: 0), 1)
        XCTAssertEqual(gaussianTwinSplatOpacity(state: .reverting, progress: 0.25), 0.75)
    }

    func testOptionsFromASceneLinkTakeTheRecordValues() {
        let link = GaussianAssetLinkComponent()
        link.swapDistanceMeters = 4
        link.occluderShrinkMeters = 0.03
        link.exposureOffsetEV = 0.5
        let options = GaussianTwinOptions(link: link)
        XCTAssertEqual(options.swapDistanceMeters, 4)
        XCTAssertEqual(options.occluderShrinkMeters, 0.03)
        XCTAssertEqual(options.exposureOffsetEV, 0.5)
        XCTAssertEqual(options.crossFadeDuration, 0.25, "Not in the record: the default")
        XCTAssertNil(options.alignment, "No alignment in the record: identity")

        let alignment = GaussianSplatAlignment(translation: SIMD3<Float>(0, 0.02, -0.1), yawDegrees: 90, scale: 1.02)
        link.alignment = alignment
        let aligned = GaussianTwinOptions(link: link)
        XCTAssertEqual(aligned.alignment, alignment)
        XCTAssertNotEqual(aligned, options, "The alignment is part of the options' equality")
    }

    /// A resident splat's placement follows the twin's options tick by tick: an alignment set
    /// after the link moves it without relinking, nil puts it back to identity.
    func testAResidentSplatFollowsTheOptionsAlignment() {
        GaussianTwinSystem.shared.splatRenderingAvailableOverride = true
        let camera = createEntity()
        registerComponent(entityId: camera, componentType: CameraComponent.self)
        CameraSystem.shared.activeCamera = camera

        let entity = createEntity()
        registerTransformComponent(entityId: entity)
        let alignment = GaussianSplatAlignment(translation: SIMD3<Float>(1, 0, 0), yawDegrees: 30, scale: 1.5)
        setEntityGaussianTwin(entityId: entity, payloadURL: URL(fileURLWithPath: "/tmp/chair.untoldgs"), options: GaussianTwinOptions(alignment: alignment))
        // A splat on the entity (no renderer needed to carry the component) is the twin's payload.
        registerComponent(entityId: entity, componentType: GaussianComponent.self)
        let gaussian = scene.get(component: GaussianComponent.self, for: entity)
        XCTAssertEqual(gaussian?.splatToEntity, matrix_identity_float4x4, "Nothing applied before the first tick")

        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(gaussian?.splatToEntity, alignment.matrix, "The link's alignment is on the component")

        let moved = GaussianSplatAlignment(translation: SIMD3<Float>(0, 0.5, 0), yawDegrees: -45, scale: 0.9)
        scene.get(component: GaussianTwinComponent.self, for: entity)?.options.alignment = moved
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(gaussian?.splatToEntity, moved.matrix, "An options change moves the resident splat on the next tick")

        scene.get(component: GaussianTwinComponent.self, for: entity)?.options.alignment = nil
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(gaussian?.splatToEntity, matrix_identity_float4x4, "nil is identity")

        scene.get(component: GaussianTwinComponent.self, for: entity)?.options.alignment = moved
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        for invalid in [
            GaussianSplatAlignment(scale: 0),
            GaussianSplatAlignment(yawDegrees: .nan),
            GaussianSplatAlignment(translation: SIMD3<Float>(.infinity, 0, 0)),
        ] {
            scene.get(component: GaussianTwinComponent.self, for: entity)?.options.alignment = invalid
            GaussianTwinSystem.shared.update(deltaTime: 0.016)
            XCTAssertEqual(gaussian?.splatToEntity, matrix_identity_float4x4, "An invalid alignment places the splat at identity: \(invalid)")
        }
    }

    // MARK: - Registration (needs the engine's scene, no renderer)

    func testSetEntityGaussianTwinRegistersAnArmedComponentAndRemoveUnlinks() {
        let entity = createEntity()
        registerTransformComponent(entityId: entity)
        let url = URL(fileURLWithPath: "/tmp/chair.untoldgs")
        let options = GaussianTwinOptions(swapDistanceMeters: 3, crossFadeDuration: 0.3, occluderShrinkMeters: 0.05, exposureOffsetEV: 0.5, useRealWorldTint: true)

        setEntityGaussianTwin(entityId: entity, payloadURL: url, options: options)

        let twin = scene.get(component: GaussianTwinComponent.self, for: entity)
        XCTAssertEqual(twin?.payloadURL, url)
        XCTAssertEqual(twin?.options, options)
        XCTAssertEqual(twin?.state, .armed)
        XCTAssertNil(scene.get(component: GaussianComponent.self, for: entity), "Linking loads nothing")
        XCTAssertNil(scene.get(component: MeshOccluderComponent.self, for: entity), "Armed: no shell")

        removeEntityGaussianTwin(entityId: entity)
        XCTAssertNil(scene.get(component: GaussianTwinComponent.self, for: entity))
    }

    func testTwinWithoutMeshStaysArmedAndLoadsNothing() {
        GaussianTwinSystem.shared.splatRenderingAvailableOverride = true
        let entity = createEntity()
        registerTransformComponent(entityId: entity)
        setEntityGaussianTwin(entityId: entity, payloadURL: URL(fileURLWithPath: "/tmp/chair.untoldgs"))

        let camera = createEntity()
        registerComponent(entityId: camera, componentType: CameraComponent.self)
        CameraSystem.shared.activeCamera = camera

        GaussianTwinSystem.shared.update(deltaTime: 0.016)

        let twin = scene.get(component: GaussianTwinComponent.self, for: entity)
        XCTAssertEqual(twin?.state, .armed, "Nothing to swap from yet")
        XCTAssertNil(twin?.loadTask)
    }

    /// A scene link flagged `meshTwin` is adopted once; unlinking it sticks, and a link that is
    /// not a mesh twin is never adopted.
    func testSceneLinksAreAdoptedOnceAndUnlinkingSticks() {
        GaussianTwinSystem.shared.splatRenderingAvailableOverride = true
        let camera = createEntity()
        registerComponent(entityId: camera, componentType: CameraComponent.self)
        CameraSystem.shared.activeCamera = camera

        let twinEntity = createEntity()
        registerTransformComponent(entityId: twinEntity)
        registerComponent(entityId: twinEntity, componentType: RenderComponent.self)
        registerComponent(entityId: twinEntity, componentType: GaussianAssetLinkComponent.self)
        let link = scene.get(component: GaussianAssetLinkComponent.self, for: twinEntity)
        link?.payloadURL = URL(fileURLWithPath: "/tmp/chair.untoldgs")
        link?.flags = UntoldGaussianAssetFlags.meshTwin
        link?.swapDistanceMeters = 7

        let environmentEntity = createEntity()
        registerTransformComponent(entityId: environmentEntity)
        registerComponent(entityId: environmentEntity, componentType: RenderComponent.self)
        registerComponent(entityId: environmentEntity, componentType: GaussianAssetLinkComponent.self)
        scene.get(component: GaussianAssetLinkComponent.self, for: environmentEntity)?.payloadURL = URL(fileURLWithPath: "/tmp/room.untoldgs")
        scene.get(component: GaussianAssetLinkComponent.self, for: environmentEntity)?.flags = UntoldGaussianAssetFlags.environment

        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        let twin = scene.get(component: GaussianTwinComponent.self, for: twinEntity)
        XCTAssertNotNil(twin, "The meshTwin link is adopted")
        XCTAssertEqual(twin?.options.swapDistanceMeters, 7, "With the record's settings")
        XCTAssertNil(scene.get(component: GaussianTwinComponent.self, for: environmentEntity), "An environment link is not a twin")

        removeEntityGaussianTwin(entityId: twinEntity)
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertNil(scene.get(component: GaussianTwinComponent.self, for: twinEntity), "Unlinking sticks across ticks")

        setEntityGaussianTwin(entityId: twinEntity, payloadURL: URL(fileURLWithPath: "/tmp/other.untoldgs"))
        XCTAssertEqual(scene.get(component: GaussianTwinComponent.self, for: twinEntity)?.payloadURL?.lastPathComponent, "other.untoldgs", "An explicit relink works after an unlink")
    }

    func testUninstallPutsTwinsBackOnTheirMeshAndInstallCanFollow() {
        GaussianTwinSystem.shared.install()
        let entity = createEntity()
        registerTransformComponent(entityId: entity)
        setEntityGaussianTwin(entityId: entity, payloadURL: URL(fileURLWithPath: "/tmp/chair.untoldgs"))
        let twin = scene.get(component: GaussianTwinComponent.self, for: entity)
        twin?.state = .swapped
        registerComponent(entityId: entity, componentType: MeshOccluderComponent.self)
        scene.get(component: MeshOccluderComponent.self, for: entity)?.drawsColor = false

        GaussianTwinSystem.shared.uninstall()
        XCTAssertEqual(twin?.state, .armed)
        XCTAssertNil(scene.get(component: MeshOccluderComponent.self, for: entity), "The shell is gone with the system")
        XCTAssertFalse(EngineExtensionRegistry.shared.registeredIDs().contains(GaussianTwinSystem.shared.id))

        GaussianTwinSystem.shared.install()
        XCTAssertTrue(EngineExtensionRegistry.shared.registeredIDs().contains(GaussianTwinSystem.shared.id), "install works again after uninstall")
        GaussianTwinSystem.shared.uninstall()
    }
}
