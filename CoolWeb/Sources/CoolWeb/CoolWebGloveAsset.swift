//
//  CoolWebGloveAsset.swift
//  CoolWeb
//
//  Loads the rigged Spider-Man glove USDZs (movie-suit extraction, 17-bone
//  ARKit-named skeleton, 2 bone influences per vertex) into plain CPU structs
//  the renderer and the retarget solver consume. ModelIO does the USD parsing;
//  everything it returns is copied out into value types so the asset can cross
//  threads and be asserted on in host unit tests without ModelIO around.
//

import Foundation
import ModelIO
import simd

/// One glove submesh: a contiguous index range drawn with one material.
public struct CoolWebGloveSubmesh: Sendable, Equatable {
    /// 0 = red suit fabric, 1 = web-shooter metal (matches the material lane
    /// baked into the vertices and the texture pair the renderer binds).
    public var materialIndex: Int
    public var indexStart: Int
    public var indexCount: Int
}

/// Skeleton of one glove: joint j's bind-pose head position in mesh space,
/// with `parent[j]` indexing into the same arrays (-1 = root). Joint order is
/// the order `jointIndices` in the vertex data refer to.
public struct CoolWebGloveSkeleton: Sendable, Equatable {
    public var names: [String]
    public var parents: [Int]
    public var bindPositions: [SIMD3<Float>]

    public func jointIndex(named name: String) -> Int? {
        names.firstIndex(of: name)
    }

    /// The 17 deform bones the retarget solver drives (ARKit joint names).
    public static let requiredJoints: [String] = ["forearmArm", "wrist"]
        + ["thumb", "indexFinger", "middleFinger", "ringFinger", "littleFinger"]
        .flatMap { ["\($0)Knuckle", "\($0)IntermediateBase", "\($0)IntermediateTip"] }

    /// Optional non-deforming marker at the web-shooter emitter, parented
    /// to the wrist; strands fire from its skinned position.
    public static let muzzleJoint = "webMuzzle"
}

/// One loaded glove: static bind-space geometry + skeleton. Vertices are
/// already in the GPU layout so the renderer can memcpy them into a buffer.
public struct CoolWebGloveAsset: @unchecked Sendable {
    public var side: CoolWebHandSide
    public var vertices: [CoolWebSkinnedGloveVertexGPU]
    public var indices: [UInt32]
    public var submeshes: [CoolWebGloveSubmesh]
    public var skeleton: CoolWebGloveSkeleton
    /// Largest baked per-vertex coverage distance (m) — the suit-up front
    /// sweeps 0 → this.
    public var coverageExtent: Float
}

public enum CoolWebGloveAssetError: Error, CustomStringConvertible {
    case notFound(String)
    case missingMesh
    case missingSkeleton
    case missingAttribute(String)
    case unexpectedJointCount(Int)

    public var description: String {
        switch self {
        case let .notFound(path): return "glove asset not found: \(path)"
        case .missingMesh: return "glove usdz contains no mesh"
        case .missingSkeleton: return "glove usdz contains no skeleton"
        case let .missingAttribute(name): return "glove mesh lacks attribute \(name)"
        case let .unexpectedJointCount(count): return "glove skeleton has \(count) joints"
        }
    }
}

public enum CoolWebGloveAssetLoader {
    /// Parses one rigged glove usdz. Blocking — call once at startup.
    public static func load(
        url: URL,
        side: CoolWebHandSide
    ) throws -> CoolWebGloveAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoolWebGloveAssetError.notFound(url.path)
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()

        guard let mesh = firstMesh(in: asset) else {
            throw CoolWebGloveAssetError.missingMesh
        }
        guard let skeletonObject = firstSkeleton(in: asset) else {
            throw CoolWebGloveAssetError.missingSkeleton
        }

        let skeleton = try makeSkeleton(from: skeletonObject)
        // The 17 deform bones the solver drives must exist; extra joints
        // (fingertips, the muzzle marker) ride along up to the palette cap.
        guard skeleton.names.count <= CoolWebShaderLimits.maxGloveJoints,
              CoolWebGloveSkeleton.requiredJoints.allSatisfy({
                  skeleton.jointIndex(named: $0) != nil
              })
        else {
            throw CoolWebGloveAssetError.unexpectedJointCount(skeleton.names.count)
        }

        let meshTransform = worldTransform(of: mesh)
        let normalTransform = normalMatrix(of: meshTransform)

