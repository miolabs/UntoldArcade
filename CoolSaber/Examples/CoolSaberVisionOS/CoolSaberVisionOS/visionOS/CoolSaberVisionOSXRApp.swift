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
    /// Main-actor flag: the immersive space is currently open and rendering.
    var spaceOpen = false
    /// Main-actor: result of the most recent openImmersiveSpace call.
    var lastOpenResult = "—"
    /// Set by the game thread when the first wand delivers a tracked pose;
    /// reset on game start. While false the arena shows the loading spinner
    /// and the window shows a progress row.
    var wandsEverTracked = false

    private let lock = NSLock()
    private var localColorStorage = SIMD3<Float>(0.35, 0.55, 1.0)
    private var bladeTiltStorage: Float = SaberFitDefaults.tilt
    private var bladeLeanStorage: Float = SaberFitDefaults.lean
    private var gripOffsetStorage = SaberFitDefaults.gripOffset

    var localColor: SIMD3<Float> {
        get { lock.withLock { localColorStorage } }
        set { lock.withLock { localColorStorage = newValue } }
    }

    /// Forward tilt of the blade in degrees: 0 = straight out of the fist
    /// (controller +Y), 90 = along the controller's forward axis (-Z).
    var bladeTiltDegrees: Float {
        get { lock.withLock { bladeTiltStorage } }
        set { lock.withLock { bladeTiltStorage = newValue } }
    }

    /// Sideways lean of the tilted blade in degrees: swings the blade's
    /// forward tilt left (-) or right (+) around the controller's up axis —
    /// the correction tilt alone can't make.
    var bladeLeanDegrees: Float {
        get { lock.withLock { bladeLeanStorage } }
        set { lock.withLock { bladeLeanStorage = newValue } }
    }

    /// Blade origin relative to the controller pose, controller-local metres:
    /// x = side (right +), y = up out of the fist, z = forward (-) / back (+).
    var gripOffsetLocal: SIMD3<Float> {
        get { lock.withLock { gripOffsetStorage } }
        set { lock.withLock { gripOffsetStorage = newValue } }
    }
}

/// Defaults for the saber-fit tuning; the control window persists each
/// player's own adjustments on their device (grips and hand sizes differ).
enum SaberFitDefaults {
    static let tilt: Float = 73
    static let lean: Float = 6
    static let gripOffset = SIMD3<Float>(-0.015, -0.005, -0.055)
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
    // Saber fit, persisted per player: everyone grips the wand differently.
    @AppStorage("saber.fit.tilt") private var bladeTilt = Double(SaberFitDefaults.tilt)
    @AppStorage("saber.fit.lean") private var bladeLean = Double(SaberFitDefaults.lean)
    @AppStorage("saber.fit.side") private var fitSide = Double(SaberFitDefaults.gripOffset.x)
    @AppStorage("saber.fit.height") private var fitHeight = Double(SaberFitDefaults.gripOffset.y)
    @AppStorage("saber.fit.forward") private var fitForward = Double(SaberFitDefaults.gripOffset.z)

