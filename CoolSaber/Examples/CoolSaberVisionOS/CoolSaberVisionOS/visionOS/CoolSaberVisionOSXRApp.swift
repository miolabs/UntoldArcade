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
import Spatial
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
    /// Main-actor: the arena's open/dismiss gatekeeper, so the layer
    /// lifecycle can report back to it.
    weak var presenter: SaberArenaPresenter?
    /// Set by the game thread when the first wand delivers a tracked pose;
    /// reset on game start. While false the arena shows the loading spinner
    /// and the window shows a progress row.
    var wandsEverTracked = false

    private let lock = NSLock()
    private var localColorStorage = SIMD3<Float>(0.35, 0.55, 1.0)
    private var fitStorage = [SaberFitDefaults.left, SaberFitDefaults.right]
    /// SwiftUI's `immersiveSpaceDisplacement` as a matrix: ARKit-from-shared.
    /// A pose in the group's shared immersive-space frame, multiplied by
    /// this, lands in this device's ARKit frame (the frame the engine renders
    /// and the wands track in). Identity outside a shared session.
    private var displacementStorage = matrix_identity_float4x4
    private var displacementSummaryStorage = "identity"

    var localColor: SIMD3<Float> {
        get { lock.withLock { localColorStorage } }
        set { lock.withLock { localColorStorage = newValue } }
    }

    /// Per-hand saber fit (index 0 = left, 1 = right — the game's hand order).
    func fit(forHand hand: Int) -> SaberFitValues {
        lock.withLock { fitStorage[hand == 0 ? 0 : 1] }
    }

    func setFit(_ fit: SaberFitValues, forHand hand: Int) {
        lock.withLock { fitStorage[hand == 0 ? 0 : 1] = fit }
    }

    /// ARKit-from-shared (see `displacementStorage`). Read per frame by the
    /// game thread; written from the arena's SwiftUI environment.
    var spaceDisplacement: simd_float4x4 {
        lock.withLock { displacementStorage }
    }

    /// Human-readable displacement for the window's diagnostics row.
    var displacementSummary: String {
        lock.withLock { displacementSummaryStorage }
    }

    func setSpaceDisplacement(_ matrix: simd_float4x4, summary: String) {
        lock.withLock {
            displacementStorage = matrix
            displacementSummaryStorage = summary
        }
    }
}

/// How a blade sits on one wand.
struct SaberFitValues: Sendable {
    /// Forward tilt in degrees: 0 = straight out of the fist (controller +Y),
    /// 90 = along the controller's forward axis (-Z).
    var tiltDegrees: Float
    /// Sideways lean in degrees: swings the tilted blade left (-) or
    /// right (+) around the controller's up axis.
    var leanDegrees: Float
    /// Blade origin relative to the controller pose, controller-local metres:
    /// x = side (right +), y = up out of the fist, z = forward (-) / back (+).
    var gripOffset: SIMD3<Float>
}

