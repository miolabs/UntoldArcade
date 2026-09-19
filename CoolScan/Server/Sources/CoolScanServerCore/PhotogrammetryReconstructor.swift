import Foundation
#if canImport(RealityKit) && os(macOS)
import RealityKit

/// Apple photogrammetry on the Mac at full detail, reusing the phone's
/// checkpoints (camera poses) when the capture shipped them.
public struct PhotogrammetryReconstructor: Reconstructor {
    public init() {}

    public var isSupported: Bool { PhotogrammetrySession.isSupported }

    public func reconstruct(
        images: URL,
        checkpoints: URL?,
        output: URL,
        options: ReconstructionOptions,
        progress: @escaping @Sendable (ReconstructionProgress) -> Void
    ) async throws {
        guard PhotogrammetrySession.isSupported else { throw ReconstructionError.unsupportedOnThisMac }
        let imageCount = (try? FileManager.default.contentsOfDirectory(atPath: images.path).count) ?? 0
        guard imageCount > 0 else { throw ReconstructionError.noImages }

        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = checkpoints
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = true

        let detail: PhotogrammetrySession.Request.Detail
        switch options.detail {
        case .medium:
            detail = .medium
        case .full:
            detail = .full
        case .custom:
            var spec = PhotogrammetrySession.Configuration.CustomDetailSpecification()
            spec.maximumPolygonCount = UInt(max(options.maxPolygons, 1_000))
            spec.maximumTextureDimension = Self.textureDimension(for: options.textureSize)
            spec.outputTextureMaps = [.diffuseColor, .normal, .roughness, .ambientOcclusion]
            spec.textureFormat = .png
            configuration.customDetailSpecification = spec
            detail = .custom
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let session = try PhotogrammetrySession(input: images, configuration: configuration)
        let box = SessionBox(session)
        try session.process(requests: [.modelFile(url: output, detail: detail)])

        try await withTaskCancellationHandler {
            for try await result in box.session.outputs {
                switch result {
                case let .requestProgress(_, fractionComplete):
                    progress(ReconstructionProgress(fraction: fractionComplete))
                case let .requestProgressInfo(_, info):
                    progress(ReconstructionProgress(
                        fraction: -1,
                        stage: Self.describe(info.processingStage),
                        etaSeconds: info.estimatedRemainingTime
                    ))
                case let .requestError(_, error):
                    throw ReconstructionError.failed("\(error)")
                case .requestComplete:
                    continue
                case .processingComplete:
                    return
                case .processingCancelled:
                    throw ReconstructionError.cancelled
                case let .invalidSample(id, reason):
                    progress(ReconstructionProgress(fraction: -1, warning: "Sample \(id) rejected: \(reason)"))
                case let .skippedSample(id):
                    progress(ReconstructionProgress(fraction: -1, warning: "Sample \(id) skipped"))
                case .automaticDownsampling:
                    progress(ReconstructionProgress(fraction: -1, warning: "Images were downsampled to fit memory"))
                case .stitchingIncomplete:
                    progress(ReconstructionProgress(fraction: -1, warning: "Some views could not be stitched; expect holes"))
                default:
                    continue
                }
            }
        } onCancel: {
            box.session.cancel()
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ReconstructionError.failed("Reconstruction finished without producing a model")
        }
    }

    private static func textureDimension(for size: Int)
        -> PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension
    {
        switch size {
        case ...1024: .oneK
        case ...2048: .twoK
        case ...4096: .fourK
        default: .eightK // 16K needs macOS 15 and is pointless for a phone target
        }
    }

    private static func describe(_ stage: PhotogrammetrySession.Output.ProcessingStage?) -> String? {
        guard let stage else { return nil }
        return String(describing: stage)
    }

    /// `PhotogrammetrySession` is not Sendable; it is only ever touched from
    /// the task that created it plus `cancel()` from the cancellation handler,
    /// which the API documents as safe.
    private final class SessionBox: @unchecked Sendable {
        let session: PhotogrammetrySession
        init(_ session: PhotogrammetrySession) { self.session = session }
    }
}
#else
public struct PhotogrammetryReconstructor: Reconstructor {
    public init() {}
    public var isSupported: Bool { false }
    public func reconstruct(
        images _: URL, checkpoints _: URL?, output _: URL, options _: ReconstructionOptions,
        progress _: @escaping @Sendable (ReconstructionProgress) -> Void
    ) async throws {
        throw ReconstructionError.unsupportedOnThisMac
    }
}
#endif
