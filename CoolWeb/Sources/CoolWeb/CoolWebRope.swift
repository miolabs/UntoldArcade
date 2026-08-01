import Foundation
import simd

/// Tuning for one simulated web strand.
public struct CoolWebRopeParams: Sendable, Equatable {
    public var particleCount: Int
    public var substeps: Int
    public var gravity: SIMD3<Float>
    /// Per-second velocity damping factor exponent (higher = calmer rope).
    public var damping: Float

    public init(
        particleCount: Int = CoolWebShaderLimits.strandParticles,
        substeps: Int = 8,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        damping: Float = 1.5
    ) {
        self.particleCount = min(
            max(2, particleCount),
            CoolWebShaderLimits.strandParticles
        )
        self.substeps = max(1, substeps)
        self.gravity = gravity
        self.damping = damping
    }
}

/// Position-based rope: Verlet integration + sequential distance-constraint
/// projection (forward and backward sweeps per substep, which converges far
/// faster on a chain than Jacobi). Ends are pinned by overriding positions;
/// interior particles have unit mass.
public final class CoolWebRope {
    public private(set) var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    public let params: CoolWebRopeParams

    /// Rest length of one segment. The strand pays out by growing this.
    public var segmentRestLength: Float = 0

    public var rootPin: SIMD3<Float>?
    public var tipPin: SIMD3<Float>?

    public init(params: CoolWebRopeParams = CoolWebRopeParams(), origin: SIMD3<Float>) {
        self.params = params
        positions = Array(repeating: origin, count: params.particleCount)
        previous = positions
    }

    public var particleCount: Int { positions.count }
    public var totalRestLength: Float {
        segmentRestLength * Float(particleCount - 1)
    }

    /// Straight-line length between the current end particles.
    public var endToEndLength: Float {
        simd_length(positions[particleCount - 1] - positions[0])
    }

    public func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 30.0)
        guard dt > 0 else { return }
        let substepDt = dt / Float(params.substeps)
        let dampingFactor = exp(-params.damping * substepDt)
        let gravityStep = params.gravity * (substepDt * substepDt)

        for _ in 0 ..< params.substeps {
            applyPins()
            for i in 0 ..< positions.count {
                let velocity = (positions[i] - previous[i]) * dampingFactor
                previous[i] = positions[i]
                positions[i] += velocity + gravityStep
            }
            applyPins()
            solveDistanceConstraints(forward: true)
            solveDistanceConstraints(forward: false)
            applyPins()
        }
    }

    /// Teleports every particle onto the segment from root to tip (used when a
    /// strand spawns so the first frame doesn't show stale positions).
    public func layoutStraight(from root: SIMD3<Float>, to tip: SIMD3<Float>) {
        let count = positions.count
        for i in 0 ..< count {
            let t = Float(i) / Float(count - 1)
            positions[i] = simd_mix(root, tip, SIMD3<Float>(repeating: t))
        }
        previous = positions
    }

    private func applyPins() {
        if let rootPin {
            positions[0] = rootPin
            previous[0] = rootPin
        }
        if let tipPin {
            positions[positions.count - 1] = tipPin
            previous[positions.count - 1] = tipPin
        }
    }

    private func solveDistanceConstraints(forward: Bool) {
        guard segmentRestLength >= 0 else { return }
        let count = positions.count
        let lastIndex = count - 1
        let range = forward
            ? Array(0 ..< lastIndex)
            : Array((0 ..< lastIndex).reversed())

        for i in range {
            let j = i + 1
            var delta = positions[j] - positions[i]
            let distance = simd_length(delta)
            guard distance > 1e-7 else { continue }
            delta /= distance
            let error = distance - segmentRestLength

            let iPinned = (i == 0 && rootPin != nil)
            let jPinned = (j == lastIndex && tipPin != nil)
            let correction = delta * error
            switch (iPinned, jPinned) {
            case (true, true):
                continue
            case (true, false):
                positions[j] -= correction
            case (false, true):
                positions[i] += correction
            case (false, false):
                positions[i] += correction * 0.5
                positions[j] -= correction * 0.5
            }
        }
    }
}
