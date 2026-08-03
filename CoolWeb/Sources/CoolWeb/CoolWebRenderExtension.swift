import Foundation
import Metal
import simd
import UntoldEngine

/// Rendering implementation owned by `CoolWebPlugin`.
///
/// Render-only: one scene pass at `.beforePostProcess` first writes real-scene
/// depth (ARKit reconstruction meshes, depth-only) and then draws every thread
/// segment and impact splat in a single alpha-blended draw call over the
/// engine's HDR scene targets. The engine executes the graph once per eye, so
/// nothing here is eye-aware.
final class CoolWebRenderExtension: RenderExtension, @unchecked Sendable {
    let id = CoolWebPluginContract.extensionID

    private let encodeLock = NSLock()

    // Segments are far too big for setVertexBytes (4 KB limit), so they travel
    // in a small ring of shared buffers. The pass encodes twice per frame
    // (once per eye); 6 slots keep writes clear of in-flight reads.
    private static let segmentBufferRingSize = 6
    private var segmentBuffers: [MTLBuffer] = []
    private var segmentBufferCursor = 0

    // Glove mesh travels the same way: vertex + index ring, one slot per encode.
    private var gloveVertexBuffers: [MTLBuffer] = []
    private var gloveIndexBuffers: [MTLBuffer] = []
    private var gloveBufferCursor = 0

    // One-shot diagnostics so a silently skipped pass is visible in the log.
    private var loggedScenePass = false
    private var loggedSceneFailure = false
    private var loggedOcclusionMeshes = false

    private func logOnce(_ flag: inout Bool, _ message: String) {
        guard !flag else { return }
        flag = true
        print("CoolWeb: \(message)")
    }

