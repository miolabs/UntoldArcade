//
//  ZombieChaseGame.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine

/// A zombie that waits a few meters away and chases the player once they
/// come close. Every frame the game states a *goal* (desired velocity and
/// facing toward the player); motion matching picks the clips — walks,
/// chases, circular sprints, pivots — root motion moves the character and
/// foot IK plants its feet. No animation state machine, no code steering.
///
/// Platform-neutral: the player position comes from the host (the head
/// pose on visionOS, anything on the desktop). Scene construction is
/// main-actor; per-frame updates may run on the XR render thread.
public final class ZombieChaseGame: @unchecked Sendable {
    public enum Phase: Sendable {
        /// Standing at the spawn point, shambling, waiting for the player.
        case waiting
        /// The player crossed the trigger radius: hunting.
        case chasing
        /// Within arm's reach of the player: stopped, facing them.
        case holding
    }

    public struct Configuration: Sendable {
        /// Floor height in world units. The visionOS simulator has no floor
        /// calibration (its origin is at the head), so hosts pass -1.0
        /// there; a calibrated device uses 0.
        public var floorY: Float = 0
        /// Where the zombie waits, straight ahead of the initial view.
        public var spawnDistance: Float = 4.0
        /// Come this close and it starts chasing.
        public var triggerRadius: Float = 2.5
        /// It never walks into the player: the goal drops to zero here.
        /// The last step plays out and the velocity crossfade decays, so it
        /// settles a few centimetres closer than this — about arm's length.
        public var stopDistance: Float = 1.4
        /// ...and resumes only once the player has backed off to here.
        public var resumeDistance: Float = 2.0
        /// Gait clusters (the clip set has no coverage between them).
        public var chaseEnterDistance: Float = 4.5
        public var chaseExitDistance: Float = 3.0

        public init() {}
    }

    // Rig constants (UE4 Mannequin skeleton).
    private enum Rig {
        static let leftFoot = "/root/pelvis/thigh_l/calf_l/foot_l"
        static let rightFoot = "/root/pelvis/thigh_r/calf_r/foot_r"
        static let leftLeg = (hip: "/root/pelvis/thigh_l", knee: "/root/pelvis/thigh_l/calf_l")
        static let rightLeg = (hip: "/root/pelvis/thigh_r", knee: "/root/pelvis/thigh_r/calf_r")
    }

    // Authored clip speeds: walk/chase 0.4-0.91, hyper 2.73-5.56.
    private enum Locomotion {
        static let maxSpeed: Float = 5.56
        static let walkTopSpeed: Float = 0.91
        /// Never ask for a creep: below this the matcher cannot tell the
        /// goal from standing still.
        static let walkFloorSpeed: Float = 0.3
        static let chaseFloorSpeed: Float = 2.73
        static let speedPerMeter: Float = 1.0
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var zombie: EntityID = .invalid
    private var ready = false
    private var phaseStorage: Phase = .waiting
    private var hyper = false
    private var moving = false
    private var distanceStorage: Float = .infinity
    private var provokePending = false
    private var resetPending = false
    private var lightingApplied = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Host-facing state

    public var phase: Phase { lock.withLock { phaseStorage } }
    /// Horizontal distance to the player last frame.
    public var distanceToPlayer: Float { lock.withLock { distanceStorage } }
    public var isReady: Bool { lock.withLock { ready } }

    /// Starts the chase regardless of distance (debug / simulator runs).
    public func provoke() { lock.withLock { provokePending = true } }

    /// Sends the zombie back to its spawn point, waiting.
    public func reset() { lock.withLock { resetPending = true } }

    public var spawnPosition: simd_float3 {
        simd_float3(0, configuration.floorY, -configuration.spawnDistance)
    }

    // MARK: - Scene

    /// Builds the lighting and loads the zombie. Main-actor: node and
    /// asset registration are.
    @MainActor
    public func setupScene() {
        if let resources = ZombieResources.baseURL {
            setEngine(.assetBasePath(resources))
        }

        let sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, angle: -50.0, axis: simd_float3(1, 0, 0))
        setLight(entityId: sun, .color(simd_float3(1.0, 0.94, 0.86)))
        setLight(entityId: sun, .intensity(1.5))
        setLight(entityId: sun, .directional(.active))

        zombie = createEntity()
        setEntityName(entityId: zombie, name: "Zombie")
        setEntityMeshAsync(entityId: zombie, filename: "ZombieAA", withExtension: "untold") { [weak self] success in
            guard let self, success else {
                print("CoolZombie: failed to load ZombieAA mesh")
                return
            }
            configureAnimation()
            placeAtSpawn()
            lock.withLock { ready = true }
        }
    }

