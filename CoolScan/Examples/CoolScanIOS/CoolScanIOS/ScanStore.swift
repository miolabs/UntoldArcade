import CoolScanPipeline
import Foundation
import simd

/// Metadata persisted next to every cooked scan (meta.json).
struct ScanMetadata: Codable, Sendable {
    var name: String
    var createdAt: Date
    var untoldFilename: String
    var vertexCount: Int
    var triangleCount: Int
    var boundsMin: [Float]
    var boundsMax: [Float]
}

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
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let metadata = try? JSONDecoder().decode(ScanMetadata.self, from: data)
            else {
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

            let metadata = ScanMetadata(
                name: name,
                createdAt: Date(),
                untoldFilename: cooked.untoldURL.lastPathComponent,
                vertexCount: cooked.vertexCount,
                triangleCount: cooked.triangleCount,
                boundsMin: [cooked.worldBoundsMin.x, cooked.worldBoundsMin.y, cooked.worldBoundsMin.z],
                boundsMax: [cooked.worldBoundsMax.x, cooked.worldBoundsMax.y, cooked.worldBoundsMax.z]
            )
            let metaData = try JSONEncoder().encode(metadata)
            try metaData.write(to: folder.appendingPathComponent("meta.json"))
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
