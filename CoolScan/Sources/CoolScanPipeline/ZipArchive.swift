import Compression
import Foundation
import zlib

/// Minimal ZIP support shared by the phone and the Mac server.
///
/// Reader: used to unpack USDZ packages (ModelIO resolves in-archive texture
/// references unreliably — Object Capture keeps textures under `0/` and logs
/// `Failed to resolve reference @0/…png@`) and to install result bundles.
/// Entries are written straight from slices of the memory-mapped archive, so
/// peak memory stays flat even for multi-hundred-megabyte results.
///
/// Writer: stored (uncompressed) entries streamed from files in 1 MB chunks.
/// Captures are HEIC and results are PNG, both already compressed; stored
/// keeps the writer trivial and the CPU cost to one CRC pass.
public enum ZipArchive {
    public struct Entry {
        public let name: String
        public let data: Data
    }

    public enum ArchiveError: Error, CustomStringConvertible {
        case notAZip
        case truncated
        case unsupportedCompression(UInt16)
        case inflateFailed(String)
        case unsafeEntryName(String)
        case entryTooLarge(String)
        case archiveTooLarge

        public var description: String {
            switch self {
            case .notAZip: "Not a ZIP archive"
            case .truncated: "Archive is truncated"
            case let .unsupportedCompression(method): "Unsupported ZIP compression method \(method)"
            case let .inflateFailed(name): "Failed to inflate \(name)"
            case let .unsafeEntryName(name): "Refusing unsafe archive entry name: \(name)"
            case let .entryTooLarge(name): "Entry exceeds 4 GB (zip64 unsupported): \(name)"
            case .archiveTooLarge: "Archive exceeds 4 GB (zip64 unsupported)"
            }
        }
    }

    // MARK: - Reading

    /// Extracts every regular file into `directory`, preserving relative
    /// paths, and returns the written URLs in archive order (USDZ puts the
    /// root layer first).
    @discardableResult
    public static func extract(_ archiveURL: URL, into directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        try forEachEntry(in: data) { name, payload in
            guard let components = safeComponents(name) else {
                throw ArchiveError.unsafeEntryName(name)
            }
            let url = components.dropLast()
                .reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
                .appendingPathComponent(components.last!)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload.write(to: url)
            written.append(url)
        }
        return written
    }

    /// Materialises every entry in memory. Fine for small archives and tests;
    /// use `extract` for real packages.
    public static func readEntries(_ data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        try forEachEntry(in: data) { name, payload in
            entries.append(Entry(name: name, data: payload))
        }
        return entries
    }

