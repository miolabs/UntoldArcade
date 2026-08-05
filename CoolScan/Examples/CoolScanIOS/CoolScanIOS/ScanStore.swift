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
    }

    func delete(_ scan: ScanRecord) {
        try? FileManager.default.removeItem(at: scan.folder)
        reload()
    }

    /// Cooks a USDZ (bundled sample or a fresh Object Capture result) into a
    /// new scan folder. Runs the cooker off the main thread.
    func importUSDZ(at usdzURL: URL, name: String) async {
        guard !isCooking else { return }
        isCooking = true
        lastError = nil
        defer { isCooking = false }

        let folder = scansDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

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
            reload()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "\(error)"
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
