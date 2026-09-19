//
//  CoolBowlingScene.swift
//  CoolBowling
//
//  Entity construction for the bowling demo: a lane with bumpers (static
//  boxes), ten pins (lathe meshes with convex-hull colliders), the ball
//  (dynamic sphere), the placement ghost, and two invisible kinematic hand
//  bodies. Visuals use engine nodes and one bundled USD mesh; physics uses
//  the engine-owned ColliderComponent / RigidBodyComponent vocabulary.
//

import Foundation
import simd
import UntoldEngine

/// Node creation is main-actor (the DSL requirement); runtime mutation uses
/// the engine's lock-backed nonisolated API, callable from the XR game thread.
public final class CoolBowlingScene: @unchecked Sendable {
    public private(set) var ballEntity: EntityID = .invalid
    public private(set) var pinEntities: [EntityID] = []
    private var pinSet: Set<EntityID> = []
    public private(set) var leftHandEntity: EntityID = .invalid
    public private(set) var rightHandEntity: EntityID = .invalid
    public private(set) var sunEntity: EntityID = .invalid
    private var laneEntities: [EntityID] = []
    private var ghostEntities: [EntityID] = []
    /// The lane standing in the room (nil during placement).
    public private(set) var layout: LaneLayout?

    /// Re-racks the pins visually as well (the backend teleport is the
    /// game's; this keeps the entity transforms in step until read-back).
    public func standPin(_ entity: EntityID, at position: SIMD3<Float>, orientation: simd_quatf) {
        guard isPin(entity) else { return }
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
    }

    /// Regulation ball: 8.5 in across, up to 16 lb; 6 kg here.
    public static let ballRadius: Float = 0.108
    public static let ballMass: Float = 6.0
    public static let ballRestitution: Float = 0.15
    public static let ballFriction: Float = 0.3
    /// Living-room lane: regulation width, a quarter of regulation length.
    public static let laneWidth: Float = 1.06
    public static let laneLength: Float = 4.5
    public static let laneThickness: Float = 0.02
    /// Oiled maple: the ball slides more than it grips.
    static let laneFriction: Float = 0.08
    static let bumperWidth: Float = 0.08
    static let bumperHeight: Float = 0.12
    /// The pit wall behind the deck: the ball and the pins stop there.
    static let backstopHeight: Float = 0.35
    static let backstopThickness: Float = 0.06
    /// Regulation pin: 15 in tall, 4.75 in at the belly, 3 lb 6 oz.
    public static let pinHeight: Float = 0.381
    public static let pinMaxRadius: Float = 0.0605
    public static let pinMass: Float = 1.53
    /// Pin centres 12 in apart on the deck; the head pin this far from the
    /// foul line, leaving a pit of more than a pin's length behind the back
    /// row so a pin knocked backward falls flat instead of leaning on the wall.
    public static let pinSpacing: Float = 0.3048
    public static let pinDeckDistance: Float = laneLength - 1.6
    static let handRadius: Float = 0.07

    public init() {}

    // MARK: - Lane layout

    /// Shared placement math for the ghost and the real lane: `foul` is the
    /// floor point at the centre of the foul line, `facing` points from the
    /// player down the lane toward the pins.
    public struct LaneLayout {
        public let foul: SIMD3<Float>
        public let forward: SIMD3<Float> // toward the pins
        public let right: SIMD3<Float>
        public let orientation: simd_quatf
        public let laneCenter: SIMD3<Float>
        /// Height of the lane surface.
        public let surfaceY: Float
        /// Where each of the ten pins stands (base centre), in the usual
        /// numbering: 1; 2, 3; 4, 5, 6; 7, 8, 9, 10.
        public let pinPositions: [SIMD3<Float>]