    var body: some SwiftUI.Scene {
        WindowGroup {
            // Scrollable so expanding the fit panel can never push the
            // SharePlay controls out of the window.
            ScrollView {
            VStack(spacing: 20) {
                Text("Cool Saber").font(.extraLargeTitle).fontWeight(.bold)
                Text("Grab your PSVR2 controllers, pull a trigger to ignite.\nStart a duel on a FaceTime call for a two-player laser battle.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                Button {
                    Task {
                        let result = await openImmersiveSpace(id: "Saber")
                        SaberXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolSaber: openImmersiveSpace → \(String(describing: result))")
                    }
                } label: {
                    Label("Enter the Duel Arena", systemImage: "sparkles")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                #if targetEnvironment(simulator)
                // The simulator has no controllers: enter directly and watch
                // the auto-swinging debug blades.
                .task { _ = await openImmersiveSpace(id: "Saber") }
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

                // Saber fit: how the blade sits on THIS player's grip. Applied
                // live and saved on this device, so every player dials in
                // their own controller without touching code. Collapsed by
                // default so the main actions stay visible in the window.
                DisclosureGroup("Saber fit") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Tilt \(Int(bladeTilt))°").monospacedDigit()
                        Slider(value: $bladeTilt, in: 0 ... 90, step: 1)
                    }
                    GridRow {
                        Text("Lean \(Int(bladeLean))°").monospacedDigit()
                        Slider(value: $bladeLean, in: -60 ... 60, step: 1)
                    }
                    GridRow {
                        Text(cmLabel("Side", fitSide)).monospacedDigit()
                        Slider(value: $fitSide, in: -0.06 ... 0.06, step: 0.005)
                    }
                    GridRow {
                        Text(cmLabel("Height", fitHeight)).monospacedDigit()
                        Slider(value: $fitHeight, in: -0.05 ... 0.12, step: 0.005)
                    }
                    GridRow {
                        Text(cmLabel("Forward", -fitForward)).monospacedDigit()
                        // Controller -Z is forward; invert so right = forward.
                        Slider(
                            value: Binding(get: { -fitForward }, set: { fitForward = -$0 }),
                            in: -0.06 ... 0.15,
                            step: 0.005
                        )
                    }
                }
                .font(.callout)
                .padding(.top, 8)

                Button("Reset saber fit") {
                    bladeTilt = Double(SaberFitDefaults.tilt)
                    bladeLean = Double(SaberFitDefaults.lean)
                    fitSide = Double(SaberFitDefaults.gripOffset.x)
                    fitHeight = Double(SaberFitDefaults.gripOffset.y)
                    fitForward = Double(SaberFitDefaults.gripOffset.z)
                }
                .buttonStyle(.borderless)
                .font(.footnote)
                }
                .onChange(of: bladeTilt) { _, _ in pushFit() }
                .onChange(of: bladeLean) { _, _ in pushFit() }
                .onChange(of: fitSide) { _, _ in pushFit() }
                .onChange(of: fitHeight) { _, _ in pushFit() }
                .onChange(of: fitForward) { _, _ in pushFit() }

                Divider()

                Text(sessionController.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Live diagnostics: shows exactly where the entry flow stalls.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let sense = getPSVR2SenseState()
                    let holder = SaberXRHolder.shared
                    VStack(spacing: 8) {
                        if holder.spaceOpen, !holder.wandsEverTracked {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(
                                    sense.isConnected
                                        ? "Preparing wand tracking — the sabers ignite in a few seconds…"
                                        : "Waiting for PSVR2 controllers — press PS to wake them…"
                                )
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        Text(
                            "Arena \(holder.spaceOpen ? "OPEN" : "closed")"
                                + " (last open: \(holder.lastOpenResult))"
                                + " · PSVR2 \(sense.isConnected ? "connected" : "NOT connected")"
                                + " · L \(sense.left.isTracked ? "tracked" : "—")"
                                + " · R \(sense.right.isTracked ? "tracked" : "—")"
                        )
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                    }
                }

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
                pushFit() // restore this player's saved saber fit
                sessionController.startSessionObserver()
                // Warm up the engine's input system at launch: touching it
                // starts PSVR2 wand discovery and the (slow) ARKit accessory
                // loading NOW, so the accessory provider already exists when
                // the immersive space runs its ARKit providers. Loading it
                // late forces a provider re-run that can leave world tracking
                // paused (observed on device).
                _ = isPSVR2SenseConnected()
            }
            .onChange(of: sessionController.groupImmersionActive) { _, active in
                guard let active else { return }
                Task {
                    if active, !SaberXRHolder.shared.spaceOpen {
                        _ = await openImmersiveSpace(id: "Saber")
                    } else if !active, SaberXRHolder.shared.spaceOpen {
                        await dismissImmersiveSpace()
                    }
                }
            }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 640)

        ImmersiveSpace(id: "Saber") {
            CompositorLayer(configuration: SaberLayerConfiguration()) { layerRenderer in
                guard SaberXRHolder.shared.xr == nil else {
                    print("CoolSaber: immersive space reopened before teardown finished")
                    return
                }
                guard installCoolSaber() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                SaberXRHolder.shared.xr = xr
                SaberXRHolder.shared.spaceOpen = true
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
                    // The layer was invalidated: the space closed (crown press,
                    // SharePlay transition, system dismiss). Tear everything
                    // down so the next open rebuilds cleanly instead of hitting
                    // a dead renderer.
                    game.shutdown()
                    Task { @MainActor in
                        SaberXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            SaberXRHolder.shared.xr = nil
                            SaberXRHolder.shared.game = nil
                            SaberXRHolder.shared.renderThread = nil
                            print("CoolSaber: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                SaberXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }

    private func pushFit() {
        SaberXRHolder.shared.bladeTiltDegrees = Float(bladeTilt)
        SaberXRHolder.shared.bladeLeanDegrees = Float(bladeLean)
        SaberXRHolder.shared.gripOffsetLocal = SIMD3<Float>(
            Float(fitSide), Float(fitHeight), Float(fitForward)
        )
    }

    private func cmLabel(_ name: String, _ metres: Double) -> String {
        String(format: "%@ %+.1f cm", name, metres * 100)
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
