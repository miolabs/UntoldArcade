import Foundation
import Metal
import simd
import UntoldEngine

/// Rendering implementation owned by `CoolScanPlugin`.
///
/// Two seams, matching the two kinds of stylization:
/// - A model-surface pass at `.beforePostProcess` re-shades entities carrying
///   `CoolScanToonComponent` with the toon fragment (overwrites the lit PBR
///   pixels at equal depth).
/// - A full-screen compute pass at `.beforeLook` that copies the scene
///   composite into a scratch texture and writes the stylized image back, so
///   the engine's look/tonemap chain still runs afterwards.
final class CoolScanRenderExtension: RenderExtension, @unchecked Sendable {
    let id = CoolScanPluginContract.extensionID

    private let encodeLock = NSLock()

    // Lazily created 1x1 white fallback bound when no scan albedo is set.
    private var fallbackAlbedo: MTLTexture?

    // One-shot diagnostics so a silently skipped pass is visible in the log.
    private var loggedSurfaceFailure = false
    private var loggedScreenFailure = false
    private var loggedSizeMismatch = false

    private func logOnce(_ flag: inout Bool, _ message: String) {
        guard !flag else { return }
        flag = true
        print("CoolScan: \(message)")
    }

    // MARK: - Registration

    func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
        registry.registerLibrary(
            CoolScanPluginContract.shaderLibraryID,
            bundle: .module,
            resource: CoolScanPlatform.metallibResourceName
        )
    }

    func registerArgumentBuffers(_ registry: RenderExtensionArgumentBufferRegistry) {
        registry.registerArgumentBuffer(
            RenderExtensionArgumentBufferDescriptor(
                id: CoolScanPluginContract.toonArgumentLayoutID,
                textures: [
                    RenderExtensionArgumentTexture(
                        id: RenderExtensionModelSurfaceArgument.texture0
                    ),
                ],
                buffers: [
                    RenderExtensionArgumentBuffer(
                        id: RenderExtensionModelSurfaceArgument.buffer0
                    ),
                ]
            )
        )
    }

    func registerPipelines(_ registry: RenderPipelineRegistry) {
        registry.registerModelSurfacePipeline(
            CoolScanPluginContract.toonPipelineID,
            fragmentShader: "coolScanToonFragment",
            fragmentShaderLibrary: .registered(CoolScanPluginContract.shaderLibraryID),
            depthEnabled: true,
            blendMode: .none,
            name: "CoolScan Toon Surface",
            validation: .warn(
                argumentLayoutID: CoolScanPluginContract.toonArgumentLayoutID
            )
        )
    }

    func registerComputePipelines(_ registry: ComputePipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolScanPluginContract.shaderLibraryID
        )
        let kernels: [(ComputePipelineType, String, String)] = [
            (CoolScanPluginContract.comicPipelineID, "coolScanComicKernel", "CoolScan Comic"),
            (CoolScanPluginContract.pixelPipelineID, "coolScanPixelKernel", "CoolScan Pixel"),
            (CoolScanPluginContract.sketchPipelineID, "coolScanSketchKernel", "CoolScan Sketch"),
            (CoolScanPluginContract.edgePipelineID, "coolScanEdgeKernel", "CoolScan Edge"),
        ]
        for (pipelineID, function, name) in kernels {
            registry.registerComputePipeline(
                pipelineID,
                functionName: function,
                shaderLibrary: library,
                pipelineName: name
            )
        }
    }

    func registerResources(_ registry: RenderResourceRegistry) {
        registry.registerTexture(
            RenderExtensionTextureDescriptor(
                id: CoolScanPluginContract.scratchTextureID,
                label: "CoolScan Scratch",
                size: .viewportScale(1.0),
                pixelFormat: .rgba16Float,
                usage: [.shaderRead, .shaderWrite],
                storageMode: .private
            )
        )
    }

    // MARK: - Graph

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        builder.addPass(
            id: CoolScanPluginContract.surfacePassID,
            stage: .beforePostProcess,
            resources: []
        ) { [weak self] context in
            self?.encodeToonSurface(context)
        }

        builder.addPass(
            id: CoolScanPluginContract.screenPassID,
            stage: .beforeLook,
            resources: [
                .texture(
                    CoolScanPluginContract.scratchTextureID,
                    access: [.read, .write]
                ),
            ]
        ) { [weak self] context in
            self?.encodeScreenStyle(context)
        }
    }

    // MARK: - Toon surface pass

    private func encodeToonSurface(_ context: RenderPassContext) {
        let state = CoolScanStyleState.shared.snapshot()
        guard state.style == .toon else { return }

        encodeLock.withLock {
            let albedo = state.toonAlbedo ?? ensureFallbackAlbedo(device: context.device)

            var uniforms = CoolScanToonUniforms()
            uniforms.lightDirection = SIMD4<Float>(state.lightDirection, 0)
            uniforms.shadeColor = SIMD4<Float>(
                state.params.toonShadeColor,
                state.params.toonBands
            )
            uniforms.params = SIMD4<Float>(
                state.params.rimStrength,
                state.params.rimWidth,
                0, 0
            )

            context.drawModelSurfaceEntities(
                pipeline: CoolScanPluginContract.toonPipelineID,
                matching: [CoolScanToonComponent.self],
                label: "CoolScan Toon Surface",
                argumentLayoutID: CoolScanPluginContract.toonArgumentLayoutID,
                bindEntity: { encoder, _, _ in
                    // This pass re-rasterizes geometry the deferred pass
                    // already drew; the two pipelines are not bit-identical
                    // in depth, so bias toward the camera (reverse-Z: depth
                    // grows toward the viewer) to avoid equality speckle.
                    encoder.setDepthBias(64.0, slopeScale: 2.0, clamp: 0.01)
                },
                bindArguments: { arguments, entityID, _ in
                    // Prefer the engine's already-loaded material texture so
                    // sampling matches the PBR pass exactly; the app-supplied
                    // override and the white fallback cover the rest.
                    let texture = state.toonAlbedo
                        ?? Self.engineBaseColorTexture(entityID: entityID)
                        ?? albedo
                    arguments.setTexture(
                        texture,
                        id: RenderExtensionModelSurfaceArgument.texture0
                    )
                    arguments.setBytes(
                        &uniforms,
                        id: RenderExtensionModelSurfaceArgument.buffer0
                    )
                }
            )
        }
    }

    private static func engineBaseColorTexture(entityID: EntityID) -> MTLTexture? {
        guard let renderComponent = getEntityComponent(
            entityId: entityID,
            componentType: RenderComponent.self
        ) else {
            return nil
        }
        for mesh in renderComponent.mesh {
            for submesh in mesh.submeshes {
                if let texture = submesh.material?.baseColor.texture {
                    return texture
                }
            }
        }
        return nil
    }

    private func ensureFallbackAlbedo(device: MTLDevice) -> MTLTexture? {
        if let fallbackAlbedo { return fallbackAlbedo }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        var white: [UInt8] = [255, 255, 255, 255]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &white,
            bytesPerRow: 4
        )
        fallbackAlbedo = texture
        return texture
    }

    // MARK: - Screen style pass

    private func screenPipelineID(for state: CoolScanStyleState.Snapshot) -> ComputePipelineType? {
        switch state.style {
        case .original:
            return nil
        case .toon:
            // Toon shading happens in the surface pass; the screen pass only
            // adds the contour lines, so skip it when outlines are disabled.
            return state.params.outlineStrength > 0
                ? CoolScanPluginContract.edgePipelineID
                : nil
        case .comic:
            return CoolScanPluginContract.comicPipelineID
        case .pixel:
            return CoolScanPluginContract.pixelPipelineID
        case .sketch:
            return CoolScanPluginContract.sketchPipelineID
        }
    }

    private func screenUniforms(for state: CoolScanStyleState.Snapshot) -> CoolScanScreenUniforms {
        var uniforms = CoolScanScreenUniforms()
        let params = state.params
        switch state.style {
        case .original:
            break
        case .toon:
            uniforms.paramsA = SIMD4<Float>(
                0, 0, params.outlineStrength, params.outlineThreshold
            )
        case .comic:
            uniforms.paramsA = SIMD4<Float>(
                params.comicLevels,
                params.halftone,
                params.outlineStrength,
                params.outlineThreshold
            )
        case .pixel:
            uniforms.paramsA = SIMD4<Float>(
                params.pixelSize, params.pixelLevels, 0, 0
            )
        case .sketch:
            uniforms.paramsA = SIMD4<Float>(
                params.sketchScale,
                0,
                params.outlineStrength,
                params.outlineThreshold
            )
        }
        return uniforms
    }

    private func encodeScreenStyle(_ context: RenderPassContext) {
        let state = CoolScanStyleState.shared.snapshot()
        guard let pipelineID = screenPipelineID(for: state) else { return }

        encodeLock.withLock {
            guard let pipeline = context.computePipelines.pipeline(pipelineID),
                  let pipelineState = pipeline.pipelineState
            else {
                logOnce(&loggedScreenFailure, "screen pass: compute pipeline missing — NOT drawing")
                return
            }
            guard let composite = textureResources.sceneCompositeTexture,
                  let depth = textureResources.depthMap,
                  let scratch = context.resources.texture(
                      CoolScanPluginContract.scratchTextureID
                  )
            else {
                logOnce(&loggedScreenFailure, "screen pass: scene textures missing — NOT drawing")
                return
            }
            guard composite.width == scratch.width,
                  composite.height == scratch.height,
                  composite.pixelFormat == scratch.pixelFormat
            else {
                logOnce(
                    &loggedSizeMismatch,
                    "screen pass: scratch \(scratch.width)x\(scratch.height) "
                        + "\(scratch.pixelFormat.rawValue) does not match composite "
                        + "\(composite.width)x\(composite.height) "
                        + "\(composite.pixelFormat.rawValue) — NOT drawing"
                )
                return
            }

            // Copy the composite aside so the kernel never reads what it writes.
            guard let blit = context.commandBuffer.makeBlitCommandEncoder() else {
                return
            }
            blit.label = "CoolScan Scratch Copy"
            blit.copy(from: composite, to: scratch)
            blit.endEncoding()

            guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            encoder.label = "CoolScan Screen Style"
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(composite, index: 1)
            encoder.setTexture(depth, index: 2)
            var uniforms = screenUniforms(for: state)
            encoder.setBytes(
                &uniforms,
                length: MemoryLayout<CoolScanScreenUniforms>.stride,
                index: 0
            )

            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(
                width: (composite.width + 15) / 16,
                height: (composite.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }
    }
}
