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
    import UntoldEngine

    /// AI character locomotion with no animation state machine: a wandering
    /// target orbits the arena, and the character chases it. Every frame the
    /// AI states a *goal* (desired velocity + facing); motion matching picks
    /// the animation frames, root motion moves the character, foot IK plants
    /// the feet. Nobody ever calls changeAnimation.
    @MainActor
    final class ZombieScene {
        // MARK: Rig constants (redplayer skeleton)

        private enum Rig {
            static let leftFoot = "/Hips/LeftUpperLeg/LeftLowerLeg/LeftFoot"
            static let rightFoot = "/Hips/RightUpperLeg/RightLowerLeg/RightFoot"
            static let leftLeg = (hip: "/Hips/LeftUpperLeg", knee: "/Hips/LeftUpperLeg/LeftLowerLeg")
            static let rightLeg = (hip: "/Hips/RightUpperLeg", knee: "/Hips/RightUpperLeg/RightLowerLeg")
        }

        /// Effective travel speeds baked into the generated clips
        /// (root displacement per loop / loop duration).
        private enum Locomotion {
            static let runSpeed: Float = 2.35
            static let walkSpeed: Float = 0.94
            static let runDistance: Float = 4.0
            static let stopDistance: Float = 1.2
        }

        // MARK: Entities

        private var zombie: EntityID = .invalid
        private var target: EntityID = .invalid
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
            setRendering(.postProcessing(.enabled))
            setRendering(.antiAliasing(.fxaa))
            setRendering(.environment(.ibl(true)))
            setRendering(.environment(.visible(false)))
        }

        private func makeCamera() {
            let camera = createEntity()
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
        }

        private func makeTarget() {
            target = createEntity()
            setEntityName(entityId: target, name: "Target")
            let marker = BasicPrimitives.createCube(extent: 0.125)
            setEntityMeshDirect(entityId: target, meshes: marker, assetName: "target")
            translateTo(entityId: target, position: simd_float3(3.5, 0.15, 0))
        }

        private func loadZombie() {
            zombie = createEntity()
            setEntityName(entityId: zombie, name: "Zombie")
            setEntityMeshAsync(entityId: zombie, filename: "redplayer", withExtension: "untold") { [weak self] success in
                guard let self, success else {
                    print("CoolZombie: failed to load redplayer mesh")
                    setSceneReady(true)
                    return
                }
                configureZombieAnimation()
                setSceneReady(true)
            }
        }

        private func configureZombieAnimation() {
            setEntityAnimations(entityId: zombie, filename: "idle", withExtension: "untold", name: "idle")
            setEntityAnimations(entityId: zombie, filename: "walk_forward", withExtension: "untold", name: "walk_forward")
            setEntityAnimations(entityId: zombie, filename: "run_forward", withExtension: "untold", name: "run_forward")

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
            setMotionMatching(entityId: zombie, descriptor: MotionMatchingDescriptor(
                leftFootPath: Rig.leftFoot,
                rightFootPath: Rig.rightFoot
            ))
            setMotionMatchingEnabled(entityId: zombie, enabled: true)

            zombieReady = true
        }

        // MARK: - Per-frame update

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

            var desiredVelocity = simd_float3.zero
            var desiredFacing: simd_float3?
            if distance > Locomotion.stopDistance {
                let direction = toTarget / distance
                let speed = distance > Locomotion.runDistance ? Locomotion.runSpeed : Locomotion.walkSpeed
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
