//
//  CoolBallScene.swift
//  CoolBall
//
//  Entity construction for the football demo: the ball (dynamic body), the
//  goal (static posts + crossbar with an invisible trigger volume behind the
//  line), and two invisible kinematic hand bodies. Visuals use the engine's
//  primitive nodes; physics uses the engine-owned ColliderComponent /
//  RigidBodyComponent vocabulary, so any backend can simulate this scene.
//

import Foundation
import simd
import UntoldEngine

/// Node creation is main-actor (the DSL requirement); runtime mutation uses
/// the engine's lock-backed nonisolated API, callable from the XR game thread.
public final class CoolBallScene: @unchecked Sendable {
    public private(set) var ballEntity: EntityID = .invalid
    public private(set) var goalTriggerEntity: EntityID = .invalid
    public private(set) var leftHandEntity: EntityID = .invalid
    public private(set) var rightHandEntity: EntityID = .invalid
    public private(set) var footEntity: EntityID = .invalid
    public private(set) var sunEntity: EntityID = .invalid
    private var goalPartEntities: [EntityID] = []
    /// The XPBD goal net (visual cloth + the backend's catch plane).
    public let net = CoolBallNet()
    public private(set) var goalCatchPlane: CoolBallWorldPlane?
    public private(set) var goalSkirtPlane: CoolBallWorldPlane?

    /// FIFA size-5 ball: radius ~0.11 m, mass ~0.43 kg.
    public static let ballRadius: Float = 0.11
    public static let ballMass: Float = 0.43
    /// Demo goal: 1.6 m wide, 1.0 m high — furniture-scale, not regulation.
    public static let goalWidth: Float = 1.6
    public static let goalHeight: Float = 1.0
    static let postRadius: Float = 0.04
    static let handRadius: Float = 0.07
    /// The kicking boot: bigger than a hand so a leg swing connects reliably.
    public static let footRadius: Float = 0.14

    public init() {}

    // MARK: - Ball

    /// Creates the ball at `position` as a dynamic body, at rest.
    @MainActor public func spawnBall(at position: SIMD3<Float>) {
        if ballEntity != .invalid {
            destroyEntity(entityId: ballEntity)
        }
        let node = SphereNode(
            radius: Self.ballRadius,
            segments: [32, 24],
            name: "CoolBall.ball"
        )
        .baseColor(1.0, 1.0, 1.0)
        .roughness(0.45)
        .metallic(0.0)
        ballEntity = node.entityID

        // World-Cup-style panel artwork (original, Trionda-inspired),
        // equirectangular to match the sphere primitive's UVs. The engine
        // resolves texture paths by name through its asset search paths, so
        // point them at this package's resource bundle first — the demo loads
        // no other engine assets, so claiming the base path is safe.
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        if let textureURL = Bundle.module.url(
            forResource: "football_baseColor", withExtension: "png"
        ) {
            updateMaterialTexture(
                entityId: ballEntity, textureType: .baseColor, path: textureURL
            )
        } else {
            print("CoolBall: ball texture missing from bundle — plain white ball")
        }

        translateTo(entityId: ballEntity, position: position)
        attachBallBody(velocity: .zero, at: position)
    }

    /// Makes the ball a simulated body again (used on spawn and on throw
    /// release). Position is the current transform; `velocity` is imparted.
    public func attachBallBody(velocity: SIMD3<Float>, at position: SIMD3<Float>) {
        guard ballEntity != .invalid else { return }
        translateTo(entityId: ballEntity, position: position)

        registerComponent(entityId: ballEntity, componentType: ColliderComponent.self)
        registerComponent(entityId: ballEntity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: ballEntity) {
            collider.shape = .sphere(radius: Self.ballRadius)
            collider.restitution = 0.62
            collider.friction = 0.35
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: ballEntity) {
            body.motionType = .dynamic
            body.mass = Self.ballMass
            body.initialLinearVelocity = velocity
        }
    }

