@testable import CoolScanPipeline
import ModelIO
import simd
import UntoldEngine
import XCTest

final class ScanCookerTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoolScanCookerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
    }

    // MARK: - Box round trip

    func testCookedBoxRoundTripsThroughEngineReader() throws {
        let mesh = MDLMesh(
            boxWithExtent: SIMD3<Float>(1, 1, 1),
            segments: SIMD3<UInt32>(1, 1, 1),
            inwardNormals: false,
            geometryType: .triangles,
            allocator: nil
        )
        try applyMaterial(
            to: mesh,
            baseColor: SIMD3<Float>(1, 0.5, 0.25),
            roughness: 0.4,
            metallic: 0.1
        )

        let cooked = try cook([mesh], assetName: "box")
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))

        XCTAssertEqual(decoded.entities.count, 1)
        XCTAssertEqual(decoded.meshes.count, 1)
        XCTAssertEqual(decoded.materials.count, 1)
        XCTAssertEqual(decoded.header.vertexLayout, .pbrStaticV1)

        let meshRecord = decoded.meshes[0]
        XCTAssertEqual(meshRecord.vertexStrideBytes, 32)
        XCTAssertEqual(meshRecord.indexType, .uint16)
        XCTAssertEqual(
            meshRecord.indexDataSizeBytes,
            UInt64(meshRecord.indexCount) * 2
        )

        let material = decoded.materials[0]
        XCTAssertEqual(material.baseColorFactor.x, 1, accuracy: 1e-4)
        XCTAssertEqual(material.baseColorFactor.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(material.baseColorFactor.z, 0.25, accuracy: 1e-4)
        XCTAssertEqual(material.roughnessFactor, 0.4, accuracy: 1e-4)
        XCTAssertEqual(material.metallicFactor, 0.1, accuracy: 1e-4)
        XCTAssertEqual(material.baseColorTextureIndex, UntoldFormat.invalidIndex)

        // All decoded vertices lie on the unit box and carry unit normals.
        let vertices = try decodeVertices(from: cooked.untoldURL, decoded: decoded)
        XCTAssertEqual(vertices.count, Int(meshRecord.vertexCount))
        for vertex in vertices {
            XCTAssertEqual(max(
                abs(abs(vertex.position.x) - 0.5),
                max(abs(abs(vertex.position.y) - 0.5), abs(abs(vertex.position.z) - 0.5))
            ), 0, accuracy: 1e-4)
            let normal = UntoldVertexPacking.unpackNormal(vertex.normalPacked)
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.01)
        }

        // Bounds enclose the box.
        XCTAssertEqual(cooked.worldBoundsMin.x, -0.5, accuracy: 1e-4)
        XCTAssertEqual(cooked.worldBoundsMax.y, 0.5, accuracy: 1e-4)
    }

    func testCookedTextureIsWrittenAndReferenced() throws {
        let mesh = MDLMesh(
            boxWithExtent: SIMD3<Float>(1, 1, 1),
            segments: SIMD3<UInt32>(1, 1, 1),
            inwardNormals: false,
            geometryType: .triangles,
            allocator: nil
        )
        try applyMaterial(
            to: mesh,
            baseColor: SIMD3<Float>(1, 1, 1),
            roughness: 0.8,
            metallic: 0,
            baseColorTexture: makeCheckerTexture()
        )

        let cooked = try cook([mesh], assetName: "textured")
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))

        XCTAssertEqual(decoded.textures.count, 1)
        XCTAssertEqual(cooked.textureURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cooked.textureURLs[0].path))

        let material = decoded.materials[0]
        XCTAssertEqual(material.baseColorTextureIndex, 0)

        let texture = decoded.textures[0]
        XCTAssertEqual(texture.flags & UntoldTextureFlags.srgb, UntoldTextureFlags.srgb)
        let uri = try XCTUnwrap(decoded.string(at: texture.uriOffset))
        XCTAssertTrue(uri.hasSuffix(".png"))
        // URI resolves relative to the .untold file's directory.
        let resolved = cooked.untoldURL.deletingLastPathComponent().appendingPathComponent(uri)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    // MARK: - Attribute recovery

    func testMissingNormalsAreGeneratedAndTwoSubmeshesCook() throws {
        let mesh = try makePositionsOnlyMesh(submeshCount: 2)

        let cooked = try cook([mesh], assetName: "bare")
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))

        XCTAssertEqual(decoded.entities.count, 1)
        XCTAssertEqual(decoded.meshes.count, 2)
        XCTAssertEqual(decoded.materials.count, 2)
        XCTAssertEqual(decoded.entities[0].meshRecordCount, 2)

        let vertices = try decodeVertices(from: cooked.untoldURL, decoded: decoded)
        for vertex in vertices {
            let normal = UntoldVertexPacking.unpackNormal(vertex.normalPacked)
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.05)
        }
    }

    func testLargeMeshUsesUInt32Indices() throws {
        let mesh = MDLMesh(
            planeWithExtent: SIMD3<Float>(1, 0, 1),
            segments: SIMD2<UInt32>(300, 300),
            geometryType: .triangles,
            allocator: nil
        )
        XCTAssertGreaterThan(mesh.vertexCount, Int(UInt16.max))

        let cooked = try cook([mesh], assetName: "large")
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))

        let meshRecord = decoded.meshes[0]
        XCTAssertEqual(meshRecord.indexType, .uint32)
        XCTAssertEqual(
            meshRecord.indexDataSizeBytes,
            UInt64(meshRecord.indexCount) * 4
        )
    }

    // MARK: - UV round trip

    func testUVsRoundTripAsFloat16() throws {
        let mesh = MDLMesh(
            boxWithExtent: SIMD3<Float>(1, 1, 1),
            segments: SIMD3<UInt32>(1, 1, 1),
            inwardNormals: false,
            geometryType: .triangles,
            allocator: nil
        )

        let sourceUVs = MDLExtraction.extract(asMeshesFrom: mesh).first?.uvs ?? []
        XCTAssertFalse(sourceUVs.isEmpty)

        let cooked = try cook([mesh], assetName: "uv")
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))
        let vertices = try decodeVertices(from: cooked.untoldURL, decoded: decoded)

        for (vertex, uv) in zip(vertices, sourceUVs) {
            XCTAssertEqual(Float(Float16(bitPattern: vertex.uv0.x)), uv.x, accuracy: 1e-3)
            XCTAssertEqual(Float(Float16(bitPattern: vertex.uv0.y)), uv.y, accuracy: 1e-3)
        }
    }

    // MARK: - Real USDZ fixture

    func testRealUSDZFixtureCooksAndValidates() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ball", withExtension: "usdz"),
            "ball.usdz fixture missing from test resources"
        )

        let cooked = try ScanCooker().cook(
            usdzURL: url,
            outputDirectory: outputDirectory,
            assetName: "ball"
        )

        // Reader validation already ran inside cook(); assert the outputs.
        XCTAssertTrue(FileManager.default.fileExists(atPath: cooked.untoldURL.path))
        XCTAssertGreaterThan(cooked.vertexCount, 0)
        XCTAssertGreaterThan(cooked.triangleCount, 0)

        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: cooked.untoldURL))
        XCTAssertFalse(decoded.meshes.isEmpty)
        XCTAssertFalse(decoded.materials.isEmpty)

        // The fixture ships a diffuse texture inside the package; a cook
        // that drops it (ModelIO failing to resolve in-archive references)
        // renders as a plain white blob on device.
        let material = decoded.materials[0]
        XCTAssertNotEqual(material.baseColorTextureIndex, UntoldFormat.invalidIndex)
        XCTAssertFalse(cooked.textureURLs.isEmpty)
        for url in cooked.textureURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    func testUSDZArchiveUnpacksRootLayerAndTextures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ball", withExtension: "usdz"))
        let files = try USDZArchive.extract(url, into: outputDirectory)

        // USDZ spec: root layer first; textures keep their relative paths.
        XCTAssertEqual(files.first?.lastPathComponent, "ball.usdc")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("textures/Ball_Normal_Map.png") })
        for file in files {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
            XCTAssertGreaterThan(size ?? 0, 0, file.lastPathComponent)
        }
    }

    func testFallbackTexturesMapObjectCaptureNames() throws {
        // Object Capture names its baked textures by slot suffix; simulate an
        // unpacked package with a 1x1 PNG per slot.
        let names = [
            "0/baked_mesh_02e8718f_tex0.png",
            "0/baked_mesh_02e8718f_norm0.png",
            "0/baked_mesh_02e8718f_ao0.png",
        ]
        var files: [URL] = []
        for name in names {
            let url = outputDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try TextureExport.writePNG(makeCheckerTexture().imageFromTexture()!.takeUnretainedValue(),
                                       named: url.lastPathComponent,
                                       into: url.deletingLastPathComponent())
            files.append(url)
        }

        var material = ExtractedMaterial()
        MDLExtraction.FallbackTextures(files: files).fill(&material)
        XCTAssertNotNil(material.baseColorTexture)
        XCTAssertNotNil(material.normalTexture)
        XCTAssertNotNil(material.occlusionTexture)
        XCTAssertNil(material.roughnessTexture)
    }

    // MARK: - Helpers

    private func cook(_ meshes: [MDLMesh], assetName: String) throws -> CookedScan {
        let asset = MDLAsset()
        for mesh in meshes {
            asset.add(mesh)
        }
        let extracted = try MDLExtraction.extract(
            from: asset,
            sourceURL: URL(fileURLWithPath: "/dev/null")
        )
        return try ScanCooker().cook(
            extracted: extracted,
            outputDirectory: outputDirectory,
            assetName: assetName
        )
    }

    private func decodeVertices(
        from untoldURL: URL,
        decoded: UntoldDecodedAsset
    ) throws -> [UntoldPBRStaticVertexV1] {
        let fileData = try Data(contentsOf: untoldURL)
        let entry = try XCTUnwrap(
            decoded.chunks.first(where: { $0.chunkType == .vertexData })
        )
        let start = Int(entry.fileOffset)
        let end = start + Int(entry.compressedSize)
        let reader = UntoldBinaryReader(data: fileData.subdata(in: start ..< end))
        var vertices: [UntoldPBRStaticVertexV1] = []
        let count = Int(entry.compressedSize) / 32
        for _ in 0 ..< count {
            vertices.append(try UntoldPBRStaticVertexV1.decode(from: reader))
        }
        return vertices
    }

    private func applyMaterial(
        to mesh: MDLMesh,
        baseColor: SIMD3<Float>,
        roughness: Float,
        metallic: Float,
        baseColorTexture: MDLTexture? = nil
    ) throws {
        let material = MDLMaterial(
            name: "testMaterial",
            scatteringFunction: MDLScatteringFunction()
        )
        if let baseColorTexture {
            let sampler = MDLTextureSampler()
            sampler.texture = baseColorTexture
            material.setProperty(
                MDLMaterialProperty(
                    name: "baseColor", semantic: .baseColor, textureSampler: sampler
                )
            )
        } else {
            material.setProperty(
                MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: baseColor)
            )
        }
        material.setProperty(
            MDLMaterialProperty(name: "roughness", semantic: .roughness, float: roughness)
        )
        material.setProperty(
            MDLMaterialProperty(name: "metallic", semantic: .metallic, float: metallic)
        )

        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            submesh.material = material
        }
    }

    private func makeCheckerTexture() -> MDLTexture {
        // 2x2 RGBA checkerboard.
        let pixels: [UInt8] = [
            255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 255, 255, 255, 255,
        ]
        return MDLTexture(
            data: Data(pixels),
            topLeftOrigin: true,
            name: "checker",
            dimensions: SIMD2<Int32>(2, 2),
            rowStride: 8,
            channelCount: 4,
            channelEncoding: .uInt8,
            isCube: false
        )
    }

    /// A triangle strip mesh with positions + UVs only (no normals, no
    /// tangents), split into two submeshes so both attribute recovery and the
    /// multi-submesh path are covered at once.
    private func makePositionsOnlyMesh(submeshCount: Int) throws -> MDLMesh {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(1, 1, 0),
        ]
        let uvs: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(1, 1),
        ]

        let allocator = MDLMeshBufferDataAllocator()

        var vertexData = Data()
        for i in 0 ..< positions.count {
            var px = positions[i].x, py = positions[i].y, pz = positions[i].z
            var u = uvs[i].x, v = uvs[i].y
            withUnsafeBytes(of: &px) { vertexData.append(contentsOf: $0) }
            withUnsafeBytes(of: &py) { vertexData.append(contentsOf: $0) }
            withUnsafeBytes(of: &pz) { vertexData.append(contentsOf: $0) }
            withUnsafeBytes(of: &u) { vertexData.append(contentsOf: $0) }
            withUnsafeBytes(of: &v) { vertexData.append(contentsOf: $0) }
        }
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 12, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 20)

        let triangles: [[UInt16]] = [[0, 1, 2], [2, 1, 3]]
        var submeshes: [MDLSubmesh] = []
        for i in 0 ..< submeshCount {
            let indices = triangles[i % triangles.count]
            var indexData = Data()
            for var index in indices {
                withUnsafeBytes(of: &index) { indexData.append(contentsOf: $0) }
            }
            let indexBuffer = allocator.newBuffer(with: indexData, type: .index)
            submeshes.append(
                MDLSubmesh(
                    indexBuffer: indexBuffer,
                    indexCount: indices.count,
                    indexType: .uInt16,
                    geometryType: .triangles,
                    material: nil
                )
            )
        }

        return MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: positions.count,
            descriptor: descriptor,
            submeshes: submeshes
        )
    }
}

private extension MDLExtraction {
    /// Test-only convenience: extract a single free-standing MDLMesh.
    static func extract(asMeshesFrom mesh: MDLMesh) -> [ExtractedMesh] {
        let asset = MDLAsset()
        asset.add(mesh)
        return (try? extract(from: asset, sourceURL: URL(fileURLWithPath: "/dev/null"))) ?? []
    }
}
