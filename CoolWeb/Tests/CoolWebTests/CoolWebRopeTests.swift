@testable import CoolWeb
import simd
import XCTest

final class CoolWebRopeTests: XCTestCase {
    private func settle(_ rope: CoolWebRope, seconds: Float = 3, fps: Float = 90) {
        let dt = 1 / fps
        for _ in 0 ..< Int(seconds * fps) {
            rope.step(dt: dt)
        }
    }

    func testSlackRopeSagsBelowItsEndpoints() {
        let rope = CoolWebRope(origin: .zero)
        let root = SIMD3<Float>(0, 1.5, 0)
        let tip = SIMD3<Float>(1, 1.5, 0)
        rope.layoutStraight(from: root, to: tip)
        rope.rootPin = root
        rope.tipPin = tip
        // 30% more rope than the straight-line distance.
        rope.segmentRestLength = 1.3 / Float(rope.particleCount - 1)
        settle(rope)

        let midY = rope.positions[rope.particleCount / 2].y
        XCTAssertLessThan(midY, 1.45, "slack rope should sag below its endpoints")
        XCTAssertEqual(rope.positions[0], root)
        XCTAssertEqual(rope.positions[rope.particleCount - 1], tip)
    }

    func testTautRopeStaysNearlyStraight() {
        let rope = CoolWebRope(origin: .zero)
        let root = SIMD3<Float>(0, 1.5, 0)
        let tip = SIMD3<Float>(2, 1.5, 0)
        rope.layoutStraight(from: root, to: tip)
        rope.rootPin = root
        rope.tipPin = tip
        // Pins are 2 m apart but the rope only has 1.6 m of rest length: taut.
        rope.segmentRestLength = 1.6 / Float(rope.particleCount - 1)
        settle(rope)

        var maxDeviation: Float = 0
        for position in rope.positions {
            maxDeviation = max(maxDeviation, abs(position.y - 1.5))
        }
        XCTAssertLessThan(
            maxDeviation, 0.05,
            "overstretched rope should pull nearly straight between its pins"
        )
    }

    func testFreeEndFallsUnderGravity() {
        let rope = CoolWebRope(origin: .zero)
        let root = SIMD3<Float>(0, 2, 0)
        let tip = SIMD3<Float>(1, 2, 0)
        rope.layoutStraight(from: root, to: tip)
        rope.rootPin = root
        rope.tipPin = nil
        rope.segmentRestLength = 1.0 / Float(rope.particleCount - 1)
        settle(rope, seconds: 5)

        let end = rope.positions[rope.particleCount - 1]
        XCTAssertEqual(rope.positions[0], root)
        XCTAssertLessThan(end.y, 1.2, "free end should hang below the pinned root")
        // Hanging rope stays close to rest length (not stretched by gravity).
        var length: Float = 0
        for i in 1 ..< rope.particleCount {
            length += simd_length(rope.positions[i] - rope.positions[i - 1])
        }
        XCTAssertEqual(length, 1.0, accuracy: 0.15)
    }

    func testStepToleratesHugeAndZeroTimesteps() {
        let rope = CoolWebRope(origin: SIMD3<Float>(0, 1, 0))
        rope.rootPin = SIMD3<Float>(0, 1, 0)
        rope.segmentRestLength = 0.01
        rope.step(dt: 0)
        rope.step(dt: 10) // clamped internally
        for position in rope.positions {
            XCTAssertTrue(simd_length_squared(position).isFinite)
        }
    }
}

final class CoolWebShooterTests: XCTestCase {
    private let wallHit = CoolWebSurfaceHit(
        position: SIMD3<Float>(0, 1.5, -2),
        normal: SIMD3<Float>(0, 0, 1),
        distance: 2
    )

    private func makeShooter(hit: CoolWebSurfaceHit?) -> CoolWebShooter {
        CoolWebShooter(surfaceQuery: { _, _, _ in hit })
    }

    private func run(
        _ shooter: CoolWebShooter,
        from start: TimeInterval,
        seconds: Double,
        fps: Double = 90,
        hand: SIMD3<Float>? = nil
    ) -> TimeInterval {
        var now = start
        let dt = 1 / fps
        for _ in 0 ..< Int(seconds * fps) {
            now += dt
            if let hand {
                shooter.updateHand(.right, position: hand)
            }
            shooter.step(now: now, dt: Float(dt))
        }
        return now
    }

