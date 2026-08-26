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

    private let lock = NSLock()
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
    /// Ball below this height is considered lost and respawns.
    public var respawnFloorY: Float = CoolBallGame.floorY - 3.0

    #if os(visionOS)
    public let session = CoolBallSpatialSession()
    #endif

    private let detectedPlanes = CoolBallLockedBox<[CoolBallWorldPlane]>([])
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
        scene.buildGoal(
            at: SIMD3<Float>(0.0, Self.floorY, -2.6),
            facing: SIMD3<Float>(0.0, 0.0, 1.0)
        )
        scene.spawnBall(at: ballSpawnPosition)
        subscribeEvents()
        // The goal now exists: include its net catch plane.
        pushWorldPlanes()
    }

    /// Rebuilds the backend's plane set: detected real surfaces (or the
    /// fallback floor) plus the goal net's backstop.
    private func pushWorldPlanes() {
        guard let backend = backendStore.value else { return }
        let detected = detectedPlanes.value
        var planes = detected.isEmpty ? [CoolBallWorldPlane.infiniteFloor(y: Self.floorY)] : detected
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

        // The net cloth follows the simulated ball (or the held one).
        let ballCenter = backendStore.value?.bodyState(for: scene.ballEntity)?.position
            ?? scene.ballPosition()
        scene.net.step(
            deltaTime: deltaTime,
            ballCenter: ballCenter,
            ballRadius: CoolBallScene.ballRadius
        )

        respawnIfLost()
    }

    #if os(visionOS)
    /// Places the boot from head tracking: under the head, at floor level,
    /// leading ahead of the body's horizontal velocity. The kinematic-target
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

        if let previous = previousHeadPosition {
            let dt = Float(now - previousHeadTime)
            if dt > 0.001 {
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

        let footPosition = SIMD3<Float>(
            headPosition.x + smoothedBodyVelocity.x * footLead,
            Self.floorY + CoolBallScene.footRadius * 0.9,
            headPosition.z + smoothedBodyVelocity.z * footLead
        )
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
              position.y < respawnFloorY
        else { return }
        scene.respawnBall(at: ballSpawnPosition)
        print("CoolBall: ball lost below the world — respawned")
    }

    // MARK: - Diagnostics

    public var worldPlaneCount: Int {
        backendStore.value?.worldPlaneCount ?? 0
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