    func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
        registry.registerLibrary(
            CoolWebPluginContract.shaderLibraryID,
            bundle: .module,
            resource: CoolWebPlatform.metallibResourceName
        )
    }

    func registerPipelines(_ registry: RenderPipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolWebPluginContract.shaderLibraryID
        )
        // depthEnabled false = no depth WRITE (translucent silk must not
        // occlude); depth testing stays on so engine geometry and the
        // real-scene depth pre-pass still hide the web correctly.
        registry.registerScenePipeline(
            CoolWebPluginContract.strandPipelineID,
            vertexShader: "coolWebStrandVertex",
            fragmentShader: "coolWebStrandFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthCompareFunction: .lessEqual,
            depthEnabled: false,
            reverseZCompatible: true,
            blendMode: .alphaPremultiplied,
            name: "CoolWeb Strands"
        )
        registry.registerScenePipeline(
            CoolWebPluginContract.occlusionPipelineID,
            vertexShader: "coolWebOcclusionVertex",
            fragmentShader: "coolWebOcclusionFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolWeb Real-Scene Occlusion"
        )
        // Opaque and depth-writing: the glove replaces the (hidden) real hand,
        // and the translucent strands drawn afterwards depth-test against it.
        registry.registerScenePipeline(
            CoolWebPluginContract.glovePipelineID,
            vertexShader: "coolWebGloveVertex",
            fragmentShader: "coolWebGloveFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthCompareFunction: .lessEqual,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolWeb Spider Glove"
        )
    }

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        builder.addPass(
            id: CoolWebPluginContract.scenePassID,
            stage: .beforePostProcess,
            resources: []
        ) { [weak self] context in
            self?.encodeScene(context)
        }
    }

    private func encodeScene(_ context: RenderPassContext) {
        guard let pipeline = context.renderPipelines.pipeline(
                  CoolWebPluginContract.strandPipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else {
            logOnce(&loggedSceneFailure, "scene pass: strand pipeline missing — NOT drawing")
            return
        }

        encodeLock.withLock {
            let state = CoolWebSceneState.shared.state()
            let glove = CoolWebGloveState.shared.snapshot()
            let occlusionMeshes = CoolWebOcclusionStore.shared.snapshot()
            let hasWeb = !state.segments.isEmpty || !state.splats.isEmpty
            guard hasWeb || !glove.vertices.isEmpty else { return }

            let now = ProcessInfo.processInfo.systemUptime

            var uniforms = CoolWebUniforms()
            uniforms.viewProj = context.camera.viewProjectionMatrix
            uniforms.cameraWorld = SIMD4<Float>(
                context.camera.worldPosition,
                Float(now.truncatingRemainder(dividingBy: 3600))
            )

            guard let segmentBuffer = nextSegmentBuffer(device: context.device) else {
                logOnce(&loggedSceneFailure, "scene pass: no segment buffer — NOT drawing")
                return
            }
            let segmentPointer = segmentBuffer.contents().bindMemory(
                to: CoolWebSegmentGPU.self,
                capacity: CoolWebShaderLimits.maxSegments
            )
            for (index, segment) in state.segments.enumerated() {
                var gpu = CoolWebSegmentGPU()
                gpu.a = SIMD4<Float>(segment.a, segment.radius)
                gpu.b = SIMD4<Float>(segment.b, segment.tension)
                gpu.params = SIMD4<Float>(segment.opacity, segment.seed, 0, 0)
                segmentPointer[index] = gpu
            }

            for (index, splat) in state.splats.enumerated() {
                var gpu = CoolWebSplatGPU()
                gpu.center = SIMD4<Float>(splat.center, splat.radius)
                gpu.normal = SIMD4<Float>(splat.normal, splat.opacity)
                gpu.params = SIMD4<Float>(splat.seed, splat.age, 0, 0)
                uniforms.setSplat(index, gpu)
            }

            uniforms.counts = SIMD4<UInt32>(
                UInt32(state.segments.count),
                UInt32(state.splats.count),
                state.tensionHeatmap ? 1 : 0,
                0
            )

            guard let encoder = context.sceneRenderTargets.makeRenderCommandEncoder(
                actions: .loadAndStore,
                label: "CoolWeb Scene Pass"
            ) else {
                logOnce(&loggedSceneFailure, "scene pass: no scene encoder — NOT drawing")
                return
            }
            defer { encoder.endEncoding() }

            logOnce(
                &loggedScenePass,
                String(
                    format: "scene pass drawing — %d segment(s), %d splat(s), camera (%.2f, %.2f, %.2f)",
                    state.segments.count,
                    state.splats.count,
                    context.camera.worldPosition.x,
                    context.camera.worldPosition.y,
                    context.camera.worldPosition.z
                )
            )

            drawOcclusion(encoder, context: context, meshes: occlusionMeshes)
            drawGlove(encoder, context: context, uniforms: &uniforms, glove: glove)

            guard hasWeb else { return }

            encoder.pushDebugGroup("CoolWeb Strands")
            defer { encoder.popDebugGroup() }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(pipeline.depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<CoolWebUniforms>.stride,
                index: CoolWebBufferIndex.uniforms.rawValue
            )
            encoder.setVertexBuffer(
                segmentBuffer,
                offset: 0,
                index: CoolWebBufferIndex.segments.rawValue
            )

            let quadCount = state.segments.count + state.splats.count
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: quadCount * 6
            )
        }
    }

    private func drawGlove(
        _ encoder: MTLRenderCommandEncoder,
        context: RenderPassContext,
        uniforms: inout CoolWebUniforms,
        glove: (vertices: [CoolWebGloveVertexGPU], indices: [UInt32])
    ) {
        guard !glove.vertices.isEmpty, !glove.indices.isEmpty,
              let pipeline = context.renderPipelines.pipeline(
                  CoolWebPluginContract.glovePipelineID
              ),
              let pipelineState = pipeline.pipelineState,
              let buffers = nextGloveBuffers(device: context.device)
        else { return }

        glove.vertices.withUnsafeBytes { source in
            buffers.vertex.contents().copyMemory(
                from: source.baseAddress!, byteCount: source.count
            )
        }
        glove.indices.withUnsafeBytes { source in
            buffers.index.contents().copyMemory(
                from: source.baseAddress!, byteCount: source.count
            )
        }

        encoder.pushDebugGroup("CoolWeb Spider Glove")
        defer { encoder.popDebugGroup() }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(pipeline.depthState)
        // The lofted tubes are not a watertight solid; skip backface culling.
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<CoolWebUniforms>.stride,
            index: CoolWebGloveBufferIndex.uniforms.rawValue
        )
        encoder.setVertexBuffer(
            buffers.vertex,
            offset: 0,
            index: CoolWebGloveBufferIndex.vertices.rawValue
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CoolWebUniforms>.stride,
            index: CoolWebGloveBufferIndex.uniforms.rawValue
        )
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: glove.indices.count,
            indexType: .uint32,
            indexBuffer: buffers.index,
            indexBufferOffset: 0
        )
    }

    private func drawOcclusion(
        _ encoder: MTLRenderCommandEncoder,
        context: RenderPassContext,
        meshes: [CoolWebOcclusionMesh]
    ) {
        guard !meshes.isEmpty,
              let pipeline = context.renderPipelines.pipeline(
                  CoolWebPluginContract.occlusionPipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else { return }
        logOnce(&loggedOcclusionMeshes, "drawing \(meshes.count) real-scene occlusion meshes")

        encoder.pushDebugGroup("CoolWeb Occlusion")
        defer { encoder.popDebugGroup() }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(pipeline.depthState)
        encoder.setCullMode(.none)

        for mesh in meshes where mesh.indexCount > 0 && mesh.vertexStride > 0 {
            encoder.useResource(mesh.vertexBuffer, usage: .read, stages: .vertex)
            encoder.useResource(mesh.indexBuffer, usage: .read, stages: .vertex)
            var stride = UInt32(mesh.vertexStride)
            var offset = UInt32(max(0, mesh.vertexOffset))
            var mvp = context.camera.viewProjectionMatrix * mesh.transform
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 1)
            encoder.setVertexBytes(&offset, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: mesh.indexType,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: max(0, mesh.indexOffset)
            )
        }
    }

    private func nextGloveBuffers(
        device: MTLDevice
    ) -> (vertex: MTLBuffer, index: MTLBuffer)? {
        if gloveVertexBuffers.isEmpty {
            for slot in 0 ..< Self.segmentBufferRingSize {
                guard let vertexBuffer = device.makeBuffer(
                    length: CoolWebShaderLimits.gloveVertexBufferLength,
                    options: .storageModeShared
                ), let indexBuffer = device.makeBuffer(
                    length: CoolWebShaderLimits.gloveIndexBufferLength,
                    options: .storageModeShared
                ) else { return nil }
                vertexBuffer.label = "CoolWeb Glove Vertices \(slot)"
                indexBuffer.label = "CoolWeb Glove Indices \(slot)"
                gloveVertexBuffers.append(vertexBuffer)
                gloveIndexBuffers.append(indexBuffer)
            }
        }
        let slot = gloveBufferCursor
        gloveBufferCursor = (gloveBufferCursor + 1) % gloveVertexBuffers.count
        return (gloveVertexBuffers[slot], gloveIndexBuffers[slot])
    }

    private func nextSegmentBuffer(device: MTLDevice) -> MTLBuffer? {
        if segmentBuffers.isEmpty {
            for slot in 0 ..< Self.segmentBufferRingSize {
                guard let buffer = device.makeBuffer(
                    length: CoolWebShaderLimits.segmentBufferLength,
                    options: .storageModeShared
                ) else { return nil }
                buffer.label = "CoolWeb Segments \(slot)"
                segmentBuffers.append(buffer)
            }
        }
        let buffer = segmentBuffers[segmentBufferCursor]
        segmentBufferCursor = (segmentBufferCursor + 1) % segmentBuffers.count
        return buffer
    }
}
