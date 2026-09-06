//
//  CoolZombieVisionOSXRApp.swift  (visionOS)
//  CoolZombie
//
//  Mixed-reality zombie. It waits a few meters in front of you, shambling.
//  Walk toward it — cross the trigger radius and it comes for you, stopping
//  an arm's length away. Motion matching picks every clip; nothing is
//  scripted.
//

import CompositorServices
import CoolZombieKit
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class ZombieXRHolder: @unchecked Sendable {
    static let shared = ZombieXRHolder()
    var xr: UntoldEngineXR?
    var game: ZombieXRGame?
    var renderThread: Thread?
    /// Main-actor flag: the immersive space is currently open and rendering.
    var spaceOpen = false
    var lastOpenResult = "—"

    private let lock = NSLock()
    private var phaseStorage = "loading"
    private var distanceStorage: Float = .infinity
    private var trackedStorage = false
    private var provokePending = false
    private var resetPending = false

    // MARK: Game-thread writers

    func setDiagnostics(phase: String, distance: Float, tracked: Bool) {
        lock.withLock {
            phaseStorage = phase
            distanceStorage = distance
            trackedStorage = tracked
        }
    }

    // MARK: Control-window API

    var phase: String { lock.withLock { phaseStorage } }
    var distance: Float { lock.withLock { distanceStorage } }
    var headTracked: Bool { lock.withLock { trackedStorage } }

    func requestProvoke() { lock.withLock { provokePending = true } }
    func requestReset() { lock.withLock { resetPending = true } }

    func takeProvokeRequest() -> Bool {
        lock.withLock {
            let pending = provokePending
            provokePending = false
            return pending
        }
    }

    func takeResetRequest() -> Bool {
        lock.withLock {
            let pending = resetPending
            resetPending = false
            return pending
        }
    }
}

struct ZombieLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolZombieVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Zombie 🧟").font(.extraLargeTitle).fontWeight(.bold)
                    Text("A zombie waits a few meters in front of you. Walk toward it —\nget close and it comes for you. Motion matching picks every clip;\nnothing is scripted.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Room")
                            ZombieXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolZombie: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Enter the room", systemImage: "figure.walk")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Provoke it") {
                            ZombieXRHolder.shared.requestProvoke()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reset") {
                            ZombieXRHolder.shared.requestReset()
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = ZombieXRHolder.shared
                        VStack(spacing: 8) {
                            Text(holder.phase.capitalized)
                                .font(.title2.monospacedDigit()).fontWeight(.semibold)
                            Text(
                                "Space \(holder.spaceOpen ? "OPEN" : "closed")"
                                    + " (last open: \(holder.lastOpenResult))"
                                    + " · head \(holder.headTracked ? "tracked" : "—")"
                                    + (holder.distance.isFinite
                                        ? String(format: " · distance %.2f m", holder.distance)
                                        : "")
                            )
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(48)
                .onAppear {
                    // Test hook: `-autoOpenSpace` opens the immersive space
                    // immediately, so automated simulator runs don't depend
                    // on synthesizing a gaze-and-pinch on the button.
                    guard ProcessInfo.processInfo.arguments.contains("-autoOpenSpace"),
                          !ZombieXRHolder.shared.spaceOpen else { return }
                    Task {
                        let result = await openImmersiveSpace(id: "Room")
                        ZombieXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolZombie: auto-open → \(String(describing: result))")
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 440)

        ImmersiveSpace(id: "Room") {
            CompositorLayer(configuration: ZombieLayerConfiguration()) { layerRenderer in
                guard ZombieXRHolder.shared.xr == nil else {
                    print("CoolZombie: immersive space reopened before teardown finished")
                    return
                }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                ZombieXRHolder.shared.xr = xr
                ZombieXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // Scene construction is main-actor (the CompositorLayer closure
                // is); per-frame updates run on the XR render thread.
                let game = ZombieXRGame()
                game.game.setupScene()
                ZombieXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: {}
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                    // The layer was invalidated: the space closed (crown press,
                    // system dismiss). Tear down so the next open rebuilds
                    // cleanly instead of hitting a dead renderer.
                    game.shutdown()
                    Task { @MainActor in
                        ZombieXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            ZombieXRHolder.shared.xr = nil
                            ZombieXRHolder.shared.game = nil
                            ZombieXRHolder.shared.renderThread = nil
                            print("CoolZombie: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                ZombieXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
