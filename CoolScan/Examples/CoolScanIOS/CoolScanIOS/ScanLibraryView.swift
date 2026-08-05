import RealityKit
import SwiftUI

struct ScanLibraryView: View {
    @StateObject private var store = ScanStore.shared
    @State private var path: [String] = []
    @State private var showingScanFlow = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    scanList
                }
            }
            .navigationTitle("CoolScan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    scanButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    importSampleButton
                }
            }
            .navigationDestination(isPresented: $showingScanFlow) {
                ScanFlowView()
            }
            .overlay {
                if store.isCooking {
                    cookingOverlay
                }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { store.lastError != nil },
                    set: { if !$0 { store.lastError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
            .task {
                await runAutoDemoIfRequested()
            }
        }
    }

    /// Launch-argument hook (-CoolScanAutoDemo) used by automated UI checks:
    /// imports the bundled sample if needed and opens it in the viewer.
    private func runAutoDemoIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CoolScanAutoDemo") else {
            return
        }
        if store.scans.isEmpty {
            await store.importBundledSample()
        }
        if let first = store.scans.first {
            path = [first.id]
        }
    }

    private var scanList: some View {
        List {
            ForEach(store.scans) { scan in
                NavigationLink(value: scan.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scan.metadata.name)
                            .font(.headline)
                        Text(
                            "\(scan.metadata.triangleCount) triangles · "
                                + scan.metadata.createdAt.formatted(
                                    date: .abbreviated, time: .shortened
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    store.delete(store.scans[index])
                }
            }
        }
        .navigationDestination(for: String.self) { scanID in
            if let scan = store.scans.first(where: { $0.id == scanID }) {
                ViewerView(scan: scan)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "cube.transparent")
        } description: {
            Text("Import the sample model to try the viewer, or scan a real object.")
        } actions: {
            scanButton
            importSampleButton
        }
    }

    /// Object Capture needs LiDAR; on unsupported devices (and the
    /// simulator) the sample import remains the way in.
    private var scanButton: some View {
        Button {
            showingScanFlow = true
        } label: {
            Label("Scan Object", systemImage: "camera.viewfinder")
        }
        .disabled(!ObjectCaptureSession.isSupported || store.isCooking)
    }

    private var importSampleButton: some View {
        Button {
            Task { await store.importBundledSample() }
        } label: {
            Label("Import Sample", systemImage: "square.and.arrow.down")
        }
        .disabled(store.isCooking)
    }

    private var cookingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Cooking model…")
                .font(.callout)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
