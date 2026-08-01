@testable import CoolWeb
import Metal
import simd
import XCTest

/// Loads the committed host metallib and checks the shader contract, so a
/// renamed entry point or missing resource fails here instead of as a silent
/// black screen on device.
final class CoolWebGPUTests: XCTestCase {
    func testMetallibContainsContractFunctions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        let url = try XCTUnwrap(
            CoolWebPlugin.bundledMetallibURL,
            "bundled metallib missing — run Scripts/build-metallib.sh"
        )
        let library = try device.makeLibrary(URL: url)
        for name in CoolWebPluginContract.shaderFunctionNames {
            XCTAssertNotNil(
                library.makeFunction(name: name),
                "metallib is missing shader function \(name)"
            )
        }
    }

    /// Renders one attached strand + splat offscreen through the real shaders
    /// and asserts the web actually covers pixels.
    func testOffscreenRenderCoversPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw XCTSkip("No Metal device on this host")
        }
        let url = try XCTUnwrap(CoolWebPlugin.bundledMetallibURL)
        let library = try device.makeLibrary(URL: url)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "coolWebStrandVertex")
        )
        descriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "coolWebStrandFragment")
        )
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let size = 128
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: size,
            height: size,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))

        // Scene: a vertical strand 2 m in front of the camera, plus a splat.
        var uniforms = CoolWebUniforms()
        // Simple perspective looking down -Z from the origin.
        let fov: Float = 60 * .pi / 180
        let f = 1 / tan(fov / 2)
        uniforms.viewProj = simd_float4x4(
            SIMD4<Float>(f, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, -1, -1),
            SIMD4<Float>(0, 0, -0.01, 0)
        )
        uniforms.cameraWorld = SIMD4<Float>(0, 0, 0, 0)

        var strand = CoolWebStrandGPU()
        strand.color = SIMD4<Float>(0.92, 0.95, 1.0, 1.0)
        strand.params = SIMD4<Float>(
            0.05, // exaggerated radius so coverage is unambiguous
            Float(CoolWebShaderLimits.strandParticles),
            0,
            0
        )
        uniforms.setStrand(0, strand)

        var splat = CoolWebSplatGPU()
        splat.center = SIMD4<Float>(0.3, 0, -2, 0.4)
        splat.normal = SIMD4<Float>(0, 0, 1, 1)
        splat.params = SIMD4<Float>(0, 10, 0, 0) // fully drawn in
        uniforms.setSplat(0, splat)
        uniforms.counts = SIMD4<UInt32>(1, 1, 0, 0)

        var particles = [SIMD4<Float>](
            repeating: .zero,
            count: CoolWebShaderLimits.maxStrands * CoolWebShaderLimits.strandParticles
        )
        for i in 0 ..< CoolWebShaderLimits.strandParticles {
            let t = Float(i) / Float(CoolWebShaderLimits.strandParticles - 1)
            particles[i] = SIMD4<Float>(0, -0.8 + 1.6 * t, -2, 0)
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0
        )

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<CoolWebUniforms>.stride,
            index: CoolWebBufferIndex.uniforms.rawValue
        )
        particles.withUnsafeBytes { bytes in
            let buffer = device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            )
            encoder.setVertexBuffer(
                buffer,
                offset: 0,
                index: CoolWebBufferIndex.particles.rawValue
            )
        }
        let quadCount = CoolWebShaderLimits.maxStrands
            * CoolWebShaderLimits.strandSegments
            + CoolWebShaderLimits.maxSplats
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quadCount * 6)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        // Count covered pixels (any nonzero half-float channel).
        var pixels = [UInt16](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(
                bytes.baseAddress!,
                bytesPerRow: size * 8,
                from: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0
            )
        }
        var covered = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0 {
            covered += 1
        }
        let coverage = Float(covered) / Float(size * size)
        XCTAssertGreaterThan(
            coverage, 0.02,
            "strand + splat should cover a visible fraction of the frame"
        )
    }
}
