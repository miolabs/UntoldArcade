//
//  CoolBasketGrabTests.swift
//  CoolBasketTests
//
//  The three holds — pinch, a hand closing on the ball, two palms — as
//  pure rules over hand poses, plus the palm normal and finger curl read
//  off the hand skeleton.
//

@testable import CoolBasket
import simd
import UntoldEngine
import XCTest

final class CoolBasketGrabTests: XCTestCase {
    private typealias Rules = CoolBasketGrabRules
    private let radius = CoolBasketScene.ballRadius
    private let ball: EntityID = 7

    /// A hand at `palm` with its palm facing `normal`, fingers `curl`
    /// closed, thumb and index `pinch` apart.
    private func hand(palm: SIMD3<Float>, normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0), curl: Float = 0, pinch: Float = 0.08) -> CoolBasketHandPose {
        CoolBasketHandPose(
            isTracked: true, palm: palm,
            thumbTip: palm + SIMD3<Float>(0.05, 0.02, 0), indexTip: palm + SIMD3<Float>(0.05 + pinch, 0.02, 0),
            palmNormal: normal, fingerCurl: curl
        )
    }

    // MARK: Pinch

    func testPinchPicksTheNearestBallWithinReach() {
        let hands: [CoolBasketHandSide: CoolBasketHandPose] = [.right: hand(palm: .zero, pinch: 0.01)]
        let balls: [(entity: EntityID, center: SIMD3<Float>)] = [(1, SIMD3<Float>(0.25, 0, 0)), (2, SIMD3<Float>(0.1, 0.1, 0)), (3, SIMD3<Float>(0.5, 0, 0))]
        let grab = Rules.grab(hands: hands, closing: [], balls: balls, ballRadius: radius)
        XCTAssertEqual(grab?.kind, .pinch(.right))
        XCTAssertEqual(grab?.ball, 2)
        // Too far for a pinch.
        XCTAssertNil(Rules.grab(hands: hands, closing: [], balls: [(3, SIMD3<Float>(0.5, 0, 0))], ballRadius: radius))
        // An open hand pinches nothing.
        XCTAssertNil(Rules.grab(hands: [.right: hand(palm: .zero, pinch: 0.06)], closing: [], balls: balls, ballRadius: radius))
    }

    func testPinchHoldsAtThePinchPointAndReleasesWhenItOpens() {
        let closed = hand(palm: .zero, pinch: 0.01)
        XCTAssertEqual(Rules.holdPoint(.pinch(.left), hands: [.left: closed], ballRadius: radius), closed.pinchPoint)
        XCTAssertNil(Rules.holdPoint(.pinch(.left), hands: [.right: closed], ballRadius: radius), "the holding hand is missing")
        XCTAssertFalse(Rules.releases(.pinch(.left), hands: [.left: closed], ballRadius: radius))
        XCTAssertFalse(Rules.releases(.pinch(.left), hands: [.left: hand(palm: .zero, pinch: 0.035)], ballRadius: radius), "hysteresis")
        XCTAssertTrue(Rules.releases(.pinch(.left), hands: [.left: hand(palm: .zero, pinch: 0.06)], ballRadius: radius))
    }

    func testGuessedFingertipsNeitherPinchNorLetGo() {
        // At the edge of view ARKit extrapolates the tips: the pinch reads
        // anything. No new pinch from that, and a held pinch keeps the ball.
        var guessed = hand(palm: .zero, pinch: 0.01)
        guessed.pinchTracked = false
        let balls: [(entity: EntityID, center: SIMD3<Float>)] = [(ball, SIMD3<Float>(0.1, 0.1, 0))]
        XCTAssertNil(Rules.grab(hands: [.right: guessed], closing: [], balls: balls, ballRadius: radius))
        var openGuess = hand(palm: .zero, pinch: 0.09)
        openGuess.pinchTracked = false
        XCTAssertFalse(Rules.releases(.pinch(.right), hands: [.right: openGuess], ballRadius: radius))
        XCTAssertTrue(Rules.releases(.pinch(.right), hands: [.right: hand(palm: .zero, pinch: 0.09)], ballRadius: radius))
    }

    // MARK: Closing hand

    func testAHandClosingOnTheBallCatchesIt() {
        // The ball resting on the palm: its centre a radius out along the normal.
        let onPalm = SIMD3<Float>(0, radius + 0.02, 0)
        let balls: [(entity: EntityID, center: SIMD3<Float>)] = [(ball, onPalm)]
        let closing = hand(palm: .zero, curl: 0.3)
        let grab = Rules.grab(hands: [.left: closing], closing: [.left], balls: balls, ballRadius: radius)
        XCTAssertEqual(grab?.kind, .palm(.left))
        XCTAssertEqual(grab?.ball, ball)

        // A hand that is not closing — a fist arriving, a still hand — swats
        // or touches, it does not grab.
        XCTAssertNil(Rules.grab(hands: [.left: hand(palm: .zero, curl: 0.9)], closing: [], balls: balls, ballRadius: radius))
        // The ball at the back of the hand is not caught.
        XCTAssertNil(Rules.grab(hands: [.left: closing], closing: [.left], balls: [(ball, -onPalm)], ballRadius: radius))
        // Nor a ball beside the hand, level with the palm.
        XCTAssertNil(Rules.grab(hands: [.left: closing], closing: [.left], balls: [(ball, SIMD3<Float>(radius + 0.05, 0.02, 0))], ballRadius: radius))
        // Out of reach of the palm.
        XCTAssertNil(Rules.grab(hands: [.left: closing], closing: [.left], balls: [(ball, SIMD3<Float>(0, radius + 0.2, 0))], ballRadius: radius))
    }

    func testAHandIsClosingWhenItsCurlHasJustRisen() {
        let now: TimeInterval = 5
        // Cupping a 24 cm ball barely curls the fingers: the rise is small but real.
        let closing: [(curl: Float, time: TimeInterval)] = [(0.02, now - 0.15), (0.06, now - 0.10), (0.10, now - 0.05), (0.14, now)]
        XCTAssertTrue(Rules.isClosing(curls: closing, now: now))
        // A hand that closed a while ago and stays closed is not closing now.
        let stale: [(curl: Float, time: TimeInterval)] = [(0.02, now - 0.6), (0.3, now - 0.5), (0.3, now - 0.1), (0.3, now)]
        XCTAssertFalse(Rules.isClosing(curls: stale, now: now))
        // Opening is not closing; neither is noise.
        let opening: [(curl: Float, time: TimeInterval)] = [(0.4, now - 0.15), (0.3, now - 0.05), (0.2, now)]
        XCTAssertFalse(Rules.isClosing(curls: opening, now: now))
        let noise: [(curl: Float, time: TimeInterval)] = [(0.10, now - 0.1), (0.13, now - 0.05), (0.11, now)]
        XCTAssertFalse(Rules.isClosing(curls: noise, now: now))
        // Fingertip jitter of ±0.05 over the window is not a closing hand.
        var jitter: [(curl: Float, time: TimeInterval)] = []
        for i in 0 ..< 18 {
            jitter.append((0.15 + (i % 2 == 0 ? -0.05 : 0.05), now - 0.2 + TimeInterval(i) * 0.011))
        }
        XCTAssertFalse(Rules.isClosing(curls: jitter, now: now))
        XCTAssertFalse(Rules.isClosing(curls: [], now: now))
    }

    func testAPalmHoldSeatsTheBallOnThePalmAndReleasesWhenTheHandOpens() {
        let normal = simd_normalize(SIMD3<Float>(0, 1, 1))
        let closed = hand(palm: SIMD3<Float>(1, 1, 1), normal: normal, curl: 0.6)
        let point = Rules.holdPoint(.palm(.right), hands: [.right: closed], ballRadius: radius)
        XCTAssertEqual(simd_distance(point!, closed.palm + normal * (radius + Rules.palmSeat)), 0, accuracy: 1e-6)
        // Release is opening from the tightest grasp, not an absolute level.
        XCTAssertFalse(Rules.releases(.palm(.right), hands: [.right: closed], ballRadius: radius, graspCurl: 0.6))
        XCTAssertFalse(Rules.releases(.palm(.right), hands: [.right: hand(palm: .zero, curl: 0.55)], ballRadius: radius, graspCurl: 0.6), "a little give")
        XCTAssertTrue(Rules.releases(.palm(.right), hands: [.right: hand(palm: .zero, curl: 0.45)], ballRadius: radius, graspCurl: 0.6))
        XCTAssertTrue(Rules.releases(.palm(.right), hands: [.right: hand(palm: .zero, curl: 0.05)], ballRadius: radius, graspCurl: 0.2), "a barely curled hold opens too")
        // A hold taken with a flat hand (handed over from two hands) still
        // lets go: fingers straightened past the floor, or the palm turned
        // down without a grip. A gripping hand keeps it even palm-down.
        XCTAssertFalse(Rules.releases(.palm(.right), hands: [.right: hand(palm: .zero, curl: 0.05)], ballRadius: radius, graspCurl: 0.05))
        XCTAssertTrue(Rules.releases(.palm(.right), hands: [.right: hand(palm: .zero, curl: 0.02)], ballRadius: radius, graspCurl: 0.05))
        let palmDown = hand(palm: .zero, normal: SIMD3<Float>(0, -1, 0), curl: 0.1)
        XCTAssertTrue(Rules.releases(.palm(.right), hands: [.right: palmDown], ballRadius: radius, graspCurl: 0.1))
        let gripDown = hand(palm: .zero, normal: SIMD3<Float>(0, -1, 0), curl: 0.5)
        XCTAssertFalse(Rules.releases(.palm(.right), hands: [.right: gripDown], ballRadius: radius, graspCurl: 0.5))
    }

    func testTheOtherHandJoiningAOneHandHoldMakesItTwoHands() {
        let center = SIMD3<Float>(0, 1, 0)
        let holding = hand(palm: center + SIMD3<Float>(-(radius + 0.02), 0, 0), normal: SIMD3<Float>(1, 0, 0), curl: 0.3)
        XCTAssertFalse(Rules.rejoinsWithBothHands(.palm(.left), hands: [.left: holding], ball: ball, ballCenter: center, ballRadius: radius))
        let joining = hand(palm: center + SIMD3<Float>(radius + 0.03, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        XCTAssertTrue(Rules.rejoinsWithBothHands(.palm(.left), hands: [.left: holding, .right: joining], ball: ball, ballCenter: center, ballRadius: radius))
        XCTAssertTrue(Rules.rejoinsWithBothHands(.pinch(.left), hands: [.left: holding, .right: joining], ball: ball, ballCenter: center, ballRadius: radius))
        XCTAssertFalse(Rules.rejoinsWithBothHands(.twoHands, hands: [.left: holding, .right: joining], ball: ball, ballCenter: center, ballRadius: radius))
        // A hand merely near the ball, not facing it, does not join.
        let passing = hand(palm: center + SIMD3<Float>(radius + 0.03, 0, 0), normal: SIMD3<Float>(0, 1, 0))
        XCTAssertFalse(Rules.rejoinsWithBothHands(.palm(.left), hands: [.left: holding, .right: passing], ball: ball, ballCenter: center, ballRadius: radius))
    }

    func testCatchZonesReachPastTheHandCollider() {
        // The hand collider keeps a free ball's centre at least its radius
        // plus the ball's off the palm; a grab must be possible from there.
        XCTAssertGreaterThan(Rules.palmCatchGap, CoolBasketScene.handRadius + 0.02)
        XCTAssertGreaterThan(Rules.twoHandGap, CoolBasketScene.handRadius + 0.02)
    }

    // MARK: Two hands

    func testTheBallBetweenTwoPalmsIsHeldByBoth() {
        let center = SIMD3<Float>(0, 1.2, -0.4)
        let left = hand(palm: center + SIMD3<Float>(-(radius + 0.02), 0, 0), normal: SIMD3<Float>(1, 0, 0))
        let right = hand(palm: center + SIMD3<Float>(radius + 0.02, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        let balls: [(entity: EntityID, center: SIMD3<Float>)] = [(ball, center)]
        let grab = Rules.grab(hands: [.left: left, .right: right], closing: [], balls: balls, ballRadius: radius)
        XCTAssertEqual(grab?.kind, .twoHands)
        XCTAssertEqual(grab?.ball, ball)
        XCTAssertEqual(simd_distance(Rules.holdPoint(.twoHands, hands: [.left: left, .right: right], ballRadius: radius)!, center), 0, accuracy: 1e-6)

        // Two hands beats a pinch by one of them on the same ball.
        let pinching = hand(palm: left.palm, normal: left.palmNormal, pinch: 0.01)
        XCTAssertEqual(Rules.grab(hands: [.left: pinching, .right: right], closing: [], balls: balls, ballRadius: radius)?.kind, .twoHands)

        // Both palms on the same side of the ball are not holding it.
        let alsoLeft = hand(palm: center + SIMD3<Float>(-(radius + 0.02), 0.05, 0), normal: SIMD3<Float>(1, 0, 0))
        XCTAssertNil(Rules.grab(hands: [.left: left, .right: alsoLeft], closing: [], balls: balls, ballRadius: radius))
        // One palm too far from the ball.
        let far = hand(palm: center + SIMD3<Float>(radius + 0.2, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        XCTAssertNil(Rules.grab(hands: [.left: left, .right: far], closing: [], balls: balls, ballRadius: radius))
        // A palm turned away from the ball (the back of the hand on it) is not holding.
        let backhand = hand(palm: right.palm, normal: SIMD3<Float>(1, 0, 0))
        XCTAssertNil(Rules.grab(hands: [.left: left, .right: backhand], closing: [], balls: balls, ballRadius: radius))
    }

    func testTwoHandsHoldPartOrHandOverToTheHandStillOnTheBall() {
        let center = SIMD3<Float>.zero
        let left = hand(palm: center + SIMD3<Float>(-(radius + 0.02), 0, 0), normal: SIMD3<Float>(1, 0, 0))
        let right = hand(palm: center + SIMD3<Float>(radius + 0.02, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: left, .right: right], ballCenter: center, ballRadius: radius), .hold)
        // A little give while carrying.
        let give = hand(palm: center + SIMD3<Float>(radius + 0.05, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: left, .right: give], ballCenter: center, ballRadius: radius), .hold)
        // The right hand comes off: the left keeps the ball on its palm.
        let off = hand(palm: center + SIMD3<Float>(radius + 0.15, 0, 0), normal: SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: left, .right: off], ballCenter: center, ballRadius: radius), .handover(.left))
        // The right hand turns away (a push-off) while still close: the same.
        let turned = hand(palm: right.palm, normal: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: left, .right: turned], ballCenter: center, ballRadius: radius), .handover(.left))
        // Both part: a pass.
        let leftOff = hand(palm: center + SIMD3<Float>(-(radius + 0.15), 0, 0), normal: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: leftOff, .right: off], ballCenter: center, ballRadius: radius), .release)
        XCTAssertTrue(Rules.releases(.twoHands, hands: [.left: leftOff, .right: off], ballRadius: radius))
        XCTAssertFalse(Rules.releases(.twoHands, hands: [.left: left, .right: give], ballRadius: radius))
        // A missing hand is neither.
        XCTAssertEqual(Rules.twoHandOutcome(hands: [.left: left], ballCenter: center, ballRadius: radius), .hold)
        XCTAssertNil(Rules.holdPoint(.twoHands, hands: [.left: left], ballRadius: radius), "needs both hands")
        XCTAssertFalse(Rules.releases(.twoHands, hands: [.left: left], ballRadius: radius), "a missing hand is not a release")
        XCTAssertTrue(Rules.isOnBall(left, ballCenter: center, ballRadius: radius))
        XCTAssertFalse(Rules.isOnBall(off, ballCenter: center, ballRadius: radius))
        XCTAssertFalse(Rules.isOnBall(turned, ballCenter: center, ballRadius: radius))
    }

    // MARK: Skeleton readings

    func testPalmNormalPointsOutOfEitherPalm() {
        // A right hand held up in front of you, palm toward your face (+z
        // toward the head): fingers up, the index knuckle to your right.
        let forward = SIMD3<Float>(0, 1, 0)
        let acrossRight = SIMD3<Float>(1, 0, 0)
        let right = CoolBasketHandPose.palmNormal(forward: forward, across: acrossRight, side: .right)
        XCTAssertEqual(simd_dot(right, SIMD3<Float>(0, 0, 1)), 1, accuracy: 1e-5)
        // The left hand mirrored: index knuckle to your left, palm still toward you.
        let left = CoolBasketHandPose.palmNormal(forward: forward, across: -acrossRight, side: .left)
        XCTAssertEqual(simd_dot(left, SIMD3<Float>(0, 0, 1)), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(CoolBasketHandPose.palmNormal(forward: forward, across: SIMD3<Float>(3, 0, 0), side: .right)), 1, accuracy: 1e-5, "unit length")
    }

    func testFingerCurlReadsOpenCuppedAndFist() {
        let knuckles: [Float] = [0.09, 0.095, 0.09, 0.085]
        let straight = knuckles.map { $0 * 1.9 }
        XCTAssertEqual(CoolBasketHandPose.fingerCurl(tipDistances: straight, knuckleDistances: knuckles), 0, accuracy: 1e-6)
        let fist = knuckles.map { $0 * 1.0 }
        XCTAssertEqual(CoolBasketHandPose.fingerCurl(tipDistances: fist, knuckleDistances: knuckles), 1, accuracy: 1e-6)
        let cupped = knuckles.map { $0 * 1.45 }
        let curl = CoolBasketHandPose.fingerCurl(tipDistances: cupped, knuckleDistances: knuckles)
        XCTAssertEqual(curl, 0.5, accuracy: 1e-5, "half-way between straight and closed")
        XCTAssertEqual(CoolBasketHandPose.fingerCurl(tipDistances: [], knuckleDistances: []), 0)
    }
}
