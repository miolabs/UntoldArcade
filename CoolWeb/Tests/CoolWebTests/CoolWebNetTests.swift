@testable import CoolWeb
import simd
import XCTest

/// Stubbed room: an infinite wall at z = -2 facing the shooter.
private func wallQuery(
    _ origin: SIMD3<Float>,
    _ direction: SIMD3<Float>,
    _ maxDistance: Float
) -> CoolWebSurfaceHit? {
    guard direction.z < -1e-4 else { return nil }
    let t = (-2 - origin.z) / direction.z
    guard t > 0, t < maxDistance else { return nil }
    return CoolWebSurfaceHit(
        position: origin + direction * t,
        normal: SIMD3<Float>(0, 0, 1),
        distance: t
    )
}

final class CoolWebNetTests: XCTestCase {
    private let handOrigin = SIMD3<Float>(0, 1.5, 0)

    private func makeShooter(miss: Bool = false) -> CoolWebShooter {
        if miss {
            return CoolWebShooter(surfaceQuery: { _, _, _ in nil })
        }
        return CoolWebShooter(surfaceQuery: { origin, direction, maxDistance in
            wallQuery(origin, direction, maxDistance)
        })
    }

    @discardableResult
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

    /// Moves the hand smoothly between two points (a teleported pin reads as
    /// a tracking glitch, not a pull).
    @discardableResult
    private func runMovingHand(
        _ shooter: CoolWebShooter,
        from start: TimeInterval,
        seconds: Double,
        handFrom: SIMD3<Float>,
        handTo: SIMD3<Float>,
        fps: Double = 90
    ) -> TimeInterval {
        var now = start
        let dt = 1 / fps
        let steps = Int(seconds * fps)
        for step in 0 ..< steps {
            now += dt
            let t = Float(step + 1) / Float(steps)
            shooter.updateHand(
                .right,
                position: simd_mix(handFrom, handTo, SIMD3<Float>(repeating: t))
            )
            shooter.step(now: now, dt: Float(dt))
        }
        return now
    }

    func testCollisionSpheresKeepTheStrandOutOfTheFist() {
        let shooter = makeShooter()
        let net = shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 11
        )
        run(shooter, from: 0, seconds: 1, hand: handOrigin)
        XCTAssertEqual(net?.phase, .attached)

