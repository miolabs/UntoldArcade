//
//  AppDelegate.swift
//  CoolZombie
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)
    import AppKit
    import SwiftUI
    import UntoldEngine

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        private enum Constants {
            static let windowSize = NSSize(width: 1280, height: 720)
            static let minimumWindowSize = NSSize(width: 800, height: 600)
        }

        private var window: NSWindow!
        private var renderer: UntoldRenderer!
        private var zombieScene: ZombieScene!

        func applicationDidFinishLaunching(_: Notification) {
            setupWindow()
            setupRendererAndScene()
            presentSceneView()
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }

        private func setupWindow() {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Constants.windowSize),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "CoolZombie — Motion Matching Demo"
            window.minSize = Constants.minimumWindowSize
            window.center()
        }

        private func setupRendererAndScene() {
            guard let renderer = UntoldRenderer.create() else {
                print("Failed to initialize UntoldRenderer.")
                NSApp.terminate(nil)
                return
            }

            self.renderer = renderer
            zombieScene = ZombieScene()

            renderer.setupCallbacks(
                gameUpdate: { [weak self] deltaTime in
                    self?.zombieScene.update(deltaTime: deltaTime)
                },
                handleInput: {}
            )
        }

        private func presentSceneView() {
            guard let renderer else { return }

            let hostingView = NSHostingView(rootView: CoolZombieView(renderer: renderer))
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private struct CoolZombieView: View {
        let renderer: UntoldRenderer

        var body: some View {
            ZStack(alignment: .topLeading) {
                SceneView(renderer: renderer)
                Text("Motion matching: the character picks clips by itself — no state machine.")
                    .font(.caption)
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        }
    }
#endif
