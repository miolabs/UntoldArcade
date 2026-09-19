//
//  CoolBasketGame.swift
//  CoolBasket
//
//  Frame-driven basketball logic. The hands are kinematic sphere bodies fed
//  from hand tracking: they dribble and swat the balls through plain
//  collisions, and a pinch near a ball grabs it (the body's components are
//  removed — the coordinator diff takes it out of the backend), carrying it
//  until release throws it with the tracked hand velocity. Drop as many
//  balls as you like; every ball is equal. Score by putting one down through
//  the rim: a downward crossing of the rim plane inside the ring, confirmed
//  by the under-rim trigger firing through PhysicsEvents.
//

import Foundation
import os
import simd
import UntoldEngine
import UntoldJoltPhysics

public final class CoolBasketGame: @unchecked Sendable {
    public let scene = CoolBasketScene()
    /// Synthesized bounce/score sounds (no asset files).
    public let audio = CoolBasketAudio()
    private let backendStore = CoolBasketLockedBox<(any CoolBasketSimulation)?>(nil)

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
    private var ghostTarget = SIMD3<Float>(0, CoolBasketGame.floorY, -2.6)
    private var ghostFacing = SIMD3<Float>(0, 0, 1)
    private var autoPlaceDeadline: TimeInterval?
    /// Placement ignores pinches until this time (the pinch that pressed
    /// 'Move hoop' must not instantly re-place the hoop) and requires each
    /// confirming pinch to be freshly closed.
    private var placementPinchGraceUntil: TimeInterval = 0
    private var pinchWasClosed: [CoolBasketHandSide: Bool] = [:]
    /// Bumped by 'Move hoop': a court build scheduled before the move must
    /// not land after it.
    private var placementGeneration: UInt64 = 0
    private var started = false
    private var score = 0
    private var basketSubscription: EventSubscription?
    private var contactSubscription: EventSubscription?
    private var lastContactImpulse: Float = 0
    /// The simulated net while a hoop stands on the Jolt backend (frame
    /// thread; see `updateNet`).
    private var net: CoolBasketNet?

    // Ring-crossing state per ball (guarded by `lock`: written by the
    // per-frame update, read by the trigger handler).
    private var previousCenters: [EntityID: SIMD3<Float>] = [:]
    private var throughRingAt: [EntityID: TimeInterval] = [:]
    /// A made basket must reach the under-rim trigger within this long after
    /// crossing the rim plane downward inside the ring.
    private let basketWindow: TimeInterval = 0.6

    // Grab state (game thread only).
    private var grabbingSide: CoolBasketHandSide?
    private var heldBall: EntityID?
    private var grabSamples: [(position: SIMD3<Float>, time: TimeInterval)] = []
    /// The grabbing hand is out of the cameras' view: the ball waits where
    /// it was (see `updateHands`). The other hand may take it meanwhile.
    private var holdSuspended = false
    /// When the grabbing hand came back into view, so the first frames'
    /// pinch reading — noisy at the edge of view — cannot drop the ball.
    private var holdRegainedAt: TimeInterval = 0
    private let pinchSettleTime: TimeInterval = 0.08
    /// The lowest downward-facing surface ARKit has seen (the ceiling), for
    /// the diagnostics: the rim height was set by feel, this measures the
    /// room it has to fit.
    private let ceilingLevel = CoolBasketLockedBox<Float?>(nil)
    /// The hand that just threw is parked briefly so the ball, re-added at
    /// the pinch point, isn't shoved by that hand's own collider.
    private var handParkedUntil: [CoolBasketHandSide: TimeInterval] = [:]
    private let releaseCooldown: TimeInterval = 0.12
    /// Pinch tighter than this grabs; wider than this releases (hysteresis).
    private let pinchGrabDistance: Float = 0.025
    private let pinchReleaseDistance: Float = 0.045
    /// Palm must be this close to a ball to pick it up.
    private let grabReach: Float = 0.30
    /// A size-7 ball is never thrown faster indoors; the built-in backend
    /// enforces the same ceiling on every dynamic body.
    private let maxThrowSpeed: Float = 10.0

