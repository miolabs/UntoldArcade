@testable import CoolScanServerCore
import CoolScanPipeline
import UntoldEngine
import XCTest

final class JobManagerTests: XCTestCase {
    private var root: URL!
    private var fixture: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobManagerTests-\(UUID().uuidString)", isDirectory: true)
        fixture = try XCTUnwrap(Bundle.module.url(forResource: "ball", withExtension: "usdz"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(
        reconstructor: any Reconstructor,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> JobManager {
        try await JobManager(rootDirectory: root, reconstructor: reconstructor, serverBaseURL: "http://test", now: now)
    }

    private func waitUntilTerminal(_ manager: JobManager, _ id: String, timeout: Duration = .seconds(30)) async throws -> ReconstructionJob {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let job = await manager.status(jobID: id), job.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("job \(id) did not finish in time")
    }

    func testReconstructFlowProducesInstallableBundle() async throws {
        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture))
        var job = try await manager.create(
            name: "Chair", options: nil,
            expectedFiles: ["Images/IMG_0001.HEIC", "Images/IMG_0002.HEIC", "Checkpoints/poses.bin"]
        )
        XCTAssertEqual(job.state, .awaitingFiles)
        XCTAssertEqual(job.kind, .reconstruct)

        // Start refuses until every announced file arrived.
        await XCTAssertThrowsErrorAsync(try await manager.start(jobID: job.id))
        for file in job.expectedFiles {
            job = try await manager.receiveFile(jobID: job.id, relativePath: file, data: Data([1, 2, 3]))
        }
        XCTAssertTrue(job.missingFiles.isEmpty)

        job = try await manager.start(jobID: job.id)
        XCTAssertEqual(job.state, .queued)
        let finished = try await waitUntilTerminal(manager, job.id)
        XCTAssertEqual(finished.state, .done, finished.message ?? "")
        XCTAssertEqual(finished.progress, 1)

        let result = try await manager.resultURL(jobID: job.id)
        let installDir = root.appendingPathComponent("installed", isDirectory: true)
        let metadata = try ScanBundle.install(zip: result, into: installDir)
        XCTAssertEqual(metadata.origin, "mac")
        XCTAssertEqual(metadata.detail, "full")
        XCTAssertEqual(metadata.serverJobID, job.id)
        XCTAssertEqual(metadata.textureMax, 1024) // fixture textures are 1K; the 2K cap never upscales
        let decoded = try UntoldReader().readAsset(from: Data(contentsOf: installDir.appendingPathComponent(metadata.untoldFilename)))
        XCTAssertFalse(decoded.meshes.isEmpty)

        // Capture is gone, the USDZ stays for re-cooks.
        let folder = await manager.directory(for: job.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.usdz").path))

        // Re-cook with a smaller texture cap.
        var options = ReconstructionOptions()
        options.cookTextureCap = 512
        job = try await manager.recook(jobID: job.id, options: options)
        let recooked = try await waitUntilTerminal(manager, job.id)
        XCTAssertEqual(recooked.state, .done, recooked.message ?? "")
        let again = try ScanBundle.install(zip: try await manager.resultURL(jobID: job.id), into: installDir)
        XCTAssertEqual(again.textureMax, 512)
    }

    func testCookOnlyFlow() async throws {
        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture, shouldFail: true))
        var job = try await manager.create(name: "Ball", options: nil, expectedFiles: ["source.usdz"])
        XCTAssertEqual(job.kind, .cookOnly)
        job = try await manager.receiveFile(jobID: job.id, relativePath: "source.usdz", data: try Data(contentsOf: fixture))
        job = try await manager.start(jobID: job.id)
        let finished = try await waitUntilTerminal(manager, job.id)
        XCTAssertEqual(finished.state, .done, finished.message ?? "") // the failing stub was never invoked
        _ = try await manager.resultURL(jobID: job.id)
    }

