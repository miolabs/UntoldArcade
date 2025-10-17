//
//  AppDelegate.swift
//  SoccerGame
//
//  Created by Harold Serrano on 10/1/25.
//

import Cocoa

import MetalKit
import SwiftUI
import UntoldEngine

// GameScene is where you initialize your game and write game-specific logic.
class GameScene {
    // Toggle between Editor-loaded scene (true) and Code-built scene (false).
    var useEditorScene: Bool = true

    private let sceneFilename = "soccergamedemo"

    init() {

        //
        // -----------------------------------------------------
        // Demo Game Tutorial – How this ECS demo works
        // -----------------------------------------------------
        //
        // Untold Engine uses an ECS (Entity–Component–System) architecture:
        //
        // - Entities: Just IDs. No logic or data by themselves.
        // - Components: Small data blobs attached to entities
        //   (e.g., `BallComponent` with ball-related properties).
        // - Systems: Functions that run every frame and operate on entities
        //   that have the components they care about
        //   (e.g., `ballSystemUpdate` for ball physics).
        //
        // Think of it as:
        //   Entity = the "thing"
        //   Component = the "data"
        //   System = the "behavior"
        //
        // You extend behavior by attaching components to entities and
        // registering systems that update them each frame.
        //
        // -----------------------------------------------------
        // Two ways to initialize the same scene
        // -----------------------------------------------------
        //
        // Option 1 — Load from the Editor (default):
        //   1) Build your scene in the Untold Engine Editor and save it
        //      (e.g., `soccergamedemo.json`).
        //   2) Point the engine at your asset folder (here: Desktop/DemoGameAssets/Assets).
        //   3) Call `playSceneAt(url:)` to deserialize the JSON and recreate entities/components.
        //   4) (Optional) Find specific entities and attach extra custom components.
        //   5) Register your custom systems (run every frame).
        //   6) Hook up input (WASD).
        //
        // Option 2 — Build entirely in Code:
        //   Set `useEditorScene = false` to skip JSON loading. Then:
        //   - `createEntity()` for each object
        //   - `setEntityMesh` to assign models
        //   - `translateBy` / `rotateTo` to move/rotate
        //   - `setEntityAnimations` to wire animations
        //   - `setEntityName` so you can look entities up later
        //   - `setEntityKinetics` to enable physics/kinematics
        //   - `moveCameraTo` to position the camera
        //   - tweak globals like `ambientIntensity`
        //
        // Mix & match: load a base scene from the Editor, then add/override via code.
        //

        if useEditorScene {
            // --- Option 1: Load the scene created with the Editor ---
            if let url = Bundle.main.url(forResource: sceneFilename, withExtension: "json") {
                playSceneAt(url: url)
            } else {
                print("⚠️ Could not find scene file \(sceneFilename). " +
                      "Falling back to code-built scene.")
                // Fallback to code path if the JSON is missing.
                buildSceneInCode()
            }
        } else {
            // --- Option 2: Build the exact same scene in code ---
            buildSceneInCode()
        }

        // -----------------------------------------------------
        // Extend behavior by registering custom components
        // (attach data to specific entities)
        // -----------------------------------------------------
        if let ball = findEntity(name: "ball") {
            registerComponent(entityId: ball, componentType: BallComponent.self)
        }

        if let player = findEntity(name: "player") {
            registerComponent(entityId: player, componentType: DribblinComponent.self)
        }

        registerComponent(entityId: findGameCamera(), componentType: CameraFollowComponent.self)

        // -----------------------------------------------------
        // Register systems (run every frame)
        // -----------------------------------------------------
        registerCustomSystem(ballSystemUpdate)
        registerCustomSystem(dribblingSystemUpdate)
        registerCustomSystem(cameraFollowUpdate)

        // Input (WASD) for the demo
        InputSystem.shared.registerKeyboardEvents()
        
        // Disable SSAO
        SSAOParams.shared.enabled = false
    }

    // Build the same demo scene procedurally.
    private func buildSceneInCode() {
        // Stadium (static mesh)
        let stadium = createEntity()
        setEntityMesh(entityId: stadium, filename: "stadium", withExtension: "usdc")
        translateBy(entityId: stadium, position: simd_float3(0.0, 0.0, 0.0))

        // Player (animated, named for lookup)
        let player = createEntity()
        setEntityMesh(entityId: player, filename: "redplayer", withExtension: "usdc", flip: false)
        setEntityName(entityId: player, name: "player")
        rotateTo(entityId: player, angle: 0, axis: simd_float3(0.0, 1.0, 0.0))
        setEntityAnimations(entityId: player, filename: "running", withExtension: "usdc", name: "running")
        setEntityAnimations(entityId: player, filename: "idle", withExtension: "usdc", name: "idle")
        setEntityKinetics(entityId: player)

        // Ball (named for lookup)
        let ball = createEntity()
        setEntityMesh(entityId: ball, filename: "ball", withExtension: "usdc")
        setEntityName(entityId: ball, name: "ball")
        translateBy(entityId: ball, position: simd_float3(0.0, 0.6, 3.0))
        setEntityKinetics(entityId: ball)

        // Camera + lighting
        moveCameraTo(entityId: findGameCamera(), 0.0, 3.0, 10.0)
        ambientIntensity = 0.4
    }

    func update(deltaTime _: Float) {
        // Skip logic if not in game mode
        if gameMode == false { return }
    }

    func handleInput() {
        // Skip logic if not in game mode
        if gameMode == false { return }

        // Handle input here
    }
}


// AppDelegate: Boiler plate code -- Handles everything – Renderer, Metal setup, and GameScene initialization
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: UntoldRenderer!
    var gameScene: GameScene!

    func applicationDidFinishLaunching(_: Notification) {
        print("Launching Untold Engine v0.2")

        // Step 1. Create and configure the window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Untold Engine v0.2"
        window.center()

        // Step 2. Initialize the renderer and connect metal content
        guard let renderer = UntoldRenderer.create() else {
            print("Failed to initialize the renderer.")
            return
        }

        window.contentView = renderer.metalView

        self.renderer = renderer

        // Step 3. Create the game scene and connect callbacks
        gameScene = GameScene()
        renderer.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in self?.gameScene.update(deltaTime: deltaTime) },
            handleInput: { [weak self] in self?.gameScene.handleInput() }
        )

        let hostingView = NSHostingView(rootView: SceneView(renderer: renderer))
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
