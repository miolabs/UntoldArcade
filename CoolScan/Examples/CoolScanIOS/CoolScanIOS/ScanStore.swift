import CoolScanPipeline
import Foundation
import simd

/// Metadata persisted next to every cooked scan (meta.json). Shared with the
/// Mac server so both sides write the same file.
typealias ScanMetadata = ScanBundleMetadata

struct ScanRecord: Identifiable, Sendable {
    let id: String
    let folder: URL
    let metadata: ScanMetadata

    var untoldURL: URL {
        folder.appendingPathComponent(metadata.untoldFilename)
    }

    var sourceURL: URL {
        folder.appendingPathComponent("source.usdz")
    }

    var boundsMin: SIMD3<Float> {
        SIMD3<Float>(metadata.boundsMin[0], metadata.boundsMin[1], metadata.boundsMin[2])
    }

    var boundsMax: SIMD3<Float> {
        SIMD3<Float>(metadata.boundsMax[0], metadata.boundsMax[1], metadata.boundsMax[2])
    }
}

/// Owns Documents/Scans: listing, cooking imports, and deletion.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []
    @Published private(set) var isCooking = false
    @Published var lastError: String?

    /// Jobs running on a Mac whose result has not been installed yet.
    @Published private(set) var pendingJobs: [RemoteReconstruction.PendingJob] = []
    @Published private(set) var pendingStatus: [String: String] = [:]
    private var resuming: Set<String> = []

    static let shared = ScanStore()

    private var scansDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("Scans", isDirectory: true)
    }

    private init() {
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(
            at: scansDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        scans = folders.compactMap { folder in
            guard let metadata = try? ScanBundle.readMetadata(from: folder) else {
                return nil
            }
            return ScanRecord(
                id: folder.lastPathComponent,
                folder: folder,
                metadata: metadata
            )
        }
        .sorted { $0.metadata.createdAt > $1.metadata.createdAt }

        for scan in scans {
            print("CoolScan: library — \(scan.metadata.name): source \(canRecook(scan) ? "kept" : "MISSING") at \(scan.folder.path)")
        }
        pendingJobs = RemoteReconstruction.pendingJobs()
    }

    // MARK: - Mac jobs

    /// Picks up jobs the app was killed in the middle of: polls each one and
    /// installs the result when the Mac is done.
    func resumePendingJobs() async {
        pendingJobs = RemoteReconstruction.pendingJobs()
        for pending in pendingJobs where !resuming.contains(pending.jobID) {
            guard let baseURL = URL(string: pending.baseURL) else { continue }
            resuming.insert(pending.jobID)
            let client = ServerClient(baseURL: baseURL)
            Task { [weak self] in
                do {
                    _ = try await RemoteReconstruction.collect(
                        jobID: pending.jobID, client: client, scanID: pending.scanID,
                        progress: { [weak self] phase in
                            self?.pendingStatus[pending.jobID] = Self.describe(phase)
                        }
                    )
                    self?.pendingStatus[pending.jobID] = nil
                    self?.reload()
                } catch {
                    self?.pendingStatus[pending.jobID] = "Failed: \(error.localizedDescription)"
                    self?.reload()
                }
                self?.resuming.remove(pending.jobID)
            }
        }
    }

    func discardPending(_ pending: RemoteReconstruction.PendingJob) {
        if let baseURL = URL(string: pending.baseURL) {
            Task { try? await ServerClient(baseURL: baseURL).delete(jobID: pending.jobID) }
        }
        RemoteReconstruction.removePending(jobID: pending.jobID)
        pendingStatus[pending.jobID] = nil
        reload()
    }

    /// Sends a scan's kept source USDZ to the Mac to be cooked through the
    /// server pipeline (texture cap, cleanup) — no photogrammetry involved.
    func recookOnMac(_ scan: ScanRecord, client: ServerClient) async -> ScanRecord? {
        guard canRecook(scan) else {
            lastError = "This scan has no source model to re-cook."
            return nil
        }
        let scanID = UUID().uuidString
        let name = scan.metadata.name + " (Mac)"
        do {
            let jobID = try await RemoteReconstruction.submit(
                name: name, files: [("source.usdz", scan.sourceURL)],
                options: ServerSettings.options, client: client, scanID: scanID,
                progress: { [weak self] phase in self?.pendingStatus[scanID] = Self.describe(phase) }
            )
            pendingJobs = RemoteReconstruction.pendingJobs()
            _ = try await RemoteReconstruction.collect(
                jobID: jobID, client: client, scanID: scanID,
                progress: { [weak self] phase in self?.pendingStatus[jobID] = Self.describe(phase) }
            )
            pendingStatus[jobID] = nil
            reload()
            return scans.first { $0.id == scanID }
        } catch {
            lastError = "Mac re-cook failed: \(error.localizedDescription)"
            reload()
            return nil
        }
    }

    private static func describe(_ phase: RemoteReconstruction.Phase) -> String {
        switch phase {
        case .connecting: "Connecting…"
        case let .uploading(sent, total, _): "Uploading \(sent)/\(total)"
        case let .remote(stage, progress, _): "\(stage) \(Int(progress * 100))%"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        }
    }

    func delete(_ scan: ScanRecord) {
        try? FileManager.default.removeItem(at: scan.folder)
        reload()
    }

    /// Scans cooked since the source USDZ started being kept can be rebuilt
    /// through the current pipeline (cleanup, texture handling) without
    /// rescanning. Produces a new entry; the original stays for comparison.
    func canRecook(_ scan: ScanRecord) -> Bool {
        FileManager.default.fileExists(atPath: scan.sourceURL.path)
    }

    @discardableResult
    func recook(_ scan: ScanRecord) async -> ScanRecord? {
        guard canRecook(scan) else {
            lastError = "This scan has no source model to re-cook (scanned before sources were kept)."
            return nil
        }
        return await importUSDZ(at: scan.sourceURL, name: scan.metadata.name + " (re-cooked)")
    }

    /// Cooks a USDZ (bundled sample or a fresh Object Capture result) into a
    /// new scan folder. Runs the cooker off the main thread. Returns the new
    /// record, or nil on failure (see `lastError`).
    @discardableResult
    func importUSDZ(at usdzURL: URL, name: String) async -> ScanRecord? {
        guard !isCooking else {
            lastError = "Another import is still running"
            return nil
        }
        isCooking = true
        lastError = nil
        defer { isCooking = false }

        let scanID = UUID().uuidString
        let folder = scansDirectory.appendingPathComponent(scanID, isDirectory: true)
        let started = Date()

        do {
            let cooked = try await Task.detached(priority: .userInitiated) {
                try ScanCooker().cook(
                    usdzURL: usdzURL,
                    outputDirectory: folder,
                    assetName: "scan"
                )
            }.value

            let metadata = ScanBundleMetadata(
                name: name, cooked: cooked, origin: "phone", detail: "reduced"
            )
            try ScanBundle.writeMetadata(metadata, to: folder)
            // Keep the source next to the cooked asset so the scan can be
            // re-cooked after pipeline improvements without rescanning.
            do {
                try FileManager.default.copyItem(
                    at: usdzURL, to: folder.appendingPathComponent("source.usdz")
                )
            } catch {
                print("CoolScan: could not keep source USDZ for \(name) — \(error)")
            }
            reload()
            print(
                "CoolScan: cooked \(name) — \(cooked.vertexCount) vertices, "
                    + "\(cooked.triangleCount) triangles, \(cooked.textureURLs.count) textures "
                    + "in \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            )
            return scans.first { $0.id == scanID }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "\(error)"
            print("CoolScan: cook failed — \(error)")
            return nil
        }
    }

    /// Cooks the bundled sample model so the app works with zero scans (and
    /// on the simulator, where Object Capture is unavailable).
    func importBundledSample() async {
        guard let url = Bundle.main.url(forResource: "ball", withExtension: "usdz") else {
            lastError = "Sample model missing from the app bundle"
            return
        }
        await importUSDZ(at: url, name: "Sample Ball")
    }
}
