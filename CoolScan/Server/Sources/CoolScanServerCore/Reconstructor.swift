import Foundation

public enum ReconstructionError: Error, CustomStringConvertible {
    case unsupportedOnThisMac
    case noImages
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .unsupportedOnThisMac: "Photogrammetry is not supported on this Mac"
        case .noImages: "The capture contains no images"
        case .cancelled: "Cancelled"
        case let .failed(message): message
        }
    }
}

/// Turns a capture folder into a USDZ. Implementations must honour
/// `Task.isCancelled` and finish by throwing `ReconstructionError.cancelled`.
public protocol Reconstructor: Sendable {
    var isSupported: Bool { get }

    func reconstruct(
        images: URL,
        checkpoints: URL?,
        output: URL,
        options: ReconstructionOptions,
        progress: @escaping @Sendable (ReconstructionProgress) -> Void
    ) async throws
}

/// Test/demo reconstructor: copies a fixture USDZ to the output after a few
/// progress ticks. `--stub-usdz` on the CLI uses it to exercise the whole
/// pipeline without photogrammetry.
public struct StubReconstructor: Reconstructor {
    public let fixture: URL
    public let tickDelay: Duration
    public let shouldFail: Bool

    public init(fixture: URL, tickDelay: Duration = .milliseconds(10), shouldFail: Bool = false) {
        self.fixture = fixture
        self.tickDelay = tickDelay
        self.shouldFail = shouldFail
    }

    public var isSupported: Bool { true }

    public func reconstruct(
        images: URL,
        checkpoints _: URL?,
        output: URL,
        options _: ReconstructionOptions,
        progress: @escaping @Sendable (ReconstructionProgress) -> Void
    ) async throws {
        let stages = ["imageAlignment", "pointCloudGeneration", "meshGeneration", "textureMapping"]
        for (index, stage) in stages.enumerated() {
            try Task.checkCancellation()
            try await Task.sleep(for: tickDelay)
            progress(ReconstructionProgress(
                fraction: Double(index + 1) / Double(stages.count + 1),
                stage: stage,
                etaSeconds: Double(stages.count - index)
            ))
        }
        if shouldFail {
            throw ReconstructionError.failed("stub failure")
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.copyItem(at: fixture, to: output)
        progress(ReconstructionProgress(fraction: 1, stage: "done"))
    }
}
