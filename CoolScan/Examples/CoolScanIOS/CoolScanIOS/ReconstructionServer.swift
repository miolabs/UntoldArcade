import CoolScanPipeline
import Foundation
import Network

// Client side of the Mac reconstruction server (CoolScan/Server). The wire
// types mirror the server's JSON; the app never links the server package
// (it is macOS-only).

// MARK: - Wire types

struct ServerHealth: Decodable {
    let protocolVersion: Int
    let version: String
    let photogrammetrySupported: Bool
    let defaultDetail: String
    let maxUploadBytes: Int
    let serverName: String

    static let supportedProtocol = 1
}

/// Subset of the server's ReconstructionOptions the phone exposes.
struct RemoteReconstructionOptions: Codable, Equatable {
    enum Detail: String, Codable, CaseIterable, Identifiable {
        case medium, full, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .medium: "Medium"
            case .full: "Full (Apple)"
            case .custom: "Custom 250k / 2K"
            }
        }
    }

    var detail: Detail = .full
    var cookTextureCap: Int = 2048
}

struct RemoteJob: Decodable, Identifiable {
    enum State: String, Decodable {
        case awaitingFiles, queued, reconstructing, cooking, done, failed, cancelled
        var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
    }

    let id: String
    let name: String
    let state: State
    let progress: Double
    let stage: String?
    let etaSeconds: Double?
    let message: String?
    let warnings: [String]
    let receivedFiles: [String]

    var humanStage: String {
        switch state {
        case .awaitingFiles: "Waiting for files"
        case .queued: "Queued on the Mac"
        case .reconstructing:
            switch stage {
            case "imageAlignment": "Aligning photos"
            case "pointCloudGeneration": "Building point cloud"
            case "meshGeneration": "Generating mesh"
            case "textureMapping": "Mapping textures"
            case "optimization": "Optimising"
            case "preProcessing": "Preparing photos"
            case let other?: other
            case nil: "Reconstructing"
            }
        case .cooking: "Converting to Untold format"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct ServerErrorBody: Decodable {
    let error: String
}

enum ServerClientError: Error, LocalizedError {
    case badStatus(Int, String)
    case protocolMismatch(Int)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, message): "Server replied \(code): \(message)"
        case let .protocolMismatch(version): "Server speaks protocol \(version); this app needs \(ServerHealth.supportedProtocol)"
        case let .unsupported(name): "\(name) cannot run photogrammetry (Apple Silicon required)"
        }
    }
}

// MARK: - Client

