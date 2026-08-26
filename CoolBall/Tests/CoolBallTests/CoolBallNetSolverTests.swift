//
//  CoolBallNetSolverTests.swift
//  CoolBallTests
//

@testable import CoolBall
import simd
import UntoldEngine
import XCTest

final class CoolBallNetSolverTests: XCTestCase {
    private func makeSolver() -> CoolBallNetSolver {
        CoolBallNetSolver(
            columns: 25,
            rows: 17,
            topLeft: SIMD3<Float>(-0.8, 1.0, 0.0),
            topRight: SIMD3<Float>(0.8, 1.0, 0.0),
            bottomOffset: SIMD3<Float>(0.0, -1.0, -0.45),
            floorY: 0.0
        )
    }

    private func advance(
        _ solver: CoolBallNetSolver,
        seconds: Float,
        ball: SIMD3<Float>? = nil
    ) {
        let step: Float = 1.0 / 60.0
        var elapsed: Float = 0
        while elapsed < seconds {
            solver.step(deltaTime: step, sphereCenter: ball, sphereRadius: 0.11)
            elapsed += step
        }
    }

    func testPinnedRowsStayPut() {
        let solver = makeSolver()
        let topBefore = solver.positions[solver.index(0, 0)]
        let bottomBefore = solver.positions[solver.index(12, 16)]

        advance(solver, seconds: 2.0)

        XCTAssertEqual(solver.positions[solver.index(0, 0)], topBefore)
        XCTAssertEqual(solver.positions[solver.index(12, 16)], bottomBefore)
    }

    func testDrapeSettlesWithoutExploding() {
        let solver = makeSolver()
        advance(solver, seconds: 3.0)

        for (i, position) in solver.positions.enumerated() {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite,
                          "particle \(i) must stay finite")
            XCTAssertGreaterThanOrEqual(position.y, -1e-3, "cloth must stay above the floor")
            XCTAssertLessThanOrEqual(position.y, 1.05, "cloth cannot rise above the crossbar")
        }

        // Interior sags behind the goal plane (toward the stakes), never in
        // front of the crossbar line.
        let middle = solver.positions[solver.index(12, 8)]
        XCTAssertLessThanOrEqual(middle.z, 1e-3)
    }

    func testBallPushDeformsAndReleaseRecovers() {
        let solver = makeSolver()
        advance(solver, seconds: 2.0)
        let restMiddle = solver.positions[solver.index(12, 8)]

        // Ball pressed into the middle of the net from the front.
        let ballCenter = restMiddle + SIMD3<Float>(0, 0, 0.02)
        advance(solver, seconds: 1.0, ball: ballCenter)
        let pressed = solver.positions[solver.index(12, 8)]
        XCTAssertGreaterThan(
            simd_length(pressed - ballCenter), 0.11,
            "particles must be pushed outside the ball"
        )
        XCTAssertLessThan(pressed.z, restMiddle.z + 1e-3, "net bulges away from the ball")

        // Ball removed: the net swings back near its rest drape.
        advance(solver, seconds: 3.0)
        let recovered = solver.positions[solver.index(12, 8)]
        XCTAssertEqual(recovered.z, restMiddle.z, accuracy: 0.05)
    }

    func testBallSettlesIntoNetPocket() {
        // Regression: a goal must end with the ball caught — hammocked in the
        // pocket between the slanted net and the ground skirt, at rest, not
        // rolled out the open back (it escaped to z=-6.3 before the skirt).
        let backend = CoolBallPhysicsBackend()
        backend.configure(PhysicsWorldConfiguration())
        let floorY: Float = -1.0
        let catchPlane = CoolBallNet.catchPlane(
            goalCenter: SIMD3<Float>(0, floorY, -2.6),
            forward: SIMD3<Float>(0, 0, 1),
            width: 1.6,
            height: 1.0
        )
        let skirtPlane = CoolBallNet.groundSkirtPlane(
            goalCenter: SIMD3<Float>(0, floorY, -2.6),
            forward: SIMD3<Float>(0, 0, 1),
            width: 1.6
        )
        backend.setWorldPlanes([.infiniteFloor(y: floorY), catchPlane, skirtPlane])

        backend.didAddBody(entity: 1, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(
                shape: .sphere(radius: 0.11),
                friction: 0.35,
                restitution: 0.62
            ),
            mass: 0.43,
            position: SIMD3<Float>(0, 0, -2.75),
            linearVelocity: .zero
        ))

        for _ in 0 ..< 600 {
            backend.step(deltaTime: 1.0 / 60.0)
        }
        let state = backend.bodyState(for: 1)!
        // The slanted net and the ground skirt form a pocket that hammocks
        // the ball above the floor — like a real net.
        XCTAssertLessThan(state.position.y, floorY + 0.55,
                          "ball must settle low in the pocket (y=\(state.position.y))")
        XCTAssertGreaterThan(state.position.y, floorY,
                             "ball cannot sink below the floor (y=\(state.position.y))")
        XCTAssertGreaterThan(state.position.z, -3.2,
                             "ball must stay inside the net pocket (z=\(state.position.z))")
        XCTAssertLessThan(state.position.z, -2.55,
                          "ball must settle behind the goal line (z=\(state.position.z))")
        XCTAssertLessThan(simd_length(state.velocity), 0.3,
                          "ball must come to rest in the pocket")
    }

    func testCatchPlaneKillsBounce() {
        // Backend integration: a ball fired at the net's backstop plane
        // barely rebounds compared to a regular wall.
        let backend = CoolBallPhysicsBackend()
        backend.configure(PhysicsWorldConfiguration())
        let catchPlane = CoolBallNet.catchPlane(
            goalCenter: SIMD3<Float>(0, 0, -2.6),
            forward: SIMD3<Float>(0, 0, 1),
            width: 1.6,
            height: 1.0
        )
        backend.setWorldPlanes([.infiniteFloor(), catchPlane])

        backend.didAddBody(entity: 1, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(
                shape: .sphere(radius: 0.11),
                friction: 0.35,
                restitution: 0.62
            ),
            mass: 0.43,
            position: SIMD3<Float>(0, 0.5, -1.5),
            linearVelocity: SIMD3<Float>(0, 0, -6.0)
        ))

        var maxReboundZ: Float = -.greatestFiniteMagnitude
        for _ in 0 ..< 120 {
            backend.step(deltaTime: 1.0 / 60.0)
            if let state = backend.bodyState(for: 1) {
                maxReboundZ = max(maxReboundZ, state.velocity.z)
            }
        }

        XCTAssertGreaterThan(maxReboundZ, 0, "ball must rebound off the net plane at least slightly")
        XCTAssertLessThan(maxReboundZ, 1.2, "net must kill most of a 6 m/s shot")
    }
}
