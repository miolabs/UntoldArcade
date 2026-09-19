import CoolScanPipeline
import Foundation

/// What the phone asks the Mac to do with a capture. Every field has a
/// default so a bare `{}` is a valid request.
public struct ReconstructionOptions: Codable, Sendable, Equatable {
    public enum Detail: String, Codable, Sendable, CaseIterable {
        case medium
        case full
        case custom
    }

    public var detail: Detail = .full
    /// `.custom` only: polygon budget.
    public var maxPolygons: Int = 250_000
    /// `.custom` only: texture edge produced by photogrammetry.
    public var textureSize: Int = 2048
    /// Longest texture edge in the cooked bundle sent to the phone.
    public var cookTextureCap: Int = 2048
    public var cleanup = Cleanup()

    public struct Cleanup: Codable, Sendable, Equatable {
        public var islandMinimumFraction: Float = 0.001
        public var smoothingIterations: Int = 4
        public var recomputeNormals: Bool = true

        public init() {}

        // Every field optional on the wire.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            islandMinimumFraction = try container.decodeIfPresent(Float.self, forKey: .islandMinimumFraction) ?? 0.001
            smoothingIterations = try container.decodeIfPresent(Int.self, forKey: .smoothingIterations) ?? 4
            recomputeNormals = try container.decodeIfPresent(Bool.self, forKey: .recomputeNormals) ?? true
        }

        public var meshCleanupOptions: MeshCleanupOptions {
            var options = MeshCleanupOptions()
            options.islandMinimumFraction = islandMinimumFraction
            options.smoothingIterations = smoothingIterations
            options.recomputeNormals = recomputeNormals
            return options
        }
    }

    public init() {}

    public var cookOptions: CookOptions {
        CookOptions(cleanup: cleanup.meshCleanupOptions, maxTextureDimension: cookTextureCap)
    }

    // Every field optional on the wire.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detail = try container.decodeIfPresent(Detail.self, forKey: .detail) ?? .full
        maxPolygons = try container.decodeIfPresent(Int.self, forKey: .maxPolygons) ?? 250_000
        textureSize = try container.decodeIfPresent(Int.self, forKey: .textureSize) ?? 2048
        cookTextureCap = try container.decodeIfPresent(Int.self, forKey: .cookTextureCap) ?? 2048
        cleanup = try container.decodeIfPresent(Cleanup.self, forKey: .cleanup) ?? Cleanup()
    }
}
