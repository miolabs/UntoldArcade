import Foundation
import simd

/// One web strand as the game wants it drawn this frame.
public struct CoolWebStrandDesc: Sendable, Equatable {
    /// World-space particle positions, root (hand side) first. At most
    /// `CoolWebShaderLimits.strandParticles`; extra particles are dropped.
    public var particles: [SIMD3<Float>]
    public var radius: Float
    public var color: SIMD3<Float>
    public var opacity: Float
    public var seed: Float

    public init(
        particles: [SIMD3<Float>],
        radius: Float = 0.004,
        color: SIMD3<Float> = SIMD3<Float>(0.92, 0.95, 1.0),
        opacity: Float = 1,
        seed: Float = 0
    ) {
        self.particles = particles
        self.radius = radius
        self.color = color
        self.opacity = opacity
        self.seed = seed
    }
}

/// One impact splat (web pattern decal) at a surface attach point.
public struct CoolWebSplatDesc: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var radius: Float
    public var opacity: Float
    public var seed: Float
    /// Seconds since the splat appeared; drives the draw-in animation.
    public var age: Float

    public init(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        radius: Float = 0.18,
        opacity: Float = 1,
        seed: Float = 0,
        age: Float = 0
    ) {
        self.center = center
        self.normal = normal
        self.radius = radius
        self.opacity = opacity
        self.seed = seed
        self.age = age
    }
}

/// Lock-guarded scene state shared between the game thread (writes) and the
/// render thread (reads an immutable snapshot per pass).
final class CoolWebSceneState: @unchecked Sendable {
    static let shared = CoolWebSceneState()

    struct State: Sendable {
        var strands: [CoolWebStrandDesc] = []
        var splats: [CoolWebSplatDesc] = []
    }

    private let lock = NSLock()
    private var current = State()

    func state() -> State {
        lock.withLock { current }
    }

    func setScene(strands: [CoolWebStrandDesc], splats: [CoolWebSplatDesc]) {
        let sanitizedStrands = strands
            .prefix(CoolWebShaderLimits.maxStrands)
            .compactMap { Self.sanitize($0) }
        let sanitizedSplats = splats
            .prefix(CoolWebShaderLimits.maxSplats)
            .compactMap { Self.sanitize($0) }
        lock.withLock {
            current.strands = sanitizedStrands
            current.splats = sanitizedSplats
        }
    }

    func clear() {
        lock.withLock { current = State() }
    }

    private static func sanitize(_ desc: CoolWebStrandDesc) -> CoolWebStrandDesc? {
        var strand = desc
        if strand.particles.count > CoolWebShaderLimits.strandParticles {
            strand.particles = Array(
                strand.particles.prefix(CoolWebShaderLimits.strandParticles)
            )
        }
        guard strand.particles.count >= 2,
              strand.opacity > 0,
              strand.particles.allSatisfy({ simd_length_squared($0).isFinite })
        else { return nil }
        strand.radius = max(0.001, strand.radius)
        strand.opacity = min(1, strand.opacity)
        return strand
    }

    private static func sanitize(_ desc: CoolWebSplatDesc) -> CoolWebSplatDesc? {
        var splat = desc
        let normalLengthSq = simd_length_squared(splat.normal)
        guard splat.opacity > 0,
              normalLengthSq.isFinite, normalLengthSq > 1e-8,
              simd_length_squared(splat.center).isFinite
        else { return nil }
        splat.normal = simd_normalize(splat.normal)
        splat.radius = max(0.01, splat.radius)
        splat.opacity = min(1, splat.opacity)
        return splat
    }
}

// MARK: - Public API

/// Replaces the drawn scene wholesale. Safe to call every frame from the game
/// update; degenerate strands/splats are dropped and counts are capped at the
/// shader limits.
public func setCoolWebScene(
    strands: [CoolWebStrandDesc],
    splats: [CoolWebSplatDesc] = []
) {
    CoolWebSceneState.shared.setScene(strands: strands, splats: splats)
}

/// Hides all strands and splats (e.g. on session teardown).
public func clearCoolWebScene() {
    CoolWebSceneState.shared.clear()
}
