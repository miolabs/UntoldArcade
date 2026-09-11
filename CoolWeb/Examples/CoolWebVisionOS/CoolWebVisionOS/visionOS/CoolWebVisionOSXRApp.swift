//
//  CoolWebVisionOSXRApp.swift  (visionOS)
//  CoolWeb
//
//  Mixed-reality Spider-Man web shooter. Strike the web-shooter pose — thumb,
//  index and pinky extended, middle and ring curled — and a web fires from
//  your wrist and sticks to the real surface it hits. Clench a fist to let go.
//

import CompositorServices
import CoolWeb
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class WebXRHolder: @unchecked Sendable {
    static let shared = WebXRHolder()
    var xr: UntoldEngineXR?
    var game: WebXRGame?
    var renderThread: Thread?
    /// Main-actor flag: the immersive space is currently open and rendering.
    var spaceOpen = false
    /// Main-actor: result of the most recent openImmersiveSpace call.
    var lastOpenResult = "—"

    struct HandDiagnostics {
        var tracked = false
        /// Extension ratios thumb, index, middle, ring, little (0…1) or nil
        /// before the first classifier frame.
        var extensions: [Float]?
    }

    private let lock = NSLock()
    private var handDiagnostics: [CoolWebHandSide: HandDiagnostics] = [:]
    private var strandCountStorage = 0
    private var surfaceTriangleStorage = 0
    private var testFirePending = false
    private var releaseAllPending = false
    private var gloveFitStorage = CoolWebGloveFit()

    /// Glove fit knobs, set from the control window's sliders and read by
    /// the game thread every frame.
    var gloveFit: CoolWebGloveFit {
        get { lock.withLock { gloveFitStorage } }
        set { lock.withLock { gloveFitStorage = newValue } }
    }

    // MARK: Game-thread writers

    func setHandDiagnostics(
        _ side: CoolWebHandSide,
        tracked: Bool,
        extensions: [Float]?
    ) {
        lock.withLock {
            handDiagnostics[side] = HandDiagnostics(
                tracked: tracked,
                extensions: extensions
            )
        }
    }

    func setSceneDiagnostics(strandCount: Int, surfaceTriangles: Int) {
        lock.withLock {
            strandCountStorage = strandCount
            surfaceTriangleStorage = surfaceTriangles
        }
    }

    func resetDiagnostics() {
        lock.withLock {
            handDiagnostics.removeAll()
            strandCountStorage = 0
            surfaceTriangleStorage = 0
        }
    }

    // MARK: Control-window API

    func hand(_ side: CoolWebHandSide) -> HandDiagnostics {
        lock.withLock { handDiagnostics[side] ?? HandDiagnostics() }
    }

    var strandCount: Int { lock.withLock { strandCountStorage } }
    var surfaceTriangles: Int { lock.withLock { surfaceTriangleStorage } }

    func requestTestFire() { lock.withLock { testFirePending = true } }
    func requestReleaseAll() { lock.withLock { releaseAllPending = true } }

    func takeTestFireRequest() -> Bool {
        lock.withLock {
            let pending = testFirePending
            testFirePending = false
            return pending
        }
    }

    func takeReleaseAllRequest() -> Bool {
        lock.withLock {
            let pending = releaseAllPending
            releaseAllPending = false
            return pending
        }
    }
}

