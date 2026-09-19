//
//  CoolBallScene.swift
//  CoolBall
//
//  Entity construction for the basketball demo: the balls (dynamic bodies), the
//  hoop (static pole + backboard boxes, a rim made of a ring of static sphere
//  colliders, and an invisible trigger volume under the rim), and two
//  invisible kinematic hand bodies. Visuals use the engine's primitive nodes;
//  physics uses the engine-owned ColliderComponent / RigidBodyComponent
//  vocabulary, so any backend can simulate this scene.
//

import Foundation
import simd
import UntoldEngine

/// Node creation is main-actor (the DSL requirement); runtime mutation uses
/// the engine's lock-backed nonisolated API, callable from the XR game thread.
public final class CoolBallScene: @unchecked Sendable {
    public private(set) var basketTriggerEntity: EntityID = .invalid
    public private(set) var leftHandEntity: EntityID = .invalid
    public private(set) var rightHandEntity: EntityID = .invalid
    public private(set) var sunEntity: EntityID = .invalid
    private var hoopPartEntities: [EntityID] = []
    /// Translucent placement preview: pole + board + rim disc, no physics.
    private var ghostEntities: [EntityID] = []
    /// World-space rim center while a hoop stands (nil during placement) —
    /// the game's ring-crossing test reads it every frame.
    public private(set) var rimCenter: SIMD3<Float>?
    /// Horizontal direction from the hoop toward the player while it stands.
    public private(set) var hoopForward: SIMD3<Float>?

    /// Size-7 basketball: radius ~0.12 m, mass ~0.62 kg — and bouncy.
    public static let ballRadius: Float = 0.121
    public static let ballMass: Float = 0.62
    public static let ballRestitution: Float = 0.78
    /// Mini hoop, living-room scale: rim at 2.0 m (regulation is 3.05).
    public static let rimHeight: Float = 2.0
    /// Regulation rim: 0.23 m inner radius — twice the ball, real shots fit.
    public static let rimRadius: Float = 0.23
    static let rimTubeRadius: Float = 0.02
    /// The rim's collision proxy: a ring of small static spheres, slightly
    /// fatter than the visual tube so bounces feel solid.
    static let rimColliderRadius: Float = 0.032
    static let rimSegmentCount = 16
    static let boardWidth: Float = 0.9
    static let boardHeight: Float = 0.6
    static let boardThickness: Float = 0.03
    /// Basket trigger: a box this far under the rim plane, this big. The box
    /// alone cannot tell a made shot from a ball drifting in from the side
    /// or below — the game pairs it with a downward ring-crossing test.
    static let basketTriggerDrop: Float = 0.22
    static let basketTriggerHalfExtents = SIMD3<Float>(0.12, 0.10, 0.12)
    static let handRadius: Float = 0.07

    public init() {}

    // MARK: - Hoop layout

    /// Shared placement math for the ghost and the real hoop: `position` is
    /// the floor point under the rim center, `facing` points from the hoop
    /// toward the player.
    struct HoopLayout {
        let forward: SIMD3<Float> // toward the player
        let orientation: simd_quatf
        let rimCenter: SIMD3<Float>
        let boardCenter: SIMD3<Float>
        let poleCenter: SIMD3<Float>
        let poleHeight: Float

        init(position: SIMD3<Float>, facing: SIMD3<Float>) {
            forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
            let yaw = atan2f(forward.x, forward.z)
            orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

            rimCenter = SIMD3<Float>(
                position.x, position.y + CoolBallScene.rimHeight, position.z
            )
            // Board hangs behind the rim, bottom edge just under rim level.
            let boardFront = rimCenter
                - forward * (CoolBallScene.rimRadius + 0.06)
            let boardCenterY = position.y + CoolBallScene.rimHeight - 0.15
                + CoolBallScene.boardHeight * 0.5
            boardCenter = SIMD3<Float>(
                boardFront.x - forward.x * CoolBallScene.boardThickness * 0.5,
                boardCenterY,
                boardFront.z - forward.z * CoolBallScene.boardThickness * 0.5
            )
            // Pole runs from the floor up to the board, just behind it.
            poleHeight = boardCenterY - position.y
            let poleXZ = boardCenter - forward * (CoolBallScene.boardThickness * 0.5 + 0.05)
            poleCenter = SIMD3<Float>(
                poleXZ.x, position.y + poleHeight * 0.5, poleXZ.z
            )
        }

