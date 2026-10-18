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
//  screenshots of one build compare with the next). The presenter's settings, for comparisons
//  from the command line: `--grid 64x60`, `--skirt 0` (texels), `--adaptive-diagonal` or
//  `--fixed-diagonal`, `--no-edge-band`, `--lead 22` (ms), `--tear 0.5` (metres), the
//  presenter's own rasterization rate map with `--foveation equiangular` (or `none`); the
//  engine's anti-aliasing with `--aa fxaa|smaa|msaa|taa|msaataa`. All but the grid and the
//  rate map change from the window while the space is open too (the presenter's `settings`),
//  for comparisons on the headset without a relaunch; the grid and the map are chosen in the
//  window for the next space opened.
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
                configuration: model.configurationForNextSpace(),
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
    /// The presenter's settings as the window shows them (the launch arguments' to start
    /// with); written through to the presenter.
    var settings = XRPresenterSettings(configuration: ExampleModel.configurationFromArguments()) {
        didSet { presenter?.settings = settings }
    }
    /// The engine's anti-aliasing as the window shows it; asked of the scene when it changes,
    /// which applies it on the engine's thread before the next frame.
    var antiAliasing = ExampleAntiAliasing.fromArguments() {
        didSet { if spaceOpen, antiAliasing != oldValue { scene.setAntiAliasing(antiAliasing) } }
    }
    /// The grid each eye is shown on, for the next space opened (the grids are made with the
    /// space); remembered across launches.
    var grid = ExampleGrid.remembered() {
        didSet { grid.remember() }
    }
    /// Whether the far shell stands at 50 m instead of 100 (the 512 grid's hairlines are
    /// RealityKit's interpolation across the stretched triangles, which a nearer shell removes);
    /// for the next space opened.
    var nearShell = UserDefaults.standard.bool(forKey: "nearShell") {
        didSet { UserDefaults.standard.set(nearShell, forKey: "nearShell") }
    }
    /// A deliberate 3 cm upward offset of both eyes' viewpoints for the next space opened: a
    /// parallax test. A silhouette defect that changes with it comes from a vertex at a wrong
    /// depth seen from a displaced camera; one that does not is in the texture or its mapping.
    var viewOffsetTest = UserDefaults.standard.bool(forKey: "viewOffsetTest") {
        didSet { UserDefaults.standard.set(viewOffsetTest, forKey: "viewOffsetTest") }
    }
    /// Whether the next space opened draws each eye through the presenter's own equi-angular
    /// rasterization rate map: the same 1920 × 1824 physical pixels per eye spread evenly in
    /// angle, so the centre of view is about 1.36 times denser than the uniform frame (the grid
    /// is then the map's, a vertex every 8 texels: 241 × 229). The launch argument
    /// `--foveation equiangular|none` sets where the toggle starts; remembered across launches
    /// otherwise.
    var rateMap = ExampleModel.rateMapFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(rateMap, forKey: "rateMap") }
    }

    static func rateMapFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--foveation"), index + 1 < arguments.count {
            return arguments[index + 1].lowercased() == "equiangular"
        }
        return UserDefaults.standard.bool(forKey: "rateMap")
    }

    /// The configuration of the next space opened: the launch arguments', then the window's
    /// choices for what the presenter fixes when it is made.
    func configurationForNextSpace() -> XRRealityKitPresenterConfiguration {
        var configuration = Self.configurationFromArguments()
        if !CommandLine.arguments.contains("--grid") {
            configuration.gridColumns = grid.columns
            configuration.gridRows = grid.rows
        }
        if nearShell { configuration.farShellMetres = 50 }
        if viewOffsetTest { configuration.viewOffsetMetres = SIMD3<Float>(0, 0.03, 0) }
        configuration.foveation = rateMap ? .equiAngular : .none
        return configuration
    }
    let scene = ExampleScene()
    private(set) var presenter: XRRealityKitPresenter?
    /// The numbers go to the unified log too (subsystem `com.untoldengine.realitykitpresenterexample`,
    /// category `numbers`), so a simulator or headset run can be read back afterwards.
    private let log = os.Logger(subsystem: "com.untoldengine.realitykitpresenterexample", category: "numbers")
    private var refreshTask: Task<Void, Never>?

    /// The presenter's configuration with the launch arguments' overrides applied.
    static func configurationFromArguments() -> XRRealityKitPresenterConfiguration {
        var configuration = XRRealityKitPresenterConfiguration()
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let grid = value(after: "--grid") {
            let parts = grid.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] >= 2, parts[1] >= 2 {
                configuration.gridColumns = parts[0]
                configuration.gridRows = parts[1]
            }
        }
        if let skirt = value(after: "--skirt").flatMap(Float.init) { configuration.skirtTexels = skirt }
        if let lead = value(after: "--lead").flatMap(Double.init) { configuration.leadSeconds = lead / 1000 }
        if let tear = value(after: "--tear").flatMap(Float.init) { configuration.tearThresholdMetres = tear }
        if arguments.contains("--fixed-diagonal") { configuration.adaptiveDiagonal = false }
        if arguments.contains("--adaptive-diagonal") { configuration.adaptiveDiagonal = true }
        if arguments.contains("--no-edge-band") { configuration.edgeBlending = false }
        return configuration
    }

    func spaceOpened(xr: UntoldEngineXR, presenter: XRRealityKitPresenter) {
        self.presenter = presenter
        // The window reads the numbers; the presenter's own log line would reset them.
        presenter.reportInterval = 0
        settings = presenter.settings
        scene.start(xr)
        antiAliasing = scene.antiAliasing
        spaceOpen = true
        describeSettings()
        log.notice("\(self.materialLine, privacy: .public)")
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

    /// The material and settings line, from the presenter: what is in force.
    private func describeSettings() {
        guard let presenter else { return }
        let c = presenter.configuration
        let s = presenter.settings
        materialLine = (presenter.usesShaderGraphMaterial
            ? "Eye material: the shader graph (each eye sees its own grid). "
            : "Eye material: the FALLBACK (both eyes see both grids). ")
            + (presenter.foveation.map { "Rate map: screen \($0.screenSize.x)×\($0.screenSize.y) over \(presenter.textureSize.x)×\(presenter.textureSize.y) texels, cells of \($0.cellTexels). " } ?? "No rate map: \(presenter.textureSize.x)×\(presenter.textureSize.y) uniform texels. ")
            + "Grid \(presenter.grid.columns)×\(presenter.grid.rows), shell \(Int(c.farShellMetres)) m, view offset \(Int((c.viewOffsetMetres.y * 100).rounded())) cm, skirt \(s.skirtTexels) texels, \(s.adaptiveDiagonal ? "adaptive" : "fixed") diagonal, edge band \(presenter.drawsEdgeBand ? "on" : presenter.hasEdgeBand ? "off" : "unavailable"), lead \(Int((s.leadSeconds * 1000).rounded())) ms, tear \(s.tearThresholdMetres) m, \(scene.antiAliasing.label)."
    }

    /// Once a second from the window.
    func refresh() {
        guard let presenter else { return }
        describeSettings()
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Settings (change them with the space open)")
                    .font(.headline)
                HStack(spacing: 24) {
                    Toggle("Edge band", isOn: $model.settings.edgeBlending)
                        .disabled(!(model.presenter?.hasEdgeBand ?? true))
                    Toggle("Adaptive diagonal", isOn: $model.settings.adaptiveDiagonal)
                }
                HStack(spacing: 24) {
                    Stepper("Skirt \(Int(model.settings.skirtTexels)) texels", value: $model.settings.skirtTexels, in: 0 ... 8, step: 1)
                    Stepper(String(format: "Tear %.1f m", model.settings.tearThresholdMetres), value: $model.settings.tearThresholdMetres, in: 0.1 ... 3, step: 0.1)
                    Stepper("Lead \(Int((model.settings.leadSeconds * 1000).rounded())) ms", value: $model.settings.leadSeconds, in: 0 ... 0.06, step: 0.0055)
                }
                Picker("Anti-aliasing", selection: $model.antiAliasing) {
                    ForEach(ExampleAntiAliasing.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(!model.spaceOpen)

            VStack(alignment: .leading, spacing: 8) {
                Text("For the next space opened (close and open the space)")
                    .font(.headline)
                HStack(spacing: 24) {
                    Picker("Grid", selection: $model.grid) {
                        ForEach(ExampleGrid.allCases) { grid in
                            Text(grid.label).tag(grid)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Shell 50 m", isOn: $model.nearShell)
                    Toggle("View +3 cm", isOn: $model.viewOffsetTest)
                }
                Toggle("Equi-angular rate map (the same pixels, denser at the centre of view; the grid becomes the map's)", isOn: $model.rateMap)
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


/// The grids the window offers, each eye's vertex count.
enum ExampleGrid: String, CaseIterable, Identifiable {
    case standard, dense

    var id: String { rawValue }

    var columns: Int { self == .dense ? 512 : 256 }
    var rows: Int { self == .dense ? 480 : 240 }
    var label: String { "\(columns)×\(rows)" }

    static func remembered() -> ExampleGrid {
        ExampleGrid(rawValue: UserDefaults.standard.string(forKey: "grid") ?? "") ?? .standard
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: "grid")
    }
}
