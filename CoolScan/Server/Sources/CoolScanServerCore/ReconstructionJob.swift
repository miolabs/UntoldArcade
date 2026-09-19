import Foundation

/// One capture handed to the server. Persisted as `status.json` in the job
/// folder on every transition; that file is the single source of truth and
/// what the phone polls.
public struct ReconstructionJob: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case awaitingFiles
        case queued
        case reconstructing
        case cooking
        case done
        case failed
        case cancelled
    }

    /// `reconstruct`: a capture (Images/ + Checkpoints/) to reconstruct then
    /// cook. `cookOnly`: a `source.usdz` to cook with the current pipeline.
    public enum Kind: String, Codable, Sendable {
        case reconstruct
        case cookOnly
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var options: ReconstructionOptions
    public var state: State = .awaitingFiles
    public var progress: Double = 0
    public var stage: String?
    public var etaSeconds: Double?
    public var message: String?
    public var warnings: [String] = []
    public var expectedFiles: [String]
    public var receivedFiles: [String] = []
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        options: ReconstructionOptions,
        expectedFiles: [String],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
        self.expectedFiles = expectedFiles
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    public var missingFiles: [String] {
        let received = Set(receivedFiles)
        return expectedFiles.filter { !received.contains($0) }
    }

    public var isTerminal: Bool {
        switch state {
        case .done, .failed, .cancelled: true
        default: false
        }
    }

    public var isRunning: Bool {
        state == .reconstructing || state == .cooking
    }
}

/// Progress reported by a reconstructor while it works.
public struct ReconstructionProgress: Sendable {
    public var fraction: Double
    public var stage: String?
    public var etaSeconds: Double?
    public var warning: String?

    public init(fraction: Double, stage: String? = nil, etaSeconds: Double? = nil, warning: String? = nil) {
        self.fraction = fraction
        self.stage = stage
        self.etaSeconds = etaSeconds
        self.warning = warning
    }
}
