import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import simd

/// One texture image pulled out of a ModelIO material, deduplicated by the
/// backing MDLTexture so shared images are exported once.
struct ExtractedTexture {
    let key: ObjectIdentifier
    let image: CGImage
}

struct ExtractedMaterial {
    var name: String = "material"
    var baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
    var emissiveFactor = SIMD3<Float>(0, 0, 0)
    var roughnessFactor: Float = 0.8
    var metallicFactor: Float = 0
    var baseColorTexture: ExtractedTexture?
    var normalTexture: ExtractedTexture?
    var roughnessTexture: ExtractedTexture?
    var metallicTexture: ExtractedTexture?
    var occlusionTexture: ExtractedTexture?
    var emissiveTexture: ExtractedTexture?
}

struct ExtractedSubmesh {
    var indices: [UInt32]
    var material: ExtractedMaterial
}

struct ExtractedMesh {
    var name: String
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    /// xyz tangent + w handedness.
    var tangents: [SIMD4<Float>]
    var submeshes: [ExtractedSubmesh]
    var worldTransform: simd_float4x4
}

enum MDLExtraction {
    /// - Parameter scratchDirectory: where a `.usdz` is unpacked. The caller
    ///   owns it and must keep it alive until textures have been exported —
    ///   CGImages loaded from the unpacked files decode lazily.
    static func extract(from url: URL, scratchDirectory: URL) throws -> [ExtractedMesh] {
        guard url.pathExtension.lowercased() == "usdz" else {
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            return try extract(from: asset, sourceURL: url)
        }

        // Unpack the USDZ so ModelIO resolves texture references as plain
        // files (see USDZArchive). The unpacked folder also feeds the
        // filename-based texture fallback.
        let unpackDirectory = scratchDirectory.appendingPathComponent("usdz", isDirectory: true)
        let files = try USDZArchive.extract(url, into: unpackDirectory)
        let usdExtensions: Set<String> = ["usdc", "usda", "usd"]
        // USDZ spec: the root layer is the first entry.
        guard let rootLayer = files.first(where: { usdExtensions.contains($0.pathExtension.lowercased()) }) else {
            throw CoolScanCookerError.assetHasNoMeshes(url)
        }

        let asset = MDLAsset(url: rootLayer)
        asset.loadTextures()
        return try extract(
            from: asset,
            sourceURL: url,
            fallbackTextures: FallbackTextures(files: files)
        )
    }

    static func extract(
        from asset: MDLAsset,
        sourceURL: URL,
        fallbackTextures: FallbackTextures? = nil
    ) throws -> [ExtractedMesh] {
        let mdlMeshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !mdlMeshes.isEmpty else {
            throw CoolScanCookerError.assetHasNoMeshes(sourceURL)
        }

        var textureCache: [ObjectIdentifier: ExtractedTexture] = [:]
        var meshes = try mdlMeshes.enumerated().map { index, mesh in
            try extractMesh(
                mesh,
                fallbackName: "mesh_\(index)",
                textureCache: &textureCache
            )
        }

        if let fallbackTextures {
            for m in meshes.indices {
                for sm in meshes[m].submeshes.indices {
                    fallbackTextures.fill(&meshes[m].submeshes[sm].material)
                }
            }
        }
        return meshes
    }

    /// Textures found next to the root layer, matched to material slots by
    /// Object Capture's naming (`baked_mesh_<hash>_tex0.png`, `_norm0`,
    /// `_ao0`, …) plus common conventions. Used only for slots ModelIO left
    /// empty.
    struct FallbackTextures {
        private var baseColor: ExtractedTexture?
        private var normal: ExtractedTexture?
        private var occlusion: ExtractedTexture?
        private var roughness: ExtractedTexture?
        private var metallic: ExtractedTexture?
        // Keys are object identities; keep the objects alive so the
        // identities stay unique for the whole cook.
        private var keyObjects: [NSURL] = []

        init(files: [URL]) {
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
            for file in files where imageExtensions.contains(file.pathExtension.lowercased()) {
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                guard let image = Self.loadImage(file) else { continue }
                let keyObject = file as NSURL
                keyObjects.append(keyObject)
                let texture = ExtractedTexture(key: ObjectIdentifier(keyObject), image: image)
                if name.contains("norm") {
                    normal = normal ?? texture
                } else if name.contains("_ao") || name.contains("occlusion") {
                    occlusion = occlusion ?? texture
                } else if name.contains("rough") {
                    roughness = roughness ?? texture
                } else if name.contains("metal") {
                    metallic = metallic ?? texture
                } else if name.contains("tex") || name.contains("diffuse")
                    || name.contains("basecolor") || name.contains("albedo") || name.contains("color")
                {
                    baseColor = baseColor ?? texture
                }
            }
        }

