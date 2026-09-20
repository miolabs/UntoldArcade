import Foundation
import simd

/// One drawable web-thread segment for this frame.
public struct CoolWebSegmentDesc: Sendable, Equatable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var radius: Float
    /// 0 at rest length … 1 just before tearing (drives the debug heatmap).
    public var tension: Float
    public var opacity: Float
    public var seed: Float

    public init(
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        radius: Float = 0.002,
        tension: Float = 0,
        opacity: Float = 1,
        seed: Float = 0
    ) {
        self.a = a
        self.b = b
        self.radius = radius
        self.tension = tension
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
        var segments: [CoolWebSegmentDesc] = []
        var splats: [CoolWebSplatDesc] = []
        var tensionHeatmap = false
        /// The flat web-pattern decal at the impact point read as a sticker
        /// on device — off by default, toggleable for comparison.
        var splatsEnabled = false
    }

    private let lock = NSLock()
    private var current = State()

    func state() -> State {
        lock.withLock { current }
    }

    func setScene(segments: [CoolWebSegmentDesc], splats: [CoolWebSplatDesc]) {
        let sanitizedSegments = segments
            .prefix(CoolWebShaderLimits.maxSegments)
            .compactMap { Self.sanitize($0) }
        let sanitizedSplats = splats
            .prefix(CoolWebShaderLimits.maxSplats)
            .compactMap { Self.sanitize($0) }
        lock.withLock {
            current.segments = sanitizedSegments
            current.splats = current.splatsEnabled ? sanitizedSplats : []
        }
    }

    func setTensionHeatmap(_ enabled: Bool) {
        lock.withLock { current.tensionHeatmap = enabled }
    }

    func setSplatsEnabled(_ enabled: Bool) {
        lock.withLock {
            current.splatsEnabled = enabled
            if !enabled { current.splats = [] }
        }
    }

    func clear() {
        lock.withLock {
            let heatmap = current.tensionHeatmap
            let splatsEnabled = current.splatsEnabled
            current = State()
            current.tensionHeatmap = heatmap
            current.splatsEnabled = splatsEnabled
        }
    }

    private static func sanitize(_ desc: CoolWebSegmentDesc) -> CoolWebSegmentDesc? {
        var segment = desc
        guard segment.opacity > 0,
              simd_length_squared(segment.a).isFinite,
              simd_length_squared(segment.b).isFinite
        else { return nil }
        segment.radius = max(0.0005, segment.radius)
        segment.tension = min(max(segment.tension, 0), 1)
        segment.opacity = min(segment.opacity, 1)
        return segment
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
        splat.opacity = min(splat.opacity, 1)
        return splat
    }
}

// MARK: - Public API

/// Replaces the drawn scene wholesale. Safe to call every frame from the game
/// update; degenerate segments/splats are dropped and counts are capped at the
/// shader limits.
public func setCoolWebScene(
    segments: [CoolWebSegmentDesc],
    splats: [CoolWebSplatDesc] = []
) {
    CoolWebSceneState.shared.setScene(segments: segments, splats: splats)
}

/// Debug view: colors every thread by its tension (blue at rest → red just
/// before tearing) instead of silk white.
public func setCoolWebTensionHeatmap(_ enabled: Bool) {
    CoolWebSceneState.shared.setTensionHeatmap(enabled)
}

/// Shows/hides the flat web-pattern decal at the impact point (default off —
/// it read as a sticker on device; the residue threads carry the wall look).
public func setCoolWebSplatsEnabled(_ enabled: Bool) {
    CoolWebSceneState.shared.setSplatsEnabled(enabled)
}

/// Hides all segments and splats (e.g. on session teardown).
public func clearCoolWebScene() {
    CoolWebSceneState.shared.clear()
}
