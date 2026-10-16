//
//  GaussianTwinSystem.swift
//  SplatTwin
//
//  Swaps a mesh for its captured Gaussian-splat twin up close: loads the payload onto the
//  mesh entity, cross-fades the two, and keeps the mesh's depth through the engine's shrunk
//  occluder shell while the splat is shown. Shadows, physics and picking keep using the mesh
//  throughout. The engine provides the mechanisms (MeshOccluderComponent, MeshFadeComponent,
//  GaussianComponent.opacityScale, the gaussianAsset link and the URL splat loader); this
//  system is the policy: when, from what distance, how fast.
//

import Foundation
import simd
import UntoldEngine

final class GaussianTwinSystem: EngineExtension, @unchecked Sendable {
    static let shared = GaussianTwinSystem()

    let id = "com.untoldengine.splattwin.gaussianTwins"

    /// Whether twins are attached automatically to mesh entities that a `.untold` scene linked
    /// through a `gaussianAsset` record flagged `meshTwin` (`GaussianAssetLinkComponent`).
    var adoptsSceneLinks = true

    /// Longest frame the fade integrates, so a hitch does not jump it to the end.
    private let maxDeltaTime: Float = 0.1
    private var installed = false
    /// Scene links already looked at (adopted, not a twin, or unlinked by the app), so the
    /// per-frame adoption only touches new ones.
    private var examinedSceneLinks: Set<EntityID> = []

    /// Tests set this to exercise the state machine with or without a renderer.
    var splatRenderingAvailableOverride: Bool?

    private init() {}

    // MARK: - Lifecycle

    /// Registers the system with the engine: it ticks once per frame from the engine's update
    /// and cleans up its component when an entity is destroyed. Call once at start-up.
    func install() {
        guard !installed else { return }
        installed = true
        ComponentRegistry.register(componentType: GaussianTwinComponent.self, handlerId: "gaussianTwin", priority: 29) { entityId in
            removeEntityGaussianTwin(entityId: entityId)
        }
        _ = EngineExtensionRegistry.shared.register(self)
    }

    /// Stops ticking and puts every twin back on its mesh: pending loads are cancelled, shells
    /// and fades removed, resident payloads kept (hidden). The links stay, so `install()` picks
    /// the swaps up again.
    func uninstall() {
        guard installed else { return }
        EngineExtensionRegistry.shared.unregister(id: id)
        installed = false
        resetAllTwins()
    }

    func willUnregister() {
        installed = false
        resetAllTwins()
    }

    private func resetAllTwins() {
        let twinId = getComponentId(for: GaussianTwinComponent.self)
        withWorldMutationGate {
            for entityId in queryEntitiesWithComponentIds([twinId], in: scene) {
                guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { continue }
                twin.loadTask?.cancel()
                twin.loadTask = nil
                twin.loadGeneration &+= 1
                twin.state = .armed
                twin.fadeProgress = 0
                applyPresentation(entityId: entityId, twin: twin)
            }
        }
    }

    func update(deltaTime: Float, context _: EngineExtensionUpdateContext) {
        update(deltaTime: deltaTime)
    }

    /// Splats can be drawn at all: the engine's tile pipelines exist (the iOS simulator never
    /// creates them). Without them a swap would hide the mesh's colour behind a depth-only shell
    /// with no splat to show, so twins stay armed.
    var splatRenderingAvailable: Bool {
        if let splatRenderingAvailableOverride {
            return splatRenderingAvailableOverride
        }
        #if targetEnvironment(simulator)
            return false
        #else
            return PipelineManager.shared.renderPipelinesByType[.gaussianTBDRDraw]?.success == true
        #endif
    }

    // MARK: - Per-frame update