        func fill(_ material: inout ExtractedMaterial) {
            if material.baseColorTexture == nil { material.baseColorTexture = baseColor }
            if material.normalTexture == nil { material.normalTexture = normal }
            if material.occlusionTexture == nil { material.occlusionTexture = occlusion }
            if material.roughnessTexture == nil { material.roughnessTexture = roughness }
            if material.metallicTexture == nil { material.metallicTexture = metallic }
        }

        private static func loadImage(_ url: URL) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    // MARK: - Mesh

    private static func extractMesh(
        _ mesh: MDLMesh,
        fallbackName: String,
        textureCache: inout [ObjectIdentifier: ExtractedTexture]
    ) throws -> ExtractedMesh {
        let vertexCount = mesh.vertexCount

        guard let positions = readFloat3Attribute(
            mesh, name: MDLVertexAttributePosition, count: vertexCount
        ) else {
            throw CoolScanCookerError.missingVertexAttribute(MDLVertexAttributePosition)
        }

        var normals = readFloat3Attribute(mesh, name: MDLVertexAttributeNormal, count: vertexCount)
        if normals == nil {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.2)
            normals = readFloat3Attribute(mesh, name: MDLVertexAttributeNormal, count: vertexCount)
        }
        guard let normals else {
            throw CoolScanCookerError.missingVertexAttribute(MDLVertexAttributeNormal)
        }

        let uvs = readFloat2Attribute(
            mesh, name: MDLVertexAttributeTextureCoordinate, count: vertexCount
        ) ?? Array(repeating: SIMD2<Float>(0, 0), count: vertexCount)

        var tangents = readFloat4Attribute(mesh, name: MDLVertexAttributeTangent, count: vertexCount)
        if tangents == nil,
           readFloat2Attribute(mesh, name: MDLVertexAttributeTextureCoordinate, count: vertexCount) != nil
        {
            mesh.addOrthTanBasis(
                forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                normalAttributeNamed: MDLVertexAttributeNormal,
                tangentAttributeNamed: MDLVertexAttributeTangent
            )
            tangents = readFloat4Attribute(mesh, name: MDLVertexAttributeTangent, count: vertexCount)
        }
        let resolvedTangents = tangents ?? fallbackTangents(for: normals)

        var submeshes: [ExtractedSubmesh] = []
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            guard submesh.geometryType == .triangles else { continue }
            let indices = readIndices(submesh)
            guard !indices.isEmpty else { continue }
            let material = extractMaterial(submesh.material, textureCache: &textureCache)
            submeshes.append(ExtractedSubmesh(indices: indices, material: material))
        }
        guard !submeshes.isEmpty else {
            throw CoolScanCookerError.missingVertexAttribute("triangle submeshes")
        }

