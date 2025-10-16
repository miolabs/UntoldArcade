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
    var body: some Scene {
        WindowGroup { LauncherView().hidden() }

        ImmersiveSpace(id: "ImmersiveSpace") {
            
            CompositorLayer(configuration: UntoldEngineConfiguration(), renderer: { layerRenderer in
                // init + retain XR system
                if XRHolder.shared.xr == nil,
                   let xr = CompositorXRSystem(layerRenderer: layerRenderer) {
                    XRHolder.shared.xr = xr
                    
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
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    var body: some View {
        Color.clear.task {
            _ = await openImmersiveSpace(id: "ImmersiveSpace") // IDs match
        }
    }
}
