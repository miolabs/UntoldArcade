import simd

/// Hand-maintained Swift mirror of `Shaders/CoolWebShaderTypes.h`.
/// Every member is padded into float4/uint4 lanes; a stride test in
/// CoolWebPluginTests guards against drift between the two files.
public enum CoolWebShaderLimits {
    public static let maxStrands = 4
    public static let strandParticles = 64
    public static let strandSegments = strandParticles - 1
    public static let maxSplats = 4

    /// Bytes of the shared particle buffer:
    /// float4[maxStrands * strandParticles], xyz world, w unused.
    public static let particleBufferLength =
        maxStrands * strandParticles * MemoryLayout<SIMD4<Float>>.stride
}

public struct CoolWebStrandGPU: Sendable, Equatable {
    public var color: SIMD4<Float> = .zero  // rgb color, w opacity
    public var params: SIMD4<Float> = .zero // x core radius, y particle count, z seed

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
    public var counts = SIMD4<UInt32>(0, 0, 0, 0)     // x strand slots, y splats
    public var strands = (
        CoolWebStrandGPU(), CoolWebStrandGPU(),
        CoolWebStrandGPU(), CoolWebStrandGPU()
    )
    public var splats = (
        CoolWebSplatGPU(), CoolWebSplatGPU(),
        CoolWebSplatGPU(), CoolWebSplatGPU()
    )

    public init() {}

    public mutating func setStrand(_ index: Int, _ strand: CoolWebStrandGPU) {
        switch index {
        case 0: strands.0 = strand
        case 1: strands.1 = strand
        case 2: strands.2 = strand
        case 3: strands.3 = strand
        default: break
        }
    }

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
    case particles = 1
}
