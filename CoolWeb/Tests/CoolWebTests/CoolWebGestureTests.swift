@testable import CoolWeb
import simd
import XCTest

final class CoolWebGestureTests: XCTestCase {
    // MARK: - Synthetic hands

    /// Builds a 5-point finger chain with a controlled extension ratio:
    /// straight fingers march along the finger axis, curled fingers fold back
    /// on themselves so the end-to-end distance collapses.
    private func makeFinger(
        base: SIMD3<Float>,
        axis: SIMD3<Float>,
        extended: Bool
    ) -> CoolWebFingerChain {
        let dir = simd_normalize(axis)
        let down = SIMD3<Float>(0, -1, 0)
        if extended {
            return CoolWebFingerChain(points: [
                base,
                base + dir * 0.030,
                base + dir * 0.055,
                base + dir * 0.075,
                base + dir * 0.090,
            ])
        }
        // Folded: out along the axis, then back toward the palm.
        return CoolWebFingerChain(points: [
            base,
            base + dir * 0.030,
            base + dir * 0.040 + down * 0.015,
            base + dir * 0.020 + down * 0.025,
            base + dir * 0.002 + down * 0.020,
        ])
    }

    /// Hand at the origin, fingers pointing -Z (the aim direction).
    private func makePose(
        thumb: Bool,
        index: Bool,
        middle: Bool,
        ring: Bool,
        little: Bool,
        isTracked: Bool = true
    ) -> CoolWebHandPose {
        let wrist = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        func fingerBase(_ x: Float) -> SIMD3<Float> {
            wrist + forward * 0.06 + SIMD3<Float>(x, 0, 0)
        }
        return CoolWebHandPose(
            isTracked: isTracked,
            wrist: wrist,
            thumb: makeFinger(
                base: wrist,
                axis: simd_normalize(SIMD3<Float>(1, 0, -0.6)),
                extended: thumb
            ),
            index: makeFinger(base: fingerBase(0.030), axis: forward, extended: index),
            middle: makeFinger(base: fingerBase(0.010), axis: forward, extended: middle),
            ring: makeFinger(base: fingerBase(-0.010), axis: forward, extended: ring),
            little: makeFinger(base: fingerBase(-0.030), axis: forward, extended: little)
        )
    }

    private var webShooterPose: CoolWebHandPose {
        makePose(thumb: true, index: true, middle: false, ring: false, little: true)
    }

    private var openHand: CoolWebHandPose {
        makePose(thumb: true, index: true, middle: true, ring: true, little: true)
    }

    private var fist: CoolWebHandPose {
        makePose(thumb: false, index: false, middle: false, ring: false, little: false)
    }

    // MARK: - Extension metric

    func testExtensionRatioSeparatesStraightFromCurled() {
        let straight = makeFinger(base: .zero, axis: SIMD3<Float>(0, 0, -1), extended: true)
        let curled = makeFinger(base: .zero, axis: SIMD3<Float>(0, 0, -1), extended: false)
        XCTAssertGreaterThan(straight.extensionRatio, 0.95)
        XCTAssertLessThan(curled.extensionRatio, 0.5)
    }

    // MARK: - Classifier

    func testWebShooterPoseFiresOnceAfterOnsetFrames() {
        let classifier = CoolWebGestureClassifier()
        var events: [CoolWebGestureEvent] = []
        for _ in 0 ..< 10 {
            if let event = classifier.update(pose: webShooterPose) {
                events.append(event)
            }
        }
        XCTAssertEqual(events.count, 1, "pose held should fire exactly once")
        guard case let .webShooterFired(origin, direction) = events[0] else {
            return XCTFail("expected webShooterFired, got \(events[0])")
        }
        XCTAssertEqual(origin, SIMD3<Float>(0, 1, 0))
        // Fingers point -Z, so the aim must too.
        XCTAssertLessThan(direction.z, -0.8)
        XCTAssertEqual(simd_length(direction), 1, accuracy: 1e-4)
    }

    func testOpenHandAndPartialPosesDoNotFire() {
        let classifier = CoolWebGestureClassifier()
        let almost = makePose(thumb: true, index: true, middle: true, ring: false, little: true)
        for _ in 0 ..< 20 {
            XCTAssertNil(classifier.update(pose: openHand))
            XCTAssertNil(classifier.update(pose: almost))
        }
    }

