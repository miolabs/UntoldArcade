@testable import CoolScanPipeline
import XCTest

final class ZipArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriteThenExtractRoundTripsNestedAndLargeEntries() throws {
        let small = directory.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: small)
        let nested = directory.appendingPathComponent("nested.bin")
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024)
        for i in stride(from: 0, to: bytes.count, by: 4099) { bytes[i] = UInt8(i % 251) }
        try Data(bytes).write(to: nested)
        let empty = directory.appendingPathComponent("empty.dat")
        try Data().write(to: empty)

        let zip = directory.appendingPathComponent("out.zip")
        try ZipArchive.write([
            ZipArchive.Source(name: "a.txt", url: small),
            ZipArchive.Source(name: "Images/deep/nested.bin", url: nested),
            ZipArchive.Source(name: "empty.dat", url: empty),
        ], to: zip)

        let out = directory.appendingPathComponent("out", isDirectory: true)
        let files = try ZipArchive.extract(zip, into: out)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.txt", "nested.bin", "empty.dat"])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.txt")), Data("hello".utf8))
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent("Images/deep/nested.bin")),
            Data(bytes)
        )
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("empty.dat")).count, 0)

        // The system unzip agrees the archive is well formed (CRCs included).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip -t rejected the archive")
    }

    func testReaderRejectsEscapingEntryNames() throws {
        XCTAssertNil(ZipArchive.safeComponents("../evil"))
        XCTAssertNil(ZipArchive.safeComponents("/abs/path"))
        XCTAssertEqual(ZipArchive.safeComponents("a//b"), ["a", "b"]) // empty segments are dropped, not escapes
        XCTAssertEqual(ZipArchive.safeComponents("Images/IMG_0001.HEIC"), ["Images", "IMG_0001.HEIC"])
    }

    func testWriterRejectsEscapingEntryNames() throws {
        let file = directory.appendingPathComponent("x")
        try Data([1]).write(to: file)
        XCTAssertThrowsError(
            try ZipArchive.write([ZipArchive.Source(name: "../x", url: file)],
                                 to: directory.appendingPathComponent("bad.zip"))
        )
    }

    func testFixtureUSDZStillUnpacks() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ball", withExtension: "usdz"))
        let files = try ZipArchive.extract(url, into: directory.appendingPathComponent("ball"))
        XCTAssertEqual(files.first?.lastPathComponent, "ball.usdc")
        XCTAssertEqual(files.count, 4)
    }
}