        return ExtractedMesh(
            name: mesh.name.isEmpty ? fallbackName : mesh.name,
            positions: positions,
            normals: normals,
            uvs: uvs,
            tangents: resolvedTangents,
            submeshes: submeshes,
            worldTransform: worldMatrix(of: mesh)
        )
    }

    private static func worldMatrix(of object: MDLObject) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        var current: MDLObject? = object
        while let node = current {
            if let transform = node.transform {
                matrix = transform.matrix * matrix
            }
            current = node.parent
        }
        return matrix
    }

    private static func fallbackTangents(for normals: [SIMD3<Float>]) -> [SIMD4<Float>] {
        normals.map { normal in
            let reference = abs(normal.y) < 0.99
                ? SIMD3<Float>(0, 1, 0)
                : SIMD3<Float>(1, 0, 0)
            let tangent = simd_normalize(simd_cross(reference, normal))
            return SIMD4<Float>(tangent, 1)
        }
    }

    // MARK: - Attributes

    private static func readFloat3Attribute(
        _ mesh: MDLMesh, name: String, count: Int
    ) -> [SIMD3<Float>]? {
        guard let data = mesh.vertexAttributeData(forAttributeNamed: name, as: .float3) else {
            return nil
        }
        return readVectors(data, count: count) { pointer in
            SIMD3<Float>(pointer[0], pointer[1], pointer[2])
        }
    }

    private static func readFloat2Attribute(
        _ mesh: MDLMesh, name: String, count: Int
    ) -> [SIMD2<Float>]? {
        guard let data = mesh.vertexAttributeData(forAttributeNamed: name, as: .float2) else {
            return nil
        }
        return readVectors(data, count: count) { pointer in
            SIMD2<Float>(pointer[0], pointer[1])
        }
    }

    private static func readFloat4Attribute(
        _ mesh: MDLMesh, name: String, count: Int
    ) -> [SIMD4<Float>]? {
        guard let data = mesh.vertexAttributeData(forAttributeNamed: name, as: .float4) else {
            return nil
        }
        return readVectors(data, count: count) { pointer in
            SIMD4<Float>(pointer[0], pointer[1], pointer[2], pointer[3])
        }
    }

    private static func readVectors<V>(
        _ data: MDLVertexAttributeData,
        count: Int,
        make: (UnsafePointer<Float>) -> V
    ) -> [V] {
        let stride = data.stride
        let base = data.dataStart
        var result: [V] = []
        result.reserveCapacity(count)
        for i in 0 ..< count {
            let pointer = (base + i * stride).assumingMemoryBound(to: Float.self)
            result.append(make(pointer))
        }
        return result
    }

    private static func readIndices(_ submesh: MDLSubmesh) -> [UInt32] {
        let count = submesh.indexCount
        guard count > 0 else { return [] }
        let buffer = submesh.indexBuffer(asIndexType: .uInt32)
        let map = buffer.map()
        let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    // MARK: - Materials

    private static func extractMaterial(
        _ material: MDLMaterial?,
        textureCache: inout [ObjectIdentifier: ExtractedTexture]
    ) -> ExtractedMaterial {
        var extracted = ExtractedMaterial()
        guard let material else { return extracted }

        if !material.name.isEmpty {
            extracted.name = material.name
        }

        if let property = material.property(with: .baseColor) {
            if let texture = texture(from: property, cache: &textureCache) {
                extracted.baseColorTexture = texture
            } else if let color = colorValue(of: property) {
                extracted.baseColorFactor = color
            }
        }
        if let property = material.property(with: .emission) {
            if let texture = texture(from: property, cache: &textureCache) {
                extracted.emissiveTexture = texture
            } else if let color = colorValue(of: property) {
                // Object Capture never emits; treat pure white as "unset".
                let rgb = SIMD3<Float>(color.x, color.y, color.z)
                if simd_length(rgb - SIMD3<Float>(1, 1, 1)) > 1e-3 {
                    extracted.emissiveFactor = rgb
                }
            }
        }
        if let property = material.property(with: .tangentSpaceNormal) {
            extracted.normalTexture = texture(from: property, cache: &textureCache)
        }
        if let property = material.property(with: .roughness) {
            if let texture = texture(from: property, cache: &textureCache) {
                extracted.roughnessTexture = texture
            } else if property.type == .float {
                extracted.roughnessFactor = property.floatValue
            }
        }
        if let property = material.property(with: .metallic) {
            if let texture = texture(from: property, cache: &textureCache) {
                extracted.metallicTexture = texture
            } else if property.type == .float {
                extracted.metallicFactor = property.floatValue
            }
        }
        if let property = material.property(with: .ambientOcclusion) {
            extracted.occlusionTexture = texture(from: property, cache: &textureCache)
        }

        return extracted
    }

    private static func texture(
        from property: MDLMaterialProperty,
        cache: inout [ObjectIdentifier: ExtractedTexture]
    ) -> ExtractedTexture? {
        guard property.type == .texture,
              let mdlTexture = property.textureSamplerValue?.texture
        else {
            return nil
        }
        let key = ObjectIdentifier(mdlTexture)
        if let cached = cache[key] {
            return cached
        }
        guard let image = mdlTexture.imageFromTexture()?.takeUnretainedValue() else {
            return nil
        }
        let extracted = ExtractedTexture(key: key, image: image)
        cache[key] = extracted
        return extracted
    }

    private static func colorValue(of property: MDLMaterialProperty) -> SIMD4<Float>? {
        switch property.type {
        case .float3:
            let value = property.float3Value
            return SIMD4<Float>(value.x, value.y, value.z, 1)
        case .float4:
            let value = property.float4Value
            return SIMD4<Float>(value.x, value.y, value.z, value.w)
        case .color:
            guard let cgColor = property.color,
                  let components = cgColor.components
            else { return nil }
            switch components.count {
            case 2: // grayscale + alpha
                let gray = Float(components[0])
                return SIMD4<Float>(gray, gray, gray, Float(components[1]))
            case 4...:
                return SIMD4<Float>(
                    Float(components[0]), Float(components[1]),
                    Float(components[2]), Float(components[3])
                )
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