        /// World position of rim segment `index` (of `rimSegmentCount`), and
        /// the yaw orientation that lays a box's local X along the tangent.
        func rimSegment(_ index: Int) -> (position: SIMD3<Float>, orientation: simd_quatf) {
            let angle = Float(index) / Float(CoolBallScene.rimSegmentCount) * 2 * .pi
            let up = SIMD3<Float>(0, 1, 0)
            let right = simd_normalize(simd_cross(up, forward))
            let radial = right * cosf(angle) + forward * sinf(angle)
            let tangent = -right * sinf(angle) + forward * cosf(angle)
            let yaw = atan2f(-tangent.z, tangent.x)
            return (
                rimCenter + radial * CoolBallScene.rimRadius,
                simd_quatf(angle: yaw, axis: up)
            )
        }
    }

    // MARK: - Balls

    /// Every ball in play, oldest first. All balls are equal: any can be
    /// grabbed, thrown and scored with.
    public private(set) var balls: [EntityID] = []
    private var ballSet: Set<EntityID> = []

    public var ballCount: Int { balls.count }

    public func isBall(_ entity: EntityID) -> Bool {
        ballSet.contains(entity)
    }

    /// Creates a ball at `position` as a dynamic body, at rest.
    @MainActor @discardableResult
    public func spawnBall(at position: SIMD3<Float>) -> EntityID {
        let node = SphereNode(
            radius: Self.ballRadius,
            segments: [32, 24],
            name: "CoolBall.ball\(balls.count)"
        )
        .baseColor(1.0, 1.0, 1.0)
        .roughness(0.7)
        .metallic(0.0)
        let entity = node.entityID

        // Classic orange-with-black-channels artwork, equirectangular to
        // match the sphere primitive's UVs. The engine resolves texture paths
        // by name through its asset search paths, so point them at this
        // package's resource bundle first — the demo loads no other engine
        // assets, so claiming the base path is safe.
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        if let textureURL = Bundle.module.url(
            forResource: "basketball_baseColor", withExtension: "png"
        ) {
            updateMaterialTexture(
                entityId: entity, textureType: .baseColor, path: textureURL
            )
        } else {
            print("CoolBall: ball texture missing from bundle — plain white ball")
        }

        translateTo(entityId: entity, position: position)
        balls.append(entity)
        ballSet.insert(entity)
        attachBallBody(entity: entity, velocity: .zero, at: position)
        return entity
    }

    /// Destroys one ball (callable from the game thread).
    public func removeBall(_ entity: EntityID) {
        guard ballSet.remove(entity) != nil else { return }
        balls.removeAll { $0 == entity }
        destroyEntity(entityId: entity)
    }

    public func removeAllBalls() {
        for entity in balls {
            destroyEntity(entityId: entity)
        }
        balls.removeAll()
        ballSet.removeAll()
    }

