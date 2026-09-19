//
//  CoolBowlingTests.swift
//  CoolBowlingTests
//

@testable import CoolBowling
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

private final class RecordingSink: PhysicsEventSink {
    var contacts: [PhysicsContactEvent] = []
    func receiveContact(_ event: PhysicsContactEvent) { contacts.append(event) }
    func receiveTrigger(_: PhysicsTriggerEvent) {}
    func receiveActivation(_: PhysicsBodyActivationEvent) {}
    func reportDroppedEvents(count _: Int) {}
}

final class CoolBowlingTests: XCTestCase {
    private let step: Float = 1.0 / 60.0

    func testRackHasTenPinsInTheRegulationTriangle() {
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(layout.pinPositions.count, 10)
        // Head pin straight down the lane at the deck distance.
        let head = layout.pinPositions[0]
        XCTAssertEqual(head.x, 0, accuracy: 1e-5)
        XCTAssertEqual(head.z, -CoolBowlingScene.pinDeckDistance, accuracy: 1e-5)
        XCTAssertEqual(head.y, CoolBowlingScene.laneThickness, accuracy: 1e-5, "Pins stand on the lane surface")
        // Neighbours 12 inches apart; the back row is 10 wide (7 … 10).
        XCTAssertEqual(simd_length(layout.pinPositions[1] - layout.pinPositions[2]), CoolBowlingScene.pinSpacing, accuracy: 1e-4)
        XCTAssertEqual(simd_length(layout.pinPositions[0] - layout.pinPositions[1]), CoolBowlingScene.pinSpacing, accuracy: 1e-4)
        XCTAssertEqual(simd_length(layout.pinPositions[6] - layout.pinPositions[9]), CoolBowlingScene.pinSpacing * 3, accuracy: 1e-4)
        // The lane centre is halfway down and the surface sits on the floor.
        XCTAssertEqual(layout.laneCenter.z, -CoolBowlingScene.laneLength * 0.5, accuracy: 1e-5)
        XCTAssertEqual(layout.surfaceY, CoolBowlingScene.laneThickness, accuracy: 1e-6)
        // Local +Z of the orientation points down the lane.
        XCTAssertEqual(simd_dot(layout.orientation.act(SIMD3<Float>(0, 0, 1)), layout.forward), 1.0, accuracy: 1e-4)
    }

    func testPinHullSpansThePin() {
        let hull = CoolBowlingScene.pinHullVertices
        XCTAssertGreaterThan(hull.count, 40)
        let minY = hull.map(\.y).min()!, maxY = hull.map(\.y).max()!
        XCTAssertEqual(minY, 0, accuracy: 1e-6)
        XCTAssertEqual(maxY, CoolBowlingScene.pinHeight, accuracy: 1e-6)
        let belly = hull.map { simd_length(SIMD2<Float>($0.x, $0.z)) }.max()!
        XCTAssertEqual(belly, CoolBowlingScene.pinMaxRadius, accuracy: 1e-6)
    }

    func testPinsDownPredicate() {
        XCTAssertFalse(CoolBowlingScene.isPinDown(up: SIMD3<Float>(0, 1, 0), displacement: 0))
        XCTAssertFalse(CoolBowlingScene.isPinDown(up: simd_normalize(SIMD3<Float>(0.3, 1, 0)), displacement: 0.1), "A wobble is not a fall")
        XCTAssertTrue(CoolBowlingScene.isPinDown(up: SIMD3<Float>(1, 0, 0), displacement: 0), "Lying flat")
        XCTAssertTrue(CoolBowlingScene.isPinDown(up: SIMD3<Float>(0, 1, 0), displacement: 0.5), "Standing, but off its spot")
    }

    func testFloorPlaneBecomesASlabUnderTheSurface() {
        let floor = CoolBowlingWorldPlane.infiniteFloor(y: 0.3)
        let box = CoolBowlingSimulation.environmentBox(for: floor)
        XCTAssertEqual(box.center.y, 0.3 - CoolBowlingSimulation.slabHalfThickness, accuracy: 1e-6)
        XCTAssertEqual(box.halfExtents.x, CoolBowlingSimulation.maxHalfExtent)
        XCTAssertEqual(simd_dot(box.orientation.act(SIMD3<Float>(0, 0, 1)), floor.normal), 1.0, accuracy: 1e-4)
    }