    private static func forEachEntry(
        in data: Data,
        _ body: (String, Data) throws -> Void
    ) throws {
        // Data slices keep the original's indices; work with absolute offsets.
        let base = data.startIndex
        let count = data.count
        guard count >= 22 else { throw ArchiveError.notAZip }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[base + offset]) | (UInt16(data[base + offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[base + offset])
                | (UInt32(data[base + offset + 1]) << 8)
                | (UInt32(data[base + offset + 2]) << 16)
                | (UInt32(data[base + offset + 3]) << 24)
        }

        // End of central directory: scan backwards for the signature.
        var eocd = -1
        var i = count - 22
        let minIndex = max(0, count - 22 - 65535)
        while i >= minIndex {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.notAZip }

        let entryCount = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))

        for _ in 0 ..< entryCount {
            guard offset + 46 <= count, u32(offset) == 0x0201_4B50 else {
                throw ArchiveError.truncated
            }
            let method = u16(offset + 10)
            let compressedSize = Int(u32(offset + 20))
            let uncompressedSize = Int(u32(offset + 24))
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            let localHeaderOffset = Int(u32(offset + 42))
            guard offset + 46 + nameLength <= count else { throw ArchiveError.truncated }
            let name = String(
                decoding: data[(base + offset + 46) ..< (base + offset + 46 + nameLength)],
                as: UTF8.self
            )
            offset += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue } // directories carry no payload

            guard localHeaderOffset + 30 <= count, u32(localHeaderOffset) == 0x0403_4B50 else {
                throw ArchiveError.truncated
            }
            let localNameLength = Int(u16(localHeaderOffset + 26))
            let localExtraLength = Int(u16(localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= count else { throw ArchiveError.truncated }
            let payload = data[(base + dataStart) ..< (base + dataEnd)]

            switch method {
            case 0:
                try body(name, payload)
            case 8:
                try body(name, try inflate(payload, expectedSize: uncompressedSize, name: name))
            default:
                throw ArchiveError.unsupportedCompression(method)
            }
        }
    }

    private static func inflate(_ payload: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let produced = output.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), expectedSize,
                    srcBase.assumingMemoryBound(to: UInt8.self), payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard produced == expectedSize else { throw ArchiveError.inflateFailed(name) }
        return output
    }

    /// Path components of an entry name, or nil when the name could escape
    /// the extraction directory.
    static func safeComponents(_ name: String) -> [String]? {
        guard !name.hasPrefix("/") else { return nil }
        let components = name.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains("") else {
            return nil
        }
        return components
    }

    // MARK: - Writing

    /// A file to store in an archive under `name` (forward-slash relative path).
    public struct Source {
        public let name: String
        public let url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// Writes a stored-entry archive of `sources` to `destination`, streaming
    /// each file in 1 MB chunks. Entries and the archive must stay under 4 GB.
    public static func write(_ sources: [Source], to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        struct CentralEntry {
            let nameBytes: [UInt8]
            let crc: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
        }
        var central: [CentralEntry] = []
        var position: UInt64 = 0

        for source in sources {
            guard safeComponents(source.name) != nil else {
                throw ArchiveError.unsafeEntryName(source.name)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize < UInt32.max else { throw ArchiveError.entryTooLarge(source.name) }
            let nameBytes = Array(source.name.utf8)

            // Stream the file once to compute the CRC, then once to copy.
            // (Two passes keep the header layout simple: no data descriptor.)
            let crc = try crc32(of: source.url)

            var local = Data()
            appendU32(&local, 0x0403_4B50)
            appendU16(&local, 20)                 // version needed
            appendU16(&local, 0)                  // flags
            appendU16(&local, 0)                  // method: stored
            appendU16(&local, 0); appendU16(&local, 0x21) // time/date (fixed)
            appendU32(&local, crc)
            appendU32(&local, UInt32(fileSize))
            appendU32(&local, UInt32(fileSize))
            appendU16(&local, UInt16(nameBytes.count))
            appendU16(&local, 0)                  // extra length
            local.append(contentsOf: nameBytes)
            try handle.write(contentsOf: local)

            let localHeaderOffset = position
            position += UInt64(local.count)

            let reader = try FileHandle(forReadingFrom: source.url)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                position += UInt64(chunk.count)
            }
            guard position < UInt32.max else { throw ArchiveError.archiveTooLarge }

            central.append(CentralEntry(
                nameBytes: nameBytes, crc: crc, size: UInt32(fileSize),
                localHeaderOffset: UInt32(localHeaderOffset)
            ))
        }

        let centralStart = position
        var directory = Data()
        for entry in central {
            appendU32(&directory, 0x0201_4B50)
            appendU16(&directory, 20); appendU16(&directory, 20)
            appendU16(&directory, 0); appendU16(&directory, 0)
            appendU16(&directory, 0); appendU16(&directory, 0x21)
            appendU32(&directory, entry.crc)
            appendU32(&directory, entry.size)
            appendU32(&directory, entry.size)
            appendU16(&directory, UInt16(entry.nameBytes.count))
            appendU16(&directory, 0); appendU16(&directory, 0)   // extra, comment
            appendU16(&directory, 0); appendU16(&directory, 0)   // disk, internal attrs
            appendU32(&directory, 0)                             // external attrs
            appendU32(&directory, entry.localHeaderOffset)
            directory.append(contentsOf: entry.nameBytes)
        }
        appendU32(&directory, 0x0605_4B50)
        appendU16(&directory, 0); appendU16(&directory, 0)
        appendU16(&directory, UInt16(central.count)); appendU16(&directory, UInt16(central.count))
        appendU32(&directory, UInt32(directory.count - 22 + 0)) // placeholder, fixed below
        appendU32(&directory, UInt32(centralStart))
        appendU16(&directory, 0)

        // Central directory size = bytes before the EOCD record.
        let centralSize = UInt32(directory.count - 22)
        directory.replaceSubrange(
            (directory.count - 22 + 12) ..< (directory.count - 22 + 16),
            with: withUnsafeBytes(of: centralSize.littleEndian) { Data($0) }
        )
        try handle.write(contentsOf: directory)
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var running: uLong = zlib.crc32(0, nil, 0)
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            running = chunk.withUnsafeBytes { buffer in
                zlib.crc32(running, buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
            }
        }
        return UInt32(running)
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Historical name; the USDZ unpacking path uses the shared reader.
public typealias USDZArchive = ZipArchive
