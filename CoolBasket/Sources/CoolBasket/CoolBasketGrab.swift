//
//  CoolBasketGrab.swift
//  CoolBasket
//
//  How a ball gets into, sits in and leaves the hands — the rules, kept
//  pure so they can be tested without a headset. Three holds: a pinch
//  (thumb and index closing near the ball), a hand closing on the ball
//  (catching a bounce, palming it), and the ball between two palms. The
//  game (CoolBasketGame, visionOS) feeds these the tracked poses each frame
//  and moves the ball, bodies and colliders accordingly.
//

import Foundation
import simd
import UntoldEngine

/// A ball in the hands, and which hands.
public enum CoolBasketHoldKind: Equatable, Sendable {
    case pinch(CoolBasketHandSide)
    case palm(CoolBasketHandSide)
    case twoHands

    public var sides: Set<CoolBasketHandSide> {
        switch self {
        case let .pinch(side), let .palm(side): return [side]
        case .twoHands: return [.left, .right]
        }
    }
}

public enum CoolBasketGrabRules {
    /// Pinch tighter than this grabs; wider than this releases (hysteresis).
    public static let pinchGrabDistance: Float = 0.025
    public static let pinchReleaseDistance: Float = 0.045
    /// A pinch picks up a ball whose centre is within this of the palm.
    public static let pinchReach: Float = 0.30
    /// A hand is closing when its curl (0 open, 1 fist) has risen by this
    /// much within the window — a motion, not a level: a hand shaped
    /// around a 24 cm ball is barely curled at all, so no fixed level
    /// tells a catch from a relaxed hand.
    public static let curlCloseDelta: Float = 0.12
    public static let curlCloseWindow: TimeInterval = 0.20
    /// A held ball leaves the palm when the fingers open by this much from
    /// the tightest they were while holding, or straighten past the floor
    /// (the shot's follow-through), or the palm turns down while the
    /// fingers are not gripping (a ball on an open palm falls off it).
    public static let curlOpenDelta: Float = 0.12
    public static let curlOpenFloor: Float = 0.03
    public static let curlGrip: Float = 0.35
    public static let palmDownNormalY: Float = -0.2
    /// A closing hand catches a ball whose surface is within this of the
    /// palm, in front of it (within `palmCatchCone` of the normal). Wider
    /// than the hand collider's radius, which keeps a free ball's centre at
    /// least that far off the palm.
    public static let palmCatchGap: Float = 0.10
    public static let palmCatchCone: Float = 0.3
    /// A ball held on the palm sits its radius plus this out from the palm.
    public static let palmSeat: Float = 0.01
    /// Two palms hold a ball when both are within this of its surface,
    /// facing it, on opposite sides; a palm is off the ball once farther
    /// than this plus the hysteresis, or turned away; both parting farther
    /// than the release gap lets the ball go.
    public static let twoHandGap: Float = 0.10
    public static let twoHandOffHysteresis: Float = 0.03
    public static let twoHandReleaseGap: Float = 0.16
    /// Cosine of the angle between the two palms' directions from the ball
    /// must be below this for them to count as opposite sides, and each
    /// palm must face the ball by at least the facing value.
    public static let twoHandOpposition: Float = -0.3
    public static let twoHandFacing: Float = 0.3

    /// Whether a hand's curl history says it is closing right now: risen by
    /// `curlCloseDelta` from its lowest reading within the window.
    public static func isClosing(curls: [(curl: Float, time: TimeInterval)], now: TimeInterval) -> Bool {
        let recent = curls.filter { now - $0.time <= curlCloseWindow }
        guard let latest = recent.last, let lowest = recent.map(\.curl).min() else { return false }
        return latest.curl - lowest >= curlCloseDelta
    }

