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
    var skinningPath: CoolMirrorSkinningPath = .vertexShader {
        didSet { XRHolder.shared.game?.setSkinningPath(skinningPath) }
    }
    var clip: CoolMirrorClip = .idle {
        didSet { XRHolder.shared.game?.setClip(clip) }
    }
    var bellyWeight: Double = 0 {
        didSet { XRHolder.shared.game?.setMorphWeight(name: "belly", weight: Float(bellyWeight)) }
    }
    var bigheadWeight: Double = 0 {
        didSet { XRHolder.shared.game?.setMorphWeight(name: "bighead", weight: Float(bigheadWeight)) }
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
                        Text("Skinning")
                        Picker("Skinning", selection: $controls.skinningPath) {
                            Text("Vertex").tag(CoolMirrorSkinningPath.vertexShader)
                            Text("LBS").tag(CoolMirrorSkinningPath.computeLBS)
                            Text("DQS").tag(CoolMirrorSkinningPath.computeDQS)
                            Text("DDM").tag(CoolMirrorSkinningPath.computeDDM)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("Clip")
                        Picker("Clip", selection: $controls.clip) {
                            Text("Idle").tag(CoolMirrorClip.idle)
                            Text("Running").tag(CoolMirrorClip.running)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("Belly")
                        Slider(value: $controls.bellyWeight, in: 0 ... 1)
                            .disabled(controls.skinningPath == .vertexShader)
                    }
                    GridRow {
                        Text("Big head")
                        Slider(value: $controls.bigheadWeight, in: 0 ... 1)
                            .disabled(controls.skinningPath == .vertexShader)
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
        .defaultSize(width: 640, height: 420)

        ImmersiveSpace(id: "Mirror") {
            CompositorLayer(configuration: MirrorLayerConfiguration()) { layerRenderer in
                guard XRHolder.shared.xr == nil else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                XRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up directly
                // here (matches the engine's XR template). The blocking render loop runs
                // on its own plain Thread — NOT the main actor.
                let game = CoolMirrorGame()
                XRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let t = Thread {
                    xr.start()
                    xr.runLoop()
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
