//
//  AppDelegate.swift  (macOS)
//  WebGLWater
//

import Cocoa
import MetalKit
import SwiftUI
import simd
import UntoldEngine

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: UntoldRenderer!
    var game: WaterGame!

    func applicationDidFinishLaunching(_: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WebGL Water — Untold Engine"
        window.center()

        // Must be set before the renderer is created so the engine skips its
        // deferred pipelines (the water demo renders its own scene).
        setWaterOnlyMode(true)

        guard let renderer = UntoldRenderer.create() else {
            print("Failed to initialize the renderer.")
            return
        }
        self.renderer = renderer

        // Render into a non-sRGB drawable so the water shader's display-space colors
        // show as-is (matches the original). Must be set before the water pipelines
        // are built in game.start().
        renderer.metalView.colorPixelFormat = .bgra8Unorm
        renderInfo.presentColorPixelFormat = .bgra8Unorm

        // Build the demo (water feature must be enabled after the renderer exists).
        game = WaterGame()
        game.start()

        renderer.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in self?.game.update(deltaTime: deltaTime) },
            handleInput: { [weak self] in self?.game.handleInput() }
        )

        let hostingView = NSHostingView(rootView: SceneView(renderer: renderer))
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        setupInput()
    }

    private func setupInput() {
        // Drag: ripple / move sphere / orbit camera.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        renderer.metalView.addGestureRecognizer(pan)

        // Scroll: zoom.
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.game.zoom(by: Float(-event.scrollingDeltaY) * 0.02)
            return event
        }

        // Keyboard: space = pause, G = gravity, L = light at camera.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": self?.game.togglePause(); return nil
            case "g": self?.game.toggleGravity(); return nil
            case "l": self?.game.aimLightAtCamera(); return nil
            default: return event
            }
        }
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        let v = renderer.metalView
        let loc = g.location(in: v)
        // AppKit is already bottom-left (y-up), which is what the engine's picker expects.
        let p = simd_float2(Float(loc.x), Float(loc.y))
        game.setViewport(simd_float2(Float(v.bounds.width), Float(v.bounds.height)))
        switch g.state {
        case .began: game.dragBegan(at: p)
        case .changed: game.dragMoved(to: p)
        case .ended, .cancelled, .failed: game.dragEnded()
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
