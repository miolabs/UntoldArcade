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
    static let renderer: UntoldRenderer? = UntoldRenderer.create()
}
