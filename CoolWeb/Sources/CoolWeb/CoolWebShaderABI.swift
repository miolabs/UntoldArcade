import simd

/// Hand-maintained Swift mirror of `Shaders/CoolWebShaderTypes.h`.
/// Every member is padded into float4/uint4 lanes; a stride test in
/// CoolWebPluginTests guards against drift between the two files.
public enum CoolWebShaderLimits {
    public static let maxSegments = 4096
    public static let maxSplats = 4
    /// Both gloves combined; a full two-hand glove is ~1200 vertices.
    public static let maxGloveVertices = 4096
    public static let maxGloveIndices = 24576

    /// Bytes of the shared segment buffer: CoolWebSegmentGPU[maxSegments].
    public static let segmentBufferLength =
        maxSegments * MemoryLayout<CoolWebSegmentGPU>.stride

    /// Bytes of the glove vertex/index ring buffers.
    public static let gloveVertexBufferLength =
        maxGloveVertices * MemoryLayout<CoolWebGloveVertexGPU>.stride
    public static let gloveIndexBufferLength =
        maxGloveIndices * MemoryLayout<UInt32>.stride
}

/// One drawable thread segment. Everything on screen — flying cone threads,
/// cross-links, wall residue, torn dangles — is a list of these.
public struct CoolWebSegmentGPU: Sendable, Equatable {
    public var a: SIMD4<Float> = .zero      // xyz endpoint A, w core radius
    public var b: SIMD4<Float> = .zero      // xyz endpoint B, w tension 0…1
    public var params: SIMD4<Float> = .zero // x opacity, y seed

    public init() {}
}

/// One skinned glove vertex, regenerated from the tracked hand every frame.
public struct CoolWebGloveVertexGPU: Sendable, Equatable {
    public var position = SIMD4<Float>.zero // xyz world, w = u (0…1 around the limb)
    public var normal = SIMD4<Float>.zero   // xyz world normal, w = v (m along the limb)
    /// x material (0 red fabric + webbing, 1 metal shooter),
    /// y ring radius (m — converts u to meters for the web pattern).
    public var params = SIMD4<Float>.zero

    public init() {}
}

public struct CoolWebSplatGPU: Sendable, Equatable {
    public var center: SIMD4<Float> = .zero // xyz world, w pattern radius
    public var normal: SIMD4<Float> = .zero // xyz unit normal, w opacity
    public var params: SIMD4<Float> = .zero // x seed, y age (s)

    public init() {}
}

public struct CoolWebUniforms: Sendable {
    public var viewProj = matrix_identity_float4x4
    public var cameraWorld = SIMD4<Float>(0, 0, 0, 0) // xyz camera, w time
    /// x segments, y splats, z tension-heatmap flag.
    public var counts = SIMD4<UInt32>(0, 0, 0, 0)
    public var splats = (
        CoolWebSplatGPU(), CoolWebSplatGPU(),
        CoolWebSplatGPU(), CoolWebSplatGPU()
    )

    public init() {}

    public mutating func setSplat(_ index: Int, _ splat: CoolWebSplatGPU) {
        switch index {
        case 0: splats.0 = splat
        case 1: splats.1 = splat
        case 2: splats.2 = splat
        case 3: splats.3 = splat
        default: break
        }
    }
}

public enum CoolWebBufferIndex: Int {
    case uniforms = 0
    case segments = 1
}

/// Buffer slots of the glove pipeline (separate pipeline, separate table).
public enum CoolWebGloveBufferIndex: Int {
    case uniforms = 0
    case vertices = 1
}