    /// Advances every twin once per frame. `deltaTime` is wall-clock frame time, so the fade
    /// lasts `crossFadeDuration` at any refresh rate (each step is capped at 100 ms).
    func update(deltaTime: Float) {
        if adoptsSceneLinks {
            adoptSceneLinks()
        }

        let twinId = getComponentId(for: GaussianTwinComponent.self)
        let transformId = getComponentId(for: WorldTransformComponent.self)
        let entities = queryEntitiesWithComponentIds([twinId, transformId], in: scene)
        guard !entities.isEmpty, splatRenderingAvailable else { return }

        guard let camera = CameraSystem.shared.activeCamera,
              let cameraComponent = scene.get(component: CameraComponent.self, for: camera)
        else { return }
        let cameraPosition = SceneRootTransform.shared.effectiveCameraPosition(cameraComponent.localPosition)
        let clampedDeltaTime = min(max(deltaTime, 0), maxDeltaTime)

        for entityId in entities {
            guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { continue }

            withWorldMutationGate {
                let previousState = twin.state
                // Without a mesh there is nothing to swap from: a streaming stub whose geometry
                // has not arrived yet stays armed, and a swap already under way keeps its state
                // (the splat then shows without an occluder until the mesh returns).
                let hasMesh = scene.get(component: RenderComponent.self, for: entityId)?.mesh.isEmpty == false
                let payloadResident = scene.get(component: GaussianComponent.self, for: entityId) != nil
                let distance = distanceToCamera(entityId: entityId, cameraPosition: cameraPosition)
                let wantsSwap = gaussianTwinWantsSwap(distance: distance, options: twin.options, state: twin.state)
                    && (hasMesh || twin.state != .armed)

                let step = gaussianTwinStep(
                    state: twin.state,
                    progress: twin.fadeProgress,
                    wantsSwap: wantsSwap,
                    payloadResident: payloadResident,
                    loadFailed: twin.loadFailed,
                    deltaTime: clampedDeltaTime,
                    duration: twin.options.crossFadeDuration
                )
                twin.state = step.state
                twin.fadeProgress = step.progress

                if twin.state == .loading, previousState != .loading {
                    startPayloadLoad(entityId: entityId, twin: twin)
                }
                applyPresentation(entityId: entityId, twin: twin)
            }
        }
    }

    /// Attaches a twin to every mesh entity carrying a scene link flagged `meshTwin` that has not
    /// been looked at yet, with the record's settings. Each link is examined once: a twin the app
    /// unlinks with `removeEntityGaussianTwin` stays unlinked, and links that are not mesh twins
    /// are not re-checked every frame.
    func adoptSceneLinks() {
        let linkId = getComponentId(for: GaussianAssetLinkComponent.self)
        let renderId = getComponentId(for: RenderComponent.self)
        for entityId in queryEntitiesWithComponentIds([linkId, renderId], in: scene) where !examinedSceneLinks.contains(entityId) {
            examinedSceneLinks.insert(entityId)
            guard scene.get(component: GaussianTwinComponent.self, for: entityId) == nil,
                  let link = scene.get(component: GaussianAssetLinkComponent.self, for: entityId),
                  link.isMeshTwin,
                  let payloadURL = link.payloadURL
            else { continue }
            setEntityGaussianTwin(entityId: entityId, payloadURL: payloadURL, options: GaussianTwinOptions(link: link))
        }
    }

    /// Marks an entity's scene link as handled by the app, so `adoptSceneLinks` leaves it alone.
    func markSceneLinkExamined(_ entityId: EntityID) {
        examinedSceneLinks.insert(entityId)
    }

    /// Forgets which scene links were examined (tests, scene reloads).
    func resetSceneLinkAdoption() {
        examinedSceneLinks.removeAll()
    }

    // MARK: - Presentation