/// Defaults for the saber-fit tuning; the control window persists each
/// player's own per-hand adjustments on their device (grips, hand sizes and
/// the wands themselves differ between hands).
enum SaberFitDefaults {
    /// Verified on device for the right wand.
    static let right = SaberFitValues(
        tiltDegrees: 73,
        leanDegrees: 6,
        gripOffset: SIMD3<Float>(-0.015, -0.005, -0.055)
    )
    /// The left wand mirrors the right's sideways components as a starting point.
    static let left = SaberFitValues(
        tiltDegrees: 73,
        leanDegrees: -6,
        gripOffset: SIMD3<Float>(0.015, -0.005, -0.055)
    )
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
    @State private var arena = SaberArenaPresenter()
    @State private var bladeColorID = "blue"
    // Saber fit, persisted per player AND per hand: the two wands are not
    // symmetric, so each blade needs its own alignment.
    @State private var fitHand = 1 // 0 = left, 1 = right
    @AppStorage("saber.fit.r.tilt") private var rTilt = Double(SaberFitDefaults.right.tiltDegrees)
    @AppStorage("saber.fit.r.lean") private var rLean = Double(SaberFitDefaults.right.leanDegrees)
    @AppStorage("saber.fit.r.side") private var rSide = Double(SaberFitDefaults.right.gripOffset.x)
    @AppStorage("saber.fit.r.height") private var rHeight = Double(SaberFitDefaults.right.gripOffset.y)
    @AppStorage("saber.fit.r.forward") private var rForward = Double(SaberFitDefaults.right.gripOffset.z)
    @AppStorage("saber.fit.l.tilt") private var lTilt = Double(SaberFitDefaults.left.tiltDegrees)
    @AppStorage("saber.fit.l.lean") private var lLean = Double(SaberFitDefaults.left.leanDegrees)
    @AppStorage("saber.fit.l.side") private var lSide = Double(SaberFitDefaults.left.gripOffset.x)
    @AppStorage("saber.fit.l.height") private var lHeight = Double(SaberFitDefaults.left.gripOffset.y)
    @AppStorage("saber.fit.l.forward") private var lForward = Double(SaberFitDefaults.left.gripOffset.z)
    /// Hilt → front of the controller ring along the blade, metres: where the
    /// two rings touch during the tip-to-tip sync.
    @AppStorage("saber.sync.ringFront") private var ringFront = 0.05

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
                    arena.open(reason: "Enter the Duel Arena button")
                } label: {
                    Label("Enter the Duel Arena", systemImage: "sparkles")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(arena.phase != .closed)
                #if targetEnvironment(simulator)
                // The simulator has no controllers: enter directly and watch
                // the auto-swinging debug blades.
                .task { arena.open(reason: "simulator auto-enter") }
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
                VStack(spacing: 12) {
                    Picker("Hand", selection: $fitHand) {
                        Text("Left wand").tag(0)
                        Text("Right wand").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Tilt \(Int(fitValue(.tilt).wrappedValue))°").monospacedDigit()
                            Slider(value: fitValue(.tilt), in: 0 ... 90, step: 1)
                        }
                        GridRow {
                            Text("Lean \(Int(fitValue(.lean).wrappedValue))°").monospacedDigit()
                            Slider(value: fitValue(.lean), in: -60 ... 60, step: 1)
                        }
                        GridRow {
                            Text(cmLabel("Side", fitValue(.side).wrappedValue)).monospacedDigit()
                            Slider(value: fitValue(.side), in: -0.06 ... 0.06, step: 0.005)
                        }
                        GridRow {
                            Text(cmLabel("Height", fitValue(.height).wrappedValue)).monospacedDigit()
                            Slider(value: fitValue(.height), in: -0.05 ... 0.12, step: 0.005)
                        }
                        GridRow {
                            Text(cmLabel("Forward", -fitValue(.forward).wrappedValue)).monospacedDigit()
                            // Controller -Z is forward; invert so right = forward.
                            Slider(
                                value: Binding(
                                    get: { -fitValue(.forward).wrappedValue },
                                    set: { fitValue(.forward).wrappedValue = -$0 }
                                ),
                                in: -0.06 ... 0.15,
                                step: 0.005
                            )
                        }
                    }
                    .font(.callout)

                    Button("Reset \(fitHand == 0 ? "left" : "right") fit") {
                        let defaults = fitHand == 0 ? SaberFitDefaults.left : SaberFitDefaults.right
                        fitValue(.tilt).wrappedValue = Double(defaults.tiltDegrees)
                        fitValue(.lean).wrappedValue = Double(defaults.leanDegrees)
                        fitValue(.side).wrappedValue = Double(defaults.gripOffset.x)
                        fitValue(.height).wrappedValue = Double(defaults.gripOffset.y)
                        fitValue(.forward).wrappedValue = Double(defaults.gripOffset.z)
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
                .padding(.top, 8)
                }

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
                            "Arena \(arena.phaseLabel)"
                                + " (last open: \(holder.lastOpenResult))"
                                + " · PSVR2 \(sense.isConnected ? "connected" : "NOT connected")"
                                + " · L \(sense.left.isTracked ? "tracked" : "—")"
                                + " · R \(sense.right.isTracked ? "tracked" : "—")"
                        )
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        // Shared-frame diagnostics: whether the session is
                        // spatial/nearby and what displacement the system
                        // applied to our arena. Identity during a nearby
                        // duel means the frames were never aligned.
                        let mailbox = SaberDuelMailbox.shared
                        Text(
                            "SharePlay \(mailbox.sessionActive ? "ACTIVE" : "off")"
                                + " · spatial \(mailbox.isSpatial ? "yes" : "no")"
                                + " · nearby \(mailbox.opponentNearby ? "yes" : "no")"
                                + " · displacement \(holder.displacementSummary)"
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
                    // Manual frame sync. The system aligns nothing for nearby
                    // players in a Metal space (displacement stays identity),
                    // so the players align the frames themselves: one shared
                    // point + heading from touching controllers.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let mailbox = SaberDuelMailbox.shared
                        VStack(spacing: 8) {
                            // Alignment: the system's shared world anchor
                            // when ARKit delivers it, else the manual sync.
                            Text("Anchor: \(mailbox.anchorSummary)")
                                .font(.callout.monospaced())
                                .foregroundStyle(
                                    mailbox.alignmentSource == .sharedAnchor ? Color.green : Color.secondary
                                )
                            Text("Manual: \(mailbox.frameSyncSummary)")
                                .font(.callout.monospaced())
                                .foregroundStyle(
                                    mailbox.alignmentSource == .manual ? Color.green : Color.secondary
                                )
                            Text(
                                mailbox.alignmentSource == .sharedAnchor
                                    ? "Aligned by the shared world anchor. Sync manually only if the blades look off."
                                    : "Face each other. Touch the fronts of your right controller rings "
                                        + "together — level, pointing at each other — then one of you taps Sync."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            Button {
                                mailbox.requestFrameSync()
                            } label: {
                                Label(
                                    mailbox.alignmentSource == .sharedAnchor ? "Sync manually (override)" : "Sync positions",
                                    systemImage: "scope"
                                )
                                .frame(minWidth: 260)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!mailbox.opponentPresent || !SaberXRHolder.shared.spaceOpen)

                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                                GridRow {
                                    Text(cmLabel("Ring front", ringFront)).monospacedDigit()
                                    Slider(value: $ringFront, in: 0 ... 0.12, step: 0.005)
                                        .onChange(of: ringFront) { _, value in
                                            mailbox.ringFront = Float(value)
                                        }
                                }
                                // Fine tune after a sync, by eye: shift the
                                // opponent's blades sideways / forward along
                                // the heading you had at sync time. Sent to
                                // the opponent once the slider rests.
                                GridRow {
                                    Text(cmLabel("Side", Double(mailbox.frameSyncNudgeValue.x))).monospacedDigit()
                                    Slider(
                                        value: Binding(
                                            get: { Double(mailbox.frameSyncNudgeValue.x) },
                                            set: { mailbox.frameSyncNudgeValue.x = Float($0) }
                                        ),
                                        in: -0.25 ... 0.25,
                                        step: 0.005
                                    )
                                    .disabled(!mailbox.isFrameSynced)
                                }
                                GridRow {
                                    Text(cmLabel("Forward", Double(mailbox.frameSyncNudgeValue.y))).monospacedDigit()
                                    Slider(
                                        value: Binding(
                                            get: { Double(mailbox.frameSyncNudgeValue.y) },
                                            set: { mailbox.frameSyncNudgeValue.y = Float($0) }
                                        ),
                                        in: -0.25 ... 0.25,
                                        step: 0.005
                                    )
                                    .disabled(!mailbox.isFrameSynced)
                                }
                            }
                            .font(.callout)
                        }
                    }

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
                arena.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                pushFit() // restore this player's saved saber fit
                SaberDuelMailbox.shared.ringFront = Float(ringFront)
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
                if active {
                    // The system wants the group immersive space. An arena
                    // opened BEFORE the session joined is a private space
                    // and never becomes shared (verified on device: the
                    // opponent cannot connect until it is closed and
                    // reopened), so cycle it.
                    arena.joinGroup(reason: "groupImmersionStyle active")
                } else {
                    arena.dismiss(reason: "groupImmersionStyle ended")
                }
            }
            .onChange(of: sessionController.joinCount) { _, _ in
                // Belt and braces: the join itself also cycles an open
                // arena, in case the style publisher stays quiet because
                // our space already matched the requested style.
                arena.joinGroup(reason: "session joined")
            }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 640)

        ImmersiveSpace(id: "Saber") {
            SaberArena()
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }

    private enum FitField {
        case tilt, lean, side, height, forward
    }

    /// Binding into the selected hand's persisted fit value; every write also
    /// pushes the full fit to the game.
    private func fitValue(_ f: FitField) -> Binding<Double> {
        let right = fitHand == 1
        return Binding(
            get: {
                switch f {
                case .tilt: right ? rTilt : lTilt
                case .lean: right ? rLean : lLean
                case .side: right ? rSide : lSide
                case .height: right ? rHeight : lHeight
                case .forward: right ? rForward : lForward
                }
            },
            set: { value in
                switch f {
                case .tilt: if right { rTilt = value } else { lTilt = value }
                case .lean: if right { rLean = value } else { lLean = value }
                case .side: if right { rSide = value } else { lSide = value }
                case .height: if right { rHeight = value } else { lHeight = value }
                case .forward: if right { rForward = value } else { lForward = value }
                }
                pushFit()
            }
        )
    }

    private func pushFit() {
        SaberXRHolder.shared.setFit(
            SaberFitValues(
                tiltDegrees: Float(lTilt),
                leanDegrees: Float(lLean),
                gripOffset: SIMD3<Float>(Float(lSide), Float(lHeight), Float(lForward))
            ),
            forHand: 0
        )
        SaberXRHolder.shared.setFit(
            SaberFitValues(
                tiltDegrees: Float(rTilt),
                leanDegrees: Float(rLean),
                gripOffset: SIMD3<Float>(Float(rSide), Float(rHeight), Float(rForward))
            ),
            forHand: 1
        )
    }

    private func cmLabel(_ name: String, _ metres: Double) -> String {
        String(format: "%@ %+.1f cm", name, metres * 100)
    }
}

