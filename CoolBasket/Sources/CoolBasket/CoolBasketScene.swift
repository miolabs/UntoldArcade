//
//  CoolBasketScene.swift
//  CoolBasket
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
import SwiftUI
import UntoldEngine

/// Node creation is main-actor (the DSL requirement); runtime mutation uses
/// the engine's lock-backed nonisolated API, callable from the XR game thread.
public final class CoolBasketScene: @unchecked Sendable {
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
    /// The hoop model's pose while it stands (its origin is on the floor
    /// under the glass; local +z faces the player) — the frame the net's
    /// lattice lives in.
    public private(set) var hoopModelOrigin: SIMD3<Float>?
    public private(set) var hoopModelOrientation: simd_quatf?
    /// The model's net parts the simulated net drives (see `CoolBasketNet`).
    public private(set) var netPartEntities: [EntityID] = []

    /// Size-7 basketball: radius ~0.12 m, mass ~0.62 kg — and bouncy.
    public static let ballRadius: Float = 0.121
    public static let ballMass: Float = 0.62
    public static let ballRestitution: Float = 0.78
    /// Regulation rim height, 10 ft; the backboard's top reaches 3.9 m,
    /// through most living-room ceilings, which is the point of the demo.
    public static let rimHeight: Float = 3.05
    /// Regulation rim: 0.23 m inner radius — twice the ball, real shots fit.
    public static let rimRadius: Float = 0.23
    static let rimTubeRadius: Float = 0.02
    /// The rim's collision proxy: a ring of small static spheres, slightly
    /// fatter than the visual tube so bounces feel solid.
    static let rimColliderRadius: Float = 0.032
    static let rimSegmentCount = 16
    /// The hoop model's proportions (a regulation outdoor unit at its own
    /// height): glass, post and base as
    /// measured in the asset, so the invisible colliders sit on the model.
    static let boardWidth: Float = 1.78
    static let boardHeight: Float = 1.02
    static let boardThickness: Float = 0.04
    /// Rim centre to the glass face.
    static let boardSetback: Float = 0.38
    /// The glass's bottom edge hangs this far below the rim.
    static let boardBottomBelowRim: Float = 0.13
    /// The post stands this far behind the glass.
    static let poleSetback: Float = 0.91
    static let poleHalfWidth: Float = 0.115
    static let poleHeight: Float = 2.88
    static let baseHalfWidth: Float = 0.23
    static let baseHeight: Float = 0.46
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
        /// Where the hoop model's origin goes: on the floor under the glass,
        /// centred; its local +z faces the player.
        let modelOrigin: SIMD3<Float>
        let boardCenter: SIMD3<Float>
        let poleCenter: SIMD3<Float>
        let poleHeight: Float
        let baseCenter: SIMD3<Float>

        init(position: SIMD3<Float>, facing: SIMD3<Float>) {
            forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
            let yaw = atan2f(forward.x, forward.z)
            orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

            rimCenter = SIMD3<Float>(
                position.x, position.y + CoolBasketScene.rimHeight, position.z
            )
            modelOrigin = position - forward * CoolBasketScene.boardSetback
            // The glass hangs behind the rim, its bottom edge just under rim
            // level; the collider sits just behind its face.
            boardCenter = modelOrigin
                - forward * (CoolBasketScene.boardThickness * 0.5)
                + SIMD3<Float>(0, CoolBasketScene.rimHeight - CoolBasketScene.boardBottomBelowRim + CoolBasketScene.boardHeight * 0.5, 0)
            // The post and its padded base stand behind the glass.
            poleHeight = CoolBasketScene.poleHeight
            let postFoot = modelOrigin - forward * CoolBasketScene.poleSetback
            poleCenter = postFoot + SIMD3<Float>(0, poleHeight * 0.5, 0)
            baseCenter = postFoot + SIMD3<Float>(0, CoolBasketScene.baseHeight * 0.5, 0)
        }

