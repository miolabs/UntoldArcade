import CoolScanPipeline
import Foundation

/// Owns the job folders and runs reconstructions one at a time.
///
/// Layout: `<root>/jobs/<id>/{Images/, Checkpoints/, source.usdz, model.usdz,
/// cooked/, result.zip, status.json}`. Photogrammetry saturates the machine,
/// so jobs are processed serially in FIFO order.
public actor JobManager {
    public struct Retention: Sendable {
        /// Delete terminal jobs older than this.
        public var maxAge: TimeInterval = 24 * 3600
        /// Keep at most this many jobs on disk (oldest terminal jobs go first).
        public var maxJobs: Int = 10
        /// Drop jobs that never received their files.
        public var abandonedUploadAge: TimeInterval = 3600

        public init() {}
    }

    public enum JobError: Error, CustomStringConvertible {
        case notFound(String)
        case invalidState(String)
        case unexpectedFile(String)
        case unsafePath(String)
        case tooLarge(String)
        case missingFiles([String])
        case noResult(String)

        public var description: String {
            switch self {
            case let .notFound(id): "Job \(id) not found"
            case let .invalidState(message): message
            case let .unexpectedFile(path): "File was not announced when the job was created: \(path)"
            case let .unsafePath(path): "Refusing path: \(path)"
            case let .tooLarge(path): "File exceeds the upload limit: \(path)"
            case let .missingFiles(files): "Job is still missing \(files.count) file(s)"
            case let .noResult(id): "Job \(id) has no result"
            }
        }
    }

    public static let allowedPrefixes = ["Images/", "Checkpoints/"]
    public static let sourceFilename = "source.usdz"

    public let rootDirectory: URL
    public var maxUploadBytes: Int
    public var serverBaseURL: String?

    private let reconstructor: any Reconstructor
    private let retention: Retention
    private let now: @Sendable () -> Date
    private var jobs: [String: ReconstructionJob] = [:]
    private var queue: [String] = []
    private var running: (id: String, task: Task<Void, Never>)?
    private var activity: NSObjectProtocol?

    public init(
        rootDirectory: URL,
        reconstructor: any Reconstructor,
        retention: Retention = Retention(),
        maxUploadBytes: Int = 64 * 1024 * 1024,
        serverBaseURL: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws {
        self.rootDirectory = rootDirectory
        self.reconstructor = reconstructor
        self.retention = retention
        self.maxUploadBytes = maxUploadBytes
        self.serverBaseURL = serverBaseURL
        self.now = now
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent("jobs", isDirectory: true),
            withIntermediateDirectories: true
        )
        sweep()
    }

    public var isSupported: Bool { reconstructor.isSupported }

    private nonisolated var jobsDirectory: URL {
        rootDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    public nonisolated func directory(for id: String) -> URL {
        jobsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Lifecycle

    public func create(name: String, options: ReconstructionOptions?, expectedFiles: [String]) throws -> ReconstructionJob {
        for path in expectedFiles {
            try Self.validate(relativePath: path)
        }
        let kind: ReconstructionJob.Kind = expectedFiles == [Self.sourceFilename] ? .cookOnly : .reconstruct
        var job = ReconstructionJob(
            name: name,
            kind: kind,
            options: options ?? ReconstructionOptions(),
            expectedFiles: expectedFiles,
            createdAt: now()
        )
        if expectedFiles.isEmpty {
            job.state = .failed
            job.message = "No files announced"
        }
        try FileManager.default.createDirectory(at: directory(for: job.id), withIntermediateDirectories: true)
        try persist(&job)
        return job
    }

    public func receiveFile(jobID: String, relativePath: String, data: Data) throws -> ReconstructionJob {
        guard var job = jobs[jobID] else { throw JobError.notFound(jobID) }
        guard job.state == .awaitingFiles else {
            throw JobError.invalidState("Job \(jobID) is \(job.state.rawValue); it no longer accepts files")
        }
        try Self.validate(relativePath: relativePath)
        guard job.expectedFiles.contains(relativePath) else { throw JobError.unexpectedFile(relativePath) }
        guard data.count <= maxUploadBytes else { throw JobError.tooLarge(relativePath) }

        let url = directory(for: jobID).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if !job.receivedFiles.contains(relativePath) {
            job.receivedFiles.append(relativePath)
        }
        try persist(&job)
        return job
    }

    public func start(jobID: String) throws -> ReconstructionJob {
        guard var job = jobs[jobID] else { throw JobError.notFound(jobID) }
        guard job.state == .awaitingFiles else {
            throw JobError.invalidState("Job \(jobID) is already \(job.state.rawValue)")
        }
        let missing = job.missingFiles
        guard missing.isEmpty else { throw JobError.missingFiles(missing) }
        job.state = .queued
        try persist(&job)
        queue.append(jobID)
        pump()
        return job
    }

    /// Re-cooks a finished job's USDZ with new options (no reconstruction).
    public func recook(jobID: String, options: ReconstructionOptions?) throws -> ReconstructionJob {
        guard var job = jobs[jobID] else { throw JobError.notFound(jobID) }
        guard job.isTerminal else { throw JobError.invalidState("Job \(jobID) is still \(job.state.rawValue)") }
        guard FileManager.default.fileExists(atPath: modelURL(for: job).path) else {
            throw JobError.noResult(jobID)
        }
        if let options { job.options = options }
        job.state = .queued
        job.progress = 0
        job.stage = nil
        job.message = nil
        try persist(&job)
        queue.append(jobID)
        pump()
        return job
    }

    public func status(jobID: String) -> ReconstructionJob? {
        jobs[jobID]
    }

    public func allJobs() -> [ReconstructionJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func resultURL(jobID: String) throws -> URL {
        guard let job = jobs[jobID] else { throw JobError.notFound(jobID) }
        guard job.state == .done else { throw JobError.invalidState("Job \(jobID) is \(job.state.rawValue)") }
        let url = directory(for: jobID).appendingPathComponent("result.zip")
        guard FileManager.default.fileExists(atPath: url.path) else { throw JobError.noResult(jobID) }
        return url
    }

    public func cancel(jobID: String) throws -> ReconstructionJob {
        guard var job = jobs[jobID] else { throw JobError.notFound(jobID) }
        if let running, running.id == jobID {
            running.task.cancel()
            return job
        }
        queue.removeAll { $0 == jobID }
        if !job.isTerminal {
            job.state = .cancelled
            try persist(&job)
        }
        return job
    }

    public func delete(jobID: String) throws {
        guard jobs[jobID] != nil else { throw JobError.notFound(jobID) }
        if let running, running.id == jobID {
            running.task.cancel()
        }
        queue.removeAll { $0 == jobID }
        jobs[jobID] = nil
        try? FileManager.default.removeItem(at: directory(for: jobID))
    }

    // MARK: - Worker

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = jobs[id], job.state == .queued else { return pump() }
        // Explicit type: `await self?.run(...)` would infer Task<Void?, Never>.
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.run(jobID: id)
        }
        running = (id: id, task: task)
    }

    private func run(jobID: String) async {
        guard var job = jobs[jobID] else { finished(jobID); return }
        let folder = directory(for: jobID)
        let model = modelURL(for: job)
        beginActivity()
        defer {
            endActivity()
            finished(jobID)
        }

        do {
            if job.kind == .reconstruct, !FileManager.default.fileExists(atPath: model.path) {
                job.state = .reconstructing
                try persist(&job)
                let images = folder.appendingPathComponent("Images", isDirectory: true)
                let checkpoints = folder.appendingPathComponent("Checkpoints", isDirectory: true)
                let hasCheckpoints = FileManager.default.fileExists(atPath: checkpoints.path)
                try await reconstructor.reconstruct(
                    images: images,
                    checkpoints: hasCheckpoints ? checkpoints : nil,
                    output: model,
                    options: job.options,
                    progress: { [weak self] progress in
                        Task { await self?.report(jobID: jobID, progress: progress) }
                    }
                )
                try Task.checkCancellation()
                // The capture is no longer needed; the USDZ is kept for re-cooks.
                try? FileManager.default.removeItem(at: images)
                try? FileManager.default.removeItem(at: checkpoints)
            }

            guard var current = jobs[jobID] else { return }
            current.state = .cooking
            current.progress = 1
            current.stage = "cooking"
            current.etaSeconds = nil
            try persist(&current)

            let baseURL = serverBaseURL
            let currentJob = current
            _ = try await Task.detached(priority: .userInitiated) {
                try ResultBundler.bundle(usdz: model, into: folder, job: currentJob, serverBaseURL: baseURL)
            }.value
            try Task.checkCancellation()

            guard var finishedJob = jobs[jobID] else { return }
            finishedJob.state = .done
            finishedJob.stage = nil
            finishedJob.message = nil
            try persist(&finishedJob)
        } catch is CancellationError {
            markCancelled(jobID)
        } catch ReconstructionError.cancelled {
            markCancelled(jobID)
        } catch {
            guard var failed = jobs[jobID] else { return }
            failed.state = .failed
            failed.message = "\(error)"
            failed.stage = nil
            try? persist(&failed)
        }
    }

    private func report(jobID: String, progress: ReconstructionProgress) {
        guard var job = jobs[jobID], job.state == .reconstructing else { return }
        job.progress = progress.fraction
        job.stage = progress.stage ?? job.stage
        job.etaSeconds = progress.etaSeconds
        if let warning = progress.warning, !job.warnings.contains(warning) {
            job.warnings.append(warning)
        }
        try? persist(&job)
    }

    private func markCancelled(_ jobID: String) {
        guard var job = jobs[jobID] else { return }
        job.state = .cancelled
        job.stage = nil
        try? persist(&job)
    }

    private func finished(_ jobID: String) {
        if running?.id == jobID { running = nil }
        pump()
    }

    private func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "CoolScan reconstruction"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    // MARK: - Persistence

    private func modelURL(for job: ReconstructionJob) -> URL {
        let folder = directory(for: job.id)
        return job.kind == .cookOnly
            ? folder.appendingPathComponent(Self.sourceFilename)
            : folder.appendingPathComponent("model.usdz")
    }

    private func persist(_ job: inout ReconstructionJob) throws {
        job.updatedAt = now()
        jobs[job.id] = job
        let data = try JSONEncoder().encode(job)
        try data.write(to: directory(for: job.id).appendingPathComponent("status.json"), options: .atomic)
    }

    /// Loads jobs from disk, fails anything that was mid-flight when the
    /// server last stopped, and applies retention.
    private func sweep() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: jobsDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("status.json")),
                  var job = try? JSONDecoder().decode(ReconstructionJob.self, from: data)
            else {
                try? fm.removeItem(at: folder)
                continue
            }
            if job.isRunning || job.state == .queued {
                job.state = .failed
                job.message = "The server was restarted while this job was running"
            }
            jobs[job.id] = job
        }

        let current = now()
        for job in jobs.values {
            let age = current.timeIntervalSince(job.updatedAt)
            let abandoned = job.state == .awaitingFiles && age > retention.abandonedUploadAge
            let expired = job.isTerminal && age > retention.maxAge
            if abandoned || expired {
                try? delete(jobID: job.id)
            }
        }
        let terminal = jobs.values.filter(\.isTerminal).sorted { $0.updatedAt < $1.updatedAt }
        var excess = jobs.count - retention.maxJobs
        for job in terminal where excess > 0 {
            try? delete(jobID: job.id)
            excess -= 1
        }
        for id in jobs.keys {
            if var job = jobs[id] { try? persist(&job) }
        }
    }

    static func validate(relativePath: String) throws {
        guard ZipArchive.safeComponents(relativePath) != nil else { throw JobError.unsafePath(relativePath) }
        let allowed = relativePath == sourceFilename
            || allowedPrefixes.contains { relativePath.hasPrefix($0) && relativePath.count > $0.count }
        guard allowed else { throw JobError.unsafePath(relativePath) }
    }
}
