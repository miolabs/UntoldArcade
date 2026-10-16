import simd

/// Hand-maintained Swift mirror of `Shaders/CoolWebShaderTypes.h`.
/// Every member is padded into float4/uint4 lanes; a stride test in
/// CoolWebPluginTests guards against drift between the two files.
public enum CoolWebShaderLimits {
    public static let maxSegments = 4096
    public static let maxSplats = 4
    /// Palette cap of the glove skeleton: 17 deform bones + fingertip and
    /// muzzle markers, with headroom.
    public static let maxGloveJoints = 32

    /// Bytes of the shared segment buffer: CoolWebSegmentGPU[maxSegments].
    public static let segmentBufferLength =
        maxSegments * MemoryLayout<CoolWebSegmentGPU>.stride
}

/// One drawable thread segment. Everything on screen — flying cone threads,
/// cross-links, wall residue, torn dangles — is a list of these.
public struct CoolWebSegmentGPU: Sendable, Equatable {
    public var a: SIMD4<Float> = .zero      // xyz endpoint A, w core radius
    public var b: SIMD4<Float> = .zero      // xyz endpoint B, w tension 0…1
    public var params: SIMD4<Float> = .zero // x opacity, y seed

    public init() {}
}

/// One static bind-space vertex of the rigged glove. Uploaded once per hand;
/// the vertex shader skins it (4 influences) with the per-frame palette.
public struct CoolWebSkinnedGloveVertexGPU: Sendable, Equatable {
    /// xyz bind-space position, w = coverage distance from wrist (m).
    public var position = SIMD4<Float>.zero
    /// xyz bind-space normal, w = material (0 red fabric, 1 shooter metal).
    public var normal = SIMD4<Float>.zero
    /// xy = uv (v already flipped for Metal), zw = joint indices 0/1 as floats.
    public var texJoint = SIMD4<Float>.zero
    /// The four joint weights.
    public var weights = SIMD4<Float>(1, 0, 0, 0)
    /// xy = joint indices 2/3 as floats, zw unused.
    public var extra = SIMD4<Float>.zero

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
/// The joint palette and per-hand params ride setVertexBytes — they are tiny.
public enum CoolWebGloveBufferIndex: Int {
    case uniforms = 0
    case vertices = 1
    case joints = 2
    case params = 3
}
