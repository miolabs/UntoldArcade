//
//  CoolBallPhysicsBackend.swift
//  CoolBall
//
//  A small pure-Swift physics backend for the football demo — the first real
//  consumer of the engine's PhysicsBackend plugin seam. It simulates dynamic
//  spheres (the ball) against three kinds of static geometry:
//    - world planes fed from ARKit plane detection (real floors/walls/tables),
//    - static box colliders from engine entities (goal posts and crossbar),
//    - kinematic sphere bodies driven by the engine (the player's hands),
//  with restitution, Coulomb-style slide friction, rolling spin, contact and
//  trigger events. Heavy backends (Jolt) will live in their own package; this
//  one exists to prove the seam end to end inside the demo showcase.
//

import Foundation
import simd
import UntoldEngine

/// A bounded real-world surface (from ARKit plane detection) the ball
/// collides with. `center`/`normal` in world space; `extents` are the
/// half-sizes along the plane's two tangent axes.
public struct CoolBallWorldPlane: Sendable {
    public let id: UUID
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var tangentU: SIMD3<Float>
    public var tangentV: SIMD3<Float>
    public var extentU: Float
    public var extentV: Float
    /// Multiplies the ball's restitution on this surface — a goal net
    /// (~0.1) kills the bounce and catches the ball.
    public var restitutionScale: Float

    public init(
        id: UUID,
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        tangentU: SIMD3<Float>,
        tangentV: SIMD3<Float>,
        extentU: Float,
        extentV: Float,
        restitutionScale: Float = 1.0
    ) {
        self.id = id
        self.center = center
        self.normal = normal
        self.tangentU = tangentU
        self.tangentV = tangentV
        self.extentU = extentU
        self.extentV = extentV
        self.restitutionScale = restitutionScale
    }

    /// An unbounded horizontal floor — the simulator fallback when no real
    /// surfaces are available.
    public static func infiniteFloor(y: Float = 0.0) -> CoolBallWorldPlane {
        CoolBallWorldPlane(
            id: UUID(),
            center: SIMD3<Float>(0.0, y, 0.0),
            normal: SIMD3<Float>(0.0, 1.0, 0.0),
            tangentU: SIMD3<Float>(1.0, 0.0, 0.0),
            tangentV: SIMD3<Float>(0.0, 0.0, 1.0),
            extentU: .greatestFiniteMagnitude,
            extentV: .greatestFiniteMagnitude
        )
    }
}