    func testFlickeringPoseNeverReachesOnset() {
        let classifier = CoolWebGestureClassifier()
        for _ in 0 ..< 10 {
            XCTAssertNil(classifier.update(pose: webShooterPose))
            XCTAssertNil(classifier.update(pose: webShooterPose))
            XCTAssertNil(classifier.update(pose: openHand)) // resets the count
        }
    }

    func testReleasingThePoseReArmsTheShooter() {
        let classifier = CoolWebGestureClassifier()
        var fires = 0
        for _ in 0 ..< 10 where classifier.update(pose: webShooterPose) != nil {
            fires += 1
        }
        // Leave the pose long enough to re-arm, then strike it again.
        for _ in 0 ..< 10 {
            _ = classifier.update(pose: openHand)
        }
        for _ in 0 ..< 10 where classifier.update(pose: webShooterPose) != nil {
            fires += 1
        }
        XCTAssertEqual(fires, 2)
    }

    func testFistFiresOnceAndOverridesThePose() {
        let classifier = CoolWebGestureClassifier()
        var events: [CoolWebGestureEvent] = []
        for _ in 0 ..< 10 {
            if let event = classifier.update(pose: fist) {
                events.append(event)
            }
        }
        XCTAssertEqual(events, [.fistClenched])
    }

    func testTrackingLossResetsTheClassifier() {
        let classifier = CoolWebGestureClassifier()
        _ = classifier.update(pose: webShooterPose)
        _ = classifier.update(pose: webShooterPose)
        let lost = makePose(
            thumb: true, index: true, middle: false, ring: false, little: true,
            isTracked: false
        )
        XCTAssertNil(classifier.update(pose: lost))
        // Two more in-pose frames are NOT enough after the reset...
        XCTAssertNil(classifier.update(pose: webShooterPose))
        XCTAssertNil(classifier.update(pose: webShooterPose))
        // ...the third is.
        XCTAssertNotNil(classifier.update(pose: webShooterPose))
    }
}

final class CoolWebSurfaceRaycastTests: XCTestCase {
    private func makeStore(withWallAtZ z: Float) -> CoolWebSurfaceStore {
        let store = CoolWebSurfaceStore()
        // Two triangles forming a 4×4 m wall in the XY plane at the given z.
        store.update(
            id: UUID(),
            worldVertices: [
                SIMD3<Float>(-2, -2, z),
                SIMD3<Float>(2, -2, z),
                SIMD3<Float>(2, 2, z),
                SIMD3<Float>(-2, 2, z),
            ],
            indices: [0, 1, 2, 0, 2, 3]
        )
        return store
    }

    func testRayHitsWallWithShooterFacingNormal() throws {
        let store = makeStore(withWallAtZ: -2)
        let hit = try XCTUnwrap(store.raycast(
            origin: SIMD3<Float>(0, 0.5, 0),
            direction: SIMD3<Float>(0, 0, -1)
        ))
        XCTAssertEqual(hit.distance, 2, accuracy: 1e-4)
        XCTAssertEqual(hit.position.z, -2, accuracy: 1e-4)
        // Normal must face back toward the shooter regardless of winding.
        XCTAssertGreaterThan(hit.normal.z, 0.99)
    }

    func testRayAwayFromWallMisses() {
        let store = makeStore(withWallAtZ: -2)
        XCTAssertNil(store.raycast(
            origin: SIMD3<Float>(0, 0.5, 0),
            direction: SIMD3<Float>(0, 0, 1)
        ))
    }

    func testNearestSurfaceWins() throws {
        let store = makeStore(withWallAtZ: -2)
        store.update(
            id: UUID(),
            worldVertices: [
                SIMD3<Float>(-2, -2, -1),
                SIMD3<Float>(2, -2, -1),
                SIMD3<Float>(2, 2, -1),
            ],
            indices: [0, 1, 2]
        )
        let hit = try XCTUnwrap(store.raycast(
            origin: SIMD3<Float>(0, 0, 0),
            direction: SIMD3<Float>(0, 0, -1)
        ))
        XCTAssertEqual(hit.distance, 1, accuracy: 1e-4)
    }

    func testMaxDistanceIsRespected() {
        let store = makeStore(withWallAtZ: -5)
        XCTAssertNil(store.raycast(
            origin: SIMD3<Float>(0, 0, 0),
            direction: SIMD3<Float>(0, 0, -1),
            maxDistance: 3
        ))
    }
}