    private func configureAnimation() {
        for clip in ZombieResources.chaseClips {
            setEntityAnimations(entityId: zombie, filename: clip, withExtension: "untold", name: clip)
        }

        setRootMotionEnabled(entityId: zombie, enabled: true)

        setFootIKChains(entityId: zombie, chains: [
            FootIKChainDescriptor(hipPath: Rig.leftLeg.hip, kneePath: Rig.leftLeg.knee, anklePath: Rig.leftFoot),
            FootIKChainDescriptor(hipPath: Rig.rightLeg.hip, kneePath: Rig.rightLeg.knee, anklePath: Rig.rightFoot),
        ])
        let floor = configuration.floorY
        setFootIKGroundQuery(entityId: zombie) { _ in
            FootIKGroundSample(height: floor)
        }
        setFootIKEnabled(entityId: zombie, enabled: true)
        setFootIKStanceLocking(entityId: zombie, enabled: true)

        setMotionMatching(entityId: zombie, descriptor: MotionMatchingDescriptor(
            leftFootPath: Rig.leftFoot,
            rightFootPath: Rig.rightFoot,
            predictionHalflife: 0.12,
            headingCorrectionRate: 1.5,
            // The database spans 0-5.6 m/s, so per-dimension normalisation
            // makes a slow walk look almost like standing. The trajectory
            // must outweigh pose continuity or a zero goal never leaves the
            // walk and the zombie creeps into the player.
            weights: MotionMatchingWeights(trajectoryPosition: 5.0, trajectoryDirection: 1.25)
        ))
        // Build the database at load time: it is enabled only when the
        // zombie is provoked, and that frame must not stall.
        prepareMotionMatching(entityId: zombie)
    }

    private func placeAtSpawn() {
        translateTo(entityId: zombie, position: spawnPosition)
        // Spawned ahead of the player (-Z) and facing them: the character's
        // forward is its local +Z, so the identity rotation looks at +Z.
        rotateTo(entityId: zombie, rotation: simd_quatf(angle: 0, axis: simd_float3(0, 1, 0)))
        // Waiting is the one scripted state: a calm idle plays directly and
        // motion matching stays off until the zombie is provoked — a zero
        // goal would have it pick the aggressive attack idles instead.
        setMotionMatchingEnabled(entityId: zombie, enabled: false)
        changeAnimation(entityId: zombie, name: ZombieResources.waitingClip, transitionHalflife: 0.3)
        lock.withLock {
            phaseStorage = .waiting
            hyper = false
            moving = false
        }
    }

    /// Hands the character to motion matching: from here on the goal
    /// drives every clip choice.
    private func startHunting() {
        setMotionMatchingEnabled(entityId: zombie, enabled: true)
    }

    // MARK: - Per-frame

    /// `playerPosition` is the player's head in world space (nil while
    /// tracking is not available — the zombie just waits).
    public func update(deltaTime _: Float, playerPosition: simd_float3?) {
        // The environment can only be swapped once the renderer has built
        // its IBL resources, which on visionOS happens after scene setup —
        // an earlier call fails and the engine's default sky bake wins.
        // The first frame is the earliest safe point on every platform.
        if lock.withLock({ defer { lightingApplied = true }; return !lightingApplied }) {
            ZombieLighting.applyNeutralEnvironment()
        }

        guard lock.withLock({ ready }) else { return }

        if lock.withLock({ defer { resetPending = false }; return resetPending }) {
            placeAtSpawn()
        }
        let provoked = lock.withLock { defer { provokePending = false }; return provokePending }

        guard let player = playerPosition else {
            setMotionMatchingGoal(entityId: zombie, desiredVelocity: .zero, desiredFacing: nil)
            return
        }

        let zombiePosition = getPosition(entityId: zombie)
        var toPlayer = player - zombiePosition
        toPlayer.y = 0
        let distance = simd_length(toPlayer)
        let direction = distance > 1e-4 ? toPlayer / distance : simd_float3(0, 0, 1)

        var phase = lock.withLock { phaseStorage }
        if phase == .waiting, provoked || distance < configuration.triggerRadius {
            startHunting()
            phase = .chasing
        }

        switch phase {
        case .waiting:
            break
        case .chasing, .holding:
            // Stop short of the player with hysteresis, and pick a gait
            // cluster with hysteresis so the goal never hovers in the hole
            // between walks and hyper chases.
            if distance < configuration.stopDistance {
                moving = false
            } else if distance > configuration.resumeDistance {
                moving = true
            }
            if distance > configuration.chaseEnterDistance {
                hyper = true
            } else if distance < configuration.chaseExitDistance {
                hyper = false
            }
            phase = moving ? .chasing : .holding
        }

        var desiredVelocity = simd_float3.zero
        switch phase {
        case .waiting:
            break
        case .chasing:
            let ramp = (distance - configuration.stopDistance) * Locomotion.speedPerMeter
            let speed = hyper
                ? min(Locomotion.maxSpeed, max(Locomotion.chaseFloorSpeed, ramp))
                : min(Locomotion.walkTopSpeed, max(Locomotion.walkFloorSpeed, ramp))
            desiredVelocity = direction * speed
        case .holding:
            break
        }

        // Waiting: shamble in place, no facing goal. Chasing/holding: always
        // face the player — the pivot clips turn the zombie even when it
        // stands its ground.
        setMotionMatchingGoal(
            entityId: zombie,
            desiredVelocity: desiredVelocity,
            desiredFacing: phase == .waiting ? nil : direction
        )

        lock.withLock {
            phaseStorage = phase
            distanceStorage = distance
        }
    }
}