    /// Turns the swap state into the engine's per-entity knobs: the occluder shell and colour
    /// switch, the mesh dither, the splat's opacity weight and its placement inside the mesh.
    /// Batching is told when the shell or fade components come and go, since their presence
    /// takes the entity out of its batch.
    private func applyPresentation(entityId: EntityID, twin: GaussianTwinComponent) {
        let gaussian = scene.get(component: GaussianComponent.self, for: entityId)
        gaussian?.exposureOffsetEV = twin.options.exposureOffsetEV
        gaussian?.useRealWorldTint = twin.options.useRealWorldTint
        // Every tick, so a live edit of the alignment moves the resident splat without relinking
        // (the engine ignores an unchanged matrix and carries a splat-only box along).
        // An alignment that is not finite or has no scale would poison the matrix (the engine
        // inverts it for the harmonics' camera position), so such an option is identity.
        if gaussian != nil {
            let alignment = twin.options.alignment.flatMap { $0.isValid ? $0 : nil }
            setGaussianSplatToEntity(entityId: entityId, alignment?.matrix ?? matrix_identity_float4x4)
        }

        // Authoring (`showsMeshWhileSwapped`): the plain mesh (colour and depth, no shell, no
        // dither) stays under the splat through the fades too, so the swap is a splat fade-in
        // over an untouched mesh. A fade that starts from a plain mesh stays plain even once
        // the flag is cleared: dithering a fully drawn mesh in from nothing would pop.
        let meshPlain = twin.options.showsMeshWhileSwapped || twin.meshKeptPlain
        switch twin.state {
        case .armed, .loading:
            gaussian?.opacityScale = 0
            setOccluder(entityId: entityId, twin: twin, present: false, drawsColor: true)
            setFade(entityId: entityId, present: false, direction: .fadeOut, progress: 0)
            twin.meshKeptPlain = false
        case .crossFading:
            gaussian?.opacityScale = gaussianTwinSplatOpacity(state: .crossFading, progress: twin.fadeProgress)
            setOccluder(entityId: entityId, twin: twin, present: !meshPlain, drawsColor: true)
            setFade(entityId: entityId, present: !meshPlain, direction: .fadeOut, progress: twin.fadeProgress)
            twin.meshKeptPlain = meshPlain
        case .swapped:
            gaussian?.opacityScale = 1
            if twin.options.showsMeshWhileSwapped {
                setOccluder(entityId: entityId, twin: twin, present: false, drawsColor: true)
            } else {
                setOccluder(entityId: entityId, twin: twin, present: true, drawsColor: false)
            }
            setFade(entityId: entityId, present: false, direction: .fadeOut, progress: 0)
            twin.meshKeptPlain = twin.options.showsMeshWhileSwapped
        case .reverting:
            gaussian?.opacityScale = gaussianTwinSplatOpacity(state: .reverting, progress: twin.fadeProgress)
            setOccluder(entityId: entityId, twin: twin, present: !meshPlain, drawsColor: true)
            setFade(entityId: entityId, present: !meshPlain, direction: .fadeIn, progress: twin.fadeProgress)
            twin.meshKeptPlain = meshPlain
        }
    }

    private func setOccluder(entityId: EntityID, twin: GaussianTwinComponent, present: Bool, drawsColor: Bool) {
        let existing = scene.get(component: MeshOccluderComponent.self, for: entityId)
        if present {
            if existing == nil {
                registerComponent(entityId: entityId, componentType: MeshOccluderComponent.self)
                BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
                RenderPasses.invalidateShadowEntityCache()
            }
            guard let occluder = scene.get(component: MeshOccluderComponent.self, for: entityId) else { return }
            occluder.shrinkMeters = twin.options.occluderShrinkMeters
            occluder.drawsColor = drawsColor
        } else if existing != nil {
            scene.remove(component: MeshOccluderComponent.self, from: entityId)
            BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
            RenderPasses.invalidateShadowEntityCache()
        }
    }

    /// The fade only ever accompanies the occluder shell, which already keeps the entity out of
    /// its batch, so adding or removing it needs no batching notification of its own.
    private func setFade(entityId: EntityID, present: Bool, direction: MeshFadeComponent.Direction, progress: Float) {
        let existing = scene.get(component: MeshFadeComponent.self, for: entityId)
        if present {
            if existing == nil {
                registerComponent(entityId: entityId, componentType: MeshFadeComponent.self)
            }
            guard let fade = scene.get(component: MeshFadeComponent.self, for: entityId) else { return }
            fade.direction = direction
            fade.progress = progress
        } else if existing != nil {
            scene.remove(component: MeshFadeComponent.self, from: entityId)
        }
    }

    /// Camera distance to the entity's bounds centre, like the engine's LOD systems. An entity
    /// without transforms is treated as infinitely far (it never swaps).
    func distanceToCamera(entityId: EntityID, cameraPosition: simd_float3) -> Float {
        guard let worldTransform = scene.get(component: WorldTransformComponent.self, for: entityId),
              let localTransform = scene.get(component: LocalTransformComponent.self, for: entityId)
        else { return .greatestFiniteMagnitude }
        let box = localTransform.boundingBox
        let localCenter = (box.min + box.max) * 0.5
        let worldCenter = worldTransform.space * simd_float4(localCenter, 1)
        return simd_distance(cameraPosition, simd_float3(worldCenter.x, worldCenter.y, worldCenter.z))
    }

    // MARK: - Payload loading

