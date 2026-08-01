import Foundation
import simd

public enum CoolWebHandSide: Sendable, Hashable, CaseIterable {
    case left
    case right
}

public enum CoolWebStrandPhase: Sendable, Equatable {
    /// Tip is kinematic, flying from the hand toward the target.
    case flying
    /// Tip pinned to a real surface, root follows the hand.
    case attached
    /// Root released; the strand hangs from the surface before dissolving.
    case dangling
    /// Fading out; removed when opacity reaches zero.
    case dissolving
}

/// Tuning for the shooter and its strands.
public struct CoolWebShooterParams: Sendable, Equatable {
    public var webSpeed: Float
    public var maxRange: Float
    /// Extra rest length as a fraction of the attach distance (visible sag).
    public var slack: Float
    public var strandRadius: Float
    public var splatRadius: Float
    public var danglingDuration: Float
    public var dissolveDuration: Float
    public var missDissolveDuration: Float
    public var rope: CoolWebRopeParams

    public init(
        webSpeed: Float = 18,
        maxRange: Float = 7,
        slack: Float = 0.08,
        strandRadius: Float = 0.004,
        splatRadius: Float = 0.18,
        danglingDuration: Float = 2.5,
        dissolveDuration: Float = 0.8,
        missDissolveDuration: Float = 0.3,
        rope: CoolWebRopeParams = CoolWebRopeParams()
    ) {
        self.webSpeed = webSpeed
        self.maxRange = maxRange
        self.slack = slack
        self.strandRadius = strandRadius
        self.splatRadius = splatRadius
        self.danglingDuration = danglingDuration
        self.dissolveDuration = dissolveDuration
        self.missDissolveDuration = missDissolveDuration
        self.rope = rope
    }
}

/// One fired web: fly → attach (or miss) → dangle → dissolve.
public final class CoolWebStrand {
    public let hand: CoolWebHandSide
    public private(set) var phase: CoolWebStrandPhase = .flying
    public let seed: Float

    private let params: CoolWebShooterParams
    private let rope: CoolWebRope
    private let origin: SIMD3<Float>
    private let direction: SIMD3<Float>
    public let hit: CoolWebSurfaceHit?
    private let spawnTime: TimeInterval

    private var handPosition: SIMD3<Float>
    private var tipTravel: Float = 0
    private var attachTime: TimeInterval?
    private var phaseChangeTime: TimeInterval
    private var opacity: Float = 1
    private var dissolveDuration: Float

    public init(
        hand: CoolWebHandSide,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        hit: CoolWebSurfaceHit?,
        params: CoolWebShooterParams,
        now: TimeInterval
    ) {
        self.hand = hand
        self.origin = origin
        self.direction = simd_normalize(direction)
        self.hit = hit
        self.params = params
        seed = Float.random(in: 0 ..< 100)
        spawnTime = now
        phaseChangeTime = now
        handPosition = origin
        dissolveDuration = params.dissolveDuration
        rope = CoolWebRope(params: params.rope, origin: origin)
        rope.rootPin = origin
        rope.tipPin = origin
        rope.segmentRestLength = 0
    }

    public var isDead: Bool { opacity <= 0 }
    public var isHeld: Bool { phase == .flying || phase == .attached }
    public var attachPoint: SIMD3<Float>? { phase == .flying ? nil : hit?.position }

    public func updateHand(_ position: SIMD3<Float>) {
        handPosition = position
    }

    /// Lets go of the root: the strand stays on the wall and dangles.
    public func release(now: TimeInterval) {
        guard isHeld else { return }
        if phase == .attached {
            transition(to: .dangling, now: now)
            rope.rootPin = nil
        } else {
            // Released mid-flight: just dissolve quickly.
            dissolveDuration = params.missDissolveDuration
            transition(to: .dissolving, now: now)
        }
    }

    public func update(now: TimeInterval, dt: Float) {
        switch phase {
        case .flying:
            updateFlying(now: now, dt: dt)
        case .attached:
            rope.rootPin = handPosition
        case .dangling:
            if now - phaseChangeTime > TimeInterval(params.danglingDuration) {
                transition(to: .dissolving, now: now)
            }
        case .dissolving:
            let t = Float(now - phaseChangeTime) / max(0.01, dissolveDuration)
            opacity = max(0, 1 - t)
        }
        rope.step(dt: dt)
    }

    private func updateFlying(now: TimeInterval, dt: Float) {
        rope.rootPin = handPosition
        tipTravel += params.webSpeed * dt
        let targetDistance = hit?.distance ?? params.maxRange

        if tipTravel >= targetDistance {
            if let hit {
                rope.tipPin = hit.position
                // Slightly slack rest length so the attached strand sags.
                let attachDistance = simd_length(hit.position - handPosition)
                rope.segmentRestLength = attachDistance * (1 + params.slack)
                    / Float(rope.particleCount - 1)
                attachTime = now
                transition(to: .attached, now: now)
            } else {
                rope.tipPin = origin + direction * params.maxRange
                rope.segmentRestLength = params.maxRange
                    / Float(rope.particleCount - 1)
                dissolveDuration = params.missDissolveDuration
                transition(to: .dissolving, now: now)
            }
            return
        }

        // Pay out: tip is kinematic, rope rest length tracks the travel so the
        // strand stays taut behind the tip.
        let tip = origin + direction * tipTravel
        rope.tipPin = tip
        rope.segmentRestLength = simd_length(tip - handPosition)
            / Float(rope.particleCount - 1)
    }

