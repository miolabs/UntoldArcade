//
//  CoolBallPhysicsBackendTests.swift
//  CoolBallTests
//

@testable import CoolBall
import simd
import UntoldEngine
import XCTest

private final class RecordingSink: PhysicsEventSink {
    var contacts: [PhysicsContactEvent] = []
    var triggers: [PhysicsTriggerEvent] = []
    var dropped = 0

    func receiveContact(_ event: PhysicsContactEvent) { contacts.append(event) }
    func receiveTrigger(_ event: PhysicsTriggerEvent) { triggers.append(event) }
    func receiveActivation(_: PhysicsBodyActivationEvent) {}
    func reportDroppedEvents(count: Int) { dropped += count }
}

final class CoolBallPhysicsBackendTests: XCTestCase {
    private let step: Float = 1.0 / 60.0

    private func makeBackend(planes: [CoolBallWorldPlane] = [.infiniteFloor()]) -> CoolBallPhysicsBackend {
        let backend = CoolBallPhysicsBackend()
        backend.configure(PhysicsWorldConfiguration())
        backend.setWorldPlanes(planes)
        return backend
    }

    private func ballDescriptor(
        position: SIMD3<Float>,
        velocity: SIMD3<Float> = .zero,
        restitution: Float = 0.6
    ) -> PhysicsBodyDescriptor {
        PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(
                shape: .sphere(radius: 0.11),
                friction: 0.35,
                restitution: restitution
            ),
            mass: 0.43,
            position: position,
            linearVelocity: velocity
        )
    }

    private func advance(_ backend: CoolBallPhysicsBackend, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            backend.step(deltaTime: step)
            elapsed += step
        }
    }

    func testBallFallsAndBouncesOffFloor() {
        let backend = makeBackend()
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(position: SIMD3<Float>(0, 1.0, 0)))

        // Fall, hit the floor, and be somewhere in the first rebound.
        advance(backend, seconds: 0.6)
        let atFloor = backend.bodyState(for: 1)!
        XCTAssertGreaterThanOrEqual(atFloor.position.y, 0.10, "Ball must not sink through the floor")
        XCTAssertLessThan(atFloor.position.y, 1.0, "Rebound cannot exceed the drop height")

        let sink = RecordingSink()
        backend.drainEvents(into: sink)
        XCTAssertFalse(sink.contacts.isEmpty)
        XCTAssertEqual(sink.contacts.first?.entityB, CoolBallPhysicsBackend.environmentEntity)
        XCTAssertGreaterThan(sink.contacts.first?.normal.y ?? 0, 0.9)
    }

    func testBallEventuallyRestsOnFloor() {
        let backend = makeBackend()
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(position: SIMD3<Float>(0, 0.8, 0)))

        advance(backend, seconds: 5.0)
        let resting = backend.bodyState(for: 1)!
        XCTAssertEqual(resting.position.y, 0.11, accuracy: 0.02)
        XCTAssertLessThan(simd_length(resting.velocity), 0.2)
    }

    func testBoundedPlaneOnlyCollidesInsideItsExtent() {
        let table = CoolBallWorldPlane(
            id: UUID(),
            center: SIMD3<Float>(0, 0.7, 0),
            normal: SIMD3<Float>(0, 1, 0),
            tangentU: SIMD3<Float>(1, 0, 0),
            tangentV: SIMD3<Float>(0, 0, 1),
            extentU: 0.4,
            extentV: 0.4
        )
        let backend = makeBackend(planes: [table, .infiniteFloor()])

        // Over the table: lands on it.
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(position: SIMD3<Float>(0, 1.2, 0)))
        // Beside the table: falls past it to the floor.
        backend.didAddBody(entity: 2, descriptor: ballDescriptor(position: SIMD3<Float>(1.5, 1.2, 0)))

        advance(backend, seconds: 4.0)
        XCTAssertEqual(backend.bodyState(for: 1)!.position.y, 0.81, accuracy: 0.03)
        XCTAssertEqual(backend.bodyState(for: 2)!.position.y, 0.11, accuracy: 0.03)
    }

    func testBallBouncesOffStaticBox() {
        let backend = makeBackend()
        // A wall one meter ahead of the ball.
        backend.didAddBody(entity: 10, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(
                shape: .box(halfExtents: SIMD3<Float>(0.05, 1.0, 1.0)),
                restitution: 0.7
            ),
            position: SIMD3<Float>(1.0, 0.11, 0)
        ))
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(
            position: SIMD3<Float>(0, 0.11, 0),
            velocity: SIMD3<Float>(2.0, 0, 0)
        ))

        advance(backend, seconds: 1.0)
        let state = backend.bodyState(for: 1)!
        XCTAssertLessThan(state.velocity.x, 0, "Ball must rebound off the box")
        XCTAssertLessThan(state.position.x, 0.9)

        let sink = RecordingSink()
        backend.drainEvents(into: sink)
        XCTAssertTrue(sink.contacts.contains { $0.entityB == 10 })
    }

    func testGoalTriggerFiresEnterAndExit() {
        let backend = makeBackend()
        // Trigger volume straddling the ball's path.
        backend.didAddBody(entity: 20, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(
                shape: .box(halfExtents: SIMD3<Float>(0.2, 0.5, 0.5)),
                isTrigger: true
            ),
            position: SIMD3<Float>(1.0, 0.11, 0)
        ))
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(
            position: SIMD3<Float>(0, 0.11, 0),
            velocity: SIMD3<Float>(3.0, 0, 0)
        ))

        advance(backend, seconds: 1.5)
        let sink = RecordingSink()
        backend.drainEvents(into: sink)

        let phases = sink.triggers
            .filter { $0.triggerEntity == 20 && $0.otherEntity == 1 }
            .map(\.phase)
        XCTAssertEqual(phases, [.entered, .exited], "Ball passing through must enter then exit")
    }

    func testMovingHandKicksTheBall() {
        let backend = makeBackend()
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(position: SIMD3<Float>(0, 0.11, 0)))
        backend.didAddBody(entity: 30, descriptor: PhysicsBodyDescriptor(
            motionType: .kinematic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: 0.07)),
            position: SIMD3<Float>(-0.5, 0.11, 0)
        ))

        // Sweep the hand into the ball at 2.5 m/s using kinematic targets.
        var handX: Float = -0.5
        for _ in 0 ..< 30 {
            handX += 2.5 * step
            var entities: [EntityID] = [30]
            var transforms = [PhysicsBodyTransform(
                position: SIMD3<Float>(handX, 0.11, 0),
                orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )]
            entities.withUnsafeBufferPointer { entityBuffer in
                transforms.withUnsafeBufferPointer { transformBuffer in
                    backend.writeKinematicTargets(PhysicsBodyWriteBatch(
                        entities: entityBuffer,
                        transforms: transformBuffer
                    ))
                }
            }
            backend.step(deltaTime: step)
        }

        let state = backend.bodyState(for: 1)!
        XCTAssertGreaterThan(state.velocity.x, 1.0, "The swat must transfer hand momentum")

        let sink = RecordingSink()
        backend.drainEvents(into: sink)
        XCTAssertTrue(sink.contacts.contains { $0.entityB == 30 })
    }

    func testRemovedBodyStopsSimulating() {
        let backend = makeBackend()
        backend.didAddBody(entity: 1, descriptor: ballDescriptor(position: SIMD3<Float>(0, 1.0, 0)))
        backend.didRemoveBody(entity: 1)
        advance(backend, seconds: 0.2)
        XCTAssertNil(backend.bodyState(for: 1))
    }

    func testSphereVsBoxContactGeometry() {
        let contact = CoolBallPhysicsBackend.sphereVsBox(
            center: SIMD3<Float>(0, 0.6, 0),
            radius: 0.11,
            boxCenter: SIMD3<Float>(0, 0.25, 0),
            boxOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            halfExtents: SIMD3<Float>(0.5, 0.25, 0.5)
        )
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact!.normal.y, 1.0, accuracy: 1.0e-4)
        XCTAssertEqual(contact!.depth, 0.01, accuracy: 1.0e-4)
    }
}