    func testFireFliesAndAttachesToTheSurfaceHit() {
        let shooter = makeShooter(hit: wallHit)
        let origin = SIMD3<Float>(0, 1.5, 0)
        let strand = shooter.fire(
            hand: .right,
            origin: origin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0
        )
        XCTAssertNotNil(strand)
        XCTAssertEqual(strand?.phase, .flying)

        _ = run(shooter, from: 0, seconds: 1, hand: origin)
        XCTAssertEqual(strand?.phase, .attached)

        // The published scene has the strand and its impact splat.
        let scene = CoolWebSceneState.shared.state()
        XCTAssertEqual(scene.strands.count, 1)
        XCTAssertEqual(scene.splats.count, 1)
        XCTAssertEqual(scene.splats[0].center, wallHit.position)
        shooter.reset()
    }

    func testAttachedStrandTipStaysOnTheWallWhileHandMoves() throws {
        let shooter = makeShooter(hit: wallHit)
        let strand = shooter.fire(
            hand: .right,
            origin: SIMD3<Float>(0, 1.5, 0),
            direction: SIMD3<Float>(0, 0, -1),
            now: 0
        )
        var now = run(shooter, from: 0, seconds: 1, hand: SIMD3<Float>(0, 1.5, 0))
        XCTAssertEqual(strand?.phase, .attached)

        now = run(shooter, from: now, seconds: 1, hand: SIMD3<Float>(0.5, 1.2, 0.3))
        let scene = CoolWebSceneState.shared.state()
        let particles = try XCTUnwrap(scene.strands.first?.particles)
        XCTAssertEqual(particles.last!, wallHit.position)
        XCTAssertEqual(particles.first!, SIMD3<Float>(0.5, 1.2, 0.3))
        shooter.reset()
    }

    func testMissDissolvesAndFreesTheSlot() {
        let shooter = makeShooter(hit: nil)
        let strand = shooter.fire(
            hand: .right,
            origin: SIMD3<Float>(0, 1.5, 0),
            direction: SIMD3<Float>(0, 0, -1),
            now: 0
        )
        XCTAssertNotNil(strand)
        _ = run(shooter, from: 0, seconds: 2)
        XCTAssertEqual(shooter.liveStrandCount, 0, "missed web should dissolve away")
        XCTAssertTrue(CoolWebSceneState.shared.state().strands.isEmpty)
        shooter.reset()
    }

    func testReleaseDanglesThenDissolves() {
        let shooter = makeShooter(hit: wallHit)
        let strand = shooter.fire(
            hand: .right,
            origin: SIMD3<Float>(0, 1.5, 0),
            direction: SIMD3<Float>(0, 0, -1),
            now: 0
        )
        var now = run(shooter, from: 0, seconds: 1, hand: SIMD3<Float>(0, 1.5, 0))
        XCTAssertEqual(strand?.phase, .attached)

        shooter.release(hand: .right, now: now)
        XCTAssertEqual(strand?.phase, .dangling)

        now = run(shooter, from: now, seconds: 5)
        XCTAssertEqual(shooter.liveStrandCount, 0, "released web should dissolve")
        shooter.reset()
    }

    func testRefireReleasesThePreviousStrandAndStaysInBudget() {
        let shooter = makeShooter(hit: wallHit)
        var now: TimeInterval = 0
        for _ in 0 ..< 8 {
            shooter.fire(
                hand: .right,
                origin: SIMD3<Float>(0, 1.5, 0),
                direction: SIMD3<Float>(0, 0, -1),
                now: now
            )
            now = run(shooter, from: now, seconds: 0.3, hand: SIMD3<Float>(0, 1.5, 0))
        }
        XCTAssertLessThanOrEqual(shooter.liveStrandCount, CoolWebShaderLimits.maxStrands)
        XCTAssertEqual(
            shooter.heldStrand(for: .right)?.isHeld, true,
            "the newest strand stays held"
        )
        shooter.reset()
    }

    func testOnAttachFiresOncePerAttachment() {
        let shooter = makeShooter(hit: wallHit)
        nonisolated(unsafe) var attachCount = 0
        shooter.onAttach = { _, hit in
            attachCount += 1
            XCTAssertEqual(hit.position, SIMD3<Float>(0, 1.5, -2))
        }
        shooter.fire(
            hand: .right,
            origin: SIMD3<Float>(0, 1.5, 0),
            direction: SIMD3<Float>(0, 0, -1),
            now: 0
        )
        _ = run(shooter, from: 0, seconds: 2, hand: SIMD3<Float>(0, 1.5, 0))
        XCTAssertEqual(attachCount, 1)
        shooter.reset()
    }
}
