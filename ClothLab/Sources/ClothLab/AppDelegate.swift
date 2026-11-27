//
//  AppDelegate.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import UntoldEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: UntoldRenderer!
    private var scene: LabScene!
    private var monitors: [Any] = []

    func applicationDidFinishLaunching(_: Notification) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClothLab"
        window.minSize = NSSize(width: 800, height: 600)
        window.center()

        guard let renderer = UntoldRenderer.create() else {
            print("ClothLab: failed to initialize UntoldRenderer.")
            NSApp.terminate(nil)
            return
        }
        self.renderer = renderer
        scene = LabScene()
        renderer.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in
                self?.scene.update(deltaTime: deltaTime)
            },
            handleInput: {}
        )

        window.contentView = NSHostingView(rootView: LabView(renderer: renderer, scene: scene))
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installInput()
        // The window's id, for a capture of this window alone
        // (`screencapture -l <id>`).
        print("ClothLab: window \(window.windowNumber)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// The camera and the toggles, read straight from the window's events:
    /// drag orbits, Shift-drag (or a right drag) slides the view, scroll
    /// or pinch zooms; W wireframe, P pins, Space pause, R hang again,
    /// F frame the whole cloth, B hide or show the wall, L let the light follow the view or stay.
    private func installInput() {
        let drag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            guard let self, event.window === self.window, self.isOverScene(event) else { return event }
            if event.type == .rightMouseDragged || event.modifierFlags.contains(.shift) {
                self.scene.pan(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
            } else {
                self.scene.orbit(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
            }
            return event
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .magnify {
                self.scene.zoom(delta: Float(event.magnification) * 100)
            } else {
                self.scene.zoom(delta: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.5 : 4))
            }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window, !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": self.scene.showWireframe.toggle()
            case "p": self.scene.showPins.toggle()
            case " ": self.scene.paused.toggle()
            case "r": self.scene.reset()
            case "f": self.scene.frame()
            case "b": self.scene.showWall.toggle()
            case "l": self.scene.lightFollowsView.toggle()
            case "h": self.scene.clothCastsShadow.toggle()
            default: return event
            }
            return nil
        }
        monitors = [drag, scroll, keys].compactMap { $0 }
    }

    /// Drags that start on the menu bar along the top belong to the menus.
    private func isOverScene(_ event: NSEvent) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        return point.y < content.bounds.height - 92
    }
}

private struct LabView: View {
    let renderer: UntoldRenderer
    let scene: LabScene

    var body: some View {
        ZStack {
            SceneView(renderer: renderer)
            VStack(spacing: 0) {
                // Redrawn four times a second, so a key press shows here too.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            option("Step", LabScene.Step.allCases.map { ($0.title, $0) }, scene.step) { scene.setStep($0) }
                            if scene.step == .sheet {
                                option("Hung by", SheetPin.allCases.map { ($0.title, $0) }, scene.sheetPin) { scene.setSheetPin($0) }
                            } else {
                                option("Mesh", GarmentSource.allCases.filter(\.isAvailable).map { ($0.title, $0) },
                                       scene.garmentSource) { scene.setGarmentSource($0) }
                                option("Hung by", GarmentPin.allCases.map { ($0.title, $0) }, scene.garmentPin) { scene.setGarmentPin($0) }
                                option("Rest shape", scene.availableRestShapes.map { ($0.title, $0) }, scene.restShape) { scene.setRestShape($0) }
                                option("Fabric", LabScene.Fabric.allCases.map { ($0.title, $0) }, scene.fabric) { scene.setFabric($0) }
                                if scene.hasInterfacedPanels {
                                    toggle("Stiff cuffs and collar", scene.interfacing) { scene.setInterfacing(!scene.interfacing) }
                                }
                            }
                            Spacer()
                        }
                        // The view's own switches, on a row of their own so
                        // the bar never forces the window wider.
                        HStack(spacing: 14) {
                            toggle("Wireframe (W)", scene.showWireframe) { scene.showWireframe.toggle() }
                            toggle("Pins (P)", scene.showPins) { scene.showPins.toggle() }
                            toggle("Wall (B)", scene.showWall) { scene.showWall.toggle() }
                            toggle("Light follows (L)", scene.lightFollowsView) { scene.lightFollowsView.toggle() }
                            toggle("Cloth shadow (H)", scene.clothCastsShadow) { scene.clothCastsShadow.toggle() }
                            toggle("Pause (Space)", scene.paused) { scene.paused.toggle() }
                            toggle("Hang again (R)", false) { scene.reset() }
                            toggle("Frame (F)", false) { scene.frame() }
                            Spacer()
                        }
                        Text(scene.readout)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6))
                    .environment(\.colorScheme, .dark)
                }
                Spacer()
            }
        }
    }

    private func option<Value: Hashable>(
        _ title: String, _ options: [(String, Value)], _ current: Value, set: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize()
            Menu {
                ForEach(options, id: \.1) { item in
                    Button {
                        set(item.1)
                    } label: {
                        if item.1 == current {
                            Label(item.0, systemImage: "checkmark")
                        } else {
                            Text(item.0)
                        }
                    }
                }
            } label: {
                Text(options.first { $0.1 == current }?.0 ?? "—")
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.16)))
        }
    }

    private func toggle(_ title: String, _ isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Color.accentColor.opacity(0.8) : .white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}