    /// Reads and encodes the payload off the main thread, then attaches it under the
    /// world-mutation gate. A relink or unlink bumps the twin's load generation (and cancels the
    /// task), and the apply re-checks both under the gate, so a load that finished for an earlier
    /// link never lands on the current one.
    private func startPayloadLoad(entityId: EntityID, twin: GaussianTwinComponent) {
        guard let url = twin.payloadURL else {
            Logger.logWarning(message: "[GaussianTwinSystem] Twin of entity \(entityId) has no payload URL")
            twin.loadFailed = true
            twin.state = .armed
            return
        }
        twin.loadTask?.cancel()
        twin.loadGeneration &+= 1
        let generation = twin.loadGeneration
        twin.loadTask = Task {
            let payload = await loadGaussianSplatPayload(url: url)
            guard !Task.isCancelled else { return }
            withWorldMutationGate {
                guard !Task.isCancelled,
                      let twin = scene.get(component: GaussianTwinComponent.self, for: entityId),
                      twin.loadGeneration == generation
                else { return }
                twin.loadTask = nil
                guard let payload else {
                    twin.loadFailed = true
                    return
                }
                if scene.get(component: GaussianComponent.self, for: entityId) == nil {
                    if !setEntityGaussian(entityId: entityId, payload: payload, opacityScale: 0) {
                        twin.loadFailed = true
                    }
                }
            }
        }
    }
}

// MARK: - Public API

/// Links `entityId`'s mesh to the captured splat at `payloadURL` as its twin. Nothing is loaded
/// here: `GaussianTwinSystem` loads the payload when the camera comes within
/// `options.swapDistanceMeters` (at once when that is 0), cross-fades to it, and fades back
/// when the camera leaves. A splat already on the entity becomes the twin's payload and is
/// hidden until the swap. Relinking an entity drops the payload of the previous link.
func setEntityGaussianTwin(
    entityId: EntityID,
    payloadURL: URL,
    options: GaussianTwinOptions = GaussianTwinOptions()
) {
    guard hasComponent(entityId: entityId, componentType: LocalTransformComponent.self) else {
        Logger.logWarning(message: "[GaussianTwinSystem] setEntityGaussianTwin: entity \(entityId) has no transform; link ignored")
        return
    }
    withWorldMutationGate {
        if let existing = scene.get(component: GaussianTwinComponent.self, for: entityId) {
            existing.loadTask?.cancel()
            existing.loadTask = nil
            existing.loadGeneration &+= 1
            if scene.get(component: GaussianComponent.self, for: entityId) != nil {
                removeEntityGaussian(entityId: entityId)
            }
        } else {
            registerComponent(entityId: entityId, componentType: GaussianTwinComponent.self)
        }
        guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { return }
        twin.payloadURL = payloadURL
        twin.options = options
        twin.state = .armed
        twin.fadeProgress = 0
        twin.loadFailed = false
        GaussianTwinSystem.shared.markSceneLinkExamined(entityId)
        // Back to the plain mesh at once; the next tick re-evaluates.
        if scene.get(component: MeshOccluderComponent.self, for: entityId) != nil
            || scene.get(component: MeshFadeComponent.self, for: entityId) != nil
        {
            scene.remove(component: MeshOccluderComponent.self, from: entityId)
            scene.remove(component: MeshFadeComponent.self, from: entityId)
            BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
            RenderPasses.invalidateShadowEntityCache()
        }
    }
}

/// `setEntityGaussianTwin(entityId:payloadURL:options:)` with the payload looked up through
/// `LoadingSystem` like the engine's asset entry points.
func setEntityGaussianTwin(
    entityId: EntityID,
    filename: String,
    withExtension: String,
    options: GaussianTwinOptions = GaussianTwinOptions()
) {
    guard let url = LoadingSystem.shared.resourceURL(forResource: filename, withExtension: withExtension, subResource: nil) else {
        Logger.logWarning(message: "[GaussianTwinSystem] setEntityGaussianTwin: '\(filename).\(withExtension)' not found")
        return
    }
    setEntityGaussianTwin(entityId: entityId, payloadURL: url, options: options)
}

/// Unlinks the twin: cancels a pending load, drops the splat and shows the mesh again. A scene
/// link on the entity is left in place but not adopted again. Also the component's cleanup
/// handler when the entity is destroyed.
func removeEntityGaussianTwin(entityId: EntityID) {
    withWorldMutationGate {
        GaussianTwinSystem.shared.markSceneLinkExamined(entityId)
        guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { return }
        twin.loadTask?.cancel()
        twin.loadTask = nil
        twin.loadGeneration &+= 1
        if scene.get(component: GaussianComponent.self, for: entityId) != nil {
            removeEntityGaussian(entityId: entityId)
        }
        scene.remove(component: MeshOccluderComponent.self, from: entityId)
        scene.remove(component: MeshFadeComponent.self, from: entityId)
        scene.remove(component: GaussianTwinComponent.self, from: entityId)
        BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
        RenderPasses.invalidateShadowEntityCache()
    }
}