    /// Takes the ball out of simulation (while held in the hand). The next
    /// coordinator substep removes the body from the backend via the query
    /// diff — no backend-specific call needed.
    public func detachBallBody() {
        guard ballEntity != .invalid else { return }
        scene.remove(component: RigidBodyComponent.self, from: ballEntity)
        scene.remove(component: ColliderComponent.self, from: ballEntity)
    }

    /// Puts the ball back at `position`, at rest — without recreating the
    /// entity, so it is callable from the game thread.
    public func respawnBall(at position: SIMD3<Float>) {
        detachBallBody()
        attachBallBody(velocity: .zero, at: position)
    }

    /// Directly places the ball (held state — not simulated).
    public func moveBall(to position: SIMD3<Float>) {
        guard ballEntity != .invalid else { return }
        translateTo(entityId: ballEntity, position: position)
    }

    public func ballPosition() -> SIMD3<Float>? {
        scene.get(component: LocalTransformComponent.self, for: ballEntity)?.position
    }

    // MARK: - Lighting

    /// A sun so the ball and goal shade like solid objects instead of flat
    /// ambient blobs.
    @MainActor public func addLighting() {
        guard sunEntity == .invalid else { return }
        let sun = DirectionalLightNode(name: "CoolBall.sun")
            .color(1.0, 0.98, 0.92)
            .intensity(2.0)
            .rotateBy(angle: -50, axis: [.x])
            .rotateBy(angle: 30, axis: [.y])
        sunEntity = sun.entityID
    }

    // MARK: - Goal

    /// Builds the goal centered at `position` (on the floor), opening facing
    /// `facing` (horizontal, normalized). Posts and crossbar are static
    /// bodies; a flat trigger volume just behind the goal line detects goals.
    @MainActor public func buildGoal(at position: SIMD3<Float>, facing: SIMD3<Float>) {
        clearGoal()

        let forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
        let yaw = atan2f(forward.x, forward.z)
        let orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let right = orientation.act(SIMD3<Float>(1, 0, 0))

        let halfWidth = Self.goalWidth * 0.5
        let postHalf = SIMD3<Float>(Self.postRadius, Self.goalHeight * 0.5, Self.postRadius)

        func staticBox(
            node: PrimitiveNode,
            at boxPosition: SIMD3<Float>,
            halfExtents: SIMD3<Float>
        ) {
            let entity = node.entityID
            translateTo(entityId: entity, position: boxPosition)
            rotateTo(entityId: entity, rotation: orientation)
            registerComponent(entityId: entity, componentType: ColliderComponent.self)
            registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
            if let collider = scene.get(component: ColliderComponent.self, for: entity) {
                collider.shape = .box(halfExtents: halfExtents)
                collider.restitution = 0.7
                collider.friction = 0.3
            }
            if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
                body.motionType = .static
            }
            goalPartEntities.append(entity)
        }

        // Two posts.
        for side: Float in [-1.0, 1.0] {
            let node = CubeNode(size: 1.0, name: "CoolBall.post\(side > 0 ? "R" : "L")")
                .baseColor(0.92, 0.92, 0.98)
                .roughness(0.4)
                .scaleTo(
                    x: Self.postRadius * 2,
                    y: Self.goalHeight,
                    z: Self.postRadius * 2
                )
            staticBox(
                node: node,
                at: position + right * (side * halfWidth)
                    + SIMD3<Float>(0, Self.goalHeight * 0.5, 0),
                halfExtents: postHalf
            )
        }

        // Crossbar.
        let crossbar = CubeNode(size: 1.0, name: "CoolBall.crossbar")
            .baseColor(0.92, 0.92, 0.98)
            .roughness(0.4)
            .scaleTo(
                x: Self.goalWidth + Self.postRadius * 2,
                y: Self.postRadius * 2,
                z: Self.postRadius * 2
            )
        staticBox(
            node: crossbar,
            at: position + SIMD3<Float>(0, Self.goalHeight + Self.postRadius, 0),
            halfExtents: SIMD3<Float>(
                halfWidth + Self.postRadius,
                Self.postRadius,
                Self.postRadius
            )
        )