    /// Floor height in the world frame. On device the ARKit world origin sits
    /// on the floor beneath the user, so 0 is right. The SIMULATOR has no
    /// floor calibration — its origin is at the head — so the court drops to
    /// a plausible standing-eye offset below it.
    #if targetEnvironment(simulator)
    public static let floorY: Float = -1.0
    #else
    public static let floorY: Float = 0.0
    #endif
    /// Fallback drop point when the head isn't tracked: chest-high, in front
    /// of the player (and inside the simulator's fixed view).
    public var ballSpawnPosition = SIMD3<Float>(
        0.0, CoolBasketGame.floorY + 1.1, -1.6
    )
    /// A ball this far below the floor, or this far from the court, is lost
    /// and comes back at the drop point.
    private let respawnDepth: Float = 3.0
    private let respawnRange: Float = 15.0
    /// Balls in play at once; dropping one more retires the oldest.
    private let maxBalls = 24

    #if os(visionOS)
    public let session = CoolBasketSpatialSession()
    #endif

    private let detectedPlanes = CoolBasketLockedBox<[CoolBasketWorldPlane]>([])
    /// The real floor height, measured from detected upward planes below the
    /// head (the compile-time constant is only the pre-scan default: on
    /// device the world origin is NOT reliably on the real floor).
    private let floorLevel = CoolBasketLockedBox<Float>(CoolBasketGame.floorY)
    private var heartbeatAccumulator: Float = 0

    public init() {}

    // MARK: - Lifecycle

    /// Installs the chosen physics backend. Must run before the renderer is
    /// created. The registry allows one backend per process: when a backend
    /// is already installed (the immersive space was reopened) it is reused
    /// whatever `engine` asks for — the diagnostics show which one is live.
    @discardableResult
    public func installPhysics(engine: CoolBasketPhysicsEngine = .coolBasket) -> Bool {
        if let active = PhysicsBackendRegistry.shared.activeBackend() {
            if let builtIn = active as? CoolBasketPhysicsBackend {
                backendStore.value = builtIn
            } else if let jolt = active as? JoltPhysicsBackend {
                backendStore.value = CoolBasketJoltSimulation(backend: jolt)
            } else {
                return false
            }
            pushWorldPlanes()
            logActiveEngine(requested: engine)
            return true
        }

        switch engine {
        case .coolBasket:
            guard let backend = registerCoolBasketPhysics() else { return false }
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
            backendStore.value = CoolBasketJoltSimulation(backend: backend)
        }
        pushWorldPlanes()
        logActiveEngine(requested: engine)
        return true
    }

    /// The backend actually simulating (nil before `installPhysics`).
    public var activeEngine: CoolBasketPhysicsEngine? {
        backendStore.value?.engine
    }

