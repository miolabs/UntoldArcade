//
//  ZombieScene.swift
//  CoolZombie
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)
    import Foundation
    import simd
    import SwiftUI
    import UntoldEngine

    /// AI character locomotion with no animation state machine: a wandering
    /// target orbits the arena, and the character chases it. Every frame the
    /// AI states a *goal* (desired velocity + facing); motion matching picks
    /// the animation frames, root motion moves the character, foot IK plants
    /// the feet. Nobody ever calls changeAnimation.
    @MainActor
    final class ZombieScene {
        // MARK: Rig constants (UE4 Mannequin skeleton)

        private enum Rig {
            static let leftFoot = "/root/pelvis/thigh_l/calf_l/foot_l"
            static let rightFoot = "/root/pelvis/thigh_r/calf_r/foot_r"
            static let leftLeg = (hip: "/root/pelvis/thigh_l", knee: "/root/pelvis/thigh_l/calf_l")
            static let rightLeg = (hip: "/root/pelvis/thigh_r", knee: "/root/pelvis/thigh_r/calf_r")
        }

        /// The clip vocabulary spans 0-2.55 m/s (travel injected at cook
        /// time from the game's blend-sample speeds); the goal speed ramps
        /// continuously with distance so the search can use the whole
        /// ladder.
        private enum Locomotion {
            // Clips carry CONTACT-MATCHED root travel: per frame the root
            // moves by the stance foot's measured sweep, so planted feet are
            // world-stationary by construction. Mean speeds run
            // 0.15/0.41/0.51/0.58/0.69 (walk cluster) and 2.36/3.17/5.06
            // (chase cluster) — nothing in between, so the goal snaps to a
            // cluster with hysteresis instead of hovering in the hole and
            // churning transitions.
            static let maxSpeed: Float = 5.05 // hyperchase_5 mean travel
            static let walkTopSpeed: Float = 0.69 // chase_2 mean travel
            static let chaseFloorSpeed: Float = 2.36 // hyperchase_1 mean travel
            static let speedPerMeter: Float = 1.0
            static let chaseEnterDistance: Float = 4.5
            static let chaseExitDistance: Float = 3.0
            static let stopDistance: Float = 1.2
        }

        private var chasing = false

        // MARK: Entities

        private var zombie: EntityID = .invalid
        private var target: EntityID = .invalid
        private var camera: EntityID = .invalid
        private var zombieReady = false

        private var targetAngle: Float = 0

        init() {
            configureEngine()
            makeCamera()
            makeSun()
            makeGround()
            makeTarget()
            loadZombie()
        }

        // MARK: - Setup

        private func configureEngine() {
            // Starts paused; the play button (or Space) flips gameMode so a
            // screen recording can be armed on a clean still frame.
            gameMode = false
            setSceneReady(false)
            if let resources = Bundle.module.resourceURL {
                setEngine(.assetBasePath(resources))
            }
            registerKeyboardEvents()
            registerMouseEvents()
            setRendering(.postProcessing(.enabled))
            setRendering(.antiAliasing(.fxaa))
            setRendering(.environment(.ibl(true)))
            setRendering(.environment(.visible(false)))
        }

        private func makeCamera() {
            camera = createEntity()
            setEntityName(entityId: camera, name: "Main Camera")
            createGameCamera(entityId: camera)
            cameraLookAt(
                entityId: camera,
                eye: simd_float3(0, 4.5, -7.5),
                target: simd_float3(0, 0.8, 0),
                up: simd_float3(0, 1, 0)
            )
            setCamera(.active(camera))
        }

        private func makeSun() {
            let sun = createEntity()
            setEntityName(entityId: sun, name: "Sun")
            createDirLight(entityId: sun)
            rotateTo(entityId: sun, angle: -50.0, axis: simd_float3(1, 0, 0))
            setLight(entityId: sun, .color(simd_float3(1.0, 0.94, 0.86)))
            setLight(entityId: sun, .intensity(1.5))
            setLight(entityId: sun, .directional(.active))
        }

        private func makeGround() {
            let ground = createEntity()
            setEntityName(entityId: ground, name: "Ground")
            let plane = BasicPrimitives.createPlane(width: 24, depth: 24)
            setEntityMeshDirect(entityId: ground, meshes: plane, assetName: "ground")
            updateMaterialColor(entityId: ground, color: Color(red: 0.55, green: 0.55, blue: 0.52))
        }

        private func makeTarget() {
            target = createEntity()
            setEntityName(entityId: target, name: "Target")
            let marker = BasicPrimitives.createCube(extent: 0.125)
            setEntityMeshDirect(entityId: target, meshes: marker, assetName: "target")
            updateMaterialColor(entityId: target, color: Color(red: 0.85, green: 0.15, blue: 0.1))
            translateTo(entityId: target, position: simd_float3(3.5, 0.15, 0))
        }

        private func loadZombie() {
            zombie = createEntity()
            setEntityName(entityId: zombie, name: "Zombie")
            setEntityMeshAsync(entityId: zombie, filename: "ZombieAA", withExtension: "untold") { [weak self] success in
                guard let self, success else {
                    print("CoolZombie: failed to load ZombieAA mesh")
                    setSceneReady(true)
                    return
                }
                configureZombieAnimation()
                setSceneReady(true)
            }
        }

        private func configureZombieAnimation() {
            // Idles + a speed ladder from creep (0.2) to sprint (2.55);
            // motion matching picks and blends, nobody selects a clip.
            for clip in [
                "idle_3", "shamble_1", "walk_f", "chase_1", "walk_f6",
                "chase_3", "chase_2", "hyperchase_1", "hyperchase_2", "hyperchase_5",
            ] {
                setEntityAnimations(entityId: zombie, filename: clip, withExtension: "untold", name: clip)
            }

            // The clips' own travel moves the entity.
            setRootMotionEnabled(entityId: zombie, enabled: true)

            // Feet planted on the (flat) arena; swap the query for a terrain
            // heightfield when the demo gains real ground.
            setFootIKChains(entityId: zombie, chains: [
                FootIKChainDescriptor(hipPath: Rig.leftLeg.hip, kneePath: Rig.leftLeg.knee, anklePath: Rig.leftFoot),
                FootIKChainDescriptor(hipPath: Rig.rightLeg.hip, kneePath: Rig.rightLeg.knee, anklePath: Rig.rightFoot),
            ])
            setFootIKGroundQuery(entityId: zombie) { _ in
                FootIKGroundSample(height: 0)
            }
            setFootIKEnabled(entityId: zombie, enabled: true)

            // Motion matching: the loaded clips are the whole vocabulary.
            // A responsive trajectory prediction plus a heavier trajectory
            // weight let the search actually reach the fast gaits; the
            // defaults park it on the mid gait even for sprint goals.
            setMotionMatching(entityId: zombie, descriptor: MotionMatchingDescriptor(
                leftFootPath: Rig.leftFoot,
                rightFootPath: Rig.rightFoot,
                predictionHalflife: 0.12,
                weights: MotionMatchingWeights(trajectoryPosition: 2.5, trajectoryDirection: 1.25)
            ))
            setMotionMatchingEnabled(entityId: zombie, enabled: true)

            zombieReady = true
        }

        // MARK: - Per-frame update

        /// Free camera: WASD pans and dollies (W/S zoom, A/D strafe),
        /// Q/E move vertically. Right-drag orbits around the zombie;
        /// Shift+right-drag free-looks instead. Works while paused too,
        /// so a shot can be framed before pressing play.
        func handleInput() {
            let input = InputSystem.shared
            moveCameraWithInput(
                entityId: camera,
                input: (
                    w: input.keyState.wPressed,
                    a: input.keyState.aPressed,
                    s: input.keyState.sPressed,
                    d: input.keyState.dPressed,
                    q: input.keyState.qPressed,
                    e: input.keyState.ePressed
                ),
                speed: 3.0,
                deltaTime: 1.0 / 60.0
            )

            if input.keyState.rightMousePressed {
                if input.keyState.shiftPressed || zombie == .invalid {
                    rotateCamera(
                        entityId: camera,
                        pitch: input.mouseDeltaY,
                        yaw: input.mouseDeltaX,
                        sensitivity: -0.01
                    )
                } else {
                    // Re-anchor the orbit pivot to the (moving) zombie every
                    // frame: aim at it, set the pivot at that distance, then
                    // orbit by the drag delta.
                    let eye = getCameraPosition(entityId: camera)
                    let pivot = getPosition(entityId: zombie) + simd_float3(0, 0.9, 0)
                    cameraLookAt(entityId: camera, eye: eye, target: pivot, up: simd_float3(0, 1, 0))
                    setOrbitOffset(entityId: camera, uTargetOffset: simd_length(pivot - eye))
                    orbitCameraAround(
                        entityId: camera,
                        uDelta: simd_float2(input.mouseDeltaX, input.mouseDeltaY)
                    )
                }
            }
        }

        func update(deltaTime: Float) {
            guard gameMode else { return }

            moveTarget(deltaTime: deltaTime)

            guard zombieReady else { return }

            // The AI: chase the target. Far away → run, closing in → walk,
            // arrived → stand. The goal is the only animation input.
            let zombiePosition = getPosition(entityId: zombie)
            let targetPosition = getPosition(entityId: target)
            var toTarget = targetPosition - zombiePosition
            toTarget.y = 0
            let distance = simd_length(toTarget)

            if distance > Locomotion.chaseEnterDistance {
                chasing = true
            } else if distance < Locomotion.chaseExitDistance {
                chasing = false
            }

            var desiredVelocity = simd_float3.zero
            var desiredFacing: simd_float3?
            if distance > Locomotion.stopDistance {
                let direction = toTarget / distance
                let ramp = (distance - Locomotion.stopDistance) * Locomotion.speedPerMeter
                let speed = chasing
                    ? min(Locomotion.maxSpeed, max(Locomotion.chaseFloorSpeed, ramp))
                    : min(Locomotion.walkTopSpeed, ramp)
                desiredVelocity = direction * speed
                desiredFacing = direction
            }

            setMotionMatchingGoal(
                entityId: zombie,
                desiredVelocity: desiredVelocity,
                desiredFacing: desiredFacing
            )

            // The generated clips travel without turning, so steer the
            // heading directly toward the goal; turning clips replace this
            // once real mocap lands.
            if distance > Locomotion.stopDistance {
                turnToward(direction: toTarget / distance, deltaTime: deltaTime)
            }
        }

        /// Rotates the character's yaw toward `direction` along the shortest
        /// arc, capped at `turnSpeed` rad/s. Explicit yaw-only control: the
        /// engine's alignOrientation mixes orientation-matrix columns, which
        /// degenerates for large heading changes (a target passing behind
        /// the character), and it expects physics components this entity
        /// doesn't carry.
        private func turnToward(direction: simd_float3, deltaTime: Float) {
            let turnSpeed: Float = 3.0 // rad/s

            let forward = getForwardAxisVector(entityId: zombie)
            let currentYaw = atan2f(forward.x, forward.z)
            let targetYaw = atan2f(direction.x, direction.z)

            // Shortest signed arc, wrapped to (-π, π].
            var delta = fmodf(targetYaw - currentYaw + .pi, 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            delta -= .pi

            let maxStep = turnSpeed * deltaTime
            let step = max(-maxStep, min(maxStep, delta))
            rotateTo(
                entityId: zombie,
                rotation: simd_quatf(angle: currentYaw + step, axis: simd_float3(0, 1, 0))
            )
        }

        private func moveTarget(deltaTime: Float) {
            targetAngle += deltaTime * 0.35
            let radius: Float = 3.5 + sinf(targetAngle * 0.7) * 1.5
            let position = simd_float3(cosf(targetAngle) * radius, 0.15, sinf(targetAngle) * radius)
            translateTo(entityId: target, position: position)
        }
    }
#endif