        // Goal-line trigger: a thin box spanning the mouth, half a ball deep
        // behind the line so grazing shots don't count.
        let triggerNode = Node(name: "CoolBall.goalTrigger")
        goalTriggerEntity = triggerNode.entityID
        translateTo(
            entityId: goalTriggerEntity,
            position: position
                - forward * (Self.ballRadius * 1.5)
                + SIMD3<Float>(0, Self.goalHeight * 0.5, 0)
        )
        rotateTo(entityId: goalTriggerEntity, rotation: orientation)
        // The net: XPBD cloth hanging from the crossbar, staked behind the
        // goal, plus a low-restitution backstop plane so the ball is caught.
        net.build(
            goalCenter: position,
            forward: forward,
            width: Self.goalWidth,
            height: Self.goalHeight,
            floorY: position.y
        )
        goalCatchPlane = CoolBallNet.catchPlane(
            goalCenter: position,
            forward: forward,
            width: Self.goalWidth,
            height: Self.goalHeight
        )
        goalSkirtPlane = CoolBallNet.groundSkirtPlane(
            goalCenter: position,
            forward: forward,
            width: Self.goalWidth
        )

        registerComponent(entityId: goalTriggerEntity, componentType: ColliderComponent.self)
        registerComponent(entityId: goalTriggerEntity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: goalTriggerEntity) {
            collider.shape = .box(halfExtents: SIMD3<Float>(
                halfWidth - Self.postRadius,
                Self.goalHeight * 0.5,
                Self.ballRadius * 0.5
            ))
            collider.isTrigger = true
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: goalTriggerEntity) {
            body.motionType = .static
        }
        goalPartEntities.append(goalTriggerEntity)
    }

    private func clearGoal() {
        for entity in goalPartEntities {
            destroyEntity(entityId: entity)
        }
        goalPartEntities.removeAll()
        goalTriggerEntity = .invalid
        net.destroy()
        goalCatchPlane = nil
        goalSkirtPlane = nil
    }

    // MARK: - Body proxies

    /// Invisible kinematic bodies the backend collides the ball against.
    /// Hands catch, dribble and make goalkeeper saves; the foot proxy — a
    /// boot-sized sphere at floor level driven from head tracking, since
    /// Vision Pro tracks no legs — is what kicks.
    @MainActor public func createBodyProxies() {
        leftHandEntity = makeKinematicSphere(name: "CoolBall.handL", radius: Self.handRadius)
        rightHandEntity = makeKinematicSphere(name: "CoolBall.handR", radius: Self.handRadius)
        footEntity = makeKinematicSphere(name: "CoolBall.foot", radius: Self.footRadius)
    }

    private func makeKinematicSphere(name: String, radius: Float) -> EntityID {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        // Parked far below until tracking places it.
        translateTo(entityId: entity, position: SIMD3<Float>(0, -100, 0))
        registerComponent(entityId: entity, componentType: ColliderComponent.self)
        registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: entity) {
            collider.shape = .sphere(radius: radius)
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
            body.motionType = .kinematic
        }
        return entity
    }

    /// Moves a kinematic proxy (hand or foot) to its tracked position, or
    /// parks it when tracking is lost. The coordinator forwards this as the
    /// kinematic target next substep.
    public func moveProxy(_ entity: EntityID, to position: SIMD3<Float>?) {
        guard entity != .invalid else { return }
        translateTo(entityId: entity, position: position ?? SIMD3<Float>(0, -100, 0))
    }

    // MARK: - Teardown

    public func clear() {
        if ballEntity != .invalid { destroyEntity(entityId: ballEntity) }
        if leftHandEntity != .invalid { destroyEntity(entityId: leftHandEntity) }
        if rightHandEntity != .invalid { destroyEntity(entityId: rightHandEntity) }
        if footEntity != .invalid { destroyEntity(entityId: footEntity) }
        if sunEntity != .invalid { destroyEntity(entityId: sunEntity) }
        ballEntity = .invalid
        leftHandEntity = .invalid
        rightHandEntity = .invalid
        footEntity = .invalid
        sunEntity = .invalid
        clearGoal()
    }
}