    /// The grab a set of tracked hands makes this frame, if any: the ball
    /// between two palms first, then a pinch, then a hand closing on a ball.
    /// `closing` names the hands whose fingers are curling right now (see
    /// `isClosing`) — a fist arriving at a ball swats it, it does not pick
    /// it up.
    public static func grab(
        hands: [CoolBasketHandSide: CoolBasketHandPose],
        closing: Set<CoolBasketHandSide>,
        balls: [(entity: EntityID, center: SIMD3<Float>)],
        ballRadius: Float
    ) -> (kind: CoolBasketHoldKind, ball: EntityID)? {
        if let left = hands[.left], let right = hands[.right] {
            var best: (entity: EntityID, spread: Float)?
            for ball in balls {
                let toLeft = left.palm - ball.center
                let toRight = right.palm - ball.center
                let reachL = simd_length(toLeft), reachR = simd_length(toRight)
                guard reachL < ballRadius + twoHandGap, reachR < ballRadius + twoHandGap,
                      reachL > 1e-4, reachR > 1e-4,
                      simd_dot(toLeft / reachL, toRight / reachR) < twoHandOpposition,
                      simd_dot(-toLeft / reachL, left.palmNormal) > twoHandFacing,
                      simd_dot(-toRight / reachR, right.palmNormal) > twoHandFacing
                else { continue }
                let spread = reachL + reachR
                if spread < (best?.spread ?? .greatestFiniteMagnitude) { best = (ball.entity, spread) }
            }
            if let best { return (.twoHands, best.entity) }
        }
        for side in CoolBasketHandSide.allCases {
            guard let hand = hands[side], hand.pinchDistance < pinchGrabDistance else { continue }
            if let ball = nearest(balls, to: hand.palm, within: pinchReach) {
                return (.pinch(side), ball)
            }
        }
        for side in CoolBasketHandSide.allCases {
            guard let hand = hands[side], closing.contains(side) else { continue }
            var best: (entity: EntityID, distance: Float)?
            for ball in balls {
                let offset = ball.center - hand.palm
                let distance = simd_length(offset)
                // In front of the palm, its surface within reach of it.
                guard distance > 1e-4, distance < ballRadius + palmCatchGap,
                      simd_dot(offset / distance, hand.palmNormal) > palmCatchCone
                else { continue }
                if distance < (best?.distance ?? .greatestFiniteMagnitude) { best = (ball.entity, distance) }
            }
            if let best { return (.palm(side), best.entity) }
        }
        return nil
    }

    /// What becomes of a two-hand hold this frame: kept, handed over to the
    /// one hand still on the ball (a pick-up with both hands, then a
    /// one-hand shot; a chest pass where one hand comes off first), or
    /// released (both hands parted or off). `ballCenter` is where the ball
    /// was, so the hand that moved off is told from the one that stayed.
    public enum TwoHandOutcome: Equatable {
        case hold
        case handover(CoolBasketHandSide)
        case release
    }

    public static func twoHandOutcome(
        hands: [CoolBasketHandSide: CoolBasketHandPose], ballCenter: SIMD3<Float>, ballRadius: Float
    ) -> TwoHandOutcome {
        guard let left = hands[.left], let right = hands[.right] else { return .hold }
        let leftOn = isOnBall(left, ballCenter: ballCenter, ballRadius: ballRadius)
        let rightOn = isOnBall(right, ballCenter: ballCenter, ballRadius: ballRadius)
        let parted = simd_distance(left.palm, right.palm) > ballRadius * 2 + twoHandReleaseGap
        if leftOn, rightOn, !parted { return .hold }
        if leftOn != rightOn { return .handover(leftOn ? .left : .right) }
        return .release
    }

    /// Whether the other hand has joined a one-hand hold: both palms now on
    /// the ball as a two-hand grab would need.
    public static func rejoinsWithBothHands(
        _ kind: CoolBasketHoldKind, hands: [CoolBasketHandSide: CoolBasketHandPose], ball: EntityID, ballCenter: SIMD3<Float>, ballRadius: Float
    ) -> Bool {
        guard kind != .twoHands else { return false }
        return grab(hands: hands, closing: [], balls: [(ball, ballCenter)], ballRadius: ballRadius)?.kind == .twoHands
    }

