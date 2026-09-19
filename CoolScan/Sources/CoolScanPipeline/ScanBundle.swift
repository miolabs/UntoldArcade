import Foundation

/// Metadata stored as `meta.json` next to every cooked scan. Shared by the
/// iPhone app and the Mac server so both write exactly what `ScanStore`
/// reads. Field names and the default `JSONEncoder` date encoding are part
/// of the on-disk contract; new fields must stay optional.
public struct ScanBundleMetadata: Codable, Sendable, Equatable {
    public var name: String
    public var createdAt: Date
    public var untoldFilename: String
    public var vertexCount: Int
    public var triangleCount: Int
    public var boundsMin: [Float]
    public var boundsMax: [Float]

    // Added with the Mac server; optional for scans cooked before.
    public var schemaVersion: Int?
    /// "phone" or "mac".
    public var origin: String?
    /// Reconstruction detail used ("reduced", "full", …).
    public var detail: String?
    /// Longest texture edge in the bundle, for the viewer's streaming profile.
    public var textureMax: Int?
    public var serverJobID: String?
    public var serverBaseURL: String?

    public static let currentSchemaVersion = 2

    public init(
        name: String,
        createdAt: Date = Date(),
        untoldFilename: String,
        vertexCount: Int,
        triangleCount: Int,
        boundsMin: [Float],
        boundsMax: [Float],
        origin: String? = nil,
        detail: String? = nil,
        textureMax: Int? = nil,
        serverJobID: String? = nil,
        serverBaseURL: String? = nil
    ) {
        self.name = name
        self.createdAt = createdAt
        self.untoldFilename = untoldFilename
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        schemaVersion = Self.currentSchemaVersion
        self.origin = origin
        self.detail = detail
        self.textureMax = textureMax
        self.serverJobID = serverJobID
        self.serverBaseURL = serverBaseURL
    }

    /// Builds metadata from a cook result.
    public init(
        name: String,
        cooked: CookedScan,
        origin: String,
        detail: String?,
        serverJobID: String? = nil,
        serverBaseURL: String? = nil
    ) {
        self.init(
            name: name,
            untoldFilename: cooked.untoldURL.lastPathComponent,
            vertexCount: cooked.vertexCount,
            triangleCount: cooked.triangleCount,
            boundsMin: [cooked.worldBoundsMin.x, cooked.worldBoundsMin.y, cooked.worldBoundsMin.z],
            boundsMax: [cooked.worldBoundsMax.x, cooked.worldBoundsMax.y, cooked.worldBoundsMax.z],
            origin: origin,
            detail: detail,
            textureMax: cooked.textureMax,
            serverJobID: serverJobID,
            serverBaseURL: serverBaseURL
        )
    }
}

/// Layout of a cooked scan folder and helpers to read/write/install one.
public enum ScanBundle {
    public static let metadataFilename = "meta.json"
    public static let modelFilename = "scan.untold"

    public enum BundleError: Error, CustomStringConvertible {
        case missingModel
        case missingMetadata

        public var description: String {
            switch self {
            case .missingModel: "Bundle has no \(ScanBundle.modelFilename)"
            case .missingMetadata: "Bundle has no \(ScanBundle.metadataFilename)"
            }
        }
    }

    public static func writeMetadata(_ metadata: ScanBundleMetadata, to folder: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: folder.appendingPathComponent(metadataFilename), options: .atomic)
    }

    public static func readMetadata(from folder: URL) throws -> ScanBundleMetadata {
        let data = try Data(contentsOf: folder.appendingPathComponent(metadataFilename))
        return try JSONDecoder().decode(ScanBundleMetadata.self, from: data)
    }

    /// Validates that a folder is a complete bundle.
    public static func validate(_ folder: URL) throws -> ScanBundleMetadata {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(metadataFilename).path) else {
            throw BundleError.missingMetadata
        }
        let metadata = try readMetadata(from: folder)
        guard fm.fileExists(atPath: folder.appendingPathComponent(metadata.untoldFilename).path) else {
            throw BundleError.missingModel
        }
        return metadata
    }

    /// Unpacks a result archive into `destination` atomically: extraction
    /// happens in a sibling temp folder and is moved into place only after
    /// validation, so a library scan never sees a half-written bundle.
    @discardableResult
    public static func install(zip: URL, into destination: URL) throws -> ScanBundleMetadata {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try ZipArchive.extract(zip, into: staging)
        let metadata = try validate(staging)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
        return metadata
    }

    /// Zips a bundle folder (flat: model, textures, metadata) for transfer.
    public static func archive(folder: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try ZipArchive.write(files.map { ZipArchive.Source(name: $0.lastPathComponent, url: $0) }, to: zipURL)
    }
}
