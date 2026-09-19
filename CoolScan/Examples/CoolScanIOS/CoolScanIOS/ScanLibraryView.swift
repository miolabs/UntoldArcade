import RealityKit
import SwiftUI

struct ScanLibraryView: View {
    @StateObject private var store = ScanStore.shared
    @StateObject private var discovery = ServerDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [String] = []
    @State private var showingSettings = false

    /// Sentinel route for the scan flow, so finishing a scan can atomically
    /// replace it with the viewer for the new model.
    private static let scanRoute = "__scan__"

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty, store.pendingJobs.isEmpty {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Mac server", systemImage: discovery.servers.isEmpty && ServerSettings.manualBaseURL == nil
                              ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    scanButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    importSampleButton
                }
            }
            .sheet(isPresented: $showingSettings) {
                ServerSettingsView(discovery: discovery)
            }
            .onAppear { discovery.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.resumePendingJobs() }
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
                await store.resumePendingJobs()
                await runAutoDemoIfRequested()
            }
        }
    }

    /// Launch hooks used by automated UI checks (the simulator cannot be
    /// driven by touch from the build machine):
    /// - `-CoolScanAutoDemo`: import the bundled sample if needed, open it.
    /// - `COOLSCAN_SERVER=http://host:port`: pin that server address.
    /// - `-CoolScanAutoRecookOnMac`: send the first scan's source to the
    ///   pinned server and open the result — the full Mac loop.
    private func runAutoDemoIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let server = ProcessInfo.processInfo.environment["COOLSCAN_SERVER"], let url = URL(string: server) {
            ServerSettings.manualBaseURL = url
        }
        let wantsMacRecook = arguments.contains("-CoolScanAutoRecookOnMac")
        guard arguments.contains("-CoolScanAutoDemo") || wantsMacRecook else { return }

        if store.scans.isEmpty {
            await store.importBundledSample()
        }
        guard let first = store.scans.first else { return }
        if wantsMacRecook {
            await recookOnMac(first)
        } else {
            path = [first.id]
        }
    }

    private var scanList: some View {
        List {
            if !store.pendingJobs.isEmpty {
                Section("On the Mac") {
                    ForEach(store.pendingJobs, id: \.jobID) { pending in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.name)
                                .font(.headline)
                            Text(store.pendingStatus[pending.jobID] ?? "Waiting for the Mac…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.discardPending(pending)
                            } label: {
                                Label("Discard", systemImage: "trash")
                            }
                        }
                    }
                }
            }
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
                    if store.canRecook(scan) {
                        Button {
                            Task { await recookOnMac(scan) }
                        } label: {
                            Label("Re-cook on Mac", systemImage: "desktopcomputer.and.arrow.down")
                        }
                    }
                    Button(role: .destructive) {
                        store.delete(scan)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Ships the scan's source USDZ to the Mac server and opens the result.
    private func recookOnMac(_ scan: ScanRecord) async {
        guard let client = await ServerSettingsView.currentClient(discovery: discovery) else {
            store.lastError = "No Mac server found. Start CoolScanServer on your Mac or set its address in the server settings."
            return
        }
        if let cooked = await store.recookOnMac(scan, client: client) {
            path = [cooked.id]
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
