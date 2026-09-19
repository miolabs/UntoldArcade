import Foundation
import ModelIO
import simd
import UntoldEngine

/// Errors thrown while converting a scanned USDZ into a `.untold` asset.
public enum CoolScanCookerError: Error, CustomStringConvertible {
    case assetHasNoMeshes(URL)
    case missingVertexAttribute(String)
    case textureExportFailed(String)
    case validationFailed(underlying: Error)

    public var description: String {
        switch self {
        case let .assetHasNoMeshes(url):
            return "No meshes found in \(url.lastPathComponent)"
        case let .missingVertexAttribute(name):
            return "Mesh is missing required vertex attribute: \(name)"
        case let .textureExportFailed(name):
            return "Failed to export texture: \(name)"
        case let .validationFailed(underlying):
            return "Cooked file failed validation: \(underlying)"
        }
    }
}

/// Result of a successful cook.
public struct CookedScan: Sendable {
    public let untoldURL: URL
    public let textureURLs: [URL]
    public let worldBoundsMin: SIMD3<Float>
    public let worldBoundsMax: SIMD3<Float>
    public let vertexCount: Int
    public let triangleCount: Int
    /// Longest edge among the exported textures (0 when untextured).
    public let textureMax: Int
}

/// Everything that tunes a cook besides the input file.
public struct CookOptions: Sendable {
    public var cleanup = MeshCleanupOptions()
    /// Downscale exported textures whose longer edge exceeds this. Mac
    /// reconstructions ship 8K maps; the phone renderer caps at 2K.
    public var maxTextureDimension: Int?

    public init(cleanup: MeshCleanupOptions = MeshCleanupOptions(), maxTextureDimension: Int? = nil) {
        self.cleanup = cleanup
        self.maxTextureDimension = maxTextureDimension
    }
}

/// Converts a textured USDZ (Object Capture output) into the engine's native
/// `.untold` container plus PNG texture siblings, entirely on device.
///
/// The `.untold` writer is the engine's public AssetFormat API; textures are
/// written as plain PNGs referenced by URI, which the engine loads through
/// MTKTextureLoader — no ASTC baking required.
public struct ScanCooker {
    public init() {}

    public func cook(
        usdzURL: URL,
        outputDirectory: URL,
        assetName: String = "scan",
        cleanup: MeshCleanupOptions = MeshCleanupOptions()
    ) throws -> CookedScan {
        try cook(
            usdzURL: usdzURL,
            outputDirectory: outputDirectory,
            assetName: assetName,
            options: CookOptions(cleanup: cleanup)
        )
    }

    public func cook(
        usdzURL: URL,
        outputDirectory: URL,
        assetName: String = "scan",
        options: CookOptions
    ) throws -> CookedScan {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoolScanCook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let meshes = try MDLExtraction.extract(from: usdzURL, scratchDirectory: scratchDirectory)
        return try cook(
            extracted: meshes,
            outputDirectory: outputDirectory,
            assetName: assetName,
            options: options
        )
    }

    func cook(
        extracted meshes: [ExtractedMesh],
        outputDirectory: URL,
        assetName: String,
        cleanup: MeshCleanupOptions = .none
    ) throws -> CookedScan {
        try cook(
            extracted: meshes,
            outputDirectory: outputDirectory,
            assetName: assetName,
            options: CookOptions(cleanup: cleanup)
        )
    }

