//
//  CoolMirrorVisionOSXRApp.swift  (visionOS)
//  CoolMirror
//
//  Virtual-mirror demo host: a rigged character stands in front of the user
//  playing animation clips, with the engine's deformation stack switchable
//  live from the control window. Later phases add live iPhone mocap so the
//  character mirrors the user's own movements.
//

import CompositorServices
import CoolMirror
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated.
final class XRHolder {
    static let shared = XRHolder()
    var xr: UntoldEngineXR?
    var game: CoolMirrorGame?
    var renderThread: Thread?
}

struct MirrorLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities _: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration)
    {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

/// UI-facing knobs; every change is pushed straight into the demo game.
@Observable
@MainActor
final class MirrorControls {
    var character: CoolMirrorCharacter = .spiderman {
        didSet {
            morphNames = []
            morphWeights = [:]
            muscleNames = []
            muscleEnabled = [:]
            muscleActivation = [:]
            hasMLDeformer = false
            if muscleMode == .mlDeformer { muscleMode = .off }
            clips = []
            clip = ""
            XRHolder.shared.game?.setCharacter(character)
        }
    }
    var skinningPath: CoolMirrorSkinningPath = .vertexShader {
        didSet { XRHolder.shared.game?.setSkinningPath(skinningPath) }
    }
    var clip: String = "" {
        didSet {
            guard !clip.isEmpty else { return }
            XRHolder.shared.game?.setClip(clip)
        }
    }
    var paused = false {
        didSet { XRHolder.shared.game?.setPaused(paused) }
    }
    var poseDrivers = true {
        didSet { XRHolder.shared.game?.setPoseDrivers(enabled: poseDrivers) }
    }
    var muscleMode: CoolMirrorMuscleMode = .off {
        didSet { XRHolder.shared.game?.setMuscleMode(muscleMode) }
    }
    var hasMLDeformer = false
    var mlWeight: Double = 1 {
        didSet { XRHolder.shared.game?.setMLDeformerWeight(Float(mlWeight)) }
    }
    var flex: Double = 0 {
        didSet { XRHolder.shared.game?.setMuscleFlex(Float(flex)) }
    }
    var showCages = false {
        didSet { XRHolder.shared.game?.setMuscleCagesVisible(showCages) }
    }
    var showMuscleList = false

    // iPhone motion capture
    var mocapEnabled = false {
        didSet {
            XRHolder.shared.game?.setMocapEnabled(mocapEnabled)
            refreshMocapStatus()
        }
    }
    var mocapMirror = true { didSet { pushMocapOptions() } }
    var mocapFlipFacing = false { didSet { pushMocapOptions() } }
    var mocapRootMotion = true { didSet { pushMocapOptions() } }
    var mocapGroundLock = true { didSet { pushMocapOptions() } }
    var mocapWeight: Double = 1 { didSet { pushMocapOptions() } }
    var mocapBodySmoothing: Double = 0.4 { didSet { pushMocapOptions() } }
    var mocapLegSmoothing: Double = 0.6 { didSet { pushMocapOptions() } }
    var mocapDebugOverlay = false {
        didSet { XRHolder.shared.game?.setMocapDebugOverlay(mocapDebugOverlay) }
    }
    var mocapStatus = "off"
    var mocapCalibrated = false
    var calibrationCountdown: Int?

    func pushMocapOptions() {
        XRHolder.shared.game?.setMocapOptions(
            mirror: mocapMirror, flipFacing: mocapFlipFacing, weight: Float(mocapWeight), rootMotion: mocapRootMotion,
            bodySmoothing: Float(mocapBodySmoothing), legSmoothing: Float(mocapLegSmoothing), groundLock: mocapGroundLock
        )
    }

    func refreshMocapStatus() {
        guard let game = XRHolder.shared.game else { return }
        mocapStatus = game.mocapStatus()
        mocapCalibrated = game.mocapIsCalibrated()
    }

    /// Three-second countdown so the user can settle into the character's
    /// rest pose, then the next tracked frame becomes the calibration.
    func startCalibration() {
        guard calibrationCountdown == nil else { return }
        calibrationCountdown = 3
        Task { @MainActor in
            while let remaining = calibrationCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                calibrationCountdown = remaining - 1
            }
            XRHolder.shared.game?.calibrateMocap()
            calibrationCountdown = nil
            refreshMocapStatus()
        }
    }
    var muscleNames: [String] = []
    var muscleEnabled: [String: Bool] = [:]
    var muscleActivation: [String: Double] = [:]

    func setMuscleEnabled(_ name: String, _ enabled: Bool) {
        muscleEnabled[name] = enabled
        XRHolder.shared.game?.setMuscleEnabled(name: name, enabled: enabled)
    }

    func setMuscleActivation(_ name: String, _ value: Double) {
        muscleActivation[name] = value
        XRHolder.shared.game?.setMuscleActivation(name: name, value: Float(value))
    }
    var clips: [String] = []
    var morphNames: [String] = []
    var morphWeights: [String: Double] = [:]

    func setMorphWeight(_ name: String, _ weight: Double) {
        morphWeights[name] = weight
        XRHolder.shared.game?.setMorphWeight(name: name, weight: Float(weight))
    }

    func characterReady() {
        guard let game = XRHolder.shared.game else { return }
        pushMocapOptions()
        game.setMocapEnabled(mocapEnabled)
        game.setMocapDebugOverlay(mocapDebugOverlay)
        morphNames = game.morphTargetNames()
        muscleNames = game.muscleNames()
        hasMLDeformer = game.hasMLDeformer()
        clips = game.clipNames()
        clip = clips.first ?? ""
        paused = false
    }
}