    /// Makes a ball a simulated body again (used on spawn and on throw
    /// release). Position is the current transform; `velocity` is imparted.
    public func attachBallBody(entity: EntityID, velocity: SIMD3<Float>, at position: SIMD3<Float>) {
        guard isBall(entity) else { return }
        translateTo(entityId: entity, position: position)

        registerComponent(entityId: entity, componentType: ColliderComponent.self)
        registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: entity) {
            collider.shape = .sphere(radius: Self.ballRadius)
            collider.restitution = Self.ballRestitution
            collider.friction = 0.4
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
            body.motionType = .dynamic
            body.mass = Self.ballMass
            body.initialLinearVelocity = velocity
        }
    }

    /// Takes a ball out of simulation (while held in the hand). The next
    /// coordinator substep removes the body from the backend via the query
    /// diff — no backend-specific call needed.
    public func detachBallBody(entity: EntityID) {
        guard isBall(entity) else { return }
        scene.remove(component: RigidBodyComponent.self, from: entity)
        scene.remove(component: ColliderComponent.self, from: entity)
    }

    /// Directly places a ball (held state — not simulated).
    public func moveBall(_ entity: EntityID, to position: SIMD3<Float>) {
        guard isBall(entity) else { return }
        translateTo(entityId: entity, position: position)
    }

    public func ballPosition(_ entity: EntityID) -> SIMD3<Float>? {
        guard isBall(entity) else { return nil }
        return scene.get(component: LocalTransformComponent.self, for: entity)?.position
    }

    // MARK: - Lighting

    /// A sun so the ball and hoop shade like solid objects instead of flat
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

    // MARK: - Hoop placement ghost

    /// Builds the translucent placement preview (parked out of sight until
    /// the first `moveHoopGhost`). No colliders — just pole, board and a
    /// flat disc where the rim will be.
    @MainActor public func buildHoopGhost() {
        removeHoopGhost()
        var entities: [EntityID] = []
        for (name, scale) in [
            ("CoolBall.ghostPole", SIMD3<Float>(0.08, Self.rimHeight + 0.15, 0.08)),
            ("CoolBall.ghostBoard", SIMD3<Float>(Self.boardWidth, Self.boardHeight, Self.boardThickness)),
            ("CoolBall.ghostRim", SIMD3<Float>(Self.rimRadius * 2.2, Self.rimTubeRadius * 2, Self.rimRadius * 2.2)),
        ] {
            let node = CubeNode(size: 1.0, name: name)
                .baseColor(1.0, 0.55, 0.15, 0.4)
                .roughness(0.3)
                .scaleTo(x: scale.x, y: scale.y, z: scale.z)
            updateMaterialAlphaMode(entityId: node.entityID, mode: .blend)
            translateTo(entityId: node.entityID, position: SIMD3<Float>(0, -100, 0))
            entities.append(node.entityID)
        }
        // Assigned once: the game thread iterates this every placement frame.
        ghostEntities = entities
    }

    /// Places the preview at `position` (the floor point under the rim)
    /// facing `facing`. Callable from the game thread every frame.
    public func moveHoopGhost(to position: SIMD3<Float>, facing: SIMD3<Float>) {
        guard ghostEntities.count == 3 else { return }
        let layout = HoopLayout(position: position, facing: facing)
        let placements = [
            layout.poleCenter,
            layout.boardCenter,
            layout.rimCenter,
        ]
        for (entity, target) in zip(ghostEntities, placements) {
            translateTo(entityId: entity, position: target)
            rotateTo(entityId: entity, rotation: layout.orientation)
        }
    }

    public func removeHoopGhost() {
        for entity in ghostEntities {
            destroyEntity(entityId: entity)
        }
        ghostEntities.removeAll()
    }

    // MARK: - Hoop

    /// Builds the hoop with its rim center above `position` (a floor point),
    /// board facing `facing` (horizontal, toward the player). Pole and
    /// backboard are static boxes; the rim is a ring of small static sphere
    /// colliders (smooth ball-rim bounces with plain sphere-sphere math);
    /// a trigger volume under the rim detects made baskets.
    @MainActor public func buildHoop(at position: SIMD3<Float>, facing: SIMD3<Float>) {
        clearHoop()
        let layout = HoopLayout(position: position, facing: facing)
        rimCenter = layout.rimCenter
        hoopForward = layout.forward

        func staticBox(
            node: PrimitiveNode,
            at boxPosition: SIMD3<Float>,
            halfExtents: SIMD3<Float>,
            restitution: Float
        ) {
            let entity = node.entityID
            translateTo(entityId: entity, position: boxPosition)
            rotateTo(entityId: entity, rotation: layout.orientation)
            registerComponent(entityId: entity, componentType: ColliderComponent.self)
            registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
            if let collider = scene.get(component: ColliderComponent.self, for: entity) {
                collider.shape = .box(halfExtents: halfExtents)
                collider.restitution = restitution
                collider.friction = 0.3
            }
            if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
                body.motionType = .static
            }
            hoopPartEntities.append(entity)
        }

        // Pole.
        let pole = CubeNode(size: 1.0, name: "CoolBall.pole")
            .baseColor(0.25, 0.26, 0.30)
            .roughness(0.5)
            .scaleTo(x: 0.08, y: layout.poleHeight, z: 0.08)
        staticBox(
            node: pole,
            at: layout.poleCenter,
            halfExtents: SIMD3<Float>(0.04, layout.poleHeight * 0.5, 0.04),
            restitution: 0.4
        )

        // Backboard — the bank shot's best friend.
        let board = CubeNode(size: 1.0, name: "CoolBall.board")
            .baseColor(1.0, 1.0, 1.0)
            .roughness(0.35)
            .scaleTo(x: Self.boardWidth, y: Self.boardHeight, z: Self.boardThickness)
        if let textureURL = Bundle.module.url(
            forResource: "backboard_baseColor", withExtension: "png"
        ) {
            updateMaterialTexture(
                entityId: board.entityID, textureType: .baseColor, path: textureURL
            )
        }
        staticBox(
            node: board,
            at: layout.boardCenter,
            halfExtents: SIMD3<Float>(
                Self.boardWidth * 0.5, Self.boardHeight * 0.5, Self.boardThickness * 0.5
            ),
            restitution: 0.72
        )

        // Rim: visual segments (a 16-gon of small boxes reads as a torus at
        // this size) carrying the sphere colliders.
        let segmentLength = 2 * Float.pi * Self.rimRadius / Float(Self.rimSegmentCount) * 1.12
        for index in 0 ..< Self.rimSegmentCount {
            let segment = layout.rimSegment(index)
            let node = CubeNode(size: 1.0, name: "CoolBall.rim\(index)")
                .baseColor(0.90, 0.28, 0.08)
                .roughness(0.35)
                .metallic(0.4)
                .scaleTo(
                    x: segmentLength,
                    y: Self.rimTubeRadius * 2,
                    z: Self.rimTubeRadius * 2
                )
            let entity = node.entityID
            translateTo(entityId: entity, position: segment.position)
            rotateTo(entityId: entity, rotation: segment.orientation)
            registerComponent(entityId: entity, componentType: ColliderComponent.self)
            registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
            if let collider = scene.get(component: ColliderComponent.self, for: entity) {
                collider.shape = .sphere(radius: Self.rimColliderRadius)
                collider.restitution = 0.6
                collider.friction = 0.3
            }
            if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
                body.motionType = .static
            }
            hoopPartEntities.append(entity)
        }

        // Basket trigger: a box under the rim mouth. It is open on every
        // side, so by itself it also catches balls drifting in from below or
        // from the side — the game only counts its entry right after a
        // downward crossing of the rim plane inside the ring.
        let triggerNode = Node(name: "CoolBall.basketTrigger")
        basketTriggerEntity = triggerNode.entityID
        translateTo(
            entityId: basketTriggerEntity,
            position: layout.rimCenter - SIMD3<Float>(0, Self.basketTriggerDrop, 0)
        )
        rotateTo(entityId: basketTriggerEntity, rotation: layout.orientation)
        registerComponent(entityId: basketTriggerEntity, componentType: ColliderComponent.self)
        registerComponent(entityId: basketTriggerEntity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: basketTriggerEntity) {
            collider.shape = .box(halfExtents: Self.basketTriggerHalfExtents)
            collider.isTrigger = true
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: basketTriggerEntity) {
            body.motionType = .static
        }
        hoopPartEntities.append(basketTriggerEntity)
    }

    private func clearHoop() {
        for entity in hoopPartEntities {
            destroyEntity(entityId: entity)
        }
        hoopPartEntities.removeAll()
        basketTriggerEntity = .invalid
        rimCenter = nil
        hoopForward = nil
    }

    // MARK: - Body proxies

    /// Invisible kinematic sphere bodies the backend collides the ball
    /// against: the player's hands — they dribble, swat, and (with the pinch
    /// grab in the game logic) catch and throw.
    @MainActor public func createBodyProxies() {
        leftHandEntity = makeKinematicSphere(name: "CoolBall.handL", radius: Self.handRadius)
        rightHandEntity = makeKinematicSphere(name: "CoolBall.handR", radius: Self.handRadius)
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

    /// Moves a kinematic hand proxy to its tracked position, or parks it
    /// when tracking is lost. The coordinator forwards this as the kinematic
    /// target next substep.
    public func moveProxy(_ entity: EntityID, to position: SIMD3<Float>?) {
        guard entity != .invalid else { return }
        translateTo(entityId: entity, position: position ?? SIMD3<Float>(0, -100, 0))
    }

    // MARK: - Teardown

    public func clear() {
        removeAllBalls()
        if leftHandEntity != .invalid { destroyEntity(entityId: leftHandEntity) }
        if rightHandEntity != .invalid { destroyEntity(entityId: rightHandEntity) }
        if sunEntity != .invalid { destroyEntity(entityId: sunEntity) }
        leftHandEntity = .invalid
        rightHandEntity = .invalid
        sunEntity = .invalid
        removeHoopGhost()
        clearHoop()
    }
}
