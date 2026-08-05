import Foundation

/// Errors thrown while converting a scanned USDZ into a `.untold` asset.
public enum CoolScanCookerError: Error, CustomStringConvertible {
    case assetHasNoMeshes(URL)
    case missingVertexAttribute(String)
    case textureExportFailed(String)
    case validationFailed(underlying: Error)

    public var description: String {
        switch self {
        case let .assetHasNoMeshes(url):
            return "No meshes found in \(url.lastPathComponent)"
        case let .missingVertexAttribute(name):
            return "Mesh is missing required vertex attribute: \(name)"
        case let .textureExportFailed(name):
            return "Failed to export texture: \(name)"
        case let .validationFailed(underlying):
            return "Cooked file failed validation: \(underlying)"
        }
    }
}

/// Converts a textured USDZ (Object Capture output) into the engine's native
/// `.untold` container plus PNG texture siblings, entirely on device.
///
/// Implemented in Phase 2 of the CoolScan plan.
public struct ScanCooker {
    public init() {}
}