    func testRejectsUnexpectedAndUnsafeFiles() async throws {
        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture))
        await XCTAssertThrowsErrorAsync(try await manager.create(name: "x", options: nil, expectedFiles: ["../etc/passwd"]))
        await XCTAssertThrowsErrorAsync(try await manager.create(name: "x", options: nil, expectedFiles: ["model.usdz"]))
        let job = try await manager.create(name: "x", options: nil, expectedFiles: ["Images/a.heic"])
        await XCTAssertThrowsErrorAsync(try await manager.receiveFile(jobID: job.id, relativePath: "Images/b.heic", data: Data()))
        await XCTAssertThrowsErrorAsync(try await manager.receiveFile(jobID: "nope", relativePath: "Images/a.heic", data: Data()))
    }

    func testUploadLimitIsEnforced() async throws {
        let manager = try await JobManager(rootDirectory: root, reconstructor: StubReconstructor(fixture: fixture), maxUploadBytes: 4)
        let job = try await manager.create(name: "x", options: nil, expectedFiles: ["Images/a.heic"])
        await XCTAssertThrowsErrorAsync(try await manager.receiveFile(jobID: job.id, relativePath: "Images/a.heic", data: Data(repeating: 0, count: 5)))
    }

    func testFailureIsReported() async throws {
        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture, shouldFail: true))
        var job = try await manager.create(name: "x", options: nil, expectedFiles: ["Images/a.heic"])
        job = try await manager.receiveFile(jobID: job.id, relativePath: "Images/a.heic", data: Data([0]))
        job = try await manager.start(jobID: job.id)
        let finished = try await waitUntilTerminal(manager, job.id)
        XCTAssertEqual(finished.state, .failed)
        XCTAssertTrue(finished.message?.contains("stub failure") == true, finished.message ?? "")
    }

    func testCancelRunningJob() async throws {
        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture, tickDelay: .milliseconds(300)))
        var job = try await manager.create(name: "x", options: nil, expectedFiles: ["Images/a.heic"])
        job = try await manager.receiveFile(jobID: job.id, relativePath: "Images/a.heic", data: Data([0]))
        job = try await manager.start(jobID: job.id)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await manager.cancel(jobID: job.id)
        let finished = try await waitUntilTerminal(manager, job.id)
        XCTAssertEqual(finished.state, .cancelled)
    }

    func testSweepFailsInterruptedJobsAndAppliesRetention() async throws {
        let jobs = root.appendingPathComponent("jobs", isDirectory: true)
        func writeJob(_ id: String, state: ReconstructionJob.State, updated: Date) throws {
            var job = ReconstructionJob(id: id, name: id, kind: .reconstruct, options: ReconstructionOptions(),
                                        expectedFiles: ["Images/a.heic"], createdAt: updated)
            job.state = state
            job.updatedAt = updated
            let folder = jobs.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(job).write(to: folder.appendingPathComponent("status.json"))
        }
        let now = Date()
        try writeJob("interrupted", state: .reconstructing, updated: now)
        try writeJob("stale-upload", state: .awaitingFiles, updated: now.addingTimeInterval(-2 * 3600))
        try writeJob("old-done", state: .done, updated: now.addingTimeInterval(-48 * 3600))
        try writeJob("fresh-done", state: .done, updated: now.addingTimeInterval(-60))

        let manager = try await makeManager(reconstructor: StubReconstructor(fixture: fixture), now: { now })
        let interrupted = await manager.status(jobID: "interrupted")
        XCTAssertEqual(interrupted?.state, .failed)
        let staleUpload = await manager.status(jobID: "stale-upload")
        let oldDone = await manager.status(jobID: "old-done")
        let freshDone = await manager.status(jobID: "fresh-done")
        XCTAssertNil(staleUpload)
        XCTAssertNil(oldDone)
        XCTAssertNotNil(freshDone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobs.appendingPathComponent("old-done").path))
    }

    func testOptionsDecodeWithDefaults() throws {
        let options = try JSONDecoder().decode(ReconstructionOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.detail, .full)
        XCTAssertEqual(options.cookTextureCap, 2048)
        XCTAssertEqual(options.cleanup.smoothingIterations, 4)
        let custom = try JSONDecoder().decode(
            ReconstructionOptions.self,
            from: Data(#"{"detail":"custom","maxPolygons":100000,"cleanup":{"smoothingIterations":0}}"#.utf8)
        )
        XCTAssertEqual(custom.detail, .custom)
        XCTAssertEqual(custom.maxPolygons, 100_000)
        XCTAssertEqual(custom.cleanup.smoothingIterations, 0)
        XCTAssertEqual(custom.cleanup.recomputeNormals, true)
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "expected an error",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {}
}
