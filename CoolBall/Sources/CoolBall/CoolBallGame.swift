//
//  CoolBallGame.swift
//  CoolBall
//
//  Frame-driven football logic. KICKING: Vision Pro tracks no legs, so the
//  boot is a kinematic sphere at floor level driven from head tracking — it
//  sits under you and leads ahead of your horizontal motion, so stepping into
//  the ball or swinging a leg through it sweeps the proxy through with your
//  body's momentum, and the backend turns that into a kick. Hands (pinch to
//  grab, release to throw with the tracked hand velocity; catch and make
//  goalkeeper saves) are kinematic spheres too. Score by putting the ball
//  through the goal mouth: the goal-line trigger fires PhysicsEvents.
//

import Foundation
import os
import simd
import UntoldEngine

public final class CoolBallGame: @unchecked Sendable {
    public let scene = CoolBallScene()
    /// Synthesized kick/goal sounds (no asset files).
    public let audio = CoolBallAudio()
    private let backendStore = CoolBallLockedBox<CoolBallPhysicsBackend?>(nil)

    /// The demo starts by placing the goal: a translucent ghost frame
    /// follows the player's gaze along the floor until they confirm (pinch,
    /// or the control window's button); only then do the real goal, net and
    /// ball exist.
    public enum Phase: Sendable {
        case placingGoal
        case playing
    }

    private let lock = NSLock()
    private var phase = Phase.placingGoal
    private var placePending = false
    private var ghostTarget = SIMD3<Float>(0, CoolBallGame.floorY, -2.6)
    private var ghostFacing = SIMD3<Float>(0, 0, 1)
    private var autoPlaceDeadline: TimeInterval?
    /// Placement ignores pinches until this time (the pinch that pressed
    /// 'Move goal' must not instantly re-place the goal) and requires each
    /// confirming pinch to be freshly closed.
    private var placementPinchGraceUntil: TimeInterval = 0
    private var pinchWasClosed: [CoolBallHandSide: Bool] = [:]
    private var started = false
    private var score = 0
    private var goalSubscription: EventSubscription?
    private var contactSubscription: EventSubscription?
    private var lastKickImpulse: Float = 0

    // Grab state (game thread only).
    private var grabbingSide: CoolBallHandSide?
    private var grabSamples: [(position: SIMD3<Float>, time: TimeInterval)] = []
    /// Pinch tighter than this grabs; wider than this releases (hysteresis).
    private let pinchGrabDistance: Float = 0.025
    private let pinchReleaseDistance: Float = 0.045
    /// Palm must be this close to the ball to pick it up.
    private let grabReach: Float = 0.30

    // Foot-proxy state (game thread only).
    private var previousHeadPosition: SIMD3<Float>?
    private var previousHeadTime: TimeInterval = 0
    private var smoothedBodyVelocity = SIMD3<Float>.zero
    /// Where the BODY is, not where the head glances: a slow-following
    /// anchor so head turns and leans don't swing the boot through the ball
    /// ("it feels like kicking with my head").
    private var smoothedBodyPosition: SIMD3<Float>?
    private var lastFootPosition: SIMD3<Float>?
    /// How far ahead of your motion the boot leads — approximates the swing
    /// leg being out in front during a step or kick.
    private let footLead: Float = 0.25
    /// Floor height in the world frame. On device the ARKit world origin sits
    /// on the floor beneath the user, so 0 is right. The SIMULATOR has no
    /// floor calibration — its origin is at the head — so the pitch drops to
    /// a plausible standing-eye offset below it.
    #if targetEnvironment(simulator)
    public static let floorY: Float = -1.0
    #else
    public static let floorY: Float = 0.0
    #endif
    /// Ball spawns a meter up, drops in and settles on the floor — visibly in
    /// front of the player (and inside the simulator's fixed view).
    public var ballSpawnPosition = SIMD3<Float>(
        0.0, CoolBallGame.floorY + 1.0, -2.0
    )
    /// Ball this far below the floor is considered lost and respawns.
    private var respawnDepth: Float = 3.0

    #if os(visionOS)
    public let session = CoolBallSpatialSession()
    #endif

    private let detectedPlanes = CoolBallLockedBox<[CoolBallWorldPlane]>([])
    /// The real floor height, measured from detected upward planes below the
    /// head (the compile-time constant is only the pre-scan default: on
    /// device the world origin is NOT reliably on the real floor).
    private let floorLevel = CoolBallLockedBox<Float>(CoolBallGame.floorY)
    private var heartbeatAccumulator: Float = 0

    public init() {}

