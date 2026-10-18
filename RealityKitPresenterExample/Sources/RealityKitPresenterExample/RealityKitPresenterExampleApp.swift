//
//  RealityKitPresenterExampleApp.swift
//  RealityKitPresenterExample
//
//  The engine's XR frame presented by RealityKit: the immersive space holds an
//  `UntoldXRPresenterView` where the other visionOS examples hold a `CompositorLayer`. A
//  control window opens and closes the space, picks the immersion, and shows the presenter's
//  numbers once a second.
//
//  Launch arguments: `--open-space` opens the space at start, `--hide-window` then closes the
//  window (simulator screenshots), `--turning` turns the cubes (still by default, so that
//  screenshots of one build compare with the next).
//

import os
import SwiftUI
import UntoldEngine
import UntoldEngineXR
import UntoldEngineXRRealityKit

@main
struct RealityKitPresenterExampleApp: App {
    @State private var model = ExampleModel()

    var body: some SwiftUI.Scene {
        WindowGroup(id: "control") {
            ControlView(model: model)
        }
        .defaultSize(width: 560, height: 560)

        ImmersiveSpace(id: "presenter") {
            UntoldXRPresenterView(
                immersionMode: model.immersion == .full ? .full : .mixed,
                onReady: { xr, presenter in
                    model.spaceOpened(xr: xr, presenter: presenter)
                },
                onShutdown: {
                    model.spaceClosed()
                }
            )
        }
        .immersionStyle(selection: $model.immersionSelection, in: .mixed, .full)
    }
}

enum Immersion: String, CaseIterable, Identifiable {
    case mixed
    case full

    var id: String { rawValue }
    var label: String { self == .mixed ? "Mixed" : "Full" }
    var style: ImmersionStyle { self == .mixed ? .mixed : .full }
}

/// What the window and the space share: the immersion choice, the scene, the presenter's
/// numbers.
@Observable
@MainActor
final class ExampleModel {
    var immersion: Immersion = .mixed {
        didSet { immersionSelection = immersion.style }
    }
    var immersionSelection: ImmersionStyle = .mixed
    var spaceOpen = false
    var statusLine = "The space is closed."
    var materialLine = ""
    let scene = ExampleScene()
    private(set) var presenter: XRRealityKitPresenter?
    /// The numbers go to the unified log too (subsystem `com.untoldengine.realitykitpresenterexample`,
    /// category `numbers`), so a simulator or headset run can be read back afterwards.
    private let log = os.Logger(subsystem: "com.untoldengine.realitykitpresenterexample", category: "numbers")
    private var refreshTask: Task<Void, Never>?

    func spaceOpened(xr: UntoldEngineXR, presenter: XRRealityKitPresenter) {
        self.presenter = presenter
        // The window reads the numbers; the presenter's own log line would reset them.
        presenter.reportInterval = 0
        materialLine = presenter.usesShaderGraphMaterial
            ? "Eye material: the shader graph (each eye sees its own grid)."
            : "Eye material: the FALLBACK (both eyes see both grids)."
        scene.start(xr)
        spaceOpen = true
        // Once a second while the space is open, whether or not the window is (a hidden window
        // ends its own tasks).
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func spaceClosed() {
        refreshTask?.cancel()
        refreshTask = nil
        scene.stop()
        presenter = nil
        spaceOpen = false
        statusLine = "The space is closed."
    }

    /// Once a second from the window.
    func refresh() {
        guard let presenter else { return }
        let numbers = presenter.statistics.snapshot()
        statusLine = String(
            format: "%.0f updates/s · %.0f frames/s · %d dropped (%d in all) · replace %.2f ms (max %.2f) · pickup age %.1f ms · frame %.1f ms · GPU %.1f ms (max %.1f) · %d taps",
            numbers.updatesPerSecond, numbers.framesPerSecond, numbers.ticketsDropped, numbers.ticketsDroppedTotal,
            numbers.replaceMsAverage, numbers.replaceMsMax, numbers.pickupAgeMsAverage, numbers.frameMsAverage,
            numbers.gpuMsAverage, numbers.gpuMsMax, scene.tapCount
        )
        log.notice("\(self.statusLine, privacy: .public)")
    }
}

struct ControlView: View {
    @Bindable var model: ExampleModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("RealityKit Presenter")
                .font(.extraLargeTitle)
                .fontWeight(.bold)
            Text("The Untold Engine renders every frame; RealityKit shows it on two depth-displaced grids, one per eye, so the system owns the space.")
                .foregroundStyle(.secondary)

            Picker("Immersion", selection: $model.immersion) {
                ForEach(Immersion.allCases) { immersion in
                    Text(immersion.label).tag(immersion)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.spaceOpen)

            HStack {
                Button {
                    Task { await openImmersiveSpace(id: "presenter") }
                } label: {
                    Label("Open the space", systemImage: "visionpro.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.spaceOpen)

                Button {
                    Task { await dismissImmersiveSpace() }
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .disabled(!model.spaceOpen)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What to look for")
                    .font(.headline)
                Text("Three cubes on a slab 1.6 m ahead, with a sphere above them (still, so screenshots compare; launch with --turning for motion). They must stay put while you move your head. Pinch a cube to light it up; the tap count rises. In Mixed the room shows around the slab; in Full it is dark.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Numbers (last second)")
                    .font(.headline)
                Text(model.statusLine)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                if !model.materialLine.isEmpty {
                    Text(model.materialLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(28)
        .task {
            let arguments = CommandLine.arguments
            if arguments.contains("--open-space") {
                await openImmersiveSpace(id: "presenter")
                if arguments.contains("--hide-window") {
                    dismissWindow(id: "control")
                }
            }
        }
    }
}