    private func transition(to newPhase: CoolWebStrandPhase, now: TimeInterval) {
        phase = newPhase
        phaseChangeTime = now
    }

    public func strandDesc() -> CoolWebStrandDesc {
        CoolWebStrandDesc(
            particles: rope.positions,
            radius: params.strandRadius,
            opacity: opacity,
            seed: seed
        )
    }

    public func splatDesc(now: TimeInterval) -> CoolWebSplatDesc? {
        guard let hit, let attachTime else { return nil }
        return CoolWebSplatDesc(
            center: hit.position,
            normal: hit.normal,
            radius: params.splatRadius,
            opacity: opacity,
            seed: seed,
            age: Float(now - attachTime)
        )
    }
}

/// Owns every live strand and publishes the drawable scene once per frame.
/// Fire/release/update calls must all come from the same (game) thread.
public final class CoolWebShooter {
    public var params: CoolWebShooterParams
    /// Injected surface query so tests can stub hits; the app wires this to
    /// the scene-mesh raycast with a plane-store fallback.
    public var surfaceQuery: (SIMD3<Float>, SIMD3<Float>, Float) -> CoolWebSurfaceHit?

    private var strands: [CoolWebStrand] = []
    /// Fired when a strand attaches (for sound/haptics). Called during update.
    public var onAttach: ((CoolWebHandSide, CoolWebSurfaceHit) -> Void)?

    public init(
        params: CoolWebShooterParams = CoolWebShooterParams(),
        surfaceQuery: @escaping (SIMD3<Float>, SIMD3<Float>, Float) -> CoolWebSurfaceHit? = { origin, direction, maxDistance in
            raycastCoolWebSurface(
                origin: origin,
                direction: direction,
                maxDistance: maxDistance
            )
        }
    ) {
        self.params = params
        self.surfaceQuery = surfaceQuery
    }

    public var liveStrandCount: Int { strands.count }

    public func heldStrand(for hand: CoolWebHandSide) -> CoolWebStrand? {
        strands.first { $0.hand == hand && $0.isHeld }
    }

    /// Fires a new web from a hand. An already-held strand on that hand is
    /// released first (it stays on the wall and dissolves).
    @discardableResult
    public func fire(
        hand: CoolWebHandSide,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        now: TimeInterval
    ) -> CoolWebStrand? {
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared.isFinite, lengthSquared > 1e-8 else { return nil }

        heldStrand(for: hand)?.release(now: now)

        // Keep within the renderer's strand budget: drop the oldest strand
        // that is no longer held.
        while strands.count >= CoolWebShaderLimits.maxStrands {
            if let index = strands.firstIndex(where: { !$0.isHeld }) {
                strands.remove(at: index)
            } else {
                strands.removeFirst()
            }
        }

        let hit = surfaceQuery(origin, simd_normalize(direction), params.maxRange)
        let strand = CoolWebStrand(
            hand: hand,
            origin: origin,
            direction: direction,
            hit: hit,
            params: params,
            now: now
        )
        strands.append(strand)
        return strand
    }

    /// Releases the held strand on a hand (fist gesture / tracking loss).
    public func release(hand: CoolWebHandSide, now: TimeInterval) {
        heldStrand(for: hand)?.release(now: now)
    }

    public func releaseAll(now: TimeInterval) {
        for strand in strands { strand.release(now: now) }
    }

    /// Moves the root anchor of the held strands with the tracked hands.
    public func updateHand(_ hand: CoolWebHandSide, position: SIMD3<Float>) {
        heldStrand(for: hand)?.updateHand(position)
    }

    /// Steps every strand and publishes the frame's drawable scene.
    public func step(now: TimeInterval, dt: Float) {
        var attachedBefore = Set<ObjectIdentifier>()
        for strand in strands where strand.phase == .attached {
            attachedBefore.insert(ObjectIdentifier(strand))
        }

        for strand in strands {
            strand.update(now: now, dt: dt)
        }

        if let onAttach {
            for strand in strands
            where strand.phase == .attached
                && !attachedBefore.contains(ObjectIdentifier(strand)) {
                if let hit = strand.hit {
                    onAttach(strand.hand, hit)
                }
            }
        }

        strands.removeAll { $0.isDead }

        setCoolWebScene(
            strands: strands.map { $0.strandDesc() },
            splats: strands.compactMap { $0.splatDesc(now: now) }
        )
    }

    public func reset() {
        strands.removeAll()
        clearCoolWebScene()
    }
}