public final class CoolBallPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    public let id = CoolBallPluginContract.backendID
    public let capabilities: PhysicsCapabilities = [.collisions, .triggers]

    /// Entity reported for contacts against real-world surfaces, which have no
    /// engine entity of their own.
    public static let environmentEntity: EntityID = 0

    private struct Body {
        var descriptor: PhysicsBodyDescriptor
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var linearVelocity: SIMD3<Float>
        var angularVelocity: SIMD3<Float>
        /// Kinematic bodies: velocity estimated from consecutive targets, so a
        /// moving hand imparts momentum on the ball (the kick).
        var kinematicVelocity: SIMD3<Float> = .zero
        /// Kinematic bodies: the target position seen last substep.
        var previousTarget: SIMD3<Float>?
        /// Dynamic bodies: gripped by the net pocket — integration paused
        /// until something (a hand, the boot) touches it again.
        var isAsleep = false
        var radius: Float {
            if case let .sphere(radius) = descriptor.collider.shape { return radius }
            return 0.1
        }
    }

    private struct TriggerVolume {
        var descriptor: PhysicsBodyDescriptor
        var occupants: Set<EntityID> = []
        var halfExtents: SIMD3<Float> {
            if case let .box(halfExtents) = descriptor.collider.shape { return halfExtents }
            return SIMD3<Float>(repeating: 0.5)
        }
    }

    private let lock = NSLock()
    private var configuration = PhysicsWorldConfiguration()
    private var dynamicBodies: [EntityID: Body] = [:]
    private var kinematicBodies: [EntityID: Body] = [:]
    private var staticBodies: [EntityID: Body] = [:]
    private var triggers: [EntityID: TriggerVolume] = [:]
    private var worldPlanes: [CoolBallWorldPlane] = []

    // Fixed-capacity event buffers, per the backend threading contract:
    // filled during step, handed over in drainEvents, overflow only counted.
    private let eventCapacity = 128
    private var pendingContacts: [PhysicsContactEvent] = []
    private var pendingTriggers: [PhysicsTriggerEvent] = []
    private var droppedEvents = 0

    /// Ball speed below which a floor contact stops bouncing and starts rolling.
    private let restingSpeed: Float = 0.35
    /// Sanity caps: hand-tracking glitches must not teleport-launch the ball
    /// (a fast enough ball tunnels straight through the net planes).
    private let maxKinematicSpeed: Float = 6.0
    private let maxDynamicSpeed: Float = 10.0

    public init() {}

    // MARK: - Demo-facing API (plugin-owned, outside the engine protocol)

    /// Replaces the set of real-world surfaces. Called from the ARKit plane
    /// stream (any thread); the simulation reads a snapshot each substep.
    public func setWorldPlanes(_ planes: [CoolBallWorldPlane]) {
        lock.lock()
        worldPlanes = planes
        lock.unlock()
    }

    public var worldPlaneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return worldPlanes.count
    }

    /// Applies a velocity change to an awake dynamic body — the cloth's
    /// reaction on the ball. Sleeping bodies (hammocked in the net) ignore
    /// small nudges so the pocket stays at rest.
    public func nudgeBody(entity: EntityID, velocityDelta: SIMD3<Float>) {
        lock.lock()
        defer { lock.unlock() }
        guard var body = dynamicBodies[entity] else { return }
        if body.isAsleep {
            guard simd_length(velocityDelta) > 1.0 else { return }
            body.isAsleep = false
        }
        body.linearVelocity += velocityDelta
        let speed = simd_length(body.linearVelocity)
        if speed > maxDynamicSpeed {
            body.linearVelocity *= maxDynamicSpeed / speed
        }
        dynamicBodies[entity] = body
    }

    /// Current simulated state of a dynamic body (read-back for game logic,
    /// e.g. respawning a ball that fell out of the room).
    public func bodyState(
        for entity: EntityID
    ) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)? {
        lock.lock()
        defer { lock.unlock() }
        guard let body = dynamicBodies[entity] else { return nil }
        return (body.position, body.linearVelocity)
    }

    // MARK: - PhysicsBackend

    public func configure(_ config: PhysicsWorldConfiguration) {
        lock.lock()
        configuration = config
        lock.unlock()
    }

    public func didAddBody(entity: EntityID, descriptor: PhysicsBodyDescriptor) {
        let body = Body(
            descriptor: descriptor,
            position: descriptor.position,
            orientation: descriptor.orientation,
            linearVelocity: descriptor.linearVelocity,
            angularVelocity: descriptor.angularVelocity
        )
        lock.lock()
        if descriptor.collider.isTrigger {
            triggers[entity] = TriggerVolume(descriptor: descriptor)
        } else {
            switch descriptor.motionType {
            case .dynamic: dynamicBodies[entity] = body
            case .kinematic: kinematicBodies[entity] = body
            case .static: staticBodies[entity] = body
            }
        }
        lock.unlock()
    }

    public func didRemoveBody(entity: EntityID) {
        lock.lock()
        dynamicBodies.removeValue(forKey: entity)
        kinematicBodies.removeValue(forKey: entity)
        staticBodies.removeValue(forKey: entity)
        triggers.removeValue(forKey: entity)
        lock.unlock()
    }

    public func writeKinematicTargets(_ batch: PhysicsBodyWriteBatch) {
        lock.lock()
        for index in 0 ..< batch.entities.count {
            let entity = batch.entities[index]
            guard var body = kinematicBodies[entity] else { continue }
            body.position = batch.transforms[index].position
            body.orientation = batch.transforms[index].orientation
            kinematicBodies[entity] = body
        }
        lock.unlock()
    }

    public func step(deltaTime: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard deltaTime > 0 else { return }

        // Kinematic velocity from consecutive targets: `position` was just
        // overwritten by writeKinematicTargets; diff it against the target
        // seen last substep.
        for (entity, var body) in kinematicBodies {
            if let previous = body.previousTarget {
                var velocity = (body.position - previous) / deltaTime
                let speed = simd_length(velocity)
                if speed > maxKinematicSpeed {
                    velocity *= maxKinematicSpeed / speed
                }
                body.kinematicVelocity = velocity
            }
            body.previousTarget = body.position
            kinematicBodies[entity] = body
        }

        let gravity = configuration.gravity

        for (entity, var body) in dynamicBodies {
            let restitution = body.descriptor.collider.restitution
            let friction = body.descriptor.collider.friction

            if body.isAsleep {
                // A sleeping ball still reacts to the hands and the boot —
                // any such contact wakes it.
                for (handEntity, hand) in kinematicBodies {
                    resolveSphereVsKinematic(
                        &body, entity: entity,
                        hand: hand, handEntity: handEntity,
                        restitution: restitution
                    )
                }
                if simd_length(body.linearVelocity) > 0.01 {
                    body.isAsleep = false
                }
                dynamicBodies[entity] = body
                continue
            }

            body.linearVelocity += gravity * body.descriptor.gravityScale * deltaTime
            let speed = simd_length(body.linearVelocity)
            if speed > maxDynamicSpeed {
                body.linearVelocity *= maxDynamicSpeed / speed
            }
            body.position += body.linearVelocity * deltaTime

            // Real-world planes. Two simultaneous net-surface contacts at
            // low speed mean the pocket has gripped the ball: hard rest,
            // instead of letting rigid-wedge push-outs pump jitter forever.
            var netContacts = 0
            for plane in worldPlanes {
                let contacted = resolveSphereVsPlane(
                    &body, entity: entity, plane: plane,
                    restitution: restitution, friction: friction,
                    deltaTime: deltaTime
                )
                if contacted, plane.restitutionScale < 0.99 {
                    netContacts += 1
                }
            }
            if netContacts >= 2, simd_length(body.linearVelocity) < 1.0 {
                body.linearVelocity = .zero
                body.angularVelocity = .zero
                body.isAsleep = true
            }

            // Static boxes (goal posts, crossbar, placed props).
            for (staticEntity, staticBody) in staticBodies {
                resolveSphereVsStatic(
                    &body, entity: entity,
                    staticBody: staticBody, staticEntity: staticEntity,
                    restitution: restitution, friction: friction
                )
            }

            // Hands: kinematic spheres that transfer their own velocity — the
            // kick. Impulse is resolved against the hand's motion so a fast
            // swat sends the ball flying, a slow push just nudges it.
            for (handEntity, hand) in kinematicBodies {
                resolveSphereVsKinematic(
                    &body, entity: entity,
                    hand: hand, handEntity: handEntity,
                    restitution: restitution
                )
            }

            // Integrate spin (visual roll); heavily damped in the air.
            let spin = simd_length(body.angularVelocity)
            if spin > 0 {
                let axis = body.angularVelocity / spin
                let rotation = simd_quatf(angle: spin * deltaTime, axis: axis)
                body.orientation = simd_normalize(rotation * body.orientation)
                body.angularVelocity *= 0.995
            }

            dynamicBodies[entity] = body
        }

        updateTriggerOccupancy()
    }

    public func drainEvents(into sink: any PhysicsEventSink) {
        lock.lock()
        let contacts = pendingContacts
        let triggerEvents = pendingTriggers
        let dropped = droppedEvents
        pendingContacts.removeAll(keepingCapacity: true)
        pendingTriggers.removeAll(keepingCapacity: true)
        droppedEvents = 0
        lock.unlock()

        for event in contacts {
            sink.receiveContact(event)
        }
        for event in triggerEvents {
            sink.receiveTrigger(event)
        }
        if dropped > 0 {
            sink.reportDroppedEvents(count: dropped)
        }
    }

    public func readActiveTransforms(into batch: PhysicsTransformReadBatch) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var written = 0
        for (entity, body) in dynamicBodies {
            guard written < batch.capacity else {
                break
            }
            batch.entities[written] = entity
            batch.transforms[written] = PhysicsBodyTransform(
                position: body.position,
                orientation: body.orientation
            )
            written += 1
        }
        return written
    }

    // MARK: - Collision resolution (lock held)

    @discardableResult
    private func resolveSphereVsPlane(
        _ body: inout Body,
        entity: EntityID,
        plane: CoolBallWorldPlane,
        restitution: Float,
        friction: Float,
        deltaTime: Float
    ) -> Bool {
        let toCenter = body.position - plane.center
        let signedDistance = simd_dot(toCenter, plane.normal)
        // Two-sided: walls can be hit from either face.
        guard abs(signedDistance) < body.radius else { return false }
        let normal = signedDistance >= 0 ? plane.normal : -plane.normal
        let distance = abs(signedDistance)

        // Bounded planes: the contact point must fall inside the rectangle
        // (with a ball radius of slack so edges don't cut the ball in half).
        if plane.extentU.isFinite {
            let u = abs(simd_dot(toCenter, plane.tangentU))
            let v = abs(simd_dot(toCenter, plane.tangentV))
            guard u <= plane.extentU + body.radius, v <= plane.extentV + body.radius else {
                return false
            }
        }

        let approaching = simd_dot(body.linearVelocity, normal)
        body.position += normal * (body.radius - distance)
        guard approaching < 0 else { return true }

        let normalSpeed = -approaching
        var normalVelocity = normal * approaching
        var tangentVelocity = body.linearVelocity - normalVelocity

        // Below resting speed the bounce dies and the ball rolls.
        normalVelocity = normalSpeed > restingSpeed
            ? -normalVelocity * restitution * plane.restitutionScale
            : .zero
        // Rolling friction, scaled by dt so behavior is step-rate independent.
        tangentVelocity *= max(0.0, 1.0 - friction * 2.0 * deltaTime)
        body.linearVelocity = normalVelocity + tangentVelocity

        // Net-like surfaces (restitutionScale < 1) grip: strong extra drag
        // kills the jitter a rigid wedge of planes would otherwise pump into
        // the ball, so it settles hammocked in the pocket.
        if plane.restitutionScale < 0.99 {
            body.linearVelocity *= max(0.0, 1.0 - 6.0 * deltaTime)
        }

        // Rolling spin from tangential motion: ω = (n × v) / r.
        let tangentSpeed = simd_length(tangentVelocity)
        if tangentSpeed > 0.01 {
            body.angularVelocity = simd_cross(normal, tangentVelocity) / body.radius
        }

        if normalSpeed > restingSpeed {
            emitContact(
                entityA: entity,
                entityB: Self.environmentEntity,
                position: body.position - normal * body.radius,
                normal: normal,
                impulse: normalSpeed * body.descriptor.mass
            )
        }
        return true
    }

    private func resolveSphereVsStatic(
        _ body: inout Body,
        entity: EntityID,
        staticBody: Body,
        staticEntity: EntityID,
        restitution: Float,
        friction: Float
    ) {
        let contact: (point: SIMD3<Float>, normal: SIMD3<Float>, depth: Float)?
        switch staticBody.descriptor.collider.shape {
        case let .box(halfExtents):
            contact = Self.sphereVsBox(
                center: body.position,
                radius: body.radius,
                boxCenter: staticBody.position + staticBody.descriptor.collider.localOffset,
                boxOrientation: staticBody.orientation,
                halfExtents: halfExtents
            )
        case let .sphere(radius):
            contact = Self.sphereVsSphere(
                center: body.position,
                radius: body.radius,
                otherCenter: staticBody.position + staticBody.descriptor.collider.localOffset,
                otherRadius: radius
            )
        default:
            contact = nil
        }
        guard let contact else { return }

        body.position += contact.normal * contact.depth
        let approaching = simd_dot(body.linearVelocity, contact.normal)
        guard approaching < 0 else { return }

        let combinedRestitution = max(restitution, staticBody.descriptor.collider.restitution)
        let normalVelocity = contact.normal * approaching
        let tangentVelocity = body.linearVelocity - normalVelocity
        body.linearVelocity = -normalVelocity * combinedRestitution + tangentVelocity

        emitContact(
            entityA: entity,
            entityB: staticEntity,
            position: contact.point,
            normal: contact.normal,
            impulse: -approaching * body.descriptor.mass
        )
    }

    private func resolveSphereVsKinematic(
        _ body: inout Body,
        entity: EntityID,
        hand: Body,
        handEntity: EntityID,
        restitution: Float
    ) {
        guard let contact = Self.sphereVsSphere(
            center: body.position,
            radius: body.radius,
            otherCenter: hand.position,
            otherRadius: hand.radius
        ) else { return }

        body.position += contact.normal * contact.depth

        // Resolve in the hand's frame: only if the ball approaches the hand
        // relative to the hand's own motion.
        let relativeVelocity = body.linearVelocity - hand.kinematicVelocity
        let approaching = simd_dot(relativeVelocity, contact.normal)
        guard approaching < 0 else { return }

        // Snappier than a wall bounce: a kick should feel like a strike.
        let bounce = max(restitution, 0.7)
        let reflected = relativeVelocity - (1.0 + bounce) * approaching * contact.normal
        body.linearVelocity = reflected + hand.kinematicVelocity

        emitContact(
            entityA: entity,
            entityB: handEntity,
            position: contact.point,
            normal: contact.normal,
            impulse: -approaching * body.descriptor.mass
        )
    }

    private func updateTriggerOccupancy() {
        for (triggerEntity, var volume) in triggers {
            let center = volume.descriptor.position
                + volume.descriptor.collider.localOffset
            let halfExtents = volume.halfExtents
            var current: Set<EntityID> = []

            for (entity, body) in dynamicBodies {
                let local = body.position - center
                if abs(local.x) <= halfExtents.x,
                   abs(local.y) <= halfExtents.y,
                   abs(local.z) <= halfExtents.z
                {
                    current.insert(entity)
                }
            }

            for entity in current.subtracting(volume.occupants) {
                emitTrigger(phase: .entered, trigger: triggerEntity, other: entity)
            }
            for entity in volume.occupants.subtracting(current) {
                emitTrigger(phase: .exited, trigger: triggerEntity, other: entity)
            }
            volume.occupants = current
            triggers[triggerEntity] = volume
        }
    }

    // MARK: - Event buffering (lock held)

    private func emitContact(
        entityA: EntityID,
        entityB: EntityID,
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        impulse: Float
    ) {
        guard pendingContacts.count < eventCapacity else {
            droppedEvents += 1
            return
        }
        pendingContacts.append(PhysicsContactEvent(
            phase: .began,
            entityA: entityA,
            entityB: entityB,
            position: position,
            normal: normal,
            impulse: impulse
        ))
    }

    private func emitTrigger(phase: PhysicsTriggerPhase, trigger: EntityID, other: EntityID) {
        guard pendingTriggers.count < eventCapacity else {
            droppedEvents += 1
            return
        }
        pendingTriggers.append(PhysicsTriggerEvent(
            phase: phase,
            triggerEntity: trigger,
            otherEntity: other
        ))
    }

    // MARK: - Geometry helpers

    static func sphereVsSphere(
        center: SIMD3<Float>,
        radius: Float,
        otherCenter: SIMD3<Float>,
        otherRadius: Float
    ) -> (point: SIMD3<Float>, normal: SIMD3<Float>, depth: Float)? {
        let delta = center - otherCenter
        let distance = simd_length(delta)
        let combined = radius + otherRadius
        guard distance < combined, distance > 1.0e-6 else { return nil }
        let normal = delta / distance
        return (
            point: otherCenter + normal * otherRadius,
            normal: normal,
            depth: combined - distance
        )
    }

    static func sphereVsBox(
        center: SIMD3<Float>,
        radius: Float,
        boxCenter: SIMD3<Float>,
        boxOrientation: simd_quatf,
        halfExtents: SIMD3<Float>
    ) -> (point: SIMD3<Float>, normal: SIMD3<Float>, depth: Float)? {
        // Sphere center into the box's local frame.
        let inverse = boxOrientation.inverse
        let local = inverse.act(center - boxCenter)
        let clamped = simd_clamp(local, -halfExtents, halfExtents)
        let delta = local - clamped
        let distance = simd_length(delta)
        guard distance < radius else { return nil }

        let localNormal: SIMD3<Float>
        if distance > 1.0e-6 {
            localNormal = delta / distance
        } else {
            // Center inside the box: push out along the axis of least
            // penetration.
            let overlap = halfExtents - simd_abs(local)
            if overlap.x <= overlap.y, overlap.x <= overlap.z {
                localNormal = SIMD3<Float>(local.x < 0 ? -1 : 1, 0, 0)
            } else if overlap.y <= overlap.z {
                localNormal = SIMD3<Float>(0, local.y < 0 ? -1 : 1, 0)
            } else {
                localNormal = SIMD3<Float>(0, 0, local.z < 0 ? -1 : 1)
            }
        }

        let worldNormal = boxOrientation.act(localNormal)
        let worldPoint = boxCenter + boxOrientation.act(clamped)
        return (
            point: worldPoint,
            normal: worldNormal,
            depth: radius - distance
        )
    }
}