    func cook(
        extracted meshes: [ExtractedMesh],
        outputDirectory: URL,
        assetName: String,
        options: CookOptions
    ) throws -> CookedScan {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var builder = ScanAssetBuilder(
            assetName: assetName,
            maxTextureDimension: options.maxTextureDimension
        )
        for var mesh in meshes {
            MeshCleanup.apply(&mesh, options: options.cleanup)
            builder.add(mesh)
        }
        let assembly = try builder.assemble(outputDirectory: outputDirectory)

        // Round-trip through the engine reader: runs the full validation
        // suite (magic, alignment, material indices, content hash) before we
        // claim success.
        do {
            _ = try UntoldReader().readAsset(from: assembly.fileData)
        } catch {
            throw CoolScanCookerError.validationFailed(underlying: error)
        }

        let untoldURL = outputDirectory.appendingPathComponent("\(assetName).untold")
        try assembly.fileData.write(to: untoldURL, options: .atomic)

        return CookedScan(
            untoldURL: untoldURL,
            textureURLs: assembly.textureURLs,
            worldBoundsMin: assembly.worldBounds.min,
            worldBoundsMax: assembly.worldBounds.max,
            vertexCount: assembly.vertexCount,
            triangleCount: assembly.triangleCount,
            textureMax: assembly.textureMax
        )
    }
}

// MARK: - Builder

private struct ScanAssetBuilder {
    let assetName: String
    let maxTextureDimension: Int?

    private var entities: [UntoldEntityRecordV1] = []
    private var meshRecords: [UntoldMeshRecordV1] = []
    private var materials: [UntoldMaterialRecordV1] = []
    private var pendingTextures: [(key: ObjectIdentifier, image: CGImage, filename: String, flags: UInt32)] = []
    private var textureIndexByKey: [ObjectIdentifier: UInt32] = [:]
    private var strings: [String] = []
    private var stringSet: Set<String> = []

    private let vertexWriter = UntoldBinaryWriter()
    private let indexWriter = UntoldBinaryWriter()

    private var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    private(set) var vertexCount = 0
    private(set) var triangleCount = 0

    // Set to true here if scans render with vertically flipped textures
    // (UV origin convention check happens visually in the viewer).
    private let flipV = false

    init(assetName: String, maxTextureDimension: Int? = nil) {
        self.assetName = assetName
        self.maxTextureDimension = maxTextureDimension
    }