/// The arena's immersive-space content. A `CompositorContent` rather than a
/// View so it can host the Metal `CompositorLayer` AND read SwiftUI's
/// `immersiveSpaceDisplacement`: the transform the system applies to this
/// immersive space during a shared session so the group's origin lands in a
/// good place for everyone (for nearby people, aligned in the physical room).
/// The wands and the device anchor stay in the local, un-displaced ARKit
/// frame, so this displacement is the only bridge between two headsets'
/// ARKit frames — the game applies it to every pose that crosses the wire.
struct SaberArena: CompositorContent {
    @Environment(\.immersiveSpaceDisplacement) private var displacement

    var body: some CompositorContent {
        CompositorLayer(configuration: SaberLayerConfiguration()) { layerRenderer in
            guard SaberXRHolder.shared.xr == nil else {
                // The presenter defers every open until teardown completes,
                // so this means an open bypassed it (e.g. a system-driven
                // presentation). The space is up but renders nothing; the
                // presenter learns about it so a dismiss can recover.
                print("CoolSaber[arena]: layer created before teardown finished — empty space")
                SaberXRHolder.shared.presenter?.arenaDidStart(rendering: false)
                return
            }
            guard installCoolSaber() else { return }

            guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
            SaberXRHolder.shared.xr = xr
            SaberXRHolder.shared.spaceOpen = true
            SaberXRHolder.shared.presenter?.arenaDidStart(rendering: true)
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
                        SaberXRHolder.shared.presenter?.arenaDidTearDown()
                    }
                }
            }
            thread.name = "XR Render Thread"
            thread.qualityOfService = .userInteractive
            SaberXRHolder.shared.renderThread = thread
            thread.start()
        }
        .onChange(of: displacement, initial: true) { old, new in
            Self.publish(new, previous: old, reason: "environment update")
        }
        .onWorldRecenter { phase in
            // The environment value updates on its own; this just marks the
            // moment in the log so a jump in the poses can be explained.
            print("CoolSaber: world recenter \(phase) — displacement \(SaberXRHolder.shared.displacementSummary)")
        }
    }

    private static func publish(_ pose: Pose3D, previous: Pose3D, reason: String) {
        let summary = describe(pose)
        SaberXRHolder.shared.setSpaceDisplacement(simd_float4x4(pose), summary: summary)
        print(
            "CoolSaber: immersiveSpaceDisplacement (\(reason)) → \(summary)"
                + (previous == pose ? "" : " (was \(describe(previous)))")
        )
    }

    private static func describe(_ pose: Pose3D) -> String {
        guard pose != .identity else { return "identity" }
        let p = pose.position.vector
        let axis = pose.rotation.axis.vector
        return String(
            format: "pos (%.2f, %.2f, %.2f) m · rot %.1f° about (%.2f, %.2f, %.2f)",
            p.x, p.y, p.z, pose.rotation.angle.degrees, axis.x, axis.y, axis.z
        )
    }
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

