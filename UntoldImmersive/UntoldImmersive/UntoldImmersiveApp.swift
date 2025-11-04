//
//  UntoldImmersiveApp.swift
//  UntoldImmersive
//
//  Created by Harold Serrano on 10/14/25.
//

import SwiftUI
import CompositorServices
import UntoldEngineXR


// Simple owner so the XR system doesn't deallocate.
final class XRHolder {
    static let shared = XRHolder()
    var xr: CompositorXRSystem?
    var renderThread: Thread?
}

struct UntoldEngineConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct UntoldImmersiveApp: App {

    @State private var selectedImmersionMode: UntoldImmersionMode = .full
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup {
            LauncherView(
                selectedMode: $selectedImmersionMode,
                immersionStyle: $immersionStyle
            )
        }
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 400)

        ImmersiveSpace(id: "ImmersiveSpace") {
            
            CompositorLayer(configuration: UntoldEngineConfiguration(), renderer: { layerRenderer in
                // init + retain XR system
                if XRHolder.shared.xr == nil,
                   let xr = CompositorXRSystem(layerRenderer: layerRenderer) {
                    XRHolder.shared.xr = xr

                    // Set engine's immersion mode
                    xr.setImmersionMode(xrImmersionMode: selectedImmersionMode)
                    
                    // load assets
                    loadAssets()
                    
                    let t = Thread {
                        Task { @MainActor in xr.start() }      // sets isRunning = true
                        Task { @MainActor in xr.runLoop() }    // stays off-main on this thread
                    }
                    t.name = "XR Render Thread"
                    t.qualityOfService = .userInteractive
                    XRHolder.shared.renderThread = t
                    t.start()
                }
            })
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }
}

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Binding var selectedMode: UntoldImmersionMode
    @Binding var immersionStyle: ImmersionStyle

    var body: some View {
        VStack(spacing: 30) {
            Text("Untold Engine XR")
                .font(.extraLargeTitle)
                .fontWeight(.bold)

            Text("Select Immersion Mode")
                .font(.title)
                .foregroundColor(.secondary)

            VStack(spacing: 20) {
                Button(action: {
                    Task {
                        selectedMode = .full
                        immersionStyle = .full
                        await openImmersiveSpace(id: "ImmersiveSpace")
                    }
                }) {
                    Label("Full Immersion", systemImage: "visionpro.fill")
                        .frame(minWidth: 250)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    Task {
                        selectedMode = .mixed
                        immersionStyle = .mixed
                        await openImmersiveSpace(id: "ImmersiveSpace")
                    }
                }) {
                    Label("Mixed Mode", systemImage: "square.stack.3d.up")
                        .frame(minWidth: 250)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(60)
    }
}