    struct Assembly {
        var fileData: Data
        var textureURLs: [URL]
        var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)
        var vertexCount: Int
        var triangleCount: Int
        var textureMax: Int
    }

    private mutating func intern(_ string: String) {
        guard !stringSet.contains(string) else { return }
        stringSet.insert(string)
        strings.append(string)
    }

    mutating func add(_ mesh: ExtractedMesh) {
        let entityId = UInt32(entities.count)
        let entityName = uniqueName(mesh.name, index: entities.count)
        intern(entityName)

        // Encode this mesh's full vertex block once; every submesh record
        // references the same slice with its own index range.
        let vertexDataOffset = UInt64(vertexWriter.count)
        var localMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var localMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for i in 0 ..< mesh.positions.count {
            let position = mesh.positions[i]
            localMin = simd_min(localMin, position)
            localMax = simd_max(localMax, position)

            var uv = mesh.uvs[i]
            if flipV { uv.y = 1 - uv.y }
            let tangent = mesh.tangents[i]

            let vertex = UntoldPBRStaticVertexV1(
                position: position,
                normalPacked: UntoldVertexPacking.packNormal(mesh.normals[i]),
                tangentPacked: UntoldVertexPacking.packTangent(
                    SIMD3<Float>(tangent.x, tangent.y, tangent.z),
                    handedness: tangent.w >= 0 ? 1 : -1
                ),
                uv0: SIMD2<UInt16>(
                    Float16(uv.x).bitPattern,
                    Float16(uv.y).bitPattern
                ),
                uv1: SIMD2<UInt16>(0, 0),
                color0: SIMD4<UInt8>(255, 255, 255, 255)
            )
            vertex.encode(to: vertexWriter)
        }
        let vertexDataSize = UInt64(vertexWriter.count) - vertexDataOffset
        vertexCount += mesh.positions.count

        let localBounds = UntoldAABB(min: localMin, max: localMax)
        let worldBounds = transformedBounds(min: localMin, max: localMax, by: mesh.worldTransform)
        boundsMin = simd_min(boundsMin, worldBounds.min)
        boundsMax = simd_max(boundsMax, worldBounds.max)

        let firstMeshRecordIndex = UInt32(meshRecords.count)
        let useUInt32 = mesh.positions.count > Int(UInt16.max)

        for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
            let meshName = "\(entityName)_sub\(submeshIndex)"
            intern(meshName)

            let indexDataOffset = UInt64(indexWriter.count)
            if useUInt32 {
                for index in submesh.indices {
                    indexWriter.writeUInt32LE(index)
                }
            } else {
                for index in submesh.indices {
                    indexWriter.writeUInt16LE(UInt16(index))
                }
            }
            let indexDataSize = UInt64(indexWriter.count) - indexDataOffset
            triangleCount += submesh.indices.count / 3

            let materialIndex = UInt32(materials.count)
            appendMaterial(submesh.material, index: materialIndex)

            meshRecords.append(
                UntoldMeshRecordV1(
                    entityId: entityId,
                    meshNameOffset: 0, // patched in assemble()
                    materialIndex: materialIndex,
                    indexType: useUInt32 ? .uint32 : .uint16,
                    vertexCount: UInt32(mesh.positions.count),
                    indexCount: UInt32(submesh.indices.count),
                    vertexStrideBytes: 32,
                    flags: 0,
                    vertexDataOffset: vertexDataOffset,
                    indexDataOffset: indexDataOffset,
                    vertexDataSizeBytes: vertexDataSize,
                    indexDataSizeBytes: indexDataSize,
                    estimatedGPUBytes: vertexDataSize + indexDataSize,
                    localBounds: localBounds
                )
            )
            meshRecordNames.append(meshName)
        }

        entities.append(
            UntoldEntityRecordV1(
                entityId: entityId,
                parentEntityId: UntoldFormat.invalidIndex,
                nameOffset: 0, // patched in assemble()
                firstMeshRecordIndex: firstMeshRecordIndex,
                meshRecordCount: UInt32(mesh.submeshes.count),
                flags: 0,
                localBounds: localBounds,
                worldBounds: UntoldAABB(min: worldBounds.min, max: worldBounds.max),
                localTransform: mesh.worldTransform
            )
        )
        entityNames.append(entityName)
    }

    private var entityNames: [String] = []
    private var meshRecordNames: [String] = []
    private var materialNames: [String] = []

    private mutating func appendMaterial(_ material: ExtractedMaterial, index: UInt32) {
        let materialName = "\(material.name)_\(index)"
        intern(materialName)
        materialNames.append(materialName)

        materials.append(
            UntoldMaterialRecordV1(
                nameOffset: 0, // patched in assemble()
                flags: 0,
                baseColorFactor: material.baseColorFactor,
                emissiveFactor: material.emissiveFactor,
                normalScale: 1.0,
                metallicFactor: material.metallicFactor,
                roughnessFactor: material.roughnessFactor,
                occlusionStrength: 1.0,
                alphaCutoff: 0.5,
                baseColorTextureIndex: textureIndex(material.baseColorTexture, slot: "baseColor", flags: UntoldTextureFlags.srgb),
                normalTextureIndex: textureIndex(material.normalTexture, slot: "normal", flags: UntoldTextureFlags.normalMap),
                metallicTextureIndex: textureIndex(material.metallicTexture, slot: "metallic", flags: 0),
                roughnessTextureIndex: textureIndex(material.roughnessTexture, slot: "roughness", flags: 0),
                emissiveTextureIndex: textureIndex(material.emissiveTexture, slot: "emissive", flags: UntoldTextureFlags.srgb | UntoldTextureFlags.emissive),
                occlusionTextureIndex: textureIndex(material.occlusionTexture, slot: "occlusion", flags: UntoldTextureFlags.occlusion)
            )
        )
    }

    private mutating func textureIndex(
        _ texture: ExtractedTexture?,
        slot: String,
        flags: UInt32
    ) -> UInt32 {
        guard let texture else { return UntoldFormat.invalidIndex }
        if let existing = textureIndexByKey[texture.key] {
            return existing
        }
        let index = UInt32(pendingTextures.count)
        let filename = "\(assetName)_\(slot)_\(index).png"
        pendingTextures.append((texture.key, texture.image, filename, flags))
        textureIndexByKey[texture.key] = index
        intern(filename)
        return index
    }

    private func uniqueName(_ base: String, index: Int) -> String {
        let sanitized = base.isEmpty ? "mesh" : base
        return "\(sanitized)_\(index)"
    }

    private func transformedBounds(
        min localMin: SIMD3<Float>,
        max localMax: SIMD3<Float>,
        by transform: simd_float4x4
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var worldMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var worldMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in 0 ..< 8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? localMin.x : localMax.x,
                corner & 2 == 0 ? localMin.y : localMax.y,
                corner & 4 == 0 ? localMin.z : localMax.z
            )
            let transformed = transform * SIMD4<Float>(point, 1)
            let world = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
            worldMin = simd_min(worldMin, world)
            worldMax = simd_max(worldMax, world)
        }
        return (worldMin, worldMax)
    }

    mutating func assemble(outputDirectory: URL) throws -> Assembly {
        let stringTable = UntoldAssembly.makeStringTable(strings)

        for (i, name) in entityNames.enumerated() {
            entities[i].nameOffset = stringTable.offsets[name] ?? UntoldFormat.invalidIndex
        }
        for (i, name) in meshRecordNames.enumerated() {
            meshRecords[i].meshNameOffset = stringTable.offsets[name] ?? UntoldFormat.invalidIndex
        }
        for (i, name) in materialNames.enumerated() {
            materials[i].nameOffset = stringTable.offsets[name] ?? UntoldFormat.invalidIndex
        }

        var textureURLs: [URL] = []
        var textureRecords: [UntoldTextureRefRecordV1] = []
        var textureMax = 0
        for pending in pendingTextures {
            let written = try TextureExport.writePNG(
                pending.image,
                named: pending.filename,
                into: outputDirectory,
                maxDimension: maxTextureDimension
            )
            textureURLs.append(written.url)
            textureMax = max(textureMax, written.width, written.height)
            textureRecords.append(
                UntoldTextureRefRecordV1(
                    nameOffset: stringTable.offsets[pending.filename] ?? UntoldFormat.invalidIndex,
                    uriOffset: stringTable.offsets[pending.filename] ?? UntoldFormat.invalidIndex,
                    textureFormat: .rgba8,
                    flags: pending.flags,
                    width: UInt32(written.width),
                    height: UInt32(written.height),
                    mipCount: 1
                )
            )
        }

        let worldBounds = UntoldAABB(min: boundsMin, max: boundsMax)
        let header = UntoldFileHeaderV1(
            fileType: .tile,
            chunkCount: 0, // set by buildFileData
            meshCount: UInt32(meshRecords.count),
            materialCount: UInt32(materials.count),
            textureRefCount: UInt32(textureRecords.count),
            entityCount: UInt32(entities.count),
            vertexLayout: .pbrStaticV1,
            worldBounds: worldBounds
        )

        let chunkPayloads = UntoldAssembly.buildChunkPayloads(
            stringTableData: stringTable.data,
            entities: entities,
            meshes: meshRecords,
            materials: materials,
            textures: textureRecords,
            vertexData: vertexWriter.data,
            indexData: indexWriter.data
        )
        let fileData = UntoldAssembly.buildFileData(
            header: header,
            chunkPayloads: chunkPayloads
        )

        return Assembly(
            fileData: fileData,
            textureURLs: textureURLs,
            worldBounds: (boundsMin, boundsMax),
            vertexCount: vertexCount,
            triangleCount: triangleCount,
            textureMax: textureMax
        )
    }
}
