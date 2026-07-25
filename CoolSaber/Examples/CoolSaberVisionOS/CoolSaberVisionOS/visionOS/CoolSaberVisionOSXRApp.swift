//
//  CoolSaberVisionOSXRApp.swift  (visionOS)
//  CoolSaber
//
//  Mixed-reality lightsaber duel. The PSVR2 Sense controllers are the hilts —
//  the trigger ignites a blade from the controller tip. Start a SharePlay
//  duel from a FaceTime call and the opponent's blades appear in your room.
//

import CompositorServices
import CoolSaber
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries the
// control-window blade color to the game thread.
final class SaberXRHolder: @unchecked Sendable {
    static let shared = SaberXRHolder()
    var xr: UntoldEngineXR?
    var game: SaberXRGame?
    var renderThread: Thread?

    private let lock = NSLock()
    private var localColorStorage = SIMD3<Float>(0.35, 0.55, 1.0)

    var localColor: SIMD3<Float> {
        get { lock.withLock { localColorStorage } }
        set { lock.withLock { localColorStorage = newValue } }
    }
}

struct SaberLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

struct SaberBladeColor: Identifiable, Equatable {
    let id: String
    let name: String
    let value: SIMD3<Float>

    static let all: [SaberBladeColor] = [
        SaberBladeColor(id: "blue", name: "Blue", value: SIMD3(0.35, 0.55, 1.0)),
        SaberBladeColor(id: "green", name: "Green", value: SIMD3(0.30, 1.0, 0.45)),
        SaberBladeColor(id: "purple", name: "Purple", value: SIMD3(0.72, 0.35, 1.0)),
    ]
}

@main
struct CoolSaberVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var sessionController = SaberSessionController()
    @State private var bladeColorID = "blue"
    @State private var immersed = false

    var body: some SwiftUI.Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Cool Saber").font(.extraLargeTitle).fontWeight(.bold)
                Text("Grab your PSVR2 controllers, pull a trigger to ignite.\nStart a duel on a FaceTime call for a two-player laser battle.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                Button {
                    Task {
                        await openImmersiveSpace(id: "Saber")
                        immersed = true
                    }
                } label: {
                    Label("Enter the Duel Arena", systemImage: "sparkles")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                #if targetEnvironment(simulator)
                // The simulator has no controllers: enter directly and watch
                // the auto-swinging debug blades.
                .task { await openImmersiveSpace(id: "Saber"); immersed = true }
                #endif

                Divider()

                HStack(spacing: 16) {
                    Text("Blade")
                    Picker("Blade", selection: $bladeColorID) {
                        ForEach(SaberBladeColor.all) { color in
                            Text(color.name).tag(color.id)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                .onChange(of: bladeColorID) { _, newValue in
                    if let color = SaberBladeColor.all.first(where: { $0.id == newValue }) {
                        SaberXRHolder.shared.localColor = color.value
                    }
                }

                Divider()

                Text(sessionController.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if case .idle = sessionController.status {
                    Button {
                        sessionController.startDuel()
                    } label: {
                        Label("Start Duel (SharePlay)", systemImage: "shareplay")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button(role: .destructive) {
                        sessionController.leaveDuel()
                    } label: {
                        Label("Leave Duel", systemImage: "xmark.circle")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(48)
            .task {
                sessionController.startSessionObserver()
            }
            .onChange(of: sessionController.groupImmersionActive) { _, active in
                guard let active else { return }
                Task {
                    if active, !immersed {
                        await openImmersiveSpace(id: "Saber")
                        immersed = true
                    } else if !active, immersed {
                        await dismissImmersiveSpace()
                        immersed = false
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 560)

        ImmersiveSpace(id: "Saber") {
            CompositorLayer(configuration: SaberLayerConfiguration()) { layerRenderer in
                guard SaberXRHolder.shared.xr == nil else { return }
                guard installCoolSaber() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                SaberXRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up
                // directly here (matches the engine's XR template). The blocking
                // render loop runs on its own plain Thread — NOT the main actor.
                let game = SaberXRGame()
                SaberXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                SaberXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }

    private func installCoolSaber() -> Bool {
        switch registerCoolSaberPlugin() {
        case .installed, .replaced:
            return true
        case let .rejected(failure):
            print("CoolSaber installation rejected:", failure)
            return false
        }
    }
}