    // MARK: - Lifecycle

    /// Installs the physics backend. Must run before the renderer is created.
    @discardableResult
    public func installPhysics() -> Bool {
        guard let backend = registerCoolBallPhysics() else { return false }
        backendStore.value = backend
        pushWorldPlanes()
        return true
    }

    /// Builds the scene: ball, goal and hand bodies. Main actor — call from
    /// the immersive-space setup closure, before the render loop starts.
    @MainActor
    public func setupScene() {
        // Engine texture lookups resolve by name through the asset search
        // paths — point them at this package's bundled resources before any
        // textured entity (ball, net) is built.
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        scene.createBodyProxies()
        scene.addLighting()
        // Placement first: the goal frame appears as a gaze-following ghost;
        // the real goal, net and ball are built on confirmation.
        scene.buildGoalGhost()
        scene.moveGoalGhost(
            to: lock.withLock { ghostTarget },
            facing: lock.withLock { ghostFacing }
        )
        subscribeEvents()

        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
        }

        // Test hook: `-autoPlaceGoal` confirms placement after a short beat,
        // so automated simulator runs reach the playing phase unattended.
        if ProcessInfo.processInfo.arguments.contains("-autoPlaceGoal") {
            lock.withLock {
                autoPlaceDeadline = ProcessInfo.processInfo.systemUptime + 1.5
            }
        }
    }

    public var currentPhase: Phase {
        lock.withLock { phase }
    }

    /// Confirms the current ghost position (control-window button, pinch, or
    /// the `-autoPlaceGoal` test hook).
    public func requestGoalPlacement() {
        lock.withLock {
            guard phase == .placingGoal else { return }
            placePending = true
        }
    }

    /// Tears the goal down and returns to placement (control-window button).
    public func requestGoalMove() {
        let shouldReset = lock.withLock { () -> Bool in
            guard phase == .playing else { return false }
            phase = .placingGoal
            return true
        }
        guard shouldReset else { return }
        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
            pinchWasClosed.removeAll()
        }
        Task { @MainActor in
            self.scene.clear()
            self.scene.createBodyProxies()
            self.scene.addLighting()
            self.scene.buildGoalGhost()
            self.pushWorldPlanes()
        }
    }

    /// Builds the real pitch at the confirmed spot. Main actor: node creation.
    @MainActor
    private func buildPitch(at position: SIMD3<Float>, facing: SIMD3<Float>) {
        scene.removeGoalGhost()
        // Anchor to the measured floor even if the ghost was confirmed
        // before the scan settled.
        let grounded = SIMD3<Float>(position.x, floorLevel.value, position.z)
        scene.buildGoal(at: grounded, facing: facing)

        // Ball drops in between the player and the goal.
        let toPlayer = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
        let spawn = grounded + toPlayer * 1.2 + SIMD3<Float>(0, 1.0, 0)
        ballSpawnPosition = spawn
        scene.spawnBall(at: spawn)
        pushWorldPlanes()
        lock.withLock { phase = .playing }
        coolBallLog.log("goal placed at x=\(position.x, format: .fixed(precision: 2)) z=\(position.z, format: .fixed(precision: 2))")
    }

    /// Rebuilds the backend's plane set: detected real surfaces (or the
    /// fallback floor) plus the goal net's backstop.
    private func pushWorldPlanes() {
        guard let backend = backendStore.value else { return }
        // Detected surfaces PLUS a safety-net infinite floor at the measured
        // level: ARKit's floor coverage has holes, and a ball that finds one
        // must not fall out of the world.
        var planes = detectedPlanes.value
        planes.append(.infiniteFloor(y: floorLevel.value))
        if let catchPlane = scene.goalCatchPlane {
            planes.append(catchPlane)
        }
        if let skirtPlane = scene.goalSkirtPlane {
            planes.append(skirtPlane)
        }
        backend.setWorldPlanes(planes)
    }

    public func start() {
        lock.withLock {
            guard !started else { return }
            started = true
        }
        audio.start()
        #if os(visionOS)
        session.onPlanesChanged = { [weak self] planes in
            guard let self else { return }
            // Real surfaces replace the fallback floor as soon as they exist.
            self.detectedPlanes.value = planes
            let headY = self.session.headTransform()?.columns.3.y
            self.updateFloorLevel(planes: planes, headY: headY)
            self.pushWorldPlanes()
        }
        session.start()
        #endif
    }

    public func shutdown() {
        lock.withLock { started = false }
        audio.stop()
        #if os(visionOS)
        session.stop()
        #endif
        goalSubscription?.cancel()
        contactSubscription?.cancel()
        goalSubscription = nil
        contactSubscription = nil
        scene.clear()
    }

    // MARK: - Score

    public var currentScore: Int {
        lock.withLock { score }
    }

    /// Impulse of the most recent ball contact (N·s) — the control window
    /// shows it as a "kick strength" readout.
    public var lastImpulse: Float {
        lock.withLock { lastKickImpulse }
    }

    public func resetScore() {
        lock.withLock { score = 0 }
    }

    private func subscribeEvents() {
        goalSubscription = PhysicsEvents.shared.onTrigger { [weak self] event in
            guard let self, event.phase == .entered,
                  event.triggerEntity == self.scene.goalTriggerEntity,
                  event.otherEntity == self.scene.ballEntity
            else { return }
            let total = self.lock.withLock { () -> Int in
                self.score += 1
                return self.score
            }
            self.audio.playGoal()
            print("CoolBall: ⚽️ GOAL! score \(total)")
        }
        contactSubscription = PhysicsEvents.shared.onContact { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self.lastKickImpulse = event.impulse }

            // The thump. A kick (boot or hand contact) sounds at full
            // strength; bounces off the world are softer. Impulse for a firm
            // kick is ~1-2 N·s; a dying bounce ~0.05.
            let other = event.entityA == self.scene.ballEntity ? event.entityB : event.entityA
            let isBodyContact = other == self.scene.footEntity
                || other == self.scene.leftHandEntity
                || other == self.scene.rightHandEntity
            let scale: Float = isBodyContact ? 1.0 : 0.45
            self.audio.playKick(intensity: min(event.impulse / 1.2, 1.0) * scale)
        }
    }

    // MARK: - Per-frame update (XR render thread)

    public func update(deltaTime: Float) {
        if currentPhase == .placingGoal {
            updatePlacement(now: ProcessInfo.processInfo.systemUptime)
            return
        }

        #if os(visionOS)
        let now = ProcessInfo.processInfo.systemUptime
        updateHands(now: now)
        updateFoot(now: now)
        #endif

        // TEMP diagnostics: ball state heartbeat (os_log reaches `log stream`).
        heartbeatAccumulator += deltaTime
        if heartbeatAccumulator > 1.0 {
            heartbeatAccumulator = 0
            if let state = backendStore.value?.bodyState(for: scene.ballEntity) {
                coolBallLog.log("ball y=\(state.position.y, format: .fixed(precision: 3)) z=\(state.position.z, format: .fixed(precision: 3)) v=\(simd_length(state.velocity), format: .fixed(precision: 3))")
            }
        }

        // The net cloth follows the simulated ball (or the held one) — and
        // pushes back: the summed particle displacement the ball forced on
        // the cloth comes back as a decelerating reaction, which is what
        // makes shots die INTO the net instead of ghosting through it.
        let ballCenter = backendStore.value?.bodyState(for: scene.ballEntity)?.position
            ?? scene.ballPosition()
        scene.net.step(
            deltaTime: deltaTime,
            ballCenter: ballCenter,
            ballRadius: CoolBallScene.ballRadius
        )
        if let push = scene.net.solver?.lastBallPush, simd_length(push) > 1e-4 {
            var reaction = push * 3.0
            let magnitude = simd_length(reaction)
            if magnitude > 3.0 {
                reaction *= 3.0 / magnitude
            }
            backendStore.value?.nudgeBody(
                entity: scene.ballEntity, velocityDelta: reaction
            )
        }

        respawnIfLost()
    }

    /// Placement phase: the ghost follows the gaze ray to the floor;
    /// a pinch (either hand), the window button, or the test hook confirms.
    private func updatePlacement(now: TimeInterval) {
        var target = lock.withLock { ghostTarget }
        var facing = lock.withLock { ghostFacing }

        #if os(visionOS)
        if let head = session.headTransform() {
            let headPosition = SIMD3<Float>(
                head.columns.3.x, head.columns.3.y, head.columns.3.z
            )
            // ARKit device anchor looks along -Z.
            let forward = -SIMD3<Float>(
                head.columns.2.x, head.columns.2.y, head.columns.2.z
            )
            // The ghost only follows a gaze that actually points at the
            // floor — glancing up at the control window (to press its
            // buttons) must not drag the goal along.
            let floor = floorLevel.value
            let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
            let horizontalLength = simd_length(horizontal)
            if horizontalLength > 0.05, forward.y < -0.12 {
                let direction = horizontal / horizontalLength
                let drop = headPosition.y - floor
                var distance = drop * horizontalLength / -forward.y
                distance = min(max(distance, 1.5), 4.5)
                target = SIMD3<Float>(
                    headPosition.x + direction.x * distance,
                    floor,
                    headPosition.z + direction.z * distance
                )
                facing = -direction // goal mouth faces the player
            }

            // Pinch to confirm — but only a FRESH pinch, after a grace
            // period: the pinch that pressed 'Move goal' (or opened the
            // space) must not instantly re-place the goal.
            let graceOver = lock.withLock { now >= placementPinchGraceUntil }
            for side in CoolBallHandSide.allCases {
                guard let pose = session.predictedHandPose(side, at: now),
                      pose.isTracked
                else {
                    lock.withLock { pinchWasClosed[side] = nil }
                    continue
                }
                let closed = pose.pinchDistance < pinchGrabDistance
                let open = pose.pinchDistance > pinchReleaseDistance
                let previouslyClosed = lock.withLock { pinchWasClosed[side] }
                if closed, previouslyClosed == false, graceOver {
                    lock.withLock { placePending = true }
                }
                if closed {
                    lock.withLock { pinchWasClosed[side] = true }
                } else if open {
                    lock.withLock { pinchWasClosed[side] = false }
                }
            }
        }
        #endif

        lock.withLock {
            ghostTarget = target
            ghostFacing = facing
        }
        scene.moveGoalGhost(to: target, facing: facing)

        let shouldPlace = lock.withLock { () -> Bool in
            if let deadline = autoPlaceDeadline, now >= deadline {
                autoPlaceDeadline = nil
                placePending = true
            }
            guard placePending, phase == .placingGoal else { return false }
            placePending = false
            phase = .playing // reserved; buildPitch re-affirms after build
            return true
        }
        if shouldPlace {
            Task { @MainActor in
                self.buildPitch(at: target, facing: facing)
            }
        }
    }

    #if os(visionOS)
    /// Places the boot from head tracking. Legs aren't tracked, so when the
    /// ball is within kicking range the boot REACHES from under the head
    /// toward the ball — approximating the extended leg the player actually
    /// kicks with (the head barely moves during a real kick, which made the
    /// under-the-head boot feel like no collision at all). Away from the
    /// ball it trails the body with a velocity lead. The kinematic-target
    /// deltas give the backend the boot's sweep velocity — that is the kick.
    private func updateFoot(now: TimeInterval) {
        guard let head = session.headTransform() else {
            scene.moveProxy(scene.footEntity, to: nil)
            previousHeadPosition = nil
            return
        }
        let headPosition = SIMD3<Float>(
            head.columns.3.x, head.columns.3.y, head.columns.3.z
        )

        var frameDt: Float = 1.0 / 90.0
        if let previous = previousHeadPosition {
            let dt = Float(now - previousHeadTime)
            if dt > 0.001 {
                frameDt = min(dt, 1.0 / 30.0)
                var velocity = (headPosition - previous) / dt
                velocity.y = 0
                // Light smoothing so tracking jitter doesn't rattle the ball.
                smoothedBodyVelocity = simd_mix(
                    smoothedBodyVelocity, velocity, SIMD3<Float>(repeating: 0.35)
                )
            }
        }
        previousHeadPosition = headPosition
        previousHeadTime = now

        // Body anchor: heavy smoothing (~0.4 s) of the head's ground
        // position. Walking moves it; turning or tilting the head barely
        // does — so only real body motion drives the kick.
        let groundedHead = SIMD3<Float>(headPosition.x, 0, headPosition.z)
        let anchorBlend = 1.0 - exp(-frameDt / 0.4)
        let body = smoothedBodyPosition.map {
            simd_mix($0, groundedHead, SIMD3<Float>(repeating: anchorBlend))
        } ?? groundedHead
        smoothedBodyPosition = body

        let footY = floorLevel.value + CoolBallScene.footRadius * 0.9
        var footTarget = SIMD3<Float>(
            body.x + smoothedBodyVelocity.x * footLead,
            footY,
            body.z + smoothedBodyVelocity.z * footLead
        )

        // Reach assist: with the ball in range AND near the ground, the boot
        // extends from the body toward it (up to a leg's length), so
        // stepping into the ball connects the way the player expects.
        if let ball = scene.ballPosition(), ball.y < floorLevel.value + 0.6 {
            let toBall = SIMD3<Float>(ball.x - body.x, 0, ball.z - body.z)
            let ballDistance = simd_length(toBall)
            if ballDistance > 0.01, ballDistance < 1.3 {
                let reach = min(ballDistance, 0.95)
                let direction = toBall / ballDistance
                footTarget = SIMD3<Float>(
                    body.x + direction.x * reach,
                    footY,
                    body.z + direction.z * reach
                )
            }
        }

        // The boot never teleports: its travel is speed-limited, so retarget
        // jumps (reach engaging, tracking hiccups) cannot launch the ball.
        var footPosition = footTarget
        if let last = lastFootPosition {
            let travel = footTarget - last
            let travelLength = simd_length(travel)
            let maxTravel = 3.5 * frameDt
            if travelLength > maxTravel {
                footPosition = last + travel / travelLength * maxTravel
            }
        }
        lastFootPosition = footPosition
        scene.moveProxy(scene.footEntity, to: footPosition)
    }
    #endif

    #if os(visionOS)
    private func updateHands(now: TimeInterval) {
        for side in CoolBallHandSide.allCases {
            let handEntity = side == .left
                ? scene.leftHandEntity
                : scene.rightHandEntity

            // ~50 ms prediction keeps the collider on a fast-moving hand.
            guard let pose = session.predictedHandPose(side, at: now + 0.05),
                  pose.isTracked
            else {
                scene.moveProxy(handEntity, to: nil)
                if grabbingSide == side { releaseBall(at: nil, now: now) }
                continue
            }

            scene.moveProxy(handEntity, to: pose.palm)
            updateGrab(side: side, pose: pose, now: now)
        }
    }

    private func updateGrab(side: CoolBallHandSide, pose: CoolBallHandPose, now: TimeInterval) {
        if grabbingSide == side {
            if pose.pinchDistance > pinchReleaseDistance {
                releaseBall(at: pose.pinchPoint, now: now)
            } else {
                let held = pose.pinchPoint
                scene.moveBall(to: held)
                grabSamples.append((held, now))
                // Keep ~120 ms of motion history for the throw velocity.
                while let first = grabSamples.first, now - first.time > 0.12 {
                    grabSamples.removeFirst()
                }
            }
            return
        }

        guard grabbingSide == nil,
              pose.pinchDistance < pinchGrabDistance,
              let ballPosition = scene.ballPosition(),
              simd_length(ballPosition - pose.palm) < grabReach
        else { return }

        grabbingSide = side
        grabSamples = [(pose.pinchPoint, now)]
        scene.detachBallBody()
        scene.moveBall(to: pose.pinchPoint)
        print("CoolBall: ball grabbed (\(side == .left ? "left" : "right"))")
    }

    private func releaseBall(at position: SIMD3<Float>?, now: TimeInterval) {
        defer {
            grabbingSide = nil
            grabSamples.removeAll()
        }
        let releasePoint = position
            ?? grabSamples.last?.position
            ?? scene.ballPosition()
            ?? ballSpawnPosition

        // Throw velocity: displacement over the sampled window.
        var velocity = SIMD3<Float>.zero
        if let first = grabSamples.first, let last = grabSamples.last {
            let dt = Float(last.time - first.time)
            if dt > 0.01 {
                velocity = (last.position - first.position) / dt
            }
        }
        scene.attachBallBody(velocity: velocity, at: releasePoint)
        print(String(
            format: "CoolBall: thrown at %.1f m/s", simd_length(velocity)
        ))
    }
    #endif

    private func respawnIfLost() {
        guard grabbingSide == nil,
              let position = scene.ballPosition(),
              position.y < floorLevel.value - respawnDepth
        else { return }
        scene.respawnBall(at: ballSpawnPosition)
        print("CoolBall: ball lost below the world — respawned")
    }

    // MARK: - Diagnostics

    public var worldPlaneCount: Int {
        backendStore.value?.worldPlaneCount ?? 0
    }

    /// Current best estimate of the real floor height.
    public var currentFloorLevel: Float {
        floorLevel.value
    }

    /// Updates the floor estimate: the lowest upward-facing detected plane
    /// in a plausible band below the head.
    private func updateFloorLevel(planes: [CoolBallWorldPlane], headY: Float?) {
        let reference = headY ?? 0
        let candidates = planes.filter { plane in
            plane.normal.y > 0.85
                && plane.center.y < reference - 0.5
                && plane.center.y > reference - 2.8
        }
        guard let lowest = candidates.min(by: { $0.center.y < $1.center.y }) else { return }
        floorLevel.value = lowest.center.y
    }
}

/// Minimal lock-guarded box for cross-thread handoff.
final class CoolBallLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}


let coolBallLog = Logger(subsystem: "com.miolabs.coolball", category: "game")