        // Blender's USD export can omit authored normals; synthesize smooth
        // ones then instead of failing. MUST happen before any attribute
        // fetch: addNormals reallocates the vertex buffers, so pointers
        // fetched earlier would dangle.
        if mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributeNormal, as: .float3
        ) == nil {
            mesh.addNormals(
                withAttributeNamed: MDLVertexAttributeNormal,
                creaseThreshold: 0.5
            )
        }

        // Attribute extraction. ModelIO hands back a base pointer + stride per
        // attribute regardless of how the USD packed its buffers.
        guard let positionData = mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributePosition, as: .float3
        ) else { throw CoolWebGloveAssetError.missingAttribute("position") }
        guard let normalData = mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributeNormal, as: .float3
        ) else { throw CoolWebGloveAssetError.missingAttribute("normal") }
        guard let uvData = mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2
        ) else { throw CoolWebGloveAssetError.missingAttribute("textureCoordinate") }
        guard let jointData = mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributeJointIndices, as: .uShort4
        ) else { throw CoolWebGloveAssetError.missingAttribute("jointIndices") }
        guard let weightData = mesh.vertexAttributeData(
            forAttributeNamed: MDLVertexAttributeJointWeights, as: .float4
        ) else { throw CoolWebGloveAssetError.missingAttribute("jointWeights") }

        let wristPosition = skeleton.bindPositions[
            skeleton.jointIndex(named: "wrist") ?? 0
        ]

        let count = mesh.vertexCount
        var vertices = [CoolWebSkinnedGloveVertexGPU](
            repeating: CoolWebSkinnedGloveVertexGPU(), count: count
        )
        var coverageExtent: Float = 0
        for i in 0 ..< count {
            let rawPosition = positionData.float3(at: i)
            let rawNormal = normalData.float3(at: i)
            let uv = uvData.float2(at: i)
            let joints = jointData.ushort4(at: i)
            var weights = weightData.float4(at: i)

            let position = transformPoint(meshTransform, rawPosition)
            let normal = simd_normalize(normalTransform * rawNormal)
            let weightSum = weights.sum()
            if weightSum > 1e-5 { weights /= weightSum }
            else { weights = SIMD4<Float>(1, 0, 0, 0) }

            // Suit-up coordinate: how far this vertex sits from the wrist
            // joint in bind space. The front sweeps through it.
            let coverage = simd_length(position - wristPosition)
            coverageExtent = max(coverageExtent, coverage)

            var vertex = CoolWebSkinnedGloveVertexGPU()
            vertex.position = SIMD4<Float>(position, coverage)
            vertex.normal = SIMD4<Float>(normal, 0)
            // USD uv origin is bottom-left, MTKTextureLoader's default is
            // top-left: flip v here once instead of per-texture options.
            vertex.texJoint = SIMD4<Float>(
                uv.x, 1 - uv.y, Float(joints.x), Float(joints.y)
            )
            vertex.weights = weights
            vertex.extra = SIMD4<Float>(Float(joints.z), Float(joints.w), 0, 0)
            vertices[i] = vertex
        }

        // Submeshes: keep one contiguous uint32 index list, remember ranges.
        var indices: [UInt32] = []
        var submeshes: [CoolWebGloveSubmesh] = []
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            let start = indices.count
            indices.append(contentsOf: indices32(of: submesh))
            let materialName = submesh.material?.name ?? ""
            let materialIndex = materialName.lowercased().contains("webshooter") ? 1 : 0
            submeshes.append(
                CoolWebGloveSubmesh(
                    materialIndex: materialIndex,
                    indexStart: start,
                    indexCount: indices.count - start
                )
            )
        }
        guard !indices.isEmpty else { throw CoolWebGloveAssetError.missingMesh }

        // Stamp the material lane now that submeshes are known: a vertex's
        // material is whichever submesh references it.
        for submesh in submeshes {
            let lane = Float(submesh.materialIndex)
            for i in submesh.indexStart ..< submesh.indexStart + submesh.indexCount {
                vertices[Int(indices[i])].normal.w = lane
            }
        }

        return CoolWebGloveAsset(
            side: side,
            vertices: vertices,
            indices: indices,
            submeshes: submeshes,
            skeleton: skeleton,
            coverageExtent: coverageExtent
        )
    }

    // MARK: - ModelIO traversal

    private static func firstMesh(in asset: MDLAsset) -> MDLMesh? {
        var found: MDLMesh?
        func walk(_ object: MDLObject) {
            if found != nil { return }
            if let mesh = object as? MDLMesh { found = mesh; return }
            for child in object.children.objects { walk(child) }
        }
        for i in 0 ..< asset.count { walk(asset.object(at: i)) }
        return found
    }

    private static func firstSkeleton(in asset: MDLAsset) -> MDLSkeleton? {
        var found: MDLSkeleton?
        func walk(_ object: MDLObject) {
            if found != nil { return }
            if let skeleton = object as? MDLSkeleton { found = skeleton; return }
            for child in object.children.objects { walk(child) }
        }
        for i in 0 ..< asset.count { walk(asset.object(at: i)) }
        return found
    }

    private static func makeSkeleton(
        from skeleton: MDLSkeleton
    ) throws -> CoolWebGloveSkeleton {
        let paths = skeleton.jointPaths
        let names = paths.map { path in
            path.split(separator: "/").last.map(String.init) ?? path
        }
        let parents = paths.map { path -> Int in
            let components = path.split(separator: "/")
            guard components.count > 1 else { return -1 }
            let parentPath = components.dropLast().joined(separator: "/")
            return paths.firstIndex(of: parentPath) ?? -1
        }
        let bindMatrices = skeleton.jointBindTransforms.float4x4Array
        guard bindMatrices.count == paths.count else {
            throw CoolWebGloveAssetError.unexpectedJointCount(bindMatrices.count)
        }
        let bindPositions = bindMatrices.map {
            SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z)
        }
        return CoolWebGloveSkeleton(
            names: names, parents: parents, bindPositions: bindPositions
        )
    }

    private static func worldTransform(of object: MDLObject) -> simd_float4x4 {
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

    private static func normalMatrix(of transform: simd_float4x4) -> simd_float3x3 {
        let m = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        return m.inverse.transpose
    }

    private static func transformPoint(
        _ matrix: simd_float4x4, _ point: SIMD3<Float>
    ) -> SIMD3<Float> {
        let out = matrix * SIMD4<Float>(point, 1)
        return SIMD3<Float>(out.x, out.y, out.z)
    }

    private static func indices32(of submesh: MDLSubmesh) -> [UInt32] {
        let map = submesh.indexBuffer(asIndexType: .uInt32).map()
        let pointer = map.bytes.bindMemory(
            to: UInt32.self, capacity: submesh.indexCount
        )
        return Array(UnsafeBufferPointer(start: pointer, count: submesh.indexCount))
    }
}

