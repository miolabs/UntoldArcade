import RealityKit
import SwiftUI

struct ScanLibraryView: View {
    @StateObject private var store = ScanStore.shared
    @State private var path: [String] = []

    /// Sentinel route for the scan flow, so finishing a scan can atomically
    /// replace it with the viewer for the new model.
    private static let scanRoute = "__scan__"

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
            // On the container, not the list: the empty state must be able
            // to push the scan flow too.
            .navigationDestination(for: String.self) { route in
                if route == Self.scanRoute {
                    ScanFlowView { newScanID in
                        // Pop the scan flow and open the freshly cooked model.
                        path = [newScanID]
                    }
                } else if let scan = store.scans.first(where: { $0.id == route }) {
                    ViewerView(scan: scan)
                } else {
                    ContentUnavailableView(
                        "Scan not found", systemImage: "questionmark.folder"
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    scanButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    importSampleButton
                }
            }
            .overlay {
                if store.isCooking {
                    cookingOverlay
                }
            }
            .alert(
                "Scan library",
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
                                + (store.canRecook(scan) ? " · source kept" : "")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        store.delete(scan)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    recookButton(for: scan)
                }
                .contextMenu {
                    recookButton(for: scan)
                    Button(role: .destructive) {
                        store.delete(scan)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Rebuilds a scan from its kept source through the current pipeline
    /// and opens the result (the original stays for comparison). Always
    /// offered; a scan without a kept source explains itself via the alert.
    private func recookButton(for scan: ScanRecord) -> some View {
        Button {
            Task {
                if let cooked = await store.recook(scan) {
                    path = [cooked.id]
                }
            }
        } label: {
            Label("Re-cook", systemImage: "arrow.clockwise")
        }
        .tint(.orange)
        .disabled(store.isCooking)
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
            path = [Self.scanRoute]
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
