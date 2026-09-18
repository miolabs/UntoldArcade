//
//  CoolBallGame.swift
//  CoolBall
//
//  Frame-driven basketball logic. The hands are kinematic sphere bodies fed
//  from hand tracking: they dribble and swat the ball through plain
//  collisions, and a pinch near the ball grabs it (the body's components are
//  removed — the coordinator diff takes it out of the backend), carrying it
//  until release throws it with the tracked hand velocity. Score by putting
//  the ball down through the rim: a downward crossing of the rim plane inside
//  the ring, confirmed by the under-rim trigger firing through PhysicsEvents.
//

import Foundation
import os
import simd
import UntoldEngine
import UntoldJoltPhysics

public final class CoolBallGame: @unchecked Sendable {
    public let scene = CoolBallScene()
    /// Synthesized bounce/score sounds (no asset files).
    public let audio = CoolBallAudio()
    private let backendStore = CoolBallLockedBox<(any CoolBallSimulation)?>(nil)

    /// The demo starts by placing the hoop: a translucent ghost follows the
    /// player's gaze along the floor until they confirm (pinch, or the
    /// control window's button); only then do the real hoop and ball exist.
    public enum Phase: Sendable {
        case placingHoop
        case playing
    }

    private let lock = NSLock()
    private var phase = Phase.placingHoop
    private var placePending = false
    private var ghostTarget = SIMD3<Float>(0, CoolBallGame.floorY, -2.6)
    private var ghostFacing = SIMD3<Float>(0, 0, 1)
    private var autoPlaceDeadline: TimeInterval?
    /// Placement ignores pinches until this time (the pinch that pressed
    /// 'Move hoop' must not instantly re-place the hoop) and requires each
    /// confirming pinch to be freshly closed.
    private var placementPinchGraceUntil: TimeInterval = 0
    private var pinchWasClosed: [CoolBallHandSide: Bool] = [:]
    /// Bumped by 'Move hoop': a court build scheduled before the move must
    /// not land after it.
    private var placementGeneration: UInt64 = 0
    private var started = false
    private var score = 0
    private var basketSubscription: EventSubscription?
    private var contactSubscription: EventSubscription?
    private var lastContactImpulse: Float = 0

    // Ring-crossing state (guarded by `lock`: written by the per-frame update,
    // read by the trigger handler).
    private var previousBallCenter: SIMD3<Float>?
    private var throughRingAt: TimeInterval?
    /// A made basket must reach the under-rim trigger within this long after
    /// crossing the rim plane downward inside the ring.
    private let basketWindow: TimeInterval = 0.6

    // Grab state (game thread only).
    private var grabbingSide: CoolBallHandSide?
    private var grabSamples: [(position: SIMD3<Float>, time: TimeInterval)] = []
    /// The hand that just threw is parked briefly so the ball, re-added at
    /// the pinch point, isn't shoved by that hand's own collider.
    private var handParkedUntil: [CoolBallHandSide: TimeInterval] = [:]
    private let releaseCooldown: TimeInterval = 0.12
    /// Pinch tighter than this grabs; wider than this releases (hysteresis).
    private let pinchGrabDistance: Float = 0.025
    private let pinchReleaseDistance: Float = 0.045
    /// Palm must be this close to the ball to pick it up.
    private let grabReach: Float = 0.30

    /// Floor height in the world frame. On device the ARKit world origin sits
    /// on the floor beneath the user, so 0 is right. The SIMULATOR has no
    /// floor calibration — its origin is at the head — so the court drops to
    /// a plausible standing-eye offset below it.
    #if targetEnvironment(simulator)
    public static let floorY: Float = -1.0
    #else
    public static let floorY: Float = 0.0
    #endif
    /// Ball spawns chest-high, drops in and settles on the floor — visibly in
    /// front of the player (and inside the simulator's fixed view).
    public var ballSpawnPosition = SIMD3<Float>(
        0.0, CoolBallGame.floorY + 1.1, -1.6
    )
    /// Ball this far below the floor is considered lost and respawns.
    private var respawnDepth: Float = 3.0
    /// Loose balls per drop, and the most the scene keeps at once.
    private let looseBallsPerDrop = 5
    private let looseBallLimit = 15
    /// …or this far from where it spawned (through a wall, on the far side
    /// of the safety floor).
    private let respawnRange: Float = 15.0
    /// A size-7 ball is never thrown faster indoors; the built-in backend
    /// enforces the same ceiling on every dynamic body.
    private let maxThrowSpeed: Float = 10.0

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

