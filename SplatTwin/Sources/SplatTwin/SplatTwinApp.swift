//
//  SplatTwinApp.swift
//  SplatTwin
//
//  A macOS window with the engine view and a small HUD over it.
//

import SwiftUI
import UntoldEngine
import UntoldGaussianTwins

@main
struct SplatTwinApp: App {
    @StateObject private var host = DemoHost()

    var body: some SwiftUI.Scene {
        WindowGroup("Splat Twin") {
            DemoView(host: host)
        }
        .defaultSize(width: 1280, height: 720)
    }
}

/// Owns the renderer and the scene, and publishes what the HUD shows.
@MainActor
final class DemoHost: ObservableObject {
    let renderer: UntoldRenderer?
    private var gameScene: GameScene?

    @Published var readouts: [TwinReadout] = []
    @Published var shellsEnabled = true {
        didSet { GaussianDebugOptions.shared.disableOccluderShell = !shellsEnabled }
    }

    @Published var swapDistance: Float = 4.0 {
        didSet { gameScene?.showcase.swapDistance = swapDistance }
    }

    @Published var crossFadeDuration: Float = 0.3 {
        didSet { gameScene?.showcase.crossFadeDuration = crossFadeDuration }
    }

    init() {
        guard let renderer = UntoldRenderer.create() else {
            self.renderer = nil
            return
        }
        self.renderer = renderer
        let gameScene = GameScene()
        gameScene.onReadouts = { [weak self] readouts in
            self?.readouts = readouts
        }
        renderer.setupCallbacks(
            gameUpdate: { deltaTime in gameScene.update(deltaTime: deltaTime) },
            handleInput: { gameScene.handleInput() }
        )
        self.gameScene = gameScene
    }
}

struct DemoView: View {
    @ObservedObject var host: DemoHost

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let renderer = host.renderer {
                SceneView(renderer: renderer)
            } else {
                ContentUnavailableView("No Metal device", systemImage: "cpu", description: Text("The engine could not create a renderer."))
            }
            HUDView(host: host)
                .padding(16)
        }
    }
}

struct HUDView: View {
    @ObservedObject var host: DemoHost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Splat Twin")
                .font(.headline)
            Text("WASD move · Q/E up-down · right-drag orbit. Walk up to an object: its mesh cross-fades to its splat; walk away and it fades back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360, alignment: .leading)

            Divider()

            ForEach(host.readouts) { readout in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: readout.state))
                        .frame(width: 9, height: 9)
                    Text(readout.name)
                        .frame(width: 64, alignment: .leading)
                    Text(label(for: readout))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Occluder shells", isOn: $host.shellsEnabled)
                .toggleStyle(.switch)
                .font(.caption)
            LabeledContent("Swap at \(host.swapDistance, format: .number.precision(.fractionLength(1))) m") {
                Slider(value: $host.swapDistance, in: 1 ... 8)
                    .frame(width: 140)
            }
            .font(.caption)
            LabeledContent("Fade \(Int(host.crossFadeDuration * 1000)) ms") {
                Slider(value: $host.crossFadeDuration, in: 0.1 ... 1.0)
                    .frame(width: 140)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 400)
    }

    private func label(for readout: TwinReadout) -> String {
        let distance = String(format: "%.1f m", readout.distance)
        switch readout.state {
        case .armed: return "\(distance)  mesh"
        case .loading: return "\(distance)  loading splat"
        case .crossFading: return "\(distance)  fading in \(Int(readout.fadeProgress * 100))%"
        case .swapped: return "\(distance)  splat · \(readout.splatCount) splats"
        case .reverting: return "\(distance)  fading out \(Int(readout.fadeProgress * 100))%"
        }
    }

    private func color(for state: GaussianTwinState) -> Color {
        switch state {
        case .armed: return .gray
        case .loading: return .yellow
        case .crossFading, .reverting: return .orange
        case .swapped: return .green
        }
    }
}