// MARK: - Attribute readers

private extension MDLVertexAttributeData {
    func float3(at index: Int) -> SIMD3<Float> {
        let pointer = (dataStart + index * stride).assumingMemoryBound(to: Float.self)
        return SIMD3<Float>(pointer[0], pointer[1], pointer[2])
    }

    func float2(at index: Int) -> SIMD2<Float> {
        let pointer = (dataStart + index * stride).assumingMemoryBound(to: Float.self)
        return SIMD2<Float>(pointer[0], pointer[1])
    }

    func float4(at index: Int) -> SIMD4<Float> {
        let pointer = (dataStart + index * stride).assumingMemoryBound(to: Float.self)
        return SIMD4<Float>(pointer[0], pointer[1], pointer[2], pointer[3])
    }

    func ushort4(at index: Int) -> SIMD4<UInt16> {
        let pointer = (dataStart + index * stride).assumingMemoryBound(to: UInt16.self)
        return SIMD4<UInt16>(pointer[0], pointer[1], pointer[2], pointer[3])
    }
}

// MARK: - Loaded-asset store (game thread writes, render thread reads)

/// The texture maps each glove material carries.
public enum CoolWebGloveTextureKind: Int, CaseIterable, Sendable {
    case baseColor
    case roughness
    case normal
}

public final class CoolWebGloveAssetStore: @unchecked Sendable {
    public static let shared = CoolWebGloveAssetStore()

    private struct TextureKey: Hashable {
        var materialIndex: Int
        var kind: CoolWebGloveTextureKind
    }

    private let lock = NSLock()
    private var assets: [CoolWebHandSide: CoolWebGloveAsset] = [:]
    private var textureURLs: [TextureKey: URL] = [:]
    /// Bumped on every load so the renderer knows to rebuild GPU buffers.
    private var generationCounter = 0

    public func set(asset: CoolWebGloveAsset) {
        lock.withLock {
            assets[asset.side] = asset
            generationCounter += 1
        }
    }

    public func setTextureURL(
        _ url: URL, materialIndex: Int, kind: CoolWebGloveTextureKind
    ) {
        lock.withLock {
            textureURLs[TextureKey(materialIndex: materialIndex, kind: kind)] = url
            generationCounter += 1
        }
    }

    public func asset(for side: CoolWebHandSide) -> CoolWebGloveAsset? {
        lock.withLock { assets[side] }
    }

    public func textureURL(
        materialIndex: Int, kind: CoolWebGloveTextureKind
    ) -> URL? {
        lock.withLock {
            textureURLs[TextureKey(materialIndex: materialIndex, kind: kind)]
        }
    }

    public var generation: Int {
        lock.withLock { generationCounter }
    }
}

/// Loads both rigged gloves + their textures. Call once at startup, before
/// entering the immersive space. Throws if either usdz fails to parse.
/// `texturesDirectory` holds the cooked maps by convention:
/// `{red,webshooters}_{baseColor.jpg,roughness.jpg,normal.png}` — a missing
/// map only mutes that effect (the renderer substitutes a neutral texel).
public func loadCoolWebGloveAssets(
    rightURL: URL,
    leftURL: URL,
    texturesDirectory: URL
) throws {
    let right = try CoolWebGloveAssetLoader.load(url: rightURL, side: .right)
    let left = try CoolWebGloveAssetLoader.load(url: leftURL, side: .left)
    let store = CoolWebGloveAssetStore.shared
    store.set(asset: right)
    store.set(asset: left)
    let files: [(Int, CoolWebGloveTextureKind, String)] = [
        (0, .baseColor, "red_baseColor.jpg"),
        (0, .roughness, "red_roughness.jpg"),
        (0, .normal, "red_normal.png"),
        (1, .baseColor, "webshooters_baseColor.jpg"),
        (1, .roughness, "webshooters_roughness.jpg"),
        (1, .normal, "webshooters_normal.png"),
    ]
    for (material, kind, name) in files {
        store.setTextureURL(
            texturesDirectory.appendingPathComponent(name),
            materialIndex: material,
            kind: kind
        )
    }
}
