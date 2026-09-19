import CoolScanPipeline
import Foundation

/// Cooks a job's USDZ into a phone-ready bundle and zips it.
enum ResultBundler {
    static func bundle(
        usdz: URL,
        into jobDirectory: URL,
        job: ReconstructionJob,
        serverBaseURL: String?
    ) throws -> URL {
        let cooked = jobDirectory.appendingPathComponent("cooked", isDirectory: true)
        if FileManager.default.fileExists(atPath: cooked.path) {
            try FileManager.default.removeItem(at: cooked)
        }
        let result = try ScanCooker().cook(
            usdzURL: usdz,
            outputDirectory: cooked,
            assetName: "scan",
            options: job.options.cookOptions
        )
        let metadata = ScanBundleMetadata(
            name: job.name,
            cooked: result,
            origin: "mac",
            detail: job.kind == .cookOnly ? "recook" : job.options.detail.rawValue,
            serverJobID: job.id,
            serverBaseURL: serverBaseURL
        )
        try ScanBundle.writeMetadata(metadata, to: cooked)

        let zip = jobDirectory.appendingPathComponent("result.zip")
        if FileManager.default.fileExists(atPath: zip.path) {
            try FileManager.default.removeItem(at: zip)
        }
        try ScanBundle.archive(folder: cooked, to: zip)
        return zip
    }
}
