//
//  CoolBowlingScene.swift
//  CoolBowling
//
//  Entity construction for the bowling demo: the alley (lane plinth, pit,
//  bumpers and backstop — static boxes), the pinsetter cover over the deck,
//  ten pins, the ball and the ball-return unit — the last four are artist
//  models (`Resources/Models/*.untold`) — plus the placement ghost and two
//  invisible kinematic hand bodies. What the models look like and what they
//  collide with are separate: the pins carry a convex hull of the regulation
//  profile, the ball a sphere, the return an invisible sloped trough of
//  boxes, the cover nothing (the backstop's box stands in for its rear
//  panel). Visuals use engine nodes and meshes; physics uses the
//  engine-owned ColliderComponent / RigidBodyComponent vocabulary.
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
    /// Living-room lane: regulation width, a quarter of regulation length.
    public static let laneWidth: Float = 1.06
    public static let laneLength: Float = 4.5
    public static let laneThickness: Float = 0.02
    /// The alley stands on a plinth: the pit behind the deck drops the ball
    /// below the lane without cutting into the real floor.
    public static let laneRise: Float = 0.20
    /// Height of the lane surface above the floor.
    public static let laneSurfaceHeight: Float = laneRise + laneThickness
    /// Oiled maple: the ball slides more than it grips.
    static let laneFriction: Float = 0.08
    static let bumperWidth: Float = 0.08
    /// Bumper height above the lane surface (well above a bouncing ball's
    /// centre); the bumpers stand on the floor and run the ramp and the pit.
    static let bumperHeight: Float = 0.22
    static let bumperTop: Float = laneSurfaceHeight + bumperHeight
    /// The approach ramp bridges the real floor and the plinth, so a low
    /// release rolls up onto the lane instead of hitting its front face.
    public static let approachRampLength: Float = 1.0
    /// The pit: the lane ends this far short of the alley's end and the
    /// ball (and any pin) drops to floor level, out of play.
    public static let pitLength: Float = 0.6
    public static let pitStart: Float = laneLength - pitLength
    static let pitFloorThickness: Float = 0.02
    /// The pit wall at the end of the alley, measured above the lane surface.
    static let backstopHeight: Float = 0.5
    static let backstopThickness: Float = 0.06
    /// The pinsetter cover (`Models/pitcover`): an enclosure standing on the
    /// floor over the deck and the pit, open at the front so the pins show.
    /// Its origin is its footprint centre; placed facing the player, its
    /// open front is this far toward the player and its closed rear panel
    /// this far toward the backstop.
    static let pitCoverFrontOffset: Float = 0.80
    static let pitCoverRearOffset: Float = 0.80
    /// The cover's open front starts this far before the head pin.
    static let pitCoverGap: Float = 0.10
    /// Regulation pin: 15 in tall, 4.75 in at the belly, 3 lb 6 oz.
    public static let pinHeight: Float = 0.381
    public static let pinMaxRadius: Float = 0.0605
    public static let pinMass: Float = 1.53
    /// Pin centres 12 in apart on the deck; the head pin this far from the
    /// foul line, so the back row keeps a margin before the pit edge.
    public static let pinSpacing: Float = 0.3048
    public static let pinDeckDistance: Float = laneLength - 1.6
    /// The ball return: a sloped trough on the player's right, above the
    /// lane, carrying the ball from the pit back to a rack behind the foul
    /// line. Heights are the trough floor's top surface above the floor.
    /// The physics trough is invisible; what shows is the ball-return unit
    /// model (`Models/dispenser`) at the rack end and a plain trough from
    /// its hood back to the pit.
    public static let returnInnerWidth: Float = 0.26
    static let returnRailThickness: Float = 0.03
    static let returnRailHeight: Float = 0.12
    static let returnFloorThickness: Float = 0.03
    static let returnGap: Float = 0.04
    /// The rack end matches the unit's rails: its trough floor tops out at
    /// 0.37 m, level from its rubber stop back to the hood.
    public static let returnRackHeight: Float = 0.37
    public static let returnSlope: Float = 2.0 * .pi / 180
    public static let returnSpeed: Float = 1.0
    /// The unit's origin is its footprint centre, base on the floor. Placed
    /// facing the player, its rubber ball stop is this far toward the
    /// player and the back of its hood this far toward the pit; the ball
    /// comes out of the hood and rolls to the stop.
    static let dispenserStopOffset: Float = 1.29
    static let dispenserHoodOffset: Float = 1.49
    /// The physics rack stop's centre, past the near end of the trough.
    static let returnRackStopInset: Float = 0.02
    /// How far behind the foul line the rack sits when the player's
    /// position is unknown.
    public static let defaultApproachLength: Float = 1.0
    static let handRadius: Float = 0.07

    public init() {}

    // MARK: - Lane layout

    /// Shared placement math for the ghost and the real lane: `foul` is the
    /// floor point at the centre of the foul line, `facing` points from the
    /// player down the lane toward the pins, `approachLength` is how far
    /// behind the foul line the ball return's rack sits.
    public struct LaneLayout {
        public let foul: SIMD3<Float>
        public let forward: SIMD3<Float> // toward the pins
        public let right: SIMD3<Float>
        public let orientation: simd_quatf
        public let approachLength: Float
        /// Centre of the lane plinth (the playing surface up to the pit).
        public let laneCenter: SIMD3<Float>
        /// Height of the lane surface.
        public let surfaceY: Float
        /// Where each of the ten pins stands (base centre), in the usual
        /// numbering: 1; 2, 3; 4, 5, 6; 7, 8, 9, 10.
        public let pinPositions: [SIMD3<Float>]

        public init(foul: SIMD3<Float>, facing: SIMD3<Float>, approachLength: Float = CoolBowlingScene.defaultApproachLength) {
            self.foul = foul
            self.approachLength = approachLength
            forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
            right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))) // the player's right
            let yaw = atan2f(forward.x, forward.z)
            orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            surfaceY = foul.y + CoolBowlingScene.laneSurfaceHeight
            laneCenter = foul + forward * (CoolBowlingScene.pitStart * 0.5)
                + SIMD3<Float>(0, CoolBowlingScene.laneSurfaceHeight * 0.5, 0)

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

        /// Lane-local coordinates: x to the player's right, y up from the
        /// floor, z down the lane from the foul line.
        public func localPoint(_ world: SIMD3<Float>) -> SIMD3<Float> {
            let offset = world - foul
            return SIMD3<Float>(simd_dot(offset, right), offset.y, simd_dot(offset, forward))
        }

        public func worldPoint(_ local: SIMD3<Float>) -> SIMD3<Float> {
            foul + right * local.x + SIMD3<Float>(0, local.y, 0) + forward * local.z
        }

        /// The models' fronts are their local +z; turned about, a model
        /// faces the player, its local +z pointing back down the lane.
        public var facingPlayerOrientation: simd_quatf {
            orientation * simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        }

        // MARK: The pinsetter cover

        /// Lane-local z of the cover's origin: its open front a step before
        /// the head pin, its rear panel toward the backstop.
        public var pitCoverCenterZ: Float {
            CoolBowlingScene.pinDeckDistance - CoolBowlingScene.pitCoverGap + CoolBowlingScene.pitCoverFrontOffset
        }

        /// Lane-local z of the cover's rear panel; the backstop's collider
        /// stands there, so the panel is what the ball and the pins hit.
        public var pitCoverRearZ: Float {
            pitCoverCenterZ + CoolBowlingScene.pitCoverRearOffset
        }

        /// The bumpers run from the foot of the ramp to the backstop.
        static var bumperLength: Float {
            CoolBowlingScene.laneLength + CoolBowlingScene.approachRampLength
        }

        func bumperCenter(side: Float) -> SIMD3<Float> {
            worldPoint(SIMD3<Float>(
                side * (CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth * 0.5),
                CoolBowlingScene.bumperTop * 0.5,
                (CoolBowlingScene.laneLength - CoolBowlingScene.approachRampLength) * 0.5
            ))
        }

        // MARK: The pit

        /// The ball has dropped into the pit: past the end of the lane and
        /// below its rolling height (whatever it landed on — the floor or a
        /// pile of pins), between the bumpers.
        public func isInPit(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            return local.z > CoolBowlingScene.pitStart + CoolBowlingScene.ballRadius * 0.5
                && local.z < CoolBowlingScene.laneLength + CoolBowlingScene.backstopThickness
                && local.y < CoolBowlingScene.laneSurfaceHeight + CoolBowlingScene.ballRadius - 0.02
                && abs(local.x) < CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth
        }

        /// Inside the alley's footprint (ramp, lane, pit, bumpers, backstop),
        /// at any height.
        public func isOverAlley(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            return abs(local.x) < CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth + 0.05
                && local.z > -CoolBowlingScene.approachRampLength - 0.05
                && local.z < CoolBowlingScene.laneLength + CoolBowlingScene.backstopThickness + 0.05
        }

        /// On the real floor outside the alley and the return: a ball that
        /// left over a bumper or the backstop.
        public func isLost(_ world: SIMD3<Float>) -> Bool {
            let local = localPoint(world)
            return !isOverAlley(world) && !isOnReturn(world)
                && local.y < CoolBowlingScene.laneSurfaceHeight + 0.3
        }

        // MARK: The ball return

        /// Lateral offset of the trough's centre line, on the player's right.
        public var returnCenterX: Float {
            CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth + CoolBowlingScene.returnGap
                + CoolBowlingScene.returnRailThickness + CoolBowlingScene.returnInnerWidth * 0.5
        }

        /// The trough runs from the rack behind the foul line to the pit.
        public var returnNearZ: Float { -approachLength }
        public var returnFarZ: Float { CoolBowlingScene.laneLength }
        public var returnLength: Float { returnFarZ - returnNearZ }

        /// Lane-local z of the physics rack stop, which the ball rests against.
        var returnRackStopZ: Float { returnNearZ + CoolBowlingScene.returnRackStopInset }

        /// Lane-local z of the ball-return unit's origin: its rubber stop
        /// on the physics rack stop, its hood toward the pit.
        public var dispenserCenterZ: Float {
            returnRackStopZ + CoolBowlingScene.dispenserStopOffset
        }

        /// Lane-local z of the back of the unit's hood: the plain trough
        /// shows from here to the pit, the unit hides the rest.
        public var returnVisibleNearZ: Float {
            dispenserCenterZ + CoolBowlingScene.dispenserHoodOffset
        }

        /// Height of the trough floor's top surface at lane-local `z`. The
        /// rack end is the low end, so the ball rolls toward the player.
        public func returnFloorTop(atZ z: Float) -> Float {
            CoolBowlingScene.returnRackHeight + (z - returnNearZ) * tanf(CoolBowlingScene.returnSlope)
        }

        /// Where a returned ball reappears: the pit end of the trough…
        public var returnStart: SIMD3<Float> {
            let z = returnFarZ - 0.35
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

        /// Inside the trough, from the rack to the pit end.
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

        /// Real surfaces inside this box — the alley, the return and the air
        /// above them, but not the floor — stay out of the simulation, so a
        /// chair in the middle of the lane doesn't stop the ball.
        public var keepOut: CoolBowlingKeepOutBox {
            let minX = -(CoolBowlingScene.laneWidth * 0.5 + CoolBowlingScene.bumperWidth + 0.05)
            let maxX = returnCenterX + CoolBowlingScene.returnInnerWidth * 0.5 + CoolBowlingScene.returnRailThickness + 0.05
            let minY: Float = 0.06
            let maxY: Float = 2.2
            let minZ = min(returnNearZ, -CoolBowlingScene.approachRampLength) - 0.1
            let maxZ = CoolBowlingScene.laneLength + CoolBowlingScene.backstopThickness + 0.1
            let localCenter = SIMD3<Float>((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
            return CoolBowlingKeepOutBox(
                center: worldPoint(localCenter),
                right: right, up: SIMD3<Float>(0, 1, 0), forward: forward,
                halfExtents: SIMD3<Float>((maxX - minX) * 0.5, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5),
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

    /// Translucent preview: the lane slab, a marker on the pin deck, the
    /// pit with its backstop, and the ball return (resized per frame to
    /// the approach length, so the rack is previewed where it will stand).
    @MainActor public func buildLaneGhost() {
        removeLaneGhost()
        var entities: [EntityID] = []
        for (name, scale) in [
            ("CoolBowling.ghostLane", SIMD3<Float>(Self.laneWidth, Self.laneSurfaceHeight, Self.pitStart)),
            ("CoolBowling.ghostDeck", SIMD3<Float>(Self.pinSpacing * 3.4, 0.05, Self.pinSpacing * 3.0)),
            ("CoolBowling.ghostPit", SIMD3<Float>(Self.laneWidth + Self.bumperWidth * 2, Self.laneSurfaceHeight + Self.backstopHeight, Self.pitLength + Self.backstopThickness)),
            ("CoolBowling.ghostReturn", SIMD3<Float>(Self.returnInnerWidth + Self.returnRailThickness * 2, Self.returnRailHeight, 1.0)),
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

    public func moveLaneGhost(foul: SIMD3<Float>, facing: SIMD3<Float>, approachLength: Float = CoolBowlingScene.defaultApproachLength) {
        guard ghostEntities.count == 4 else { return }
        let layout = LaneLayout(foul: foul, facing: facing, approachLength: approachLength)
        let deckCenter = foul + layout.forward * (Self.pinDeckDistance + Self.pinSpacing * 1.3)
            + SIMD3<Float>(0, Self.laneSurfaceHeight + 0.025, 0)
        let pitCenter = layout.worldPoint(SIMD3<Float>(
            0, (Self.laneSurfaceHeight + Self.backstopHeight) * 0.5,
            Self.pitStart + (Self.pitLength + Self.backstopThickness) * 0.5
        ))
        for (entity, target) in zip(ghostEntities, [layout.laneCenter, deckCenter, pitCenter]) {
            translateTo(entityId: entity, position: target)
            rotateTo(entityId: entity, rotation: layout.orientation)
        }
        // The return: tilted like the real trough, stretched to its length.
        let tilt = simd_quatf(angle: -Self.returnSlope, axis: SIMD3<Float>(1, 0, 0))
        let orientation = layout.orientation * tilt
        let midZ = (layout.returnNearZ + layout.returnFarZ) * 0.5
        let center = layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: midZ), midZ))
            + orientation.act(SIMD3<Float>(0, Self.returnRailHeight * 0.5, 0))
        let returnGhost = ghostEntities[3]
        translateTo(entityId: returnGhost, position: center)
        rotateTo(entityId: returnGhost, rotation: orientation)
        scaleTo(entityId: returnGhost, scale: SIMD3<Float>(
            Self.returnInnerWidth + Self.returnRailThickness * 2, Self.returnRailHeight, layout.returnLength / cosf(Self.returnSlope)
        ))
    }

    public func removeLaneGhost() {
        for entity in ghostEntities {
            destroyEntity(entityId: entity)
        }
        ghostEntities.removeAll()
    }

    // MARK: - Lane

    /// Builds the alley for `layout`: the lane plinth, the pit, bumpers, the
    /// backstop, the pinsetter cover, the ball return and the ten pins.
    @MainActor public func buildLane(_ layout: LaneLayout) {
        clearLane()
        self.layout = layout
        Self.claimAssetBasePath()

        // The lane: a plinth from the floor to the playing surface, ending
        // at the pit.
        let lane = CubeNode(size: 1.0, name: "CoolBowling.lane")
            .baseColor(1.0, 1.0, 1.0)
            .roughness(0.25)
            .scaleTo(x: Self.laneWidth, y: Self.laneSurfaceHeight, z: Self.pitStart)
        if let textureURL = Bundle.module.url(forResource: "lane_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: lane.entityID, textureType: .baseColor, path: textureURL)
        }
        addStaticBox(
            lane, at: layout.laneCenter,
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5, Self.laneSurfaceHeight * 0.5, Self.pitStart * 0.5),
            orientation: layout.orientation, friction: Self.laneFriction, restitution: 0.1
        )

        // The pit floor, at floor level and black: the hole the ball drops into.
        let pit = CubeNode(size: 1.0, name: "CoolBowling.pit")
            .baseColor(0.02, 0.02, 0.03)
            .roughness(0.9)
            .scaleTo(x: Self.laneWidth, y: Self.pitFloorThickness, z: Self.pitLength)
        addStaticBox(
            pit, at: layout.worldPoint(SIMD3<Float>(0, Self.pitFloorThickness * 0.5, Self.pitStart + Self.pitLength * 0.5)),
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5, Self.pitFloorThickness * 0.5, Self.pitLength * 0.5),
            orientation: layout.orientation, friction: 0.6, restitution: 0.05
        )

        // The approach ramp: from the real floor up to the plinth's edge.
        let rampRise = Self.laneSurfaceHeight
        let rampAngle = atan2f(rampRise, Self.approachRampLength)
        let rampSlant = sqrtf(rampRise * rampRise + Self.approachRampLength * Self.approachRampLength)
        let rampOrientation = layout.orientation * simd_quatf(angle: -rampAngle, axis: SIMD3<Float>(1, 0, 0))
        let rampUp = rampOrientation.act(SIMD3<Float>(0, 1, 0))
        let ramp = CubeNode(size: 1.0, name: "CoolBowling.ramp")
            .baseColor(1.0, 1.0, 1.0)
            .roughness(0.25)
            .scaleTo(x: Self.laneWidth, y: Self.laneThickness, z: rampSlant)
        if let textureURL = Bundle.module.url(forResource: "lane_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: ramp.entityID, textureType: .baseColor, path: textureURL)
        }
        addStaticBox(
            ramp,
            at: layout.worldPoint(SIMD3<Float>(0, rampRise * 0.5, -Self.approachRampLength * 0.5)) - rampUp * (Self.laneThickness * 0.5),
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5, Self.laneThickness * 0.5, rampSlant * 0.5),
            orientation: rampOrientation, friction: Self.laneFriction, restitution: 0.1
        )

        // Bumpers keep the ball on the lane (no gutter balls in the living
        // room); they run from the ramp to the backstop and wall the pit.
        for side: Float in [-1, 1] {
            let bumper = darkBox("CoolBowling.bumper\(side > 0 ? "R" : "L")", size: SIMD3<Float>(Self.bumperWidth, Self.bumperTop, LaneLayout.bumperLength))
            addStaticBox(
                bumper, at: layout.bumperCenter(side: side),
                halfExtents: SIMD3<Float>(Self.bumperWidth * 0.5, Self.bumperTop * 0.5, LaneLayout.bumperLength * 0.5),
                orientation: layout.orientation, friction: 0.3, restitution: 0.35
            )
        }

        // The pinsetter cover over the deck and the pit: wider than the
        // alley, standing on the floor either side of the bumpers, its open
        // front toward the player.
        let cover = createEntity()
        setEntityName(entityId: cover, name: "CoolBowling.pitCover")
        setEntityMesh(entityId: cover, filename: "pitcover", withExtension: "untold")
        translateTo(entityId: cover, position: layout.worldPoint(SIMD3<Float>(0, 0, layout.pitCoverCenterZ)))
        rotateTo(entityId: cover, rotation: layout.facingPlayerOrientation)
        laneEntities.append(cover)

        // The pit wall: an invisible box just inside the cover's rear
        // panel, which is what appears to stop the ball.
        let backstopTop = Self.laneSurfaceHeight + Self.backstopHeight
        addInvisibleStaticBox(
            "CoolBowling.backstop",
            at: layout.worldPoint(SIMD3<Float>(0, backstopTop * 0.5, layout.pitCoverRearZ + Self.backstopThickness * 0.5)),
            halfExtents: SIMD3<Float>(Self.laneWidth * 0.5 + Self.bumperWidth, backstopTop * 0.5, Self.backstopThickness * 0.5),
            orientation: layout.orientation, friction: 0.5, restitution: 0.2
        )

        buildBallReturn(layout)

        // Pins face the player like the lane does.
        for (index, position) in layout.pinPositions.enumerated() {
            spawnPin(at: position, index: index, orientation: layout.orientation)
        }
    }

    /// The ball return: a sloped trough on the player's right, above the
    /// lane, from the pit to a rack behind the foul line. Tilted about the
    /// lane's right axis so the rack end is the low end. The physics trough
    /// (floor, rails, end stops) is invisible and runs the whole length;
    /// the ball-return unit model stands at the rack end, and a plain
    /// trough shows from the back of its hood to the pit.
    @MainActor private func buildBallReturn(_ layout: LaneLayout) {
        let tilt = simd_quatf(angle: -Self.returnSlope, axis: SIMD3<Float>(1, 0, 0))
        let orientation = layout.orientation * tilt
        let up = orientation.act(SIMD3<Float>(0, 1, 0))
        let outerWidth = Self.returnInnerWidth + Self.returnRailThickness * 2
        /// Centre of the trough floor's top surface and the half length of
        /// the slant between lane-local `nearZ` and `farZ`.
        func slant(_ nearZ: Float, _ farZ: Float) -> (topMid: SIMD3<Float>, halfLength: Float) {
            let midZ = (nearZ + farZ) * 0.5
            return (
                layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: midZ), midZ)),
                (farZ - nearZ) * 0.5 / cosf(Self.returnSlope)
            )
        }

        // The trough the ball actually rolls in.
        let physics = slant(layout.returnNearZ, layout.returnFarZ)
        addInvisibleStaticBox(
            "CoolBowling.returnFloor", at: physics.topMid - up * (Self.returnFloorThickness * 0.5),
            halfExtents: SIMD3<Float>(outerWidth * 0.5, Self.returnFloorThickness * 0.5, physics.halfLength),
            orientation: orientation, friction: 0.2, restitution: 0.1
        )
        for side: Float in [-1, 1] {
            addInvisibleStaticBox(
                "CoolBowling.returnRail\(side > 0 ? "R" : "L")",
                at: physics.topMid + up * (Self.returnRailHeight * 0.5)
                    + layout.right * (side * (Self.returnInnerWidth + Self.returnRailThickness) * 0.5),
                halfExtents: SIMD3<Float>(Self.returnRailThickness * 0.5, Self.returnRailHeight * 0.5, physics.halfLength),
                orientation: orientation, friction: 0.3, restitution: 0.3
            )
        }
        // End stops: the rack end holds the ball for the player (under the
        // unit's rubber stop); the pit end catches a stray.
        for (name, z) in [("CoolBowling.returnRack", layout.returnRackStopZ), ("CoolBowling.returnEnd", layout.returnFarZ - 0.02)] {
            let base = layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: z), z))
            addInvisibleStaticBox(
                name, at: base + up * 0.075,
                halfExtents: SIMD3<Float>(outerWidth * 0.5, 0.075, 0.02),
                orientation: orientation, friction: 0.5, restitution: 0.1
            )
        }

        // The ball-return unit: hood toward the pit, rubber stop toward the
        // player, on the floor beside the lane.
        let dispenser = createEntity()
        setEntityName(entityId: dispenser, name: "CoolBowling.returnUnit")
        setEntityMesh(entityId: dispenser, filename: "dispenser", withExtension: "untold")
        translateTo(entityId: dispenser, position: layout.worldPoint(SIMD3<Float>(layout.returnCenterX, 0, layout.dispenserCenterZ)))
        rotateTo(entityId: dispenser, rotation: layout.facingPlayerOrientation)
        laneEntities.append(dispenser)

        // The visible trough, from the back of the hood to the pit end, with
        // posts holding it up (all visual only).
        let visibleNearZ = layout.returnVisibleNearZ
        guard visibleNearZ < layout.returnFarZ - 0.3 else { return }
        let visible = slant(visibleNearZ, layout.returnFarZ)
        let floor = CubeNode(size: 1.0, name: "CoolBowling.returnFloorVisual")
            .baseColor(0.24, 0.25, 0.29)
            .roughness(0.45)
            .scaleTo(x: outerWidth, y: Self.returnFloorThickness, z: visible.halfLength * 2)
        placeVisual(floor, at: visible.topMid - up * (Self.returnFloorThickness * 0.5), orientation: orientation)
        for side: Float in [-1, 1] {
            let rail = darkBox("CoolBowling.returnRailVisual\(side > 0 ? "R" : "L")", size: SIMD3<Float>(Self.returnRailThickness, Self.returnRailHeight, visible.halfLength * 2))
            placeVisual(
                rail,
                at: visible.topMid + up * (Self.returnRailHeight * 0.5)
                    + layout.right * (side * (Self.returnInnerWidth + Self.returnRailThickness) * 0.5),
                orientation: orientation
            )
        }
        let midZ = (visibleNearZ + layout.returnFarZ) * 0.5
        for (index, z) in [visibleNearZ + 0.15, midZ, layout.returnFarZ - 0.15].enumerated() {
            let height = layout.returnFloorTop(atZ: z) - Self.returnFloorThickness
            let post = darkBox("CoolBowling.returnPost\(index)", size: SIMD3<Float>(0.05, height, 0.05))
            placeVisual(post, at: layout.worldPoint(SIMD3<Float>(layout.returnCenterX, height * 0.5, z)), orientation: layout.orientation)
        }
    }

    /// A lane-owned node with no body.
    @MainActor private func placeVisual(_ node: PrimitiveNode, at position: SIMD3<Float>, orientation: simd_quatf) {
        translateTo(entityId: node.entityID, position: position)
        rotateTo(entityId: node.entityID, rotation: orientation)
        laneEntities.append(node.entityID)
    }

    @MainActor private func darkBox(_ name: String, size: SIMD3<Float>) -> PrimitiveNode {
        CubeNode(size: 1.0, name: name)
            .baseColor(0.16, 0.17, 0.22)
            .roughness(0.6)
            .scaleTo(x: size.x, y: size.y, z: size.z)
    }

    /// A static box collider on a node, owned by the lane.
    @MainActor private func addStaticBox(_ node: PrimitiveNode, at position: SIMD3<Float>, halfExtents: SIMD3<Float>,
                              orientation: simd_quatf, friction: Float, restitution: Float) {
        attachStaticBox(node.entityID, at: position, halfExtents: halfExtents, orientation: orientation, friction: friction, restitution: restitution)
    }

    /// An invisible static box owned by the lane: an entity with no mesh,
    /// just the collider — the physics behind a model that only looks the
    /// part.
    private func addInvisibleStaticBox(_ name: String, at position: SIMD3<Float>, halfExtents: SIMD3<Float>,
                                       orientation: simd_quatf, friction: Float, restitution: Float) {
        let entity = createEntity()
        setEntityName(entityId: entity, name: name)
        attachStaticBox(entity, at: position, halfExtents: halfExtents, orientation: orientation, friction: friction, restitution: restitution)
    }

    private func attachStaticBox(_ entity: EntityID, at position: SIMD3<Float>, halfExtents: SIMD3<Float>,
                                 orientation: simd_quatf, friction: Float, restitution: Float) {
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
