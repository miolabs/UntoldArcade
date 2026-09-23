//
//  CoolBowlingScene.swift
//  CoolBowling
//
//  Entity construction for the bowling demo: the alley as the studio's
//  Blender scene — the parquet approach with the ball return unit on it,
//  the lane with its gutters and rails at the scene's full length,
//  the aiming arrows and deck spots, the pinsetter cover behind the deck,
//  ten pins and the ball — all artist models (`Resources/Models/*.untold`)
//  — plus the placement ghost and two invisible kinematic hand bodies.
//  What the models look like and what they collide with are separate: the
//  pins carry a convex hull of the regulation profile, the ball a sphere,
//  the lane's surface and the rails are invisible boxes, so are the cover's
//  walls and the return unit's rails (the ball comes up through the hood;
//  the track from the pit is under the floor, like a real alley's), and the
//  gutters and the approach are the room's floor. Visuals use meshes;
//  physics uses the engine-owned ColliderComponent /
//  RigidBodyComponent vocabulary.
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

    /// Regulation ball: 8.5 in across, up to 16 lb; 6 kg here.
    public static let ballRadius: Float = 0.108
    public static let ballMass: Float = 6.0
    public static let ballRestitution: Float = 0.15
    public static let ballFriction: Float = 0.3
    /// The alley is the studio's Blender scene, foul line at the origin: the
    /// lane's maple strips between concave gutters with walnut rails at the
    /// outer edges, a parquet approach behind the foul line with the ball
    /// return unit standing on it, and the pinsetter cover behind the deck.
    /// The lane is the scene's regulation length, so the alley runs through
    /// the room's walls: `laneLength` stretches or shortens the lane asset.
    public static let laneWidth: Float = 1.06
    public static let laneLength: Float = 19.16
    /// Length of the lane asset as modelled (foul line to the deck's end).
    static let laneAssetLength: Float = 19.16
    /// The lane surface lies on the floor, like the scene's.
    public static let laneSurfaceHeight: Float = 0
    /// Gutters flank the lane; the rails at their outer edge keep the ball in.
    public static let railX: Float = 0.865
    static let railHeight: Float = 0.06
    static let railThickness: Float = 0.02
    /// The parquet approach behind the foul line.
    public static let approachWidth: Float = 3.35
    public static let approachLength: Float = 4.57
    /// Oiled maple: the ball slides more than it grips.
    static let laneFriction: Float = 0.08
    /// The pinsetter cover stands behind the lane's end; the pit is the
    /// dark space under it, at floor level in the room (the scene's is a
    /// recess). Its rear panel is the backstop.
    public static let pitLength: Float = 1.6
    static let pitCoverCenterOffset: Float = 0.815
    static let pitCoverHalfWidth: Float = 1.0
    static let backstopThickness: Float = 0.06
    /// Regulation pin: 15 in tall, 4.75 in at the belly, 3 lb 6 oz.
    public static let pinHeight: Float = 0.381
    public static let pinMaxRadius: Float = 0.0605
    public static let pinMass: Float = 1.53
    /// Pin centres 12 in apart on the deck; the head pin 0.87 m before the
    /// lane's end, as in the scene.
    public static let pinSpacing: Float = 0.3048
    public static let pinDeckDistance: Float = laneLength - 0.87
    /// The deck's locating spots sit 0.395 m behind the head pin's centre;
    /// the aiming arrows 4.4 m down the lane, as in the scene.
    static let deckSpotsOffset: Float = 0.395
    static let arrowsFraction: Float = 0.23
    static let inlayLift: Float = 0.0015
    /// The ball return unit stands on the approach at the scene's spot: its
    /// centre line 1.08 m left of the lane's, its rubber stop 3.33 m and the
    /// back of its hood 0.60 m behind the foul line. The ball comes up
    /// through the hood and rolls along the unit's rails to the stop. The
    /// rails are invisible boxes inside the model: the ball rests on the
    /// unit's cheeks with its centre 0.57 m up, as the scene's balls do, so
    /// the floor's top is `returnRackHeight` at the stop, rising
    /// `returnSlope` toward the hood so the ball always settles at the stop.
    public static let returnCenterX: Float = -1.08
    public static let returnStopZ: Float = -3.33
    public static let returnHoodBackZ: Float = -0.60
    static let returnUnitCenterZ: Float = -2.055
    public static let returnInnerWidth: Float = 0.26
    static let returnRailThickness: Float = 0.03
    static let returnRailHeight: Float = 0.12
    static let returnFloorThickness: Float = 0.03
    public static let returnRackHeight: Float = 0.46
    public static let returnSlope: Float = 1.0 * .pi / 180
    public static let returnSpeed: Float = 1.0
    /// The physics rack stop's centre, past the near end of the rails.
    static let returnRackStopInset: Float = 0.02
    static let handRadius: Float = 0.07

    public init() {}

    // MARK: - Lane layout

    /// Shared placement math for the ghost and the real alley: `foul` is the
    /// floor point at the centre of the foul line, `facing` points from the
    /// player down the lane toward the pins. Lane-local coordinates are the
    /// scene's: x to the player's right, y up from the floor, z down the
    /// lane from the foul line.
    public struct LaneLayout {
        public let foul: SIMD3<Float>
        public let forward: SIMD3<Float> // toward the pins
        public let right: SIMD3<Float>
        public let orientation: simd_quatf
        /// Centre of the lane's surface.
        public let laneCenter: SIMD3<Float>
        /// Height of the lane surface (the floor).
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
            surfaceY = foul.y + CoolBowlingScene.laneSurfaceHeight
            laneCenter = foul + forward * (CoolBowlingScene.laneLength * 0.5)

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

        // MARK: Lane-local frame

        public func localPoint(_ world: SIMD3<Float>) -> SIMD3<Float> {
            let offset = world - foul
            return SIMD3<Float>(simd_dot(offset, right), offset.y, simd_dot(offset, forward))
        }

        public func worldPoint(_ local: SIMD3<Float>) -> SIMD3<Float> {
            foul + right * local.x + SIMD3<Float>(0, local.y, 0) + forward * local.z
        }

        /// The models' fronts are their local +z; the lane's +z points at the
        /// pins, so a model that faces the player turns around.
        public var facingPlayerOrientation: simd_quatf {
            orientation * simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        }

        /// Assets exported in the scene's own coordinates: the scene's "down
        /// the lane" (+y in Blender) comes out of the exporter as −z, so they
        /// turn around too to run toward the pins (they are symmetric in x).
        public var sceneOrientation: simd_quatf {
            facingPlayerOrientation
        }

        // MARK: The pit and the cover

        /// Lane-local z of the pinsetter cover's origin (its footprint centre).
        public var pitCoverCenterZ: Float {
            CoolBowlingScene.laneLength + CoolBowlingScene.pitCoverCenterOffset
        }

        /// Lane-local z of the cover's rear panel, the backstop.
        public var pitRearZ: Float {
            CoolBowlingScene.laneLength + CoolBowlingScene.pitLength
        }

        /// The ball has rolled off the lane's end into the dark under the
        /// cover, whatever it landed on (the floor, or a pile of pins).
        public func isInPit(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            return local.z > CoolBowlingScene.laneLength + CoolBowlingScene.ballRadius * 0.5
                && local.z < pitRearZ + CoolBowlingScene.backstopThickness
                && local.y < 0.45
                && abs(local.x) < CoolBowlingScene.pitCoverHalfWidth
        }

        /// Inside the alley's footprint (approach, lane with its gutters,
        /// the cover), at any height.
        public func isOverAlley(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            guard local.z > -CoolBowlingScene.approachLength - 0.05, local.z < pitRearZ + 0.1 else { return false }
            if local.z < 0 {
                return abs(local.x) < CoolBowlingScene.approachWidth * 0.5 + 0.05
            }
            if local.z < CoolBowlingScene.laneLength {
                return abs(local.x) < CoolBowlingScene.railX + 0.05
            }
            return abs(local.x) < CoolBowlingScene.pitCoverHalfWidth + 0.05
        }

        /// On the real floor outside the alley: a ball that jumped a rail.
        public func isLost(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            return !isOverAlley(world) && !isOnReturn(world) && local.y < 0.3
        }

        // MARK: The ball return

        /// The rails run from the rubber stop to the back of the hood, both
        /// behind the foul line.
        public var returnNearZ: Float { CoolBowlingScene.returnStopZ }
        public var returnFarZ: Float { CoolBowlingScene.returnHoodBackZ }
        public var returnLength: Float { returnFarZ - returnNearZ }
        public var returnCenterX: Float { CoolBowlingScene.returnCenterX }

        /// Lane-local z of the physics rack stop, which the ball rests against.
        var returnRackStopZ: Float { returnNearZ + CoolBowlingScene.returnRackStopInset }

        /// Height of the rails' floor at lane-local `z`: the stop is the low
        /// end, so the ball rolls toward the player.
        public func returnFloorTop(atZ z: Float) -> Float {
            CoolBowlingScene.returnRackHeight + (z - returnNearZ) * tanf(CoolBowlingScene.returnSlope)
        }

        /// Where a returned ball reappears: inside the hood, as if it had
        /// come up from under the floor…
        public var returnStart: SIMD3<Float> {
            let z = returnFarZ - 0.45
            return worldPoint(SIMD3<Float>(returnCenterX, returnFloorTop(atZ: z) + CoolBowlingScene.ballRadius + 0.02, z))
        }

        /// …rolling toward the player.
        public var returnVelocity: SIMD3<Float> {
            -forward * CoolBowlingScene.returnSpeed
        }

        /// Where the ball comes to rest against the rack, waiting to be picked up.
        public var rackPoint: SIMD3<Float> {
            let z = returnNearZ + 0.04 + CoolBowlingScene.ballRadius
            return worldPoint(SIMD3<Float>(returnCenterX, returnFloorTop(atZ: z) + CoolBowlingScene.ballRadius, z))
        }

        /// On the unit's rails, from the stop to the back of the hood.
        public func isOnReturn(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            guard abs(local.x - returnCenterX) < CoolBowlingScene.returnInnerWidth * 0.5 + 0.05,
                  local.z > returnNearZ - 0.05, local.z < returnFarZ + 0.05 else { return false }
            let floorTop = returnFloorTop(atZ: local.z)
            return local.y > floorTop - 0.05 && local.y < floorTop + 0.4
        }

        /// Waiting at the rack (within a ball's reach of the rack point).
        public func isAtRack(_ world: SIMD3<Float>) -> Bool {
            simd_length(world - rackPoint) < CoolBowlingScene.ballRadius * 2.5
        }

        // MARK: Real surfaces

        /// Real surfaces inside this box — the approach, the lane, the cover
        /// and the air above them, but not the floor — stay out of the
        /// simulation, so a chair on the lane doesn't stop the ball.
        public var keepOut: CoolBowlingKeepOutBox {
            let halfX = CoolBowlingScene.approachWidth * 0.5 + 0.05
            let minY: Float = 0.06
            let maxY: Float = 2.2
            let minZ = -CoolBowlingScene.approachLength - 0.1
            let maxZ = pitRearZ + 0.2
            let localCenter = SIMD3<Float>(0, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
            return CoolBowlingKeepOutBox(
                center: worldPoint(localCenter),
                right: right, up: SIMD3<Float>(0, 1, 0), forward: forward,
                halfExtents: SIMD3<Float>(halfX, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5),
                floorY: foul.y
            )
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

    /// Creates the ball at `position` as a dynamic body: the marbled ball
    /// model (origin at its centre, `ballRadius` across), sphere collider.
    @MainActor public func spawnBall(at position: SIMD3<Float>, velocity: SIMD3<Float> = .zero) {
        if ballEntity != .invalid {
            destroyEntity(entityId: ballEntity)
        }
        Self.claimAssetBasePath()
        ballEntity = createEntity()
        setEntityName(entityId: ballEntity, name: "CoolBowling.ball")
        setEntityMesh(entityId: ballEntity, filename: "bowlingball", withExtension: "untold")
        translateTo(entityId: ballEntity, position: position)
        attachBallBody(velocity: velocity, at: position)
    }

    /// The engine resolves `Models/<name>/<name>.untold` under its asset
    /// base path; this package's resource bundle is the only one the demo
    /// loads from, so claiming it is safe.
    private static func claimAssetBasePath() {
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
    }

    /// Gives the ball its physics components (back) at `position`, moving
    /// at `velocity`. Safe to call when it still has them: the fields are
    /// refreshed, nothing is registered twice.
    public func attachBallBody(velocity: SIMD3<Float>, at position: SIMD3<Float>) {
        guard ballEntity != .invalid else { return }
        translateTo(entityId: ballEntity, position: position)
        if scene.get(component: ColliderComponent.self, for: ballEntity) == nil {
            registerComponent(entityId: ballEntity, componentType: ColliderComponent.self)
        }
        if scene.get(component: RigidBodyComponent.self, for: ballEntity) == nil {
            registerComponent(entityId: ballEntity, componentType: RigidBodyComponent.self)
        }
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

    /// Deadwood taken off the deck between the two balls of a frame.
    private var parkedPins: Set<EntityID> = []

    public func isPinParked(_ entity: EntityID) -> Bool {
        parkedPins.contains(entity)
    }

    /// Takes a fallen pin out of play and out of sight; the coordinator's
    /// next substep removes its body through the component diff.
    public func parkPin(_ entity: EntityID) {
        guard isPin(entity), !parkedPins.contains(entity) else { return }
        scene.remove(component: RigidBodyComponent.self, from: entity)
        scene.remove(component: ColliderComponent.self, from: entity)
        translateTo(entityId: entity, position: SIMD3<Float>(0, -100, 0))
        parkedPins.insert(entity)
    }

    /// Stands a pin on `position`. A parked pin gets a fresh body there and
    /// the call returns true; a pin still in play only has its entity
    /// transform set (the caller teleports its body through the backend).
    @discardableResult
    public func restorePin(_ entity: EntityID, at position: SIMD3<Float>, orientation: simd_quatf) -> Bool {
        guard isPin(entity) else { return false }
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
        guard parkedPins.remove(entity) != nil else { return false }
        attachPinBody(entity)
        return true
    }

    private func attachPinBody(_ entity: EntityID) {
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

    /// A pin: the model (origin at the base centre, the regulation 0.121 m
    /// by 0.381 m the hull was built to) with the convex-hull body.
    @MainActor private func spawnPin(at position: SIMD3<Float>, index: Int, orientation: simd_quatf) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: "CoolBowling.pin\(index + 1)")
        setEntityMesh(entityId: entity, filename: "pin", withExtension: "untold")
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
        attachPinBody(entity)
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

    /// Translucent preview of the alley's footprint: the lane, the approach,
    /// the pinsetter cover and the ball return unit.
    @MainActor public func buildLaneGhost() {
        removeLaneGhost()
        var entities: [EntityID] = []
        for (name, scale) in [
            ("CoolBowling.ghostLane", SIMD3<Float>(Self.railX * 2, 0.03, Self.laneLength)),
            ("CoolBowling.ghostApproach", SIMD3<Float>(Self.approachWidth, 0.03, Self.approachLength)),
            ("CoolBowling.ghostPit", SIMD3<Float>(Self.pitCoverHalfWidth * 2, 1.13, Self.pitLength)),
            ("CoolBowling.ghostReturn", SIMD3<Float>(0.42, 0.79, 2.98)),
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
        guard ghostEntities.count == 4 else { return }
        let layout = LaneLayout(foul: foul, facing: facing)
        let targets = [
            layout.worldPoint(SIMD3<Float>(0, 0.015, Self.laneLength * 0.5)),
            layout.worldPoint(SIMD3<Float>(0, 0.015, -Self.approachLength * 0.5)),
            layout.worldPoint(SIMD3<Float>(0, 0.565, layout.pitCoverCenterZ)),
            layout.worldPoint(SIMD3<Float>(Self.returnCenterX, 0.395, Self.returnUnitCenterZ)),
        ]
        for (entity, target) in zip(ghostEntities, targets) {
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

    /// Builds the alley for `layout` from the scene's models, in the scene's
    /// own coordinates (foul line at the origin): the approach with the
    /// return unit on it, the lane (`laneLength`, the scene's 19 m) with its
    /// gutters and rails, the arrows and deck spots, the pinsetter cover,
    /// and the ten pins. What the ball hits is invisible and analytic: the
    /// lane's surface, the rails, the cover's walls, the return's rails.
    /// The gutters and the approach are the room's floor.
    @MainActor public func buildLane(_ layout: LaneLayout) {
        clearLane()
        self.layout = layout

        placeModel("CoolBowling.approach", asset: "approach", at: layout.worldPoint(.zero), orientation: layout.sceneOrientation)
        let lane = placeModel("CoolBowling.lane", asset: "lane", at: layout.worldPoint(.zero), orientation: layout.sceneOrientation)
        scaleTo(entityId: lane, scale: SIMD3<Float>(1, 1, Self.laneLength / Self.laneAssetLength))
        // Inlays a hair above the strips, or they fight the surface for depth.
        placeModel("CoolBowling.arrows", asset: "arrows",
                   at: layout.worldPoint(SIMD3<Float>(0, Self.inlayLift, Self.laneLength * Self.arrowsFraction)), orientation: layout.sceneOrientation)
        placeModel("CoolBowling.deckSpots", asset: "deckspots",
                   at: layout.worldPoint(SIMD3<Float>(0, Self.inlayLift, Self.pinDeckDistance + Self.deckSpotsOffset)), orientation: layout.sceneOrientation)
        placeModel("CoolBowling.pitCover", asset: "pitcover",
                   at: layout.worldPoint(SIMD3<Float>(0, 0, layout.pitCoverCenterZ)), orientation: layout.facingPlayerOrientation)

        // The lane's surface, a hair above the floor so the ball rides its
        // oiled friction; the gutters are the floor itself.
        addInvisibleStaticBox(
            "CoolBowling.laneSurface",
            at: layout.worldPoint(SIMD3<Float>(0, -0.005, Self.laneLength * 0.5)),
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5, 0.01, Self.laneLength * 0.5),
            orientation: layout.orientation, friction: Self.laneFriction, restitution: 0.1
        )
        // The walnut rails at the gutters' outer edges keep a gutter ball in.
        for side: Float in [-1, 1] {
            addInvisibleStaticBox(
                "CoolBowling.rail\(side > 0 ? "R" : "L")",
                at: layout.worldPoint(SIMD3<Float>(side * Self.railX, Self.railHeight * 0.5, Self.laneLength * 0.5)),
                halfExtents: SIMD3<Float>(Self.railThickness * 0.5, Self.railHeight * 0.5, Self.laneLength * 0.5),
                orientation: layout.orientation, friction: 0.3, restitution: 0.3
            )
        }
        // The cover's walls: its rear panel is the backstop.
        addInvisibleStaticBox(
            "CoolBowling.backstop",
            at: layout.worldPoint(SIMD3<Float>(0, 0.5, layout.pitRearZ + Self.backstopThickness * 0.5)),
            halfExtents: SIMD3<Float>(Self.pitCoverHalfWidth, 0.5, Self.backstopThickness * 0.5),
            orientation: layout.orientation, friction: 0.5, restitution: 0.2
        )
        for side: Float in [-1, 1] {
            addInvisibleStaticBox(
                "CoolBowling.pitWall\(side > 0 ? "R" : "L")",
                at: layout.worldPoint(SIMD3<Float>(side * Self.pitCoverHalfWidth, 0.5, Self.laneLength + Self.pitLength * 0.5)),
                halfExtents: SIMD3<Float>(0.03, 0.5, Self.pitLength * 0.5),
                orientation: layout.orientation, friction: 0.5, restitution: 0.2
            )
        }

        buildBallReturn(layout)

        // Pins face the player like the lane does.
        for (index, position) in layout.pinPositions.enumerated() {
            spawnPin(at: position, index: index, orientation: layout.orientation)
        }
    }

    /// The ball return: the unit model standing on the approach, with an
    /// invisible sloped floor, rails and two end stops inside it that the
    /// ball actually rolls on, from the back of the hood to the rubber stop.
    @MainActor private func buildBallReturn(_ layout: LaneLayout) {
        let tilt = simd_quatf(angle: -Self.returnSlope, axis: SIMD3<Float>(1, 0, 0))
        let orientation = layout.orientation * tilt
        let up = orientation.act(SIMD3<Float>(0, 1, 0))
        let outerWidth = Self.returnInnerWidth + Self.returnRailThickness * 2
        let midZ = (layout.returnNearZ + layout.returnFarZ) * 0.5
        let topMid = layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: midZ), midZ))
        let halfLength = layout.returnLength * 0.5 / cosf(Self.returnSlope)

        addInvisibleStaticBox(
            "CoolBowling.returnFloor", at: topMid - up * (Self.returnFloorThickness * 0.5),
            halfExtents: SIMD3<Float>(outerWidth * 0.5, Self.returnFloorThickness * 0.5, halfLength),
            orientation: orientation, friction: 0.2, restitution: 0.1
        )
        for side: Float in [-1, 1] {
            addInvisibleStaticBox(
                "CoolBowling.returnRail\(side > 0 ? "R" : "L")",
                at: topMid + up * (Self.returnRailHeight * 0.5)
                    + layout.right * (side * (Self.returnInnerWidth + Self.returnRailThickness) * 0.5),
                halfExtents: SIMD3<Float>(Self.returnRailThickness * 0.5, Self.returnRailHeight * 0.5, halfLength),
                orientation: orientation, friction: 0.3, restitution: 0.3
            )
        }
        // End stops: the rack end holds the ball for the player (under the
        // unit's rubber stop); the hood end keeps a stray inside.
        for (name, z) in [("CoolBowling.returnRack", layout.returnRackStopZ), ("CoolBowling.returnEnd", layout.returnFarZ - 0.02)] {
            let base = layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: z), z))
            addInvisibleStaticBox(
                name, at: base + up * 0.075,
                halfExtents: SIMD3<Float>(outerWidth * 0.5, 0.075, 0.02),
                orientation: orientation, friction: 0.5, restitution: 0.1
            )
        }

        placeModel("CoolBowling.returnUnit", asset: "dispenser",
                   at: layout.worldPoint(SIMD3<Float>(layout.returnCenterX, 0, Self.returnUnitCenterZ)),
                   orientation: layout.facingPlayerOrientation)
    }

    /// A lane-owned model entity with no body.
    @MainActor @discardableResult
    private func placeModel(_ name: String, asset: String, at position: SIMD3<Float>, orientation: simd_quatf) -> EntityID {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        setEntityMesh(entityId: entity, filename: asset, withExtension: "untold")
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
        laneEntities.append(entity)
        return entity
    }

    /// A static box collider on an entity of its own, with no mesh, owned by
    /// the lane.
    private func addInvisibleStaticBox(_ name: String, at position: SIMD3<Float>, halfExtents: SIMD3<Float>,
                                       orientation: simd_quatf, friction: Float, restitution: Float) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        translateTo(entityId: entity, position: position)
        rotateTo(entityId: entity, rotation: orientation)
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
        parkedPins.removeAll()
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
