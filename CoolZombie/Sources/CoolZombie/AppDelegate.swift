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
        @State private var isPlaying = false

        var body: some View {
            ZStack {
                SceneView(renderer: renderer)

                if isPlaying {
                    // Minimal overlay while running so recordings stay clean.
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            playPauseButton(systemName: "pause.fill")
                                .padding(16)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        Text("CoolZombie")
                            .font(.title.bold())
                        Text("Motion matching: the character picks clips by itself — no state machine.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        playPauseButton(systemName: "play.fill")
                    }
                    .padding(28)
                    .background(.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
            }
        }

        private func playPauseButton(systemName: String) -> some View {
            Button {
                isPlaying.toggle()
                gameMode = isPlaying
            } label: {
                Image(systemName: systemName)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
        }
    }
#endif