/// Thin HTTP client for one server. Uploads go one file per request —
/// the server buffers bodies in memory — which also gives per-file
/// progress and retries for free.
struct ServerClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func health() async throws -> ServerHealth {
        let health: ServerHealth = try await get("health")
        guard health.protocolVersion == ServerHealth.supportedProtocol else {
            throw ServerClientError.protocolMismatch(health.protocolVersion)
        }
        return health
    }

    func createJob(name: String, files: [String], options: RemoteReconstructionOptions) async throws -> RemoteJob {
        struct Body: Encodable {
            let name: String
            let files: [String]
            let options: RemoteReconstructionOptions
        }
        return try await send("jobs", method: "POST", json: Body(name: name, files: files, options: options))
    }

    func upload(file: URL, as relativePath: String, jobID: String) async throws -> RemoteJob {
        var request = URLRequest(url: baseURL.appendingPathComponent("jobs/\(jobID)/files"))
        request.httpMethod = "PUT"
        request.setValue(relativePath, forHTTPHeaderField: "X-File-Path")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        return try decode(data, response)
    }

    func start(jobID: String) async throws -> RemoteJob {
        try await send("jobs/\(jobID)/start", method: "POST", json: Optional<Int>.none)
    }

    func recook(jobID: String, options: RemoteReconstructionOptions) async throws -> RemoteJob {
        struct Body: Encodable { let options: RemoteReconstructionOptions }
        return try await send("jobs/\(jobID)/recook", method: "POST", json: Body(options: options))
    }

    func status(jobID: String) async throws -> RemoteJob {
        try await get("jobs/\(jobID)")
    }

    func cancel(jobID: String) async throws {
        let _: RemoteJob = try await send("jobs/\(jobID)/cancel", method: "POST", json: Optional<Int>.none)
    }

    func delete(jobID: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("jobs/\(jobID)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) || http.statusCode == 404 else {
            throw ServerClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "delete failed")
        }
    }

    /// Downloads the result archive to disk (never into memory).
    func downloadResult(jobID: String) async throws -> URL {
        let request = URLRequest(url: baseURL.appendingPathComponent("jobs/\(jobID)/result"))
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? Data(contentsOf: temporary)).flatMap { try? JSONDecoder().decode(ServerErrorBody.self, from: $0) }?.error
            throw ServerClientError.badStatus(code, message ?? "result unavailable")
        }
        // The temporary file is deleted when this call returns; keep it.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("\(jobID)-result.zip")
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }

    // MARK: Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent(path))
        return try decode(data, response)
    }

    private func send<T: Decodable, B: Encodable>(_ path: String, method: String, json: B?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(code) else {
            let message = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.error
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw ServerClientError.badStatus(code, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Discovery

struct DiscoveredServer: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Browses `_coolscan._tcp` on the local network. First use triggers the
/// Local Network permission prompt; if denied the browser sits in
/// `.waiting` and the settings sheet offers manual entry instead.
@MainActor
final class ServerDiscovery: ObservableObject {
    static let serviceType = "_coolscan._tcp"

    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var statusText = "Looking for a CoolScan server…"

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.statusText = "Searching the local network"
                case let .failed(error): self?.statusText = "Discovery failed: \(error.localizedDescription)"
                case let .waiting(error): self?.statusText = "Waiting for local network access (\(error.localizedDescription))"
                case .cancelled: self?.statusText = "Discovery stopped"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredServer? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredServer(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
            Task { @MainActor in self?.servers = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Resolves a Bonjour endpoint to an `http://ip:port` base URL by opening
    /// a throwaway TCP connection and reading where it landed. IPv4 is
    /// forced so the address is a plain dotted quad, not a link-local IPv6
    /// literal with a zone suffix that URL cannot carry.
    nonisolated static func resolve(_ server: DiscoveredServer) async throws -> URL {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: server.endpoint, using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                       let url = URL(string: "http://\(Self.literal(host)):\(port.rawValue)")
                    {
                        box.resume(.success(url))
                    } else {
                        box.resume(.failure(ServerClientError.badStatus(-1, "could not resolve \(server.name)")))
                    }
                    connection.cancel()
                case let .failed(error):
                    box.resume(.failure(error))
                    connection.cancel()
                case let .waiting(error):
                    box.resume(.failure(error))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private nonisolated static func literal(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address): "\(address)"
        case let .ipv6(address): "[\(address)]"
        case let .name(name, _): name
        @unknown default: "\(host)"
        }
    }

    /// Resumes a continuation at most once even if the connection reports
    /// several terminal states.
    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
        func resume(_ result: Result<URL, Error>) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

// MARK: - Settings

/// User-facing server preferences (manual address, detail preset).
enum ServerSettings {
    private static let manualKey = "coolscan.server.manualBaseURL"
    private static let detailKey = "coolscan.server.detail"
    private static let preferMacKey = "coolscan.server.preferMac"

    static var manualBaseURL: URL? {
        get { UserDefaults.standard.string(forKey: manualKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: manualKey) }
    }

    static var options: RemoteReconstructionOptions {
        get {
            var options = RemoteReconstructionOptions()
            if let raw = UserDefaults.standard.string(forKey: detailKey),
               let detail = RemoteReconstructionOptions.Detail(rawValue: raw)
            {
                options.detail = detail
            }
            return options
        }
        set { UserDefaults.standard.set(newValue.detail.rawValue, forKey: detailKey) }
    }

    /// Last choice after a capture; nil until the user picked once.
    static var preferMac: Bool? {
        get { UserDefaults.standard.object(forKey: preferMacKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: preferMacKey) }
    }
}

// MARK: - Remote job runner

/// Drives a capture (or a source USDZ) through the server and installs the
/// result in the scan library. Progress is reported through a callback so
/// both the scan flow and the library (resume) can show it.
enum RemoteReconstruction {
    enum Phase: Equatable {
        case connecting
        case uploading(sent: Int, total: Int, file: String)
        case remote(stage: String, progress: Double, eta: Double?)
        case downloading
        case installing
    }

    struct PendingJob: Codable {
        var jobID: String
        var baseURL: String
        var name: String
        var createdAt: Date
        var scanID: String
    }

    static var pendingDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("PendingJobs", isDirectory: true)
    }

    /// Files under `folder`, relative paths with forward slashes, limited to
    /// the server's accepted prefixes.
    static func captureFiles(in folder: URL) -> [(relativePath: String, url: URL)] {
        var files: [(String, URL)] = []
        for prefix in ["Images", "Checkpoints"] {
            let base = folder.appendingPathComponent(prefix, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = url.path.replacingOccurrences(of: base.path + "/", with: "")
                files.append(("\(prefix)/\(relative)", url))
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// Creates the job, uploads every file (skipping those the server already
    /// has), starts it, and records a pending-job file so the library can
    /// resume if the app dies. Returns the job id.
    static func submit(
        name: String,
        files: [(relativePath: String, url: URL)],
        options: RemoteReconstructionOptions,
        client: ServerClient,
        scanID: String,
        progress: @escaping @MainActor (Phase) -> Void
    ) async throws -> String {
        await progress(.connecting)
        let health = try await client.health()
        guard health.photogrammetrySupported || files.map(\.relativePath) == ["source.usdz"] else {
            throw ServerClientError.unsupported(health.serverName)
        }

        var job = try await client.createJob(name: name, files: files.map(\.relativePath), options: options)
        try savePending(PendingJob(
            jobID: job.id, baseURL: client.baseURL.absoluteString, name: name, createdAt: Date(), scanID: scanID
        ))

        let total = files.count
        for (index, file) in files.enumerated() {
            await progress(.uploading(sent: index, total: total, file: file.relativePath))
            if job.receivedFiles.contains(file.relativePath) { continue }
            job = try await retry(times: 3) {
                try await client.upload(file: file.url, as: file.relativePath, jobID: job.id)
            }
        }
        await progress(.uploading(sent: total, total: total, file: ""))
        _ = try await client.start(jobID: job.id)
        return job.id
    }

    /// Polls until the job finishes, then downloads and installs the bundle
    /// into `Documents/Scans/<scanID>`. Deletes the server job on success.
    static func collect(
        jobID: String,
        client: ServerClient,
        scanID: String,
        progress: @escaping @MainActor (Phase) -> Void
    ) async throws -> ScanBundleMetadata {
        while true {
            let job = try await client.status(jobID: jobID)
            switch job.state {
            case .done:
                await progress(.downloading)
                let zip = try await client.downloadResult(jobID: jobID)
                defer { try? FileManager.default.removeItem(at: zip) }
                await progress(.installing)
                let destination = URL.documentsDirectory
                    .appendingPathComponent("Scans", isDirectory: true)
                    .appendingPathComponent(scanID, isDirectory: true)
                let metadata = try ScanBundle.install(zip: zip, into: destination)
                try? await client.delete(jobID: jobID)
                removePending(jobID: jobID)
                return metadata
            case .failed, .cancelled:
                removePending(jobID: jobID)
                throw ServerClientError.badStatus(0, job.message ?? "The Mac \(job.state.rawValue) the job")
            default:
                await progress(.remote(stage: job.humanStage, progress: max(0, job.progress), eta: job.etaSeconds))
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Pending jobs

    static func pendingJobs() -> [PendingJob] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(PendingJob.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func savePending(_ job: PendingJob) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: pendingDirectory.appendingPathComponent("\(job.jobID).json"), options: .atomic)
    }

    static func removePending(jobID: String) {
        try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent("\(jobID).json"))
    }

    private static func retry<T>(times: Int, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch {
                attempt += 1
                if attempt >= times { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }
}