    /// A palm still on the ball: close to its surface and facing it.
    public static func isOnBall(_ hand: CoolBasketHandPose, ballCenter: SIMD3<Float>, ballRadius: Float) -> Bool {
        let offset = ballCenter - hand.palm
        let distance = simd_length(offset)
        guard distance > 1e-4, distance < ballRadius + twoHandGap + twoHandOffHysteresis else { return false }
        return simd_dot(offset / distance, hand.palmNormal) > 0
    }

    /// Where the held ball's centre goes for the hands as they are; nil when
    /// a hand the hold needs is not tracked.
    public static func holdPoint(
        _ kind: CoolBasketHoldKind, hands: [CoolBasketHandSide: CoolBasketHandPose], ballRadius: Float
    ) -> SIMD3<Float>? {
        switch kind {
        case let .pinch(side):
            return hands[side]?.pinchPoint
        case let .palm(side):
            guard let hand = hands[side] else { return nil }
            return hand.palm + hand.palmNormal * (ballRadius + palmSeat)
        case .twoHands:
            guard let left = hands[.left], let right = hands[.right] else { return nil }
            return (left.palm + right.palm) * 0.5
        }
    }

    /// Whether the hands, all tracked, have let the ball go. `graspCurl` is
    /// the tightest the palm hold's fingers have been. A two-hand hold is
    /// decided by `twoHandOutcome`; here it only reports the parted case.
    public static func releases(
        _ kind: CoolBasketHoldKind, hands: [CoolBasketHandSide: CoolBasketHandPose], ballRadius: Float, graspCurl: Float = 0
    ) -> Bool {
        switch kind {
        case let .pinch(side):
            guard let hand = hands[side] else { return false }
            return hand.pinchDistance > pinchReleaseDistance
        case let .palm(side):
            guard let hand = hands[side] else { return false }
            return hand.fingerCurl < graspCurl - curlOpenDelta
                || hand.fingerCurl < curlOpenFloor
                || (hand.palmNormal.y < palmDownNormalY && hand.fingerCurl < curlGrip)
        case .twoHands:
            guard let left = hands[.left], let right = hands[.right] else { return false }
            return simd_distance(left.palm, right.palm) > ballRadius * 2 + twoHandReleaseGap
        }
    }

    static func nearest(
        _ balls: [(entity: EntityID, center: SIMD3<Float>)], to point: SIMD3<Float>, within reach: Float
    ) -> EntityID? {
        var best: (entity: EntityID, distance: Float)?
        for ball in balls {
            let distance = simd_length(ball.center - point)
            if distance < reach, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (ball.entity, distance)
            }
        }
        return best?.entity
    }
}

extension CoolBasketHandPose {
    /// The palm's outward normal from the hand's frame: `forward` runs from
    /// the wrist to the knuckles, `across` from the little-finger knuckle to
    /// the index knuckle. The two hands mirror each other.
    public static func palmNormal(forward: SIMD3<Float>, across: SIMD3<Float>, side: CoolBasketHandSide) -> SIMD3<Float> {
        let f = simd_normalize(forward), a = simd_normalize(across)
        let normal = side == .right ? simd_cross(a, f) : simd_cross(f, a)
        let length = simd_length(normal)
        return length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0)
    }

    /// How closed the fingers are, 0 open to 1 closed, from how far each
    /// fingertip is from the wrist relative to its knuckle, whatever the
    /// hand's size: a straight finger reaches about 1.85 knuckle-distances
    /// (0); by 1.05 — a half fist, fingertips level with the knuckles —
    /// the reading saturates at 1 (a tight fist reads lower still).
    public static func fingerCurl(tipDistances: [Float], knuckleDistances: [Float]) -> Float {
        let open: Float = 1.85, closed: Float = 1.05
        var total: Float = 0
        var count = 0
        for (tip, knuckle) in zip(tipDistances, knuckleDistances) where knuckle > 1e-4 {
            let ratio = tip / knuckle
            total += simd_clamp((open - ratio) / (open - closed), 0, 1)
            count += 1
        }
        return count > 0 ? total / Float(count) : 0
    }
}