    /// Installs the chosen physics backend. Must run before the renderer is
    /// created. The registry allows one backend per process: when a backend
    /// is already installed (the immersive space was reopened) it is reused
    /// whatever `engine` asks for — the diagnostics show which one is live.
    @discardableResult
    public func installPhysics(engine: CoolBallPhysicsEngine = .coolBall) -> Bool {
        if let active = PhysicsBackendRegistry.shared.activeBackend() {
            if let builtIn = active as? CoolBallPhysicsBackend {
                backendStore.value = builtIn
            } else if let jolt = active as? JoltPhysicsBackend {
                backendStore.value = CoolBallJoltSimulation(backend: jolt)
            } else {
                return false
            }
            pushWorldPlanes()
            logActiveEngine(requested: engine)
            return true
        }

        switch engine {
        case .coolBall:
            guard let backend = registerCoolBallPhysics() else { return false }
            backendStore.value = backend
        case .jolt:
            var settings = JoltWorldSettings()
            // Hand proxies park 100 m below when tracking drops: re-appearing
            // must be a teleport, not a swat. No hand moves a metre in 1/60 s.
            settings.maxKinematicStep = 1.0
            // Nearer jumps (a tracking hiccup) approach at the built-in
            // backend's hand speed cap instead of striking at full speed.
            settings.maxKinematicSpeed = 6.0
            // Same resting threshold as the built-in backend's floor contacts.
            settings.minContactSpeed = 0.35
            guard let backend = registerJoltPhysics(settings: settings) else { return false }
            backendStore.value = CoolBallJoltSimulation(backend: backend)
        }
        pushWorldPlanes()
        logActiveEngine(requested: engine)
        return true
    }

    /// The backend actually simulating (nil before `installPhysics`).
    public var activeEngine: CoolBallPhysicsEngine? {
        backendStore.value?.engine
    }

    private func logActiveEngine(requested: CoolBallPhysicsEngine) {
        let active = activeEngine?.rawValue ?? "none"
        coolBallLog.log("physics backend: \(active, privacy: .public) (requested \(requested.rawValue, privacy: .public))")
    }

    /// Builds the scene: hand bodies, lighting, and the placement ghost.
    /// Main actor — call from the immersive-space setup closure, before the
    /// render loop starts.
    @MainActor
    public func setupScene() {
        // Engine texture lookups resolve by name through the asset search
        // paths — point them at this package's bundled resources before any
        // textured entity (ball, backboard) is built.
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        scene.createBodyProxies()
        scene.addLighting()
        // Placement first: the hoop appears as a gaze-following ghost; the
        // real hoop and ball are built on confirmation.
        scene.buildHoopGhost()
        scene.moveHoopGhost(
            to: lock.withLock { ghostTarget },
            facing: lock.withLock { ghostFacing }
        )
        subscribeEvents()

        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
        }