    private func logActiveEngine(requested: CoolBasketPhysicsEngine) {
        let active = activeEngine?.rawValue ?? "none"
        coolBasketLog.log("physics backend: \(active, privacy: .public) (requested \(requested.rawValue, privacy: .public))")
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
        // `-autoDropBalls` then drops five balls in front of the hoop,
        // `-autoDropThroughRim` one through the rim, `-autoPlaceDistance`
        // sets how far ahead the hoop goes.
        if ProcessInfo.processInfo.arguments.contains("-autoPlaceHoop") {
            lock.withLock {
                autoPlaceDeadline = ProcessInfo.processInfo.systemUptime + 1.5
            }
        }
        // `-autoPlaceDistance <m>` puts the hoop that far ahead instead of
        // 2.6 m (the simulator's fixed view sees the rim only from afar).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-autoPlaceDistance"), index + 1 < arguments.count,
           let distance = Float(arguments[index + 1]), distance > 0
        {
            lock.withLock { ghostTarget.z = -distance }
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
            throughRingAt.removeAll()
            previousCenters.removeAll()
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

        // The first ball appears in front of the player, ready to pick up.
        ballSpawnPosition = grounded
            + simd_normalize(SIMD3<Float>(facing.x, 0, facing.z)) * 1.5
            + SIMD3<Float>(0, 1.1, 0)
        scene.spawnBall(at: dropPoint())
        pushWorldPlanes()
        coolBasketLog.log("hoop placed at x=\(position.x, format: .fixed(precision: 2)) z=\(position.z, format: .fixed(precision: 2))")

        // `-autoDropThroughRim` drops one ball from above the rim centre —
        // a swish, for watching the net — once the model has streamed in.
        if ProcessInfo.processInfo.arguments.contains("-autoDropThroughRim"), let rimCenter = scene.rimCenter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                let stillWanted = self.lock.withLock { self.phase == .playing && generation == self.placementGeneration }
                guard stillWanted else { return }
                self.scene.spawnBall(at: rimCenter + SIMD3<Float>(0, 0.6, 0))
                coolBasketLog.log("dropped a ball through the rim")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-autoDropBalls"),
           let rimCenter = scene.rimCenter, let forward = scene.hoopForward
        {
            // In front of the hoop and in the simulator's fixed view.
            let base = SIMD3<Float>(rimCenter.x, floorLevel.value + 0.35, rimCenter.z) + forward * 0.9
            for index in 0 ..< 5 {
                let angle = Float(index) * 2.4
                scene.spawnBall(at: base + SIMD3<Float>(cosf(angle) * 0.03, Float(index) * CoolBasketScene.ballRadius * 2.2, sinf(angle) * 0.03))
            }
        }
    }

    /// Where a new ball appears: chest-high, 0.7 m in front of the player's
    /// head; the fallback spot when the head isn't tracked.
    private func dropPoint() -> SIMD3<Float> {
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
                return SIMD3<Float>(
                    headPosition.x + direction.x * 0.7,
                    floorLevel.value + 1.1,
                    headPosition.z + direction.z * 0.7
                )
            }
        }
        #endif
        return ballSpawnPosition
    }

    /// Drops one more ball in front of the player (control-window button).
    /// Beyond `maxBalls` the oldest ball not in hand is retired first.
    public func requestDropBall() {
        guard currentPhase == .playing else { return }
        let generation = lock.withLock { placementGeneration }
        let point = dropPoint()
        Task { @MainActor in
            withWorldAccessGate {
                let stillPlaying = self.lock.withLock {
                    self.phase == .playing && generation == self.placementGeneration
                }
                guard stillPlaying else { return }
                self.retireOldestBallIfNeeded()
                self.scene.spawnBall(at: point)
            }
        }
    }

    private func retireOldestBallIfNeeded() {
        guard scene.ballCount >= maxBalls else { return }
        let held = heldBall
        guard let oldest = scene.balls.first(where: { $0 != held }) else { return }
        scene.removeBall(oldest)
        lock.withLock {
            previousCenters.removeValue(forKey: oldest)
            throughRingAt.removeValue(forKey: oldest)
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
            // Real surfaces replace the fallback floor as soon as they exist;
            // the ceiling stays out so a high arc isn't stopped by the room.
            self.noteCeiling(planes)
            let planes = Self.playablePlanes(planes)
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
            throughRingAt.removeAll()
            previousCenters.removeAll()
        }
        // The Jolt world outlives the space; a net left in it would go on
        // catching balls, invisibly, next time.
        net?.remove()
        net = nil
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

    public var ballCount: Int {
        scene.ballCount
    }

    public func resetScore() {
        lock.withLock { score = 0 }
    }

    private func subscribeEvents() {
        basketSubscription = PhysicsEvents.shared.onTrigger { [weak self] event in
            guard let self, event.phase == .entered,
                  event.triggerEntity == self.scene.basketTriggerEntity,
                  self.scene.isBall(event.otherEntity)
            else { return }
            let ball = event.otherEntity
            // The box under the rim is open on every side: only a ball that
            // just crossed the rim plane downward INSIDE the ring has scored.
            // The crossing is normally recorded by the per-frame update; when
            // the same substep both crossed and entered, it is checked here
            // against the last polled position.
            let now = ProcessInfo.processInfo.systemUptime
            let total: Int? = self.lock.withLock {
                var armed = false
                if let at = self.throughRingAt[ball], now - at < self.basketWindow {
                    armed = true
                } else if let previous = self.previousCenters[ball],
                          let rimCenter = self.scene.rimCenter,
                          let state = self.backendStore.value?.bodyState(for: ball),
                          Self.crossedRimDownward(
                              previous: previous, current: state.position,
                              rimCenter: rimCenter,
                              rimRadius: CoolBasketScene.rimRadius,
                              ballRadius: CoolBasketScene.ballRadius
                          )
                {
                    armed = true
                }
                guard armed else { return nil }
                self.throughRingAt.removeValue(forKey: ball)
                self.score += 1
                return self.score
            }
            guard let total else { return }
            self.audio.playScore()
            print("CoolBasket: 🏀 BASKET! score \(total)")
        }
        contactSubscription = PhysicsEvents.shared.onContact { [weak self] event in
            // Only impacts make a sound: Jolt also reports contacts ending.
            guard let self, event.phase == .began else { return }
            let ballIsA = self.scene.isBall(event.entityA)
            guard ballIsA || self.scene.isBall(event.entityB) else { return }
            self.lock.withLock { self.lastContactImpulse = event.impulse }

            // The bounce. A hand hit sounds at full strength; bounces off the
            // world, the hoop and other balls are softer. Impulse for a firm
            // throw-down is ~1-2 N·s; a dying bounce ~0.05.
            let other = ballIsA ? event.entityB : event.entityA
            let isHandContact = other == self.scene.leftHandEntity
                || other == self.scene.rightHandEntity
            let scale: Float = isHandContact ? 1.0 : 0.5
            self.audio.playBounce(intensity: min(event.impulse / 1.2, 1.0) * scale)
        }
    }

    /// True when a ball center moved from on/above the rim plane to below
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
        scene.tintHoopGlassIfNeeded()
        updateNet()
        let now = ProcessInfo.processInfo.systemUptime
        if currentPhase == .placingHoop {
            updatePlacement(now: now)
            return
        }

        #if os(visionOS)
        updateHands(now: now)
        #endif
        trackRingCrossings(now: now)

        // TEMP diagnostics: ball state heartbeat (os_log reaches `log stream`).
        heartbeatAccumulator += deltaTime
        if heartbeatAccumulator > 1.0 {
            heartbeatAccumulator = 0
            for ball in scene.balls.suffix(2) {
                guard let state = backendStore.value?.bodyState(for: ball) else { continue }
                coolBasketLog.log("ball \(ball) y=\(state.position.y, format: .fixed(precision: 3)) z=\(state.position.z, format: .fixed(precision: 3)) v=\(simd_length(state.velocity), format: .fixed(precision: 3)) balls=\(self.scene.ballCount)")
            }
            if let net {
                coolBasketLog.log("net peak displacement \(net.takePeakDisplacement(), format: .fixed(precision: 3)) m, driving \(net.boundMeshCount) meshes")
            }
        }

        recoverLostBalls()
    }

    /// Keeps the simulated net in step with the hoop: built (as a Jolt soft
    /// body) once a hoop stands on the Jolt backend, driven every frame,
    /// removed when the hoop goes. On the built-in backend the model's net
    /// stays static.
    private func updateNet() {
        guard let jolt = backendStore.value as? CoolBasketJoltSimulation else { return }
        if let origin = scene.hoopModelOrigin, let orientation = scene.hoopModelOrientation {
            if net == nil {
                net = CoolBasketNet(backend: jolt.backend, origin: origin, orientation: orientation)
                coolBasketLog.log("net: \(self.net == nil ? "refused by the world" : "simulating", privacy: .public)")
            }
            net?.update(partEntities: scene.netPartEntities)
        } else if let standing = net {
            standing.remove()
            net = nil
        }
    }

    /// Whether the net is simulating right now.
    public var isNetSimulated: Bool { net != nil }

    /// Records a downward crossing of the rim plane inside the ring for each
    /// ball (arms its basket for `basketWindow`), and disarms when a ball
    /// climbs back above the rim.
    private func trackRingCrossings(now: TimeInterval) {
        guard let backend = backendStore.value else { return }
        let rimCenter = scene.rimCenter
        for ball in scene.balls {
            guard let state = backend.bodyState(for: ball) else {
                lock.withLock { _ = previousCenters.removeValue(forKey: ball) }
                continue
            }
            lock.withLock {
                defer { previousCenters[ball] = state.position }
                guard let previous = previousCenters[ball], let rimCenter else { return }
                if Self.crossedRimDownward(
                    previous: previous, current: state.position,
                    rimCenter: rimCenter,
                    rimRadius: CoolBasketScene.rimRadius,
                    ballRadius: CoolBasketScene.ballRadius
                ) {
                    throughRingAt[ball] = now
                } else if previous.y < rimCenter.y, state.position.y >= rimCenter.y {
                    throughRingAt.removeValue(forKey: ball)
                }
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
            for side in CoolBasketHandSide.allCases {
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
        for side in CoolBasketHandSide.allCases {
            let handEntity = side == .left
                ? scene.leftHandEntity
                : scene.rightHandEntity

            // ~50 ms prediction keeps the collider on a fast-moving hand.
            guard let pose = session.predictedHandPose(side, at: now + 0.05),
                  pose.isTracked
            else {
                scene.moveProxy(handEntity, to: nil)
                if grabbingSide == side, !holdSuspended {
                    // The hand left the cameras' view holding the ball.
                    // Mid-swing, that is the throw: release it with the
                    // motion it had. Otherwise — looking up at the hoop takes
                    // a resting hand out of view — the ball waits where it
                    // was until the hand is seen again: a still-closed pinch
                    // carries on, an open one releases. Dropping it here made
                    // a throw impossible.
                    if Self.releasesOnLoss(samples: grabSamples, now: now, maxSpeed: maxThrowSpeed) {
                        releaseBall(at: nil, now: now)
                    } else {
                        holdSuspended = true
                    }
                }
                continue
            }
            if grabbingSide == side, holdSuspended {
                holdSuspended = false
                holdRegainedAt = now
                grabSamples.removeAll()
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

    private func updateGrab(side: CoolBasketHandSide, pose: CoolBasketHandPose, now: TimeInterval) {
        if grabbingSide == side, let held = heldBall {
            if pose.pinchDistance > pinchReleaseDistance {
                if grabSamples.isEmpty {
                    // Back in view with the hand already open: the ball was
                    // let go out of view. It drops from where it waited —
                    // not snapped to a hand that is itself in motion.
                    releaseBall(at: scene.ballPosition(held), now: now)
                } else if now - holdRegainedAt >= pinchSettleTime {
                    releaseBall(at: pose.pinchPoint, now: now)
                }
                // Else: an open reading in the first frames back in view,
                // after a closed one — noise at the edge of view; hold on.
            } else {
                let position = pose.pinchPoint
                scene.moveBall(held, to: position)
                grabSamples.append((position, now))
                // Keep a short motion history for the throw velocity.
                while let first = grabSamples.first, now - first.time > Self.throwSampleAge {
                    grabSamples.removeFirst()
                }
            }
            return
        }

        // A new grab — or the other hand taking a ball whose hand is out of
        // view.
        guard grabbingSide == nil || holdSuspended, pose.pinchDistance < pinchGrabDistance else { return }
        // The nearest ball within reach of the palm.
        var nearest: (entity: EntityID, distance: Float)?
        for ball in scene.balls {
            guard let position = scene.ballPosition(ball) else { continue }
            let distance = simd_length(position - pose.palm)
            if distance < grabReach, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (ball, distance)
            }
        }
        guard let ball = nearest?.entity else { return }

        let takingOver = ball == heldBall
        grabbingSide = side
        heldBall = ball
        holdSuspended = false
        holdRegainedAt = 0
        grabSamples = [(pose.pinchPoint, now)]
        lock.withLock {
            throughRingAt.removeValue(forKey: ball)
            previousCenters.removeValue(forKey: ball)
        }
        // A suspended ball has no body already.
        if !takingOver {
            scene.detachBallBody(entity: ball)
        }
        scene.moveBall(ball, to: pose.pinchPoint)
        print("CoolBasket: ball grabbed (\(side == .left ? "left" : "right"))")
    }

    private func releaseBall(at position: SIMD3<Float>?, now: TimeInterval) {
        if let side = grabbingSide {
            handParkedUntil[side] = now + releaseCooldown
            // Off the hand right away: the body comes back next substep,
            // where a collider still on the palm would swat it.
            scene.moveProxy(side == .left ? scene.leftHandEntity : scene.rightHandEntity, to: nil)
        }
        defer { cancelGrab() }
        guard let ball = heldBall else { return }
        let releasePoint = position
            ?? grabSamples.last?.position
            ?? scene.ballPosition(ball)
            ?? ballSpawnPosition

        let velocity = Self.throwVelocity(samples: grabSamples, now: now, maxSpeed: maxThrowSpeed)
        scene.attachBallBody(entity: ball, velocity: velocity, at: releasePoint)
        print(String(
            format: "CoolBasket: thrown at %.1f m/s", simd_length(velocity)
        ))
    }
    #endif

    /// A hand leaving the view faster than this was mid-throw. Carrying the
    /// ball while looking up at the hoop, or walking with it, is slower.
    static let lossThrowSpeed: Float = 2.0

    /// Whether a hand that just left the cameras' view, holding the ball,
    /// was throwing it: then the ball goes with that motion; otherwise it
    /// waits for the hand.
    static func releasesOnLoss(
        samples: [(position: SIMD3<Float>, time: TimeInterval)], now: TimeInterval, maxSpeed: Float
    ) -> Bool {
        simd_length(throwVelocity(samples: samples, now: now, maxSpeed: maxSpeed)) >= lossThrowSpeed
    }

    /// The motion window behind a throw: samples older than this are not
    /// kept while holding, and say nothing at release — the hand was out of
    /// view since, and the ball waited.
    static let throwSampleAge: TimeInterval = 0.12

    /// Throw velocity from the hand's recent motion: displacement over the
    /// sampled window, capped so a glitched pinch sample cannot launch the
    /// ball through a wall. Samples older than `throwSampleAge` are
    /// ignored — a ball released after the hand was lost from view is
    /// dropped, not thrown with the motion from before.
    static func throwVelocity(
        samples: [(position: SIMD3<Float>, time: TimeInterval)], now: TimeInterval, maxSpeed: Float
    ) -> SIMD3<Float> {
        let recent = samples.filter { now - $0.time <= throwSampleAge }
        guard let first = recent.first, let last = recent.last else { return .zero }
        let dt = Float(last.time - first.time)
        guard dt > 0.01 else { return .zero }
        var velocity = (last.position - first.position) / dt
        let speed = simd_length(velocity)
        if speed > maxSpeed {
            velocity *= maxSpeed / speed
        }
        return velocity
    }

    /// Drops any grab in progress without a throw (Move hoop, shutdown).
    /// Game thread only, like the grab logic itself.
    private func cancelGrab() {
        grabbingSide = nil
        heldBall = nil
        holdSuspended = false
        holdRegainedAt = 0
        grabSamples.removeAll()
    }

    /// A ball below the floor or far from the court comes back at the drop
    /// point, at rest. The teleport goes through the backend: removing and
    /// re-adding the body's components within one frame never reaches it
    /// (the coordinator diffs the component set per substep).
    private func recoverLostBalls() {
        let floor = floorLevel.value
        for ball in scene.balls where ball != heldBall {
            guard let position = scene.ballPosition(ball) else { continue }
            let fellOut = position.y < floor - respawnDepth
            let horizontal = SIMD3<Float>(position.x - ballSpawnPosition.x, 0, position.z - ballSpawnPosition.z)
            guard fellOut || simd_length(horizontal) > respawnRange else { continue }
            let point = dropPoint()
            lock.withLock {
                throughRingAt.removeValue(forKey: ball)
                previousCenters.removeValue(forKey: ball)
            }
            scene.moveBall(ball, to: point)
            if backendStore.value?.resetBody(entity: ball, position: point, velocity: .zero) != true {
                scene.attachBallBody(entity: ball, velocity: .zero, at: point)
            }
            print("CoolBasket: ball lost \(fellOut ? "below the world" : "far away") — brought back")
        }
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
    /// Remembers the lowest ceiling ARKit has seen and logs it when it
    /// changes: whether the rim fits the room is a measurement, not a guess.
    private func noteCeiling(_ planes: [CoolBasketWorldPlane]) {
        guard let ceiling = planes.filter({ $0.normal.y < -0.5 }).map(\.center.y).min() else { return }
        let previous = ceilingLevel.value
        guard previous == nil || abs(previous! - ceiling) > 0.05 else { return }
        ceilingLevel.value = ceiling
        let floor = floorLevel.value
        coolBasketLog.log("ceiling at y=\(ceiling, format: .fixed(precision: 2)) (\(ceiling - floor, format: .fixed(precision: 2)) m above the floor; rim at \(CoolBasketScene.rimHeight, format: .fixed(precision: 2)))")
    }

    /// The room's surfaces the ball plays against: the floor, the walls and
    /// whatever furniture faces up. Anything facing down — the ceiling, the
    /// underside of a shelf — is left out: the hoop stands tall and a lob
    /// has to be free to go up.
    static func playablePlanes(_ planes: [CoolBasketWorldPlane]) -> [CoolBasketWorldPlane] {
        planes.filter { $0.normal.y > -0.5 }
    }

    private func updateFloorLevel(planes: [CoolBasketWorldPlane], headY: Float?) {
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
final class CoolBasketLockedBox<Value>: @unchecked Sendable {
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

let coolBasketLog = Logger(subsystem: "com.miolabs.coolbasket", category: "game")