/// The one place that opens and dismisses the arena.
///
/// visionOS allows a single immersive-space request at a time: a second
/// `openImmersiveSpace` while one is pending or presented fails with
/// "Unable to present another Immersive Space when one is already requested
/// or connected". The arena has several would-be openers (the window button,
/// the simulator auto-enter, the SharePlay group-immersion signal, the join),
/// and the engine's teardown finishes asynchronously after the space closes,
/// so requests are serialised through this phase machine: at most one request
/// in flight, an open during a close is deferred until teardown completes.
@MainActor
@Observable
final class SaberArenaPresenter {
    enum Phase: Equatable {
        case closed
        case opening
        case open
        case closing
    }

    private(set) var phase: Phase = .closed
    /// True while the space is presented but the engine never attached
    /// (teardown race): only a dismiss can recover.
    private(set) var presentedEmpty = false

    private var openAction: OpenImmersiveSpaceAction?
    private var dismissAction: DismissImmersiveSpaceAction?
    private var pendingOpen = false
    private var pendingDismiss = false
    private var lastJoinCycleUptime: TimeInterval = 0

    init() {
        SaberXRHolder.shared.presenter = self
    }

    var phaseLabel: String {
        switch phase {
        case .closed: SaberXRHolder.shared.xr == nil ? "closed" : "closed (tearing down)"
        case .opening: "opening…"
        case .open: presentedEmpty ? "OPEN (empty!)" : "OPEN"
        case .closing: "closing…"
        }
    }

