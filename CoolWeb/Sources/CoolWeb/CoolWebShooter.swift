import Foundation
import simd

public enum CoolWebHandSide: Sendable, Hashable, CaseIterable {
    case left
    case right
}

/// Owns every live web net and publishes the drawable scene once per frame.
/// Fire/release/update calls must all come from the same (game) thread.
public final class CoolWebShooter {
    /// Nets kept alive at once (held + fading); bounded by the splat slots.
    public static let maxLiveNets = CoolWebShaderLimits.maxSplats

    public var params: CoolWebNetParams
    /// Injected surface query so tests can stub hits; the app wires this to
    /// the scene-mesh raycast with a plane-store fallback.
    public var surfaceQuery: (SIMD3<Float>, SIMD3<Float>, Float) -> CoolWebSurfaceHit?
    /// Fired when a net's center thread attaches (for sound/haptics). Called
    /// during update.
    public var onAttach: ((CoolWebHandSide, CoolWebSurfaceHit) -> Void)?

    private var nets: [CoolWebNet] = []
    private var attachAnnounced = Set<ObjectIdentifier>()

    public init(
        params: CoolWebNetParams = CoolWebNetParams(),
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

    public var liveNetCount: Int { nets.count }

    public func heldNet(for hand: CoolWebHandSide) -> CoolWebNet? {
        nets.first { $0.hand == hand && $0.isHeld }
    }

    /// Fires a new web net from a hand. An already-held net on that hand is
    /// released first (it stays on the wall and dissolves).
    @discardableResult
    public func fire(
        hand: CoolWebHandSide,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        now: TimeInterval,
        randomSeed: UInt64 = .random(in: 1 ... .max)
    ) -> CoolWebNet? {
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared.isFinite, lengthSquared > 1e-8 else { return nil }

        heldNet(for: hand)?.release(now: now)

        // Keep within the render budget: drop the oldest net that is no
        // longer held.
        while nets.count >= Self.maxLiveNets {
            if let index = nets.firstIndex(where: { !$0.isHeld }) {
                nets.remove(at: index)
            } else {
                nets.removeFirst()
            }
        }

        let net = CoolWebNet(
            hand: hand,
            origin: origin,
            direction: direction,
            surfaceQuery: surfaceQuery,
            params: params,
            now: now,
            randomSeed: randomSeed
        )
        nets.append(net)
        return net
    }

    /// Releases the held net on a hand (fist gesture / tracking loss).
    public func release(hand: CoolWebHandSide, now: TimeInterval) {
        heldNet(for: hand)?.release(now: now)
    }

    public func releaseAll(now: TimeInterval) {
        for net in nets { net.release(now: now) }
    }

    /// Moves the root anchors of the held nets with the tracked hands.
    public func updateHand(_ hand: CoolWebHandSide, position: SIMD3<Float>) {
        heldNet(for: hand)?.updateHand(position)
    }

    /// Steps every net and publishes the frame's drawable scene.
    public func step(now: TimeInterval, dt: Float) {
        for net in nets {
            net.update(now: now, dt: dt)
        }

        if let onAttach {
            for net in nets
            where net.phase == .attached
                && !attachAnnounced.contains(ObjectIdentifier(net)) {
                attachAnnounced.insert(ObjectIdentifier(net))
                if let hit = net.centerHit {
                    onAttach(net.hand, hit)
                }
            }
        }

        nets.removeAll { net in
            if net.isDead {
                attachAnnounced.remove(ObjectIdentifier(net))
                return true
            }
            return false
        }

        var segments: [CoolWebSegmentDesc] = []
        segments.reserveCapacity(nets.reduce(0) { $0 + $1.activeSegmentCount })
        for net in nets {
            net.appendSegments(into: &segments)
        }
        setCoolWebScene(
            segments: segments,
            splats: nets.compactMap { $0.splatDesc(now: now) }
        )
    }

    public func reset() {
        nets.removeAll()
        attachAnnounced.removeAll()
        clearCoolWebScene()
    }
}
