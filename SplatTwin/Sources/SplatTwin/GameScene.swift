//
//  GameScene.swift
//  SplatTwin
//
//  Engine configuration, camera, light, and the per-frame loop that feeds the HUD.
//

import Foundation
import simd
import UntoldEngine
import UntoldGaussianTwins

final class GameScene {
    private enum Constants {
        static let cameraMoveSpeed: Float = 3.0
        static let orbitTargetOffset: Float = 6.0
        static let cameraStart = SIMD3<Float>(0, 1.8, 8.5)
        static let lookAt = SIMD3<Float>(0, 0.6, 0)
        static let hudInterval: Float = 0.1
    }

    let showcase = TwinShowcase()
    /// Called on the main thread about ten times a second with the twins' states.
    var onReadouts: (([TwinReadout]) -> Void)?

    private var wasRightMousePressed = false
    private var hudTimer: Float = 0

    init() {
        configureEngine()
        makeCamera()
        makeSunLight()
        GaussianTwinSystem.shared.install()
        showcase.build()
        setSceneReady(true)
    }

    func update(deltaTime: Float) {
        guard gameMode else { return }
        hudTimer += deltaTime
        if hudTimer >= Constants.hudInterval {
            hudTimer = 0
            onReadouts?(showcase.readouts())
        }
    }

    func handleInput() {
        guard gameMode, isSceneReady() else { return }
        guard let camera = CameraSystem.shared.activeCamera else { return }
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
            speed: Constants.cameraMoveSpeed,
            deltaTime: 1.0 / 60.0
        )
        if input.keyState.rightMousePressed {
            if !wasRightMousePressed {
                setOrbitOffset(entityId: camera, uTargetOffset: Constants.orbitTargetOffset)
            }
            orbitCameraAround(entityId: camera, uDelta: simd_float2(input.mouseDeltaX, input.mouseDeltaY))
        }
        wasRightMousePressed = input.keyState.rightMousePressed
    }

    // MARK: - Setup

    private func configureEngine() {
        if let gameData = Bundle.main.url(forResource: "GameData", withExtension: nil) {
            assetBasePath = gameData
        }
        gameMode = true
        setRendering(.postProcessing(.enabled))
        setRendering(.antiAliasing(.fxaa))
        setRendering(.environment(.ibl(true)))
        setRendering(.environment(.visible(false)))
        InputSystem.shared.registerKeyboardEvents()
    }

    private func makeCamera() {
        let camera = createEntity()
        setEntityName(entityId: camera, name: "Main Camera")
        createGameCamera(entityId: camera)
        cameraLookAt(entityId: camera, eye: Constants.cameraStart, target: Constants.lookAt, up: SIMD3(0, 1, 0))
        setOrbitOffset(entityId: camera, uTargetOffset: Constants.orbitTargetOffset)
    }

    private func makeSunLight() {
        let sun = createEntity()
        setEntityName(entityId: sun, name: "Key Light")
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, angle: -50, axis: SIMD3(1, 0, 0))
        setLight(entityId: sun, .color(SIMD3(1.0, 0.94, 0.86)))
        setLight(entityId: sun, .intensity(1.6))
        setLight(entityId: sun, .directional(.active))
    }
}