@main
struct CoolMirrorVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var controls = MirrorControls()

    var body: some SwiftUI.Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Cool Mirror").font(.extraLargeTitle).fontWeight(.bold)
                Text("A character stands in front of you like a mirror.\nSwitch the skinning path live and compare.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                Button {
                    Task { await openImmersiveSpace(id: "Mirror") }
                } label: {
                    Label("Enter Mixed Reality", systemImage: "person.and.background.dotted").frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                #if targetEnvironment(simulator)
                // The simulator has no hands: enter the immersive space directly.
                .task { await openImmersiveSpace(id: "Mirror") }
                #endif

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Character")
                        Picker("Character", selection: $controls.character) {
                            Text("Spider-Man").tag(CoolMirrorCharacter.spiderman)
                            Text("Batman").tag(CoolMirrorCharacter.batman)
                            Text("Player").tag(CoolMirrorCharacter.redplayer)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("PSD morphs")
                        Toggle(controls.poseDrivers ? "Auto (pose drivers)" : "Manual sliders", isOn: $controls.poseDrivers)
                            .toggleStyle(.button)
                            .disabled(controls.skinningPath == .vertexShader)
                    }
                    GridRow {
                        Text("Muscles")
                        Picker("Muscles", selection: $controls.muscleMode) {
                            Text("Off").tag(CoolMirrorMuscleMode.off)
                            Text("XPBD sim").tag(CoolMirrorMuscleMode.simulation)
                            Text("ML deformer").tag(CoolMirrorMuscleMode.mlDeformer)
                                .selectionDisabled(!controls.hasMLDeformer)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(controls.skinningPath == .vertexShader || controls.character == .redplayer)
                    }
                    if controls.muscleMode == .mlDeformer {
                        GridRow {
                            Text("ML blend")
                            Slider(value: $controls.mlWeight, in: 0 ... 1)
                        }
                    }
                    if controls.muscleMode == .simulation {
                        GridRow {
                            Text("Flex all")
                            Slider(value: $controls.flex, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Cages")
                            HStack {
                                Toggle(controls.showCages ? "Wireframe shown" : "Hidden", isOn: $controls.showCages)
                                    .toggleStyle(.button)
                                Toggle(controls.showMuscleList ? "Hide muscle list" : "Per muscle…", isOn: $controls.showMuscleList)
                                    .toggleStyle(.button)
                            }
                        }
                    }
                    GridRow {
                        Text("Playback")
                        Toggle(controls.paused ? "Paused — compare skinning now" : "Playing", isOn: $controls.paused)
                            .toggleStyle(.button)
                            .disabled(controls.mocapEnabled)
                    }
                    GridRow {
                        Text("iPhone")
                        Toggle(controls.mocapEnabled ? "Mirroring your body" : "Use iPhone body tracking", isOn: $controls.mocapEnabled)
                            .toggleStyle(.button)
                    }
                    if controls.mocapEnabled {
                        GridRow {
                            Text("Calibrate")
                            HStack {
                                Button {
                                    controls.startCalibration()
                                } label: {
                                    if let remaining = controls.calibrationCountdown {
                                        Text("Hold the pose… \(remaining)")
                                    } else {
                                        Text(controls.mocapCalibrated ? "Recalibrate" : "Stand upright facing the phone, then tap")
                                    }
                                }
                                .disabled(controls.calibrationCountdown != nil)
                                Toggle("Mirror", isOn: $controls.mocapMirror).toggleStyle(.button)
                                Toggle("Flip", isOn: $controls.mocapFlipFacing).toggleStyle(.button)
                                Toggle("Move", isOn: $controls.mocapRootMotion).toggleStyle(.button)
                                Toggle("Ground", isOn: $controls.mocapGroundLock).toggleStyle(.button)
                            }
                        }
                        GridRow {
                            Text("Mocap blend")
                            Slider(value: $controls.mocapWeight, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Smooth body")
                            Slider(value: $controls.mocapBodySmoothing, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Smooth legs")
                            HStack {
                                Slider(value: $controls.mocapLegSmoothing, in: 0 ... 1)
                                Toggle("Skeleton", isOn: $controls.mocapDebugOverlay).toggleStyle(.button)
                            }
                        }
                    }
                    GridRow {
                        Text("Skinning")
                        Picker("Skinning", selection: $controls.skinningPath) {
                            Text("Vertex").tag(CoolMirrorSkinningPath.vertexShader)
                            Text("LBS").tag(CoolMirrorSkinningPath.computeLBS)
                            Text("DQS").tag(CoolMirrorSkinningPath.computeDQS)
                            Text("DDM").tag(CoolMirrorSkinningPath.computeDDM)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    if controls.clips.count > 1 {
                        GridRow {
                            Text("Clip")
                            Picker("Clip", selection: $controls.clip) {
                                ForEach(controls.clips, id: \.self) { name in
                                    Text(name.capitalized).tag(name)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    ForEach(controls.morphNames, id: \.self) { name in
                        GridRow {
                            Text(name)
                            Slider(
                                value: Binding(
                                    get: { controls.morphWeights[name] ?? 0 },
                                    set: { controls.setMorphWeight(name, $0) }
                                ),
                                in: 0 ... 1
                            )
                            .disabled(controls.skinningPath == .vertexShader)
                        }
                    }
                }

                if controls.muscleMode == .simulation, controls.showMuscleList {
                    // Placement tuning: isolate one muscle and drive it by hand.
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(controls.muscleNames, id: \.self) { name in
                                HStack(spacing: 12) {
                                    Toggle(name, isOn: Binding(
                                        get: { controls.muscleEnabled[name] ?? true },
                                        set: { controls.setMuscleEnabled(name, $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .frame(width: 220, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { controls.muscleActivation[name] ?? 0 },
                                            set: { controls.setMuscleActivation(name, $0) }
                                        ),
                                        in: 0 ... 1
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text("Slider = manual activation (0 = pose driver). Switch off a muscle to take it out of the skin.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if controls.mocapEnabled {
                    Text(controls.mocapStatus)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .task {
                            while !Task.isCancelled {
                                controls.refreshMocapStatus()
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                        }
                }

                if controls.skinningPath == .vertexShader {
                    Text("Morphs need a compute skinning path (LBS/DQS/DDM).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(48)
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 600)

        ImmersiveSpace(id: "Mirror") {
            CompositorLayer(configuration: MirrorLayerConfiguration()) { layerRenderer in
                guard XRHolder.shared.xr == nil else {
                    print("CoolMirror: immersive space reopened before teardown finished")
                    return
                }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                XRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up directly
                // here (matches the engine's XR template). The blocking render loop runs
                // on its own plain Thread — NOT the main actor.
                let game = CoolMirrorGame()
                XRHolder.shared.game = game
                game.onCharacterReady = { controls.characterReady() }
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let t = Thread {
                    xr.start()
                    xr.runLoop()
                    // The run loop returns when the space is dismissed. Tear the
                    // engine down on the main actor so nothing keeps submitting
                    // GPU work from the background, and allow a clean reopen.
                    Task { @MainActor in
                        XRHolder.shared.game?.prepareForShutdown()
                        shutdownUntoldEngineXR(xr) {
                            XRHolder.shared.xr = nil
                            XRHolder.shared.game = nil
                            XRHolder.shared.renderThread = nil
                            print("CoolMirror: immersive space torn down, ready to reopen")
                        }
                    }
                }
                t.name = "XR Render Thread"
                t.qualityOfService = .userInteractive
                XRHolder.shared.renderThread = t
                t.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
