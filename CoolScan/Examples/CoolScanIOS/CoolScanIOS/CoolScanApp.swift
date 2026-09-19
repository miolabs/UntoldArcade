import CoolScan
import SwiftUI
import UntoldEngine

@main
struct CoolScanApp: App {
    init() {
        // Must run before the first renderer is created.
        let result = registerCoolScanPlugin()
        switch result {
        case .installed, .replaced:
            break
        case let .rejected(failure):
            print("CoolScan plugin rejected: \(failure)")
        @unknown default:
            break
        }
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScanLibraryView()
        }
    }
}

/// One renderer for the whole app. The engine's ECS/render state is global,
/// so creating a renderer per screen would re-initialize it.
@MainActor
enum SharedRenderer {
    private static var created: UntoldRenderer?
    private static var attempted = false

    /// Creates the renderer on first use.
    static var renderer: UntoldRenderer? {
        if !attempted {
            attempted = true
            created = UntoldRenderer.create()
        }
        return created
    }

    /// The renderer only if a screen already created it — never forces
    /// creation (the scan flow must not spin up the engine just to pause it).
    static var existing: UntoldRenderer? { created }

    /// Stops the engine's MTKView draw loop. Object Capture owns the camera
    /// and the GPU while scanning; a second Metal render loop running behind
    /// it (off-screen after leaving the viewer) only competes for both.
    static func pauseRendering() {
        existing?.metalView.isPaused = true
    }

    static func resumeRendering() {
        existing?.metalView.isPaused = false
    }
}