    func bind(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) {
        openAction = open
        dismissAction = dismiss
    }

    // MARK: Requests

    func open(reason: String) {
        switch phase {
        case .open, .opening:
            log("open (\(reason)) ignored — already \(phase)")
        case .closing:
            log("open (\(reason)) deferred — closing")
            pendingOpen = true
        case .closed:
            guard SaberXRHolder.shared.xr == nil else {
                log("open (\(reason)) deferred — engine teardown still running")
                pendingOpen = true
                return
            }
            guard let openAction else {
                log("open (\(reason)) dropped — presenter not bound yet")
                return
            }
            phase = .opening
            pendingOpen = false
            log("opening (\(reason))")
            Task { [weak self] in
                let result = await openAction(id: "Saber")
                SaberXRHolder.shared.lastOpenResult = String(describing: result)
                self?.openDidFinish(result)
            }
        }
    }

    func dismiss(reason: String) {
        switch phase {
        case .closed:
            log("dismiss (\(reason)) ignored — already closed")
            pendingOpen = false
        case .closing:
            log("dismiss (\(reason)) ignored — already closing")
            pendingOpen = false
        case .opening:
            log("dismiss (\(reason)) deferred — opening")
            pendingDismiss = true
        case .open:
            guard let dismissAction else { return }
            phase = .closing
            pendingDismiss = false
            log("dismissing (\(reason))")
            Task { await dismissAction() }
        }
    }

    /// A SharePlay duel wants the group immersive space. A closed arena
    /// simply opens; an open one must be cycled, because a space presented
    /// before the session joined stays private.
    func joinGroup(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastJoinCycleUptime < 3 {
            log("joinGroup (\(reason)) ignored — cycled \(String(format: "%.1f", now - lastJoinCycleUptime)) s ago")
            return
        }
        lastJoinCycleUptime = now
        switch phase {
        case .closed:
            open(reason: reason)
        case .opening:
            // Just requested, before the join: it will come up private.
            log("joinGroup (\(reason)) — open in flight, cycling once it is up")
            pendingDismiss = true
            pendingOpen = true
        case .open:
            log("joinGroup (\(reason)) — cycling the open arena to make it shared")
            pendingOpen = true
            dismiss(reason: reason)
        case .closing:
            pendingOpen = true
        }
    }

    // MARK: Lifecycle reports

    private func openDidFinish(_ result: OpenImmersiveSpaceAction.Result) {
        log("openImmersiveSpace → \(String(describing: result))")
        switch result {
        case .opened:
            if phase == .opening { phase = .open }
            if pendingDismiss {
                pendingDismiss = false
                dismiss(reason: "deferred dismiss")
            }
        case .userCancelled, .error:
            phase = .closed
            pendingDismiss = false
            if pendingOpen {
                // One retry, e.g. the failed request raced a closing space.
                pendingOpen = false
                log("retrying open after \(String(describing: result))")
                open(reason: "retry")
            }
        @unknown default:
            phase = .closed
        }
    }

    /// From the CompositorLayer closure: the space is presented.
    func arenaDidStart(rendering: Bool) {
        presentedEmpty = !rendering
        if phase != .open {
            log("arena started (rendering: \(rendering)) while \(phase)")
            phase = .open
        }
        if pendingDismiss || !rendering {
            pendingDismiss = false
            if !rendering { pendingOpen = true }
            dismiss(reason: rendering ? "deferred dismiss" : "recover empty space")
        }
    }

    /// From the engine's shutdown completion: safe to open again.
    func arenaDidTearDown() {
        log("arena torn down (was \(phase), pendingOpen: \(pendingOpen))")
        phase = .closed
        presentedEmpty = false
        if pendingOpen {
            pendingOpen = false
            open(reason: "reopen after teardown")
        }
    }

    private func log(_ message: String) {
        print("CoolSaber[arena]: \(message)")
    }
}