        /// World position of rim segment `index` (of `rimSegmentCount`), and
        /// the yaw orientation that lays a box's local X along the tangent.
        func rimSegment(_ index: Int) -> (position: SIMD3<Float>, orientation: simd_quatf) {
            let angle = Float(index) / Float(CoolBasketScene.rimSegmentCount) * 2 * .pi
            let up = SIMD3<Float>(0, 1, 0)
            let right = simd_normalize(simd_cross(up, forward))
            let radial = right * cosf(angle) + forward * sinf(angle)
            let tangent = -right * sinf(angle) + forward * cosf(angle)
            let yaw = atan2f(-tangent.z, tangent.x)
            return (
                rimCenter + radial * CoolBasketScene.rimRadius,
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
        // A size-7 basketball model, seams and pebbling baked into its
        // textures, origin at the ball's centre. The engine resolves assets
        // through its search paths, so point them at this package's resource
        // bundle first — the demo loads no other engine assets, so claiming
        // the base path is safe.
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        let entity = createEntity()
        setEntityName(entityId: entity, name: "CoolBasket.ball\(balls.count)")
        setEntityMesh(entityId: entity, filename: "basketball", withExtension: "untold")

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
        let sun = DirectionalLightNode(name: "CoolBasket.sun")
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
            ("CoolBasket.ghostPole", SIMD3<Float>(Self.poleHalfWidth * 2, Self.poleHeight, Self.poleHalfWidth * 2)),
            ("CoolBasket.ghostBoard", SIMD3<Float>(Self.boardWidth, Self.boardHeight, Self.boardThickness)),
            ("CoolBasket.ghostRim", SIMD3<Float>(Self.rimRadius * 2.2, Self.rimTubeRadius * 2, Self.rimRadius * 2.2)),
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
    /// facing `facing` (horizontal, toward the player). The model — post,
    /// arms, glass, rim and net — is one asset; what the ball hits is
    /// invisible and analytic: boxes for the post, base and glass, a ring of
    /// small spheres for the rim (smooth ball-rim bounces with plain
    /// sphere-sphere math), and a trigger volume under the rim for made
    /// baskets.
    @MainActor public func buildHoop(at position: SIMD3<Float>, facing: SIMD3<Float>) {
        clearHoop()
        let layout = HoopLayout(position: position, facing: facing)
        rimCenter = layout.rimCenter
        hoopForward = layout.forward
        hoopModelOrigin = layout.modelOrigin
        hoopModelOrientation = layout.orientation

        let model = createEntity()
        setEntityName(entityId: model, name: "CoolBasket.hoop")
        setEntityMesh(entityId: model, filename: "hoop", withExtension: "untold")
        translateTo(entityId: model, position: layout.modelOrigin)
        rotateTo(entityId: model, rotation: layout.orientation)
        hoopPartEntities.append(model)
        // The model's parts are child entities named after the Blender
        // objects, and their meshes stream in after the load. The exporter
        // writes the glass opaque: remember the glass parts and make them
        // see-through once they have a mesh (`tintHoopGlassIfNeeded`).
        let parts = descendants(of: model)
        hoopGlassEntities = parts.filter {
            getEntityName(entityId: $0).contains("tempered glass")
        }
        netPartEntities = parts.filter { entity in
            let name = getEntityName(entityId: entity)
            return CoolBasketNet.drivenPartNames.contains { name.contains($0) }
        }

        addStaticCollider(name: "CoolBasket.poleCollider", at: layout.poleCenter, orientation: layout.orientation, restitution: 0.4) {
            $0.shape = .box(halfExtents: SIMD3<Float>(Self.poleHalfWidth, layout.poleHeight * 0.5, Self.poleHalfWidth))
        }
        addStaticCollider(name: "CoolBasket.baseCollider", at: layout.baseCenter, orientation: layout.orientation, restitution: 0.3) {
            $0.shape = .box(halfExtents: SIMD3<Float>(Self.baseHalfWidth, Self.baseHeight * 0.5, Self.baseHalfWidth))
        }
        // The glass — the bank shot's best friend.
        addStaticCollider(name: "CoolBasket.boardCollider", at: layout.boardCenter, orientation: layout.orientation, restitution: 0.72) {
            $0.shape = .box(halfExtents: SIMD3<Float>(Self.boardWidth * 0.5, Self.boardHeight * 0.5, Self.boardThickness * 0.5))
        }
        for index in 0 ..< Self.rimSegmentCount {
            let segment = layout.rimSegment(index)
            addStaticCollider(name: "CoolBasket.rim\(index)", at: segment.position, orientation: segment.orientation, restitution: 0.6) {
                $0.shape = .sphere(radius: Self.rimColliderRadius)
            }
        }

        // Basket trigger: a box under the rim mouth. It is open on every
        // side, so by itself it also catches balls drifting in from below or
        // from the side — the game only counts its entry right after a
        // downward crossing of the rim plane inside the ring.
        let triggerNode = Node(name: "CoolBasket.basketTrigger")
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
        hoopGlassEntities.removeAll()
        netPartEntities.removeAll()
        basketTriggerEntity = .invalid
        rimCenter = nil
        hoopForward = nil
        hoopModelOrigin = nil
        hoopModelOrientation = nil
    }

    /// The glass parts of the hoop model still waiting for their mesh.
    private var hoopGlassEntities: [EntityID] = []

    /// Makes the backboard glass see-through as soon as its mesh has
    /// streamed in (an alpha below 1 switches the material to blend). Cheap
    /// once done; the game calls it every frame.
    public func tintHoopGlassIfNeeded() {
        guard !hoopGlassEntities.isEmpty else { return }
        hoopGlassEntities.removeAll { entity in
            guard let render = scene.get(component: RenderComponent.self, for: entity), !render.mesh.isEmpty else { return false }
            for index in render.mesh.indices {
                updateMaterialColor(entityId: entity, color: Color(red: 0.88, green: 0.96, blue: 1.0, opacity: 0.3), meshIndex: index)
            }
            return true
        }
    }

    private func descendants(of entity: EntityID) -> [EntityID] {
        let children = getEntityChildren(parentId: entity)
        return children + children.flatMap { descendants(of: $0) }
    }

    /// An invisible static body owned by the hoop: an entity with no mesh,
    /// just the collider `configure` sets up.
    private func addStaticCollider(
        name: String, at position: SIMD3<Float>, orientation: simd_quatf,
        restitution: Float, friction: Float = 0.3, configure: (ColliderComponent) -> Void
    ) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
        registerComponent(entityId: entity, componentType: ColliderComponent.self)
        registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: entity) {
            configure(collider)
            collider.restitution = restitution
            collider.friction = friction
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
            body.motionType = .static
        }
        hoopPartEntities.append(entity)
    }

    // MARK: - Body proxies

    /// Invisible kinematic sphere bodies the backend collides the ball
    /// against: the player's hands — they dribble, swat, and (with the pinch
    /// grab in the game logic) catch and throw.
    @MainActor public func createBodyProxies() {
        leftHandEntity = makeKinematicSphere(name: "CoolBasket.handL", radius: Self.handRadius)
        rightHandEntity = makeKinematicSphere(name: "CoolBasket.handR", radius: Self.handRadius)
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