struct WebLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolWebVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var occlusionEnabled = true
    @State private var tensionHeatmap = false
    @State private var impactSplat = false
    @State private var suitUp = false
    @State private var gloveFit = CoolWebGloveFit()

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Web").font(.extraLargeTitle).fontWeight(.bold)
                    Text("Strike the web-shooter pose — thumb, index and pinky out,\nmiddle and ring curled — to fire a web at a real surface.\nThe web stays tied to your hand, even in a fist.\nOpen your palm to let it go.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Web")
                            WebXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolWeb: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Enter the Web Room", systemImage: "sparkles")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Test fire") {
                            WebXRHolder.shared.requestTestFire()
                        }
                        .buttonStyle(.bordered)

                        Button("Release all webs") {
                            WebXRHolder.shared.requestReleaseAll()
                        }
                        .buttonStyle(.bordered)
                    }

                    // Suit-Up: flip it, then look at a hand — after a short
                    // focus delay the glove weaves over it (each hand
                    // triggers on its own gaze). Flip it off and the fabric
                    // retracts in reverse back into the wrist.
                    Toggle("Suit-Up", isOn: $suitUp)
                        .frame(maxWidth: 320)
                        .onChange(of: suitUp) { _, up in
                            setCoolWebGloveSuitUp(up)
                        }

                    Toggle("Real-room occlusion", isOn: $occlusionEnabled)
                        .frame(maxWidth: 320)
                        .onChange(of: occlusionEnabled) { _, enabled in
                            setCoolWebOcclusionEnabled(enabled)
                        }

                    // Debug view from the reference clip: threads shade from
                    // blue at rest to red right before they tear.
                    Toggle("Tension heatmap", isOn: $tensionHeatmap)
                        .frame(maxWidth: 320)
                        .onChange(of: tensionHeatmap) { _, enabled in
                            setCoolWebTensionHeatmap(enabled)
                        }

                    // The flat decal at the impact point — off by default
                    // (read as a sticker on device), kept for comparison.
                    Toggle("Impact splat decal", isOn: $impactSplat)
                        .frame(maxWidth: 320)
                        .onChange(of: impactSplat) { _, enabled in
                            setCoolWebSplatsEnabled(enabled)
                        }

                    Divider()

                    // Glove fit: how the suit hand's proportions stretch over
                    // the real hand. Bone lengths always track the joints;
                    // these shape the cross-sections and fingertip overshoot
                    // so the glove fully envelops the hand.
                    VStack(spacing: 8) {
                        Text("Glove fit").font(.headline)
                        fitSlider("Fingertip pad", value: $gloveFit.fingertipPadding,
                                  range: 0 ... 0.03, format: "%.0f mm", scale: 1000)
                        fitSlider("Finger girth", value: $gloveFit.fingerGirth,
                                  range: 0.4 ... 1.6, format: "×%.2f")
                        fitSlider("Palm thickness", value: $gloveFit.palmThickness,
                                  range: 0.25 ... 1.5, format: "×%.2f")
                        fitSlider("Cuff girth", value: $gloveFit.cuffGirth,
                                  range: 0.7 ... 1.8, format: "×%.2f")
                        fitSlider("Shell inflate", value: $gloveFit.inflate,
                                  range: 0 ... 0.012, format: "%.1f mm", scale: 1000)
                        Button("Reset fit") { gloveFit = CoolWebGloveFit() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: 420)
                    .onChange(of: gloveFit) { _, fit in
                        WebXRHolder.shared.gloveFit = fit
                    }

                    Divider()

                    // Live diagnostics: hand tracking state and the per-finger
                    // extension ratios the classifier sees — this is the panel
                    // used to tune gesture thresholds on device.
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = WebXRHolder.shared
                        VStack(spacing: 12) {
                            handDiagnosticsRow(label: "Left", diagnostics: holder.hand(.left))
                            handDiagnosticsRow(label: "Right", diagnostics: holder.hand(.right))
                            Text(
                                "Space \(holder.spaceOpen ? "OPEN" : "closed")"
                                    + " (last open: \(holder.lastOpenResult))"
                                    + " · webs \(holder.strandCount)"
                                    + " · mesh \(holder.surfaceTriangles) tris"
                            )
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(48)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 560)

        ImmersiveSpace(id: "Web") {
            CompositorLayer(configuration: WebLayerConfiguration()) { layerRenderer in
                guard WebXRHolder.shared.xr == nil else {
                    print("CoolWeb: immersive space reopened before teardown finished")
                    return
                }
                guard installCoolWeb() else { return }
                setCoolWebGloveEnabled(true)
                setCoolWebGloveSuitUp(suitUp)

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                WebXRHolder.shared.xr = xr
                WebXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up
                // directly here (matches the engine's XR template). The blocking
                // render loop runs on its own plain Thread — NOT the main actor.
                let game = WebXRGame()
                WebXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                    // The layer was invalidated: the space closed (crown press,
                    // system dismiss). Tear everything down so the next open
                    // rebuilds cleanly instead of hitting a dead renderer.
                    game.shutdown()
                    Task { @MainActor in
                        WebXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            WebXRHolder.shared.xr = nil
                            WebXRHolder.shared.game = nil
                            WebXRHolder.shared.renderThread = nil
                            print("CoolWeb: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                WebXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
        // With Suit-Up on, the system must not composite the real
        // passthrough hands over our render — the glove replaces them.
        // Driven directly by the toggle: a timer-based progress poll dies
        // with the control window and left the real hands visible on device.
        .upperLimbVisibility(suitUp ? .hidden : .automatic)
    }

    @ViewBuilder
    /// One labeled fit slider with its live value; `scale` converts the
    /// stored value for display (e.g. meters → mm).
    private func fitSlider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        format: String,
        scale: Float = 1
    ) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * scale))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func handDiagnosticsRow(
        label: String,
        diagnostics: WebXRHolder.HandDiagnostics
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.monospaced())
                .frame(width: 52, alignment: .leading)
            if diagnostics.tracked, let extensions = diagnostics.extensions {
                ForEach(Array(zip(["T", "I", "M", "R", "P"], extensions)), id: \.0) { finger, value in
                    VStack(spacing: 2) {
                        Gauge(value: Double(max(0, min(1, value)))) {
                            EmptyView()
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .frame(width: 44)
                        Text(finger).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(diagnostics.tracked ? "tracked" : "not tracked")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installCoolWeb() -> Bool {
        switch registerCoolWebPlugin() {
        case .installed, .replaced:
            return true
        case let .rejected(failure):
            print("CoolWeb installation rejected:", failure)
            return false
        }
    }
}