        // A "fist" sphere sits right on the strand's path in front of the
        // hand. With the collider fed every frame, the settled rope must not
        // leave any free segment endpoint meaningfully inside it.
        let fist = CoolWebCollisionSphere(
            center: handOrigin + SIMD3<Float>(0, 0, -0.15), radius: 0.05
        )
        var now: TimeInterval = 1
        let dt: Float = 1 / 90
        for _ in 0 ..< 90 {
            now += Double(dt)
            shooter.updateHand(.right, position: handOrigin, collision: [fist])
            shooter.step(now: now, dt: dt)
        }
        var segments: [CoolWebSegmentDesc] = []
        net?.appendSegments(into: &segments)
        XCTAssertFalse(segments.isEmpty)
        // The pinned root may sit wherever the hand is; everything else must
        // have been pushed out to (near) the sphere surface.
        let tolerance: Float = 0.005
        for segment in segments {
            for point in [segment.a, segment.b]
            where simd_length(point - handOrigin) > 1e-4 {
                XCTAssertGreaterThan(
                    simd_length(point - fist.center),
                    fist.radius - tolerance
                )
            }
        }
    }

    func testFireFliesAndAttachesTheWholeCone() throws {
        setCoolWebSplatsEnabled(true)
        defer { setCoolWebSplatsEnabled(false) }
        let shooter = makeShooter()
        let net = shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        )
        XCTAssertNotNil(net)
        XCTAssertEqual(net?.phase, .flying)
        XCTAssertNotNil(net?.centerHit)

        run(shooter, from: 0, seconds: 1, hand: handOrigin)
        XCTAssertEqual(net?.phase, .attached)

        let scene = CoolWebSceneState.shared.state()
        let params = CoolWebNetParams()
        let structuralSegments = (params.leaderParticles - 1)
            + params.branchCount * params.branchParticles
        XCTAssertGreaterThan(
            scene.segments.count, structuralSegments,
            "attached web should draw leader + net segments PLUS wall residue"
        )
        XCTAssertEqual(scene.splats.count, 1)
        shooter.reset()
    }

    func testAttachedThreadsSagBelowTheStraightLine() throws {
        let shooter = makeShooter()
        let net = try XCTUnwrap(shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        ))
        run(shooter, from: 0, seconds: 3, hand: handOrigin)
        XCTAssertEqual(net.phase, .attached)

        // The slack leader line must dip below the straight line from hand to
        // wall hit (both at y = 1.5). Look only away from the wall (z > -1.6)
        // so wall residue and net threads can't satisfy the check for free.
        var segments: [CoolWebSegmentDesc] = []
        net.appendSegments(into: &segments)
        let leaderMinY = segments
            .filter { min($0.a.z, $0.b.z) > -1.6 }
            .map { min($0.a.y, $0.b.y) }
            .min() ?? 1.5
        XCTAssertLessThan(leaderMinY, 1.47, "slack leader should sag below its endpoints")
        shooter.reset()
    }

    func testPullingFarTearsThreads() throws {
        let shooter = makeShooter()
        let net = try XCTUnwrap(shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        ))
        var now = run(shooter, from: 0, seconds: 1, hand: handOrigin)
        XCTAssertEqual(net.phase, .attached)
        XCTAssertEqual(net.tornCount, 0)

        // Walk the hand far past the tear stretch: attach distance ~2 m,
        // rest ~2.1 m, so a hand 6 m from the wall forces stretch > 1.5.
        now = runMovingHand(
            shooter,
            from: now,
            seconds: 2,
            handFrom: handOrigin,
            handTo: SIMD3<Float>(0, 1.5, 4)
        )
        XCTAssertGreaterThan(net.tornCount, 0, "overstretched threads must snap")
        shooter.reset()
    }

    func testTensionIsReportedBeforeTearing() throws {
        let shooter = makeShooter()
        let net = try XCTUnwrap(shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        ))
        var now = run(shooter, from: 0, seconds: 1, hand: handOrigin)
        XCTAssertEqual(net.phase, .attached)

        // Pull to just under tearing: rest ≈ 2.1 m end to end, hand at 0.6 m
        // behind the fire point ≈ 2.6 m — stretch ≈ 1.24 < 1.5.
        now = runMovingHand(
            shooter,
            from: now,
            seconds: 1.5,
            handFrom: handOrigin,
            handTo: SIMD3<Float>(0, 1.5, 0.6)
        )
        now = run(shooter, from: now, seconds: 0.5, hand: SIMD3<Float>(0, 1.5, 0.6))
        var segments: [CoolWebSegmentDesc] = []
        net.appendSegments(into: &segments)
        let maxTension = segments.map(\.tension).max() ?? 0
        XCTAssertGreaterThan(maxTension, 0.2, "taut threads should report tension")
        XCTAssertEqual(net.tornThreadCount, 0, "threads must not tear below the threshold")
        shooter.reset()
    }

    func testMissDissolvesAndFreesTheSlot() {
        let shooter = makeShooter(miss: true)
        let net = shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        )
        XCTAssertNotNil(net)
        run(shooter, from: 0, seconds: 2)
        XCTAssertEqual(shooter.liveNetCount, 0, "missed web should dissolve away")
        XCTAssertTrue(CoolWebSceneState.shared.state().segments.isEmpty)
        shooter.reset()
    }

    func testReleaseDanglesThenDissolves() throws {
        // Short lifecycle so the test doesn't track the cosmetic defaults.
        var params = CoolWebNetParams()
        params.danglingDuration = 1
        params.dissolveDuration = 0.3
        let shooter = makeShooter()
        shooter.params = params
        let net = try XCTUnwrap(shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        ))
        let now = run(shooter, from: 0, seconds: 1, hand: handOrigin)
        XCTAssertEqual(net.phase, .attached)

        shooter.release(hand: .right, now: now)
        XCTAssertEqual(net.phase, .dangling)

        run(shooter, from: now, seconds: 5)
        XCTAssertEqual(shooter.liveNetCount, 0, "released web should dissolve")
        shooter.reset()
    }

    func testRefireReleasesThePreviousNetAndStaysInBudget() {
        let shooter = makeShooter()
        var now: TimeInterval = 0
        for round in 0 ..< 8 {
            shooter.fire(
                hand: .right,
                origin: handOrigin,
                direction: SIMD3<Float>(0, 0, -1),
                now: now,
                randomSeed: UInt64(round + 1)
            )
            now = run(shooter, from: now, seconds: 0.3, hand: handOrigin)
        }
        XCTAssertLessThanOrEqual(shooter.liveNetCount, CoolWebShooter.maxLiveNets)
        XCTAssertEqual(
            shooter.heldNet(for: .right)?.isHeld, true,
            "the newest net stays held"
        )
        // The published scene stays inside the renderer's segment budget.
        XCTAssertLessThanOrEqual(
            CoolWebSceneState.shared.state().segments.count,
            CoolWebShaderLimits.maxSegments
        )
        shooter.reset()
    }

    func testOnAttachFiresOncePerNet() {
        let shooter = makeShooter()
        nonisolated(unsafe) var attachCount = 0
        shooter.onAttach = { _, hit in
            attachCount += 1
            XCTAssertEqual(hit.normal, SIMD3<Float>(0, 0, 1))
        }
        shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        )
        run(shooter, from: 0, seconds: 2, hand: handOrigin)
        XCTAssertEqual(attachCount, 1)
        shooter.reset()
    }

    func testStepToleratesHugeAndZeroTimesteps() throws {
        let shooter = makeShooter()
        let net = try XCTUnwrap(shooter.fire(
            hand: .right,
            origin: handOrigin,
            direction: SIMD3<Float>(0, 0, -1),
            now: 0,
            randomSeed: 7
        ))
        shooter.step(now: 0.0001, dt: 0)
        shooter.step(now: 10, dt: 10) // clamped internally
        var segments: [CoolWebSegmentDesc] = []
        net.appendSegments(into: &segments)
        for segment in segments {
            XCTAssertTrue(simd_length_squared(segment.a).isFinite)
            XCTAssertTrue(simd_length_squared(segment.b).isFinite)
        }
        shooter.reset()
    }
}
