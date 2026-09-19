@testable import CoolScanPipeline
import XCTest

final class ScanBundleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// meta.json written by the app before the server existed must keep
    /// decoding: same field names, default date encoding, no new fields.
    func testLegacyMetadataDecodes() throws {
        let legacy = """
        {"name":"Sample Ball","createdAt":780000000.5,"untoldFilename":"scan.untold",
         "vertexCount":10,"triangleCount":4,"boundsMin":[-1,-1,-1],"boundsMax":[1,1,1]}
        """
        let decoded = try JSONDecoder().decode(ScanBundleMetadata.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "Sample Ball")
        XCTAssertEqual(decoded.createdAt.timeIntervalSinceReferenceDate, 780_000_000.5, accuracy: 0.001)
        XCTAssertNil(decoded.origin)
        XCTAssertNil(decoded.schemaVersion)
    }

    func testMetadataRoundTripKeepsDefaultDateEncoding() throws {
        let metadata = ScanBundleMetadata(
            name: "x", createdAt: Date(timeIntervalSinceReferenceDate: 123),
            untoldFilename: "scan.untold", vertexCount: 1, triangleCount: 1,
            boundsMin: [0, 0, 0], boundsMax: [1, 1, 1], origin: "mac", detail: "full", textureMax: 2048
        )
        try ScanBundle.writeMetadata(metadata, to: directory)
        let json = try String(contentsOf: directory.appendingPathComponent("meta.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"createdAt\":123"), json)
        XCTAssertEqual(try ScanBundle.readMetadata(from: directory), metadata)
    }

    func testInstallIsAtomicAndValidates() throws {
        // A bundle without the model must not land in the destination.
        let bad = directory.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try ScanBundle.writeMetadata(
            ScanBundleMetadata(name: "bad", untoldFilename: "scan.untold", vertexCount: 0,
                               triangleCount: 0, boundsMin: [0, 0, 0], boundsMax: [0, 0, 0]),
            to: bad
        )
        let badZip = directory.appendingPathComponent("bad.zip")
        try ScanBundle.archive(folder: bad, to: badZip)
        let destination = directory.appendingPathComponent("Scans/one", isDirectory: true)
        XCTAssertThrowsError(try ScanBundle.install(zip: badZip, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // A complete bundle installs and reads back.
        let good = directory.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try Data([0]).write(to: good.appendingPathComponent("scan.untold"))
        try ScanBundle.writeMetadata(
            ScanBundleMetadata(name: "good", untoldFilename: "scan.untold", vertexCount: 1,
                               triangleCount: 1, boundsMin: [0, 0, 0], boundsMax: [1, 1, 1]),
            to: good
        )
        let goodZip = directory.appendingPathComponent("good.zip")
        try ScanBundle.archive(folder: good, to: goodZip)
        let installed = try ScanBundle.install(zip: goodZip, into: destination)
        XCTAssertEqual(installed.name, "good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("scan.untold").path))
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Scans").path))
                .contains { $0.hasPrefix(".installing-") }
        )
    }
}