        public init(foul: SIMD3<Float>, facing: SIMD3<Float>) {
            self.foul = foul
            forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
            right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))) // the player's right
            let yaw = atan2f(forward.x, forward.z)
            orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            surfaceY = foul.y + CoolBowlingScene.laneThickness
            laneCenter = foul + forward * (CoolBowlingScene.laneLength * 0.5)
                + SIMD3<Float>(0, CoolBowlingScene.laneThickness * 0.5, 0)

            let apex = foul + forward * CoolBowlingScene.pinDeckDistance
            let rowSpacing = CoolBowlingScene.pinSpacing * 0.8660254 // sin 60°
            var positions: [SIMD3<Float>] = []
            for row in 0 ..< 4 {
                let rowCenter = apex + forward * (Float(row) * rowSpacing)
                for column in 0 ... row {
                    let lateral = (Float(column) - Float(row) * 0.5) * CoolBowlingScene.pinSpacing
                    positions.append(SIMD3<Float>(
                        rowCenter.x + right.x * lateral,
                        surfaceY,
                        rowCenter.z + right.z * lateral
                    ))
                }
            }
            pinPositions = positions
        }

        func bumperCenter(side: Float) -> SIMD3<Float> {
            laneCenter
                + right * (side * (CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth * 0.5))
                + SIMD3<Float>(0, CoolBowlingScene.bumperHeight * 0.5 - CoolBowlingScene.laneThickness * 0.5, 0)
        }
    }

    /// The pin's collision proxy: its profile revolved in eight steps
    /// (origin at the base, like the mesh).
    public static let pinHullVertices: [SIMD3<Float>] = {
        let profile: [(r: Float, y: Float)] = [
            (0.030, 0.000), (0.058, 0.060), (0.0605, 0.110), (0.050, 0.190),
            (0.026, 0.290), (0.036, 0.340), (0.010, 0.381),
        ]
        var vertices: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, pinHeight, 0)]
        for point in profile {
            for segment in 0 ..< 8 {
                let angle = Float(segment) / 8 * 2 * .pi
                vertices.append(SIMD3<Float>(point.r * cosf(angle), point.y, point.r * sinf(angle)))
            }
        }
        return vertices
    }()

    // MARK: - Ball

    /// Creates the ball at `position` as a dynamic body, at rest.
    @MainActor public func spawnBall(at position: SIMD3<Float>) {
        if ballEntity != .invalid {
            destroyEntity(entityId: ballEntity)
        }
        let node = SphereNode(
            radius: Self.ballRadius,
            segments: [32, 24],
            name: "CoolBowling.ball"
        )
        .baseColor(1.0, 1.0, 1.0)
        .roughness(0.18)
        .metallic(0.0)
        ballEntity = node.entityID
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        if let textureURL = Bundle.module.url(forResource: "bowlingball_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: ballEntity, textureType: .baseColor, path: textureURL)
        }
        fitSphereVisual(entity: ballEntity, radius: Self.ballRadius)
        translateTo(entityId: ballEntity, position: position)
        attachBallBody(velocity: .zero, at: position)
    }

    /// Makes a sphere node's visual match `radius`: the engine builds spheres
    /// with ModelIO's `sphereWithExtent`, which takes a radius where the
    /// engine passes a diameter (fixed upstream in untoldengine/UntoldEngine
    /// #1213); measuring the bounds keeps this right on either version.
    private func fitSphereVisual(entity: EntityID, radius: Float) {
        guard let bounds = scene.get(component: LocalTransformComponent.self, for: entity)?.boundingBox else { return }
        let measured = (bounds.max.x - bounds.min.x) * 0.5
        guard measured > radius * 0.5, measured < radius * 4.0 else { return }
        let factor = radius / measured
        guard abs(factor - 1.0) > 0.01 else { return }
        scaleTo(entityId: entity, scale: SIMD3<Float>(repeating: factor))
    }

    public func attachBallBody(velocity: SIMD3<Float>, at position: SIMD3<Float>) {
        guard ballEntity != .invalid else { return }
        translateTo(entityId: ballEntity, position: position)
        registerComponent(entityId: ballEntity, componentType: ColliderComponent.self)
        registerComponent(entityId: ballEntity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: ballEntity) {
            collider.shape = .sphere(radius: Self.ballRadius)
            collider.restitution = Self.ballRestitution
            collider.friction = Self.ballFriction
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: ballEntity) {
            body.motionType = .dynamic
            body.mass = Self.ballMass
            body.initialLinearVelocity = velocity
        }
    }

    /// Takes the ball out of simulation while held; the coordinator's next
    /// substep removes the body through the component diff.
    public func detachBallBody() {
        guard ballEntity != .invalid else { return }
        scene.remove(component: RigidBodyComponent.self, from: ballEntity)
        scene.remove(component: ColliderComponent.self, from: ballEntity)
    }

    public func moveBall(to position: SIMD3<Float>) {
        guard ballEntity != .invalid else { return }
        translateTo(entityId: ballEntity, position: position)
    }

    public func ballPosition() -> SIMD3<Float>? {
        guard ballEntity != .invalid else { return nil }
        return scene.get(component: LocalTransformComponent.self, for: ballEntity)?.position
    }

    // MARK: - Pins

    public func isPin(_ entity: EntityID) -> Bool {
        pinSet.contains(entity)
    }

    /// Current pose of a pin: its base position and its up vector.
    public func pinPose(_ entity: EntityID) -> (position: SIMD3<Float>, up: SIMD3<Float>)? {
        guard let transform = scene.get(component: LocalTransformComponent.self, for: entity) else { return nil }
        return (transform.position, transform.rotation.act(SIMD3<Float>(0, 1, 0)))
    }

    /// A pin counts as down when it leans past ~45° or left its spot.
    public static func isPinDown(up: SIMD3<Float>, displacement: Float) -> Bool {
        up.y < 0.7 || displacement > 0.25
    }

    /// Built once per lane and shared by the ten pins.
    private var pinMeshes: [Mesh] = []

    @MainActor private func spawnPin(at position: SIMD3<Float>, index: Int, orientation: simd_quatf) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: "CoolBowling.pin\(index + 1)")
        if pinMeshes.isEmpty {
            pinMeshes = CoolBowlingPinMesh.makeMeshes()
        }
        setEntityMeshDirect(entityId: entity, meshes: pinMeshes, assetName: "BowlingPin")
        if let textureURL = Bundle.module.url(forResource: "pin_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: entity, textureType: .baseColor, path: textureURL)
        }
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
        registerComponent(entityId: entity, componentType: ColliderComponent.self)
        registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: entity) {
            collider.shape = .convexHull(vertices: Self.pinHullVertices)
            collider.restitution = 0.3
            collider.friction = 0.5
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
            body.motionType = .dynamic
            body.mass = Self.pinMass
        }
        pinEntities.append(entity)
        pinSet.insert(entity)
    }

    // MARK: - Lighting

    @MainActor public func addLighting() {
        guard sunEntity == .invalid else { return }
        let sun = DirectionalLightNode(name: "CoolBowling.sun")
            .color(1.0, 0.98, 0.92)
            .intensity(2.0)
            .rotateBy(angle: -50, axis: [.x])
            .rotateBy(angle: 30, axis: [.y])
        sunEntity = sun.entityID
    }

    // MARK: - Placement ghost

    /// Translucent preview: the lane slab and a marker on the pin deck.
    @MainActor public func buildLaneGhost() {
        removeLaneGhost()
        var entities: [EntityID] = []
        for (name, scale) in [
            ("CoolBowling.ghostLane", SIMD3<Float>(Self.laneWidth, Self.laneThickness, Self.laneLength)),
            ("CoolBowling.ghostDeck", SIMD3<Float>(Self.pinSpacing * 3.4, 0.05, Self.pinSpacing * 3.0)),
        ] {
            let node = CubeNode(size: 1.0, name: name)
                .baseColor(0.45, 0.8, 1.0, 0.4)
                .roughness(0.3)
                .scaleTo(x: scale.x, y: scale.y, z: scale.z)
            updateMaterialAlphaMode(entityId: node.entityID, mode: .blend)
            translateTo(entityId: node.entityID, position: SIMD3<Float>(0, -100, 0))
            entities.append(node.entityID)
        }
        ghostEntities = entities
    }

    public func moveLaneGhost(foul: SIMD3<Float>, facing: SIMD3<Float>) {
        guard ghostEntities.count == 2 else { return }
        let layout = LaneLayout(foul: foul, facing: facing)
        let deckCenter = foul + layout.forward * (Self.pinDeckDistance + Self.pinSpacing * 1.3)
            + SIMD3<Float>(0, Self.laneThickness + 0.025, 0)
        for (entity, target) in zip(ghostEntities, [layout.laneCenter, deckCenter]) {
            translateTo(entityId: entity, position: target)
            rotateTo(entityId: entity, rotation: layout.orientation)
        }
    }

    public func removeLaneGhost() {
        for entity in ghostEntities {
            destroyEntity(entityId: entity)
        }
        ghostEntities.removeAll()
    }

    // MARK: - Lane

    /// Builds the lane, bumpers and the ten pins for `layout`.
    @MainActor public func buildLane(_ layout: LaneLayout) {
        clearLane()
        self.layout = layout

        func staticBox(node: PrimitiveNode, at position: SIMD3<Float>, halfExtents: SIMD3<Float>, friction: Float, restitution: Float) {
            let entity = node.entityID
            translateTo(entityId: entity, position: position)
            rotateTo(entityId: entity, rotation: layout.orientation)
            registerComponent(entityId: entity, componentType: ColliderComponent.self)
            registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
            if let collider = scene.get(component: ColliderComponent.self, for: entity) {
                collider.shape = .box(halfExtents: halfExtents)
                collider.restitution = restitution
                collider.friction = friction
            }
            if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
                body.motionType = .static
            }
            laneEntities.append(entity)
        }

        // The lane surface: a slab lying on the floor.
        let lane = CubeNode(size: 1.0, name: "CoolBowling.lane")
            .baseColor(1.0, 1.0, 1.0)
            .roughness(0.25)
            .scaleTo(x: Self.laneWidth, y: Self.laneThickness, z: Self.laneLength)
        if let textureURL = Bundle.module.url(forResource: "lane_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: lane.entityID, textureType: .baseColor, path: textureURL)
        }
        staticBox(
            node: lane, at: layout.laneCenter,
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5, Self.laneThickness * 0.5, Self.laneLength * 0.5),
            friction: Self.laneFriction, restitution: 0.1
        )

        // Bumpers keep the ball on the lane (no gutter balls in the living room).
        for side: Float in [-1, 1] {
            let bumper = CubeNode(size: 1.0, name: "CoolBowling.bumper\(side > 0 ? "R" : "L")")
                .baseColor(0.16, 0.17, 0.22)
                .roughness(0.6)
                .scaleTo(x: Self.bumperWidth, y: Self.bumperHeight, z: Self.laneLength)
            staticBox(
                node: bumper, at: layout.bumperCenter(side: side),
                halfExtents: SIMD3<Float>(Self.bumperWidth * 0.5, Self.bumperHeight * 0.5, Self.laneLength * 0.5),
                friction: 0.3, restitution: 0.35
            )
        }

        // The pit wall behind the deck keeps the ball and the pins in the alley.
        let backstop = CubeNode(size: 1.0, name: "CoolBowling.backstop")
            .baseColor(0.16, 0.17, 0.22)
            .roughness(0.6)
            .scaleTo(x: Self.laneWidth + Self.bumperWidth * 2, y: Self.backstopHeight, z: Self.backstopThickness)
        staticBox(
            node: backstop,
            at: layout.foul + layout.forward * (Self.laneLength + Self.backstopThickness * 0.5)
                + SIMD3<Float>(0, Self.backstopHeight * 0.5, 0),
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5 + Self.bumperWidth, Self.backstopHeight * 0.5, Self.backstopThickness * 0.5),
            friction: 0.5, restitution: 0.2
        )

        // Pins face the player like the lane does.
        for (index, position) in layout.pinPositions.enumerated() {
            spawnPin(at: position, index: index, orientation: layout.orientation)
        }
    }

    private func clearLane() {
        for entity in laneEntities {
            destroyEntity(entityId: entity)
        }
        laneEntities.removeAll()
        for entity in pinEntities {
            destroyEntity(entityId: entity)
        }
        pinEntities.removeAll()
        pinSet.removeAll()
        layout = nil
    }

    // MARK: - Body proxies

    /// Invisible kinematic sphere bodies the backend collides everything
    /// against: the player's hands.
    @MainActor public func createBodyProxies() {
        leftHandEntity = makeKinematicSphere(name: "CoolBowling.handL", radius: Self.handRadius)
        rightHandEntity = makeKinematicSphere(name: "CoolBowling.handR", radius: Self.handRadius)
    }

    private func makeKinematicSphere(name: String, radius: Float) -> EntityID {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
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
    /// when tracking is lost.
    public func moveProxy(_ entity: EntityID, to position: SIMD3<Float>?) {
        guard entity != .invalid else { return }
        translateTo(entityId: entity, position: position ?? SIMD3<Float>(0, -100, 0))
    }

    // MARK: - Teardown

    public func clear() {
        if ballEntity != .invalid { destroyEntity(entityId: ballEntity) }
        if leftHandEntity != .invalid { destroyEntity(entityId: leftHandEntity) }
        if rightHandEntity != .invalid { destroyEntity(entityId: rightHandEntity) }
        if sunEntity != .invalid { destroyEntity(entityId: sunEntity) }
        ballEntity = .invalid
        leftHandEntity = .invalid
        rightHandEntity = .invalid
        sunEntity = .invalid
        removeLaneGhost()
        clearLane()
    }
}