        // Test hooks: `-autoPlaceHoop` confirms placement after a short beat,
        // so automated simulator runs reach the playing phase unattended;
        // `-autoDropBalls` then drops the loose balls right after the build.
        if ProcessInfo.processInfo.arguments.contains("-autoPlaceHoop") {
            lock.withLock {
                autoPlaceDeadline = ProcessInfo.processInfo.systemUptime + 1.5
            }
        }
    }

    public var currentPhase: Phase {
        lock.withLock { phase }
    }

    /// Confirms the current ghost position (control-window button, pinch, or
    /// the `-autoPlaceHoop` test hook).
    public func requestHoopPlacement() {
        lock.withLock {
            guard phase == .placingHoop else { return }
            placePending = true
        }
    }

    /// Tears the hoop down and returns to placement (control-window button).
    /// Game thread, like the per-frame update: it drops any grab in progress.
    public func requestHoopMove() {
        let shouldReset = lock.withLock { () -> Bool in
            guard phase == .playing else { return false }
            phase = .placingHoop
            placementGeneration &+= 1
            throughRingAt = nil
            previousBallCenter = nil
            return true
        }
        guard shouldReset else { return }
        cancelGrab()
        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
            pinchWasClosed.removeAll()
        }
        Task { @MainActor in
            // Atomic with respect to the frame loop, which holds the same
            // gate: the physics coordinator never sees a half-built scene.
            withWorldAccessGate {
                self.scene.clear()
                self.scene.createBodyProxies()
                self.scene.addLighting()
                self.scene.buildHoopGhost()
                self.pushWorldPlanes()
            }
        }
    }

    /// Builds the real court at the confirmed spot. Main actor: node creation.
    @MainActor
    private func buildCourt(at position: SIMD3<Float>, facing: SIMD3<Float>, generation: UInt64) {
        // A 'Move hoop' (or shutdown) that landed after this build was
        // scheduled revokes it — the ghost is back, nothing must be built.
        let stillWanted = lock.withLock {
            phase == .playing && generation == placementGeneration
        }
        guard stillWanted else { return }

        scene.removeHoopGhost()
        // Anchor to the measured floor even if the ghost was confirmed
        // before the scan settled.
        let grounded = SIMD3<Float>(position.x, floorLevel.value, position.z)
        scene.buildHoop(at: grounded, facing: facing)

        // Ball appears chest-high right in front of the player, ready to
        // pick up — fall back to a spot between player and hoop when the
        // head isn't tracked yet.
        var spawn = grounded
            + simd_normalize(SIMD3<Float>(facing.x, 0, facing.z)) * 1.5
            + SIMD3<Float>(0, 1.1, 0)
        #if os(visionOS)
        if let head = session.headTransform() {
            let headPosition = SIMD3<Float>(
                head.columns.3.x, head.columns.3.y, head.columns.3.z
            )
            let forward = -SIMD3<Float>(
                head.columns.2.x, head.columns.2.y, head.columns.2.z
            )
            let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
            if simd_length(horizontal) > 0.05 {
                let direction = simd_normalize(horizontal)
                spawn = SIMD3<Float>(
                    headPosition.x + direction.x * 0.7,
                    floorLevel.value + 1.1,
                    headPosition.z + direction.z * 0.7
                )
            }
        }
        #endif
        ballSpawnPosition = spawn
        scene.spawnBall(at: spawn)
        pushWorldPlanes()
        coolBallLog.log("hoop placed at x=\(position.x, format: .fixed(precision: 2)) z=\(position.z, format: .fixed(precision: 2))")
        if ProcessInfo.processInfo.arguments.contains("-autoDropBalls"), let drop = looseBallDropPoint() {
            scene.spawnLooseBalls(count: looseBallsPerDrop, above: drop)
        }
    }

    /// Where loose balls are dropped: in front of the hoop, clear of the
    /// rim, low enough that they pile up instead of bouncing away.
    private func looseBallDropPoint() -> SIMD3<Float>? {
        guard let rimCenter = scene.rimCenter, let forward = scene.hoopForward else { return nil }
        let floor = rimCenter.y - CoolBallScene.rimHeight
        return SIMD3<Float>(rimCenter.x, floor + 0.35, rimCenter.z) + forward * 0.9
    }

    /// Drops five extra balls in front of the hoop (control-window button).
    /// A backend showcase: see `CoolBallScene.spawnLooseBalls`.
    public func requestLooseBalls() {
        guard currentPhase == .playing,
              scene.looseBallCount < looseBallLimit,
              let drop = looseBallDropPoint()
        else { return }
        let generation = lock.withLock { placementGeneration }
        let count = looseBallsPerDrop
        Task { @MainActor in
            withWorldAccessGate {
                let stillPlaying = self.lock.withLock {
                    self.phase == .playing && generation == self.placementGeneration
                }
                guard stillPlaying else { return }
                self.scene.spawnLooseBalls(count: count, above: drop)
            }
        }
    }

    /// Rebuilds the backend's plane set: detected real surfaces plus a
    /// safety floor.
    private func pushWorldPlanes() {
        guard let backend = backendStore.value else { return }
        // Detected surfaces PLUS a safety-net infinite floor at the measured
        // level: ARKit's floor coverage has holes, and a ball that finds one
        // must not fall out of the world.
        var planes = detectedPlanes.value
        planes.append(.infiniteFloor(y: floorLevel.value))
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
        lock.withLock {
            started = false
            placementGeneration &+= 1
            throughRingAt = nil
            previousBallCenter = nil
        }
        cancelGrab()
        audio.stop()
        #if os(visionOS)
        session.stop()
        #endif
        basketSubscription?.cancel()
        contactSubscription?.cancel()
        basketSubscription = nil
        contactSubscription = nil
        scene.clear()
    }

    // MARK: - Score

    public var currentScore: Int {
        lock.withLock { score }
    }

    /// Impulse of the most recent ball contact (N·s) — the control window
    /// shows it as an impact readout.
    public var lastImpulse: Float {
        lock.withLock { lastContactImpulse }
    }

    public func resetScore() {
        lock.withLock { score = 0 }
    }

    /// Puts the ball back at the spawn point, at rest — the control window's
    /// 'Reset ball' and the lost-ball recovery. Game thread.
    public func resetBall() {
        let wasHeld = grabbingSide != nil
        cancelGrab()
        scene.clearLooseBalls()
        lock.withLock {
            throughRingAt = nil
            previousBallCenter = nil
        }
        let spawn = ballSpawnPosition
        scene.moveBall(to: spawn)
        // The teleport goes through the backend: removing and re-adding the
        // body's components within one frame never reaches it (the
        // coordinator diffs the component set per substep and sees no
        // change). A held ball has its components detached, so those are
        // re-registered as well — whichever backend body still exists gets
        // moved, and a missing one is re-added by the next diff.
        if wasHeld {
            scene.attachBallBody(velocity: .zero, at: spawn)
            backendStore.value?.resetBody(entity: scene.ballEntity, position: spawn, velocity: .zero)
        } else if backendStore.value?.resetBody(entity: scene.ballEntity, position: spawn, velocity: .zero) != true {
            scene.attachBallBody(velocity: .zero, at: spawn)
        }
    }

    private func subscribeEvents() {
        basketSubscription = PhysicsEvents.shared.onTrigger { [weak self] event in
            guard let self, event.phase == .entered,
                  event.triggerEntity == self.scene.basketTriggerEntity,
                  event.otherEntity == self.scene.ballEntity
            else { return }
            // The box under the rim is open on every side: only a ball that
            // just crossed the rim plane downward INSIDE the ring has scored.
            // The crossing is normally recorded by the per-frame update; when
            // the same substep both crossed and entered, it is checked here
            // against the last polled position.
            let now = ProcessInfo.processInfo.systemUptime
            let total: Int? = self.lock.withLock {
                var armed = false
                if let at = self.throughRingAt, now - at < self.basketWindow {
                    armed = true
                } else if let previous = self.previousBallCenter,
                          let rimCenter = self.scene.rimCenter,
                          let state = self.backendStore.value?.bodyState(for: self.scene.ballEntity),
                          Self.crossedRimDownward(
                              previous: previous, current: state.position,
                              rimCenter: rimCenter,
                              rimRadius: CoolBallScene.rimRadius,
                              ballRadius: CoolBallScene.ballRadius
                          )
                {
                    armed = true
                }
                guard armed else { return nil }
                self.throughRingAt = nil
                self.score += 1
                return self.score
            }
            guard let total else { return }
            self.audio.playScore()
            print("CoolBall: 🏀 BASKET! score \(total)")
        }
        contactSubscription = PhysicsEvents.shared.onContact { [weak self] event in
            // Only impacts make a sound: Jolt also reports contacts ending.
            guard let self, event.phase == .began else { return }
            self.lock.withLock { self.lastContactImpulse = event.impulse }

            // The bounce. A hand hit sounds at full strength; bounces off the
            // world and the hoop are softer. Impulse for a firm throw-down is
            // ~1-2 N·s; a dying bounce ~0.05.
            let other = event.entityA == self.scene.ballEntity ? event.entityB : event.entityA
            let isHandContact = other == self.scene.leftHandEntity
                || other == self.scene.rightHandEntity
            let scale: Float = isHandContact ? 1.0 : 0.5
            self.audio.playBounce(intensity: min(event.impulse / 1.2, 1.0) * scale)
        }
    }

    /// True when the ball center moved from on/above the rim plane to below
    /// it, and the interpolated crossing point lies inside the ring with a
    /// ball radius to spare — the geometric test for "went through the hoop".
    static func crossedRimDownward(
        previous: SIMD3<Float>,
        current: SIMD3<Float>,
        rimCenter: SIMD3<Float>,
        rimRadius: Float,
        ballRadius: Float
    ) -> Bool {
        guard previous.y >= rimCenter.y, current.y < rimCenter.y else { return false }
        let span = previous.y - current.y
        let t = span > 1e-6 ? (previous.y - rimCenter.y) / span : 0
        let crossing = previous + (current - previous) * t
        let dx = crossing.x - rimCenter.x
        let dz = crossing.z - rimCenter.z
        return (dx * dx + dz * dz).squareRoot() < rimRadius - ballRadius
    }

    // MARK: - Per-frame update (XR render thread)

    public func update(deltaTime: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if currentPhase == .placingHoop {
            updatePlacement(now: now)
            return
        }

        #if os(visionOS)
        updateHands(now: now)
        #endif
        trackRingCrossing(now: now)

        // TEMP diagnostics: ball state heartbeat (os_log reaches `log stream`).
        heartbeatAccumulator += deltaTime
        if heartbeatAccumulator > 1.0 {
            heartbeatAccumulator = 0
            if let state = backendStore.value?.bodyState(for: scene.ballEntity) {
                coolBallLog.log("ball y=\(state.position.y, format: .fixed(precision: 3)) z=\(state.position.z, format: .fixed(precision: 3)) v=\(simd_length(state.velocity), format: .fixed(precision: 3)) loose=\(self.scene.looseBallCount)")
            }
        }

        respawnIfLost()
    }

    /// Records a downward crossing of the rim plane inside the ring (arms the
    /// basket for `basketWindow`), and disarms when the ball climbs back
    /// above the rim.
    private func trackRingCrossing(now: TimeInterval) {
        guard let state = backendStore.value?.bodyState(for: scene.ballEntity) else {
            lock.withLock { previousBallCenter = nil }
            return
        }
        lock.withLock {
            defer { previousBallCenter = state.position }
            guard let previous = previousBallCenter, let rimCenter = scene.rimCenter else { return }
            if Self.crossedRimDownward(
                previous: previous, current: state.position,
                rimCenter: rimCenter,
                rimRadius: CoolBallScene.rimRadius,
                ballRadius: CoolBallScene.ballRadius
            ) {
                throughRingAt = now
            } else if previous.y < rimCenter.y, state.position.y >= rimCenter.y {
                throughRingAt = nil
            }
        }
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
            // buttons) must not drag the hoop along.
            let floor = floorLevel.value
            let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
            let horizontalLength = simd_length(horizontal)
            if horizontalLength > 0.05, forward.y < -0.12 {
                let direction = horizontal / horizontalLength
                let drop = headPosition.y - floor
                var distance = drop * horizontalLength / -forward.y
                distance = min(max(distance, 1.2), 4.5)
                target = SIMD3<Float>(
                    headPosition.x + direction.x * distance,
                    floor,
                    headPosition.z + direction.z * distance
                )
                facing = -direction // backboard faces the player
            }

            // Pinch to confirm — but only a FRESH pinch, after a grace
            // period: the pinch that pressed 'Move hoop' (or opened the
            // space) must not instantly re-place the hoop.
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
        scene.moveHoopGhost(to: target, facing: facing)

        let scheduled: UInt64? = lock.withLock {
            if let deadline = autoPlaceDeadline, now >= deadline {
                autoPlaceDeadline = nil
                placePending = true
            }
            guard placePending, phase == .placingHoop else { return nil }
            placePending = false
            phase = .playing // buildCourt verifies this reservation still holds
            return placementGeneration
        }
        if let generation = scheduled {
            Task { @MainActor in
                withWorldAccessGate {
                    self.buildCourt(at: target, facing: facing, generation: generation)
                }
            }
        }
    }

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

            // Just threw: the collider stays parked until the ball is clear
            // of the hand.
            if let parkedUntil = handParkedUntil[side], now < parkedUntil {
                scene.moveProxy(handEntity, to: nil)
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
        lock.withLock {
            throughRingAt = nil
            previousBallCenter = nil
        }
        scene.detachBallBody()
        scene.moveBall(to: pose.pinchPoint)
        print("CoolBall: ball grabbed (\(side == .left ? "left" : "right"))")
    }

    private func releaseBall(at position: SIMD3<Float>?, now: TimeInterval) {
        if let side = grabbingSide {
            handParkedUntil[side] = now + releaseCooldown
        }
        defer { cancelGrab() }
        let releasePoint = position
            ?? grabSamples.last?.position
            ?? scene.ballPosition()
            ?? ballSpawnPosition

        // Throw velocity: displacement over the sampled window, capped so a
        // glitched pinch sample cannot launch the ball through a wall.
        var velocity = SIMD3<Float>.zero
        if let first = grabSamples.first, let last = grabSamples.last {
            let dt = Float(last.time - first.time)
            if dt > 0.01 {
                velocity = (last.position - first.position) / dt
                let speed = simd_length(velocity)
                if speed > maxThrowSpeed {
                    velocity *= maxThrowSpeed / speed
                }
            }
        }
        scene.attachBallBody(velocity: velocity, at: releasePoint)
        print(String(
            format: "CoolBall: thrown at %.1f m/s", simd_length(velocity)
        ))
    }
    #endif

    /// Drops any grab in progress without a throw (Move hoop, Reset ball,
    /// shutdown). Game thread only, like the grab logic itself.
    private func cancelGrab() {
        grabbingSide = nil
        grabSamples.removeAll()
    }

    private func respawnIfLost() {
        guard grabbingSide == nil, let position = scene.ballPosition() else { return }
        let fellOut = position.y < floorLevel.value - respawnDepth
        let horizontal = SIMD3<Float>(position.x - ballSpawnPosition.x, 0, position.z - ballSpawnPosition.z)
        let wanderedOff = simd_length(horizontal) > respawnRange
        guard fellOut || wanderedOff else { return }
        resetBall()
        print("CoolBall: ball lost \(fellOut ? "below the world" : "far away") — respawned")
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
    /// in a plausible band below the head — preferring planes ARKit itself
    /// classified as floor, so a low table or a stair landing can't win.
    private func updateFloorLevel(planes: [CoolBallWorldPlane], headY: Float?) {
        let reference = headY ?? 0
        let candidates = planes.filter { plane in
            plane.normal.y > 0.85
                && plane.center.y < reference - 0.5
                && plane.center.y > reference - 2.8
        }
        let classified = candidates.filter(\.isFloor)
        let pool = classified.isEmpty ? candidates : classified
        guard let lowest = pool.min(by: { $0.center.y < $1.center.y }) else { return }
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
