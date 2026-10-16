//
//  CoolBasketJoltSimulationTests.swift
//  CoolBasketTests
//
//  The Jolt side channel: detected planes become slabs Jolt can collide with.
//

@testable import CoolBasket
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class CoolBasketJoltSimulationTests: XCTestCase {
    func testFloorPlaneBecomesASlabUnderTheSurface() {
        let floor = CoolBasketWorldPlane.infiniteFloor(y: 0.3)
        let box = CoolBasketJoltSimulation.environmentBox(for: floor)
        XCTAssertEqual(box.center.y, 0.3 - CoolBasketJoltSimulation.slabHalfThickness, accuracy: 1e-6)
        XCTAssertEqual(box.halfExtents.z, CoolBasketJoltSimulation.slabHalfThickness, accuracy: 1e-6)
        XCTAssertEqual(box.halfExtents.x, CoolBasketJoltSimulation.maxHalfExtent, "Infinite extents are capped")
        // Local Z is the surface normal even though the floor's tangent basis is mirrored.
        let localZ = box.orientation.act(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(simd_dot(localZ, floor.normal), 1.0, accuracy: 1e-4)
    }

    func testWallPlaneKeepsItsOrientation() {
        let wall = CoolBasketWorldPlane(
            id: UUID(),
            center: SIMD3<Float>(0, 1, -2),
            normal: SIMD3<Float>(0, 0, 1),
            tangentU: SIMD3<Float>(1, 0, 0),
            tangentV: SIMD3<Float>(0, 1, 0),
            extentU: 1.5,
            extentV: 1.0
        )
        let box = CoolBasketJoltSimulation.environmentBox(for: wall)
        XCTAssertEqual(box.halfExtents.x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(box.halfExtents.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(box.center.z, -2 - CoolBasketJoltSimulation.slabHalfThickness, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(box.orientation.act(SIMD3<Float>(1, 0, 0)), wall.tangentU), 1.0, accuracy: 1e-4)
        XCTAssertEqual(simd_dot(box.orientation.act(SIMD3<Float>(0, 0, 1)), wall.normal), 1.0, accuracy: 1e-4)
    }

    func testBallRestsOnADetectedFloorThroughJolt() {
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        let jolt = JoltPhysicsBackend(settings: settings)
        jolt.configure(PhysicsWorldConfiguration())
        let simulation = CoolBasketJoltSimulation(backend: jolt)
        simulation.setWorldPlanes([.infiniteFloor(y: -1.0)])
        XCTAssertEqual(simulation.worldPlaneCount, 1)

        jolt.didAddBody(entity: 1, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(
                shape: .sphere(radius: CoolBasketScene.ballRadius),
                friction: 0.4,
                restitution: CoolBasketScene.ballRestitution
            ),
            mass: CoolBasketScene.ballMass,
            position: SIMD3<Float>(0, 0.5, 0)
        ))
        for _ in 0 ..< 240 {
            jolt.step(deltaTime: 1.0 / 60.0)
        }
        let state = simulation.bodyState(for: 1)!
        XCTAssertEqual(state.position.y, -1.0 + CoolBasketScene.ballRadius, accuracy: 0.02, "Rests on the slab's top face")
        XCTAssertTrue(simulation.resetBody(entity: 1, position: SIMD3<Float>(0, 1, 0), velocity: .zero))
        XCTAssertEqual(simulation.bodyState(for: 1)!.position.y, 1.0, accuracy: 1e-5)
    }
}