    /// The whole alley on Jolt, headless: a rolled ball must topple pins,
    /// and pins standing untouched must stay up.
    func testRolledBallKnocksPinsOverOnJolt() {
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1))

        // Lane slab.
        backend.didAddBody(entity: 100, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(
                shape: .box(halfExtents: SIMD3<Float>(CoolBowlingScene.laneWidth * 0.5, CoolBowlingScene.laneThickness * 0.5, CoolBowlingScene.laneLength * 0.5)),
                friction: CoolBowlingScene.laneFriction, restitution: 0.1
            ),
            position: layout.laneCenter, orientation: layout.orientation
        ))
        // Ten pins.
        for (index, position) in layout.pinPositions.enumerated() {
            backend.didAddBody(entity: EntityID(1 + index), descriptor: PhysicsBodyDescriptor(
                motionType: .dynamic,
                collider: PhysicsColliderDescriptor(shape: .convexHull(vertices: CoolBowlingScene.pinHullVertices), friction: 0.5, restitution: 0.3),
                mass: CoolBowlingScene.pinMass,
                position: position, orientation: layout.orientation
            ))
        }
        // Let the rack settle: nothing must fall on its own.
        for _ in 0 ..< 120 { backend.step(deltaTime: step) }
        XCTAssertEqual(pinsDown(backend, layout: layout), 0, "A racked pin stands on its own")

        // The ball, rolled from the foul line straight at the head pin.
        let start = layout.foul + layout.forward * 0.3 + SIMD3<Float>(0, layout.surfaceY + CoolBowlingScene.ballRadius + 0.005, 0)
        backend.didAddBody(entity: 50, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: CoolBowlingScene.ballRadius), friction: CoolBowlingScene.ballFriction, restitution: CoolBowlingScene.ballRestitution),
            mass: CoolBowlingScene.ballMass,
            position: start, linearVelocity: layout.forward * 7.0 + layout.right * 0.1
        ))
        let sink = RecordingSink()
        for _ in 0 ..< 240 {
            backend.step(deltaTime: step)
            backend.drainEvents(into: sink)
        }
        let down = pinsDown(backend, layout: layout)
        XCTAssertGreaterThanOrEqual(down, 4, "A 7 m/s ball into the head pin scatters the rack (got \(down))")
        XCTAssertTrue(sink.contacts.contains { ($0.entityA == 50 && (1 ... 10).contains($0.entityB)) }, "The ball hit a pin")
        XCTAssertTrue(sink.contacts.contains { (1 ... 10).contains($0.entityA) && (1 ... 10).contains($0.entityB) }, "Pins hit each other")
    }

    private func pinsDown(_ backend: JoltPhysicsBackend, layout: CoolBowlingScene.LaneLayout) -> Int {
        var entities = [EntityID](repeating: 0, count: 32)
        var transforms = [PhysicsBodyTransform](repeating: PhysicsBodyTransform(position: .zero, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), count: 32)
        var poses: [EntityID: PhysicsBodyTransform] = [:]
        entities.withUnsafeMutableBufferPointer { e in
            transforms.withUnsafeMutableBufferPointer { t in
                let written = backend.readActiveTransforms(into: PhysicsTransformReadBatch(entities: e, transforms: t))
                for i in 0 ..< written { poses[e[i]] = t[i] }
            }
        }
        var down = 0
        for index in 0 ..< 10 {
            let entity = EntityID(1 + index)
            // Sleeping pins are not read back: use the backend's state for position and treat them as standing unless displaced.
            let spot = layout.pinPositions[index]
            if let pose = poses[entity] {
                let up = pose.orientation.act(SIMD3<Float>(0, 1, 0))
                let displacement = simd_length(SIMD3<Float>(pose.position.x - spot.x, 0, pose.position.z - spot.z))
                if CoolBowlingScene.isPinDown(up: up, displacement: displacement) { down += 1 }
            } else if let state = backend.bodyState(for: entity) {
                let displacement = simd_length(SIMD3<Float>(state.position.x - spot.x, 0, state.position.z - spot.z))
                if displacement > 0.25 { down += 1 }
            }
        }
        return down
    }
}
