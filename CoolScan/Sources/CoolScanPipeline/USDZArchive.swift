import Compression
import Foundation

/// Minimal ZIP reader for USDZ packages.
///
/// ModelIO resolves texture references inside a `.usdz` unreliably —
/// Object Capture output keeps its textures under a `0/` folder and the
/// resolver logs `Failed to resolve reference @0/…png@`, leaving the model
/// untextured. Unpacking the archive to disk and loading the root layer from
/// there makes the relative references plain file paths. USDZ entries are
/// stored uncompressed by spec; deflate is handled anyway for robustness.
enum USDZArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: Error, CustomStringConvertible {
        case notAZip
        case truncated
        case unsupportedCompression(UInt16)
        case inflateFailed(String)

        var description: String {
            switch self {
            case .notAZip: "Not a ZIP/USDZ archive"
            case .truncated: "Archive is truncated"
            case let .unsupportedCompression(method): "Unsupported ZIP compression method \(method)"
            case let .inflateFailed(name): "Failed to inflate \(name)"
            }
        }
    }

    /// Extracts every regular file into `directory`, preserving relative
    /// paths, and returns the entries in archive order (USDZ puts the root
    /// layer first).
    @discardableResult
    static func extract(_ archiveURL: URL, into directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let entries = try readEntries(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        for entry in entries {
            // Never write outside the target directory.
            let components = entry.name.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains("..") else { continue }
            let url = components.dropLast().reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
                .appendingPathComponent(components.last!)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try entry.data.write(to: url)
            written.append(url)
        }
        return written
    }

    static func readEntries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ArchiveError.notAZip }

        // End of central directory: scan backwards for the signature.
        var eocd = -1
        var i = bytes.count - 22
        let minIndex = max(0, bytes.count - 22 - 65535)
        while i >= minIndex {
            if u32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.notAZip }

        let entryCount = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0 ..< entryCount {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else {
                throw ArchiveError.truncated
            }
            let method = u16(bytes, offset + 10)
            let compressedSize = Int(u32(bytes, offset + 20))
            let uncompressedSize = Int(u32(bytes, offset + 24))
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let localHeaderOffset = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw ArchiveError.truncated }
            let name = String(decoding: bytes[(offset + 46) ..< (offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // Directories carry no payload.
            if name.hasSuffix("/") { continue }

            guard localHeaderOffset + 30 <= bytes.count,
                  u32(bytes, localHeaderOffset) == 0x0403_4B50
            else { throw ArchiveError.truncated }
            let localNameLength = Int(u16(bytes, localHeaderOffset + 26))
            let localExtraLength = Int(u16(bytes, localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else { throw ArchiveError.truncated }
            let payload = Data(bytes[dataStart ..< dataEnd])

            switch method {
            case 0:
                entries.append(Entry(name: name, data: payload))
            case 8:
                entries.append(Entry(name: name, data: try inflate(payload, expectedSize: uncompressedSize, name: name)))
            default:
                throw ArchiveError.unsupportedCompression(method)
            }
        }
        return entries
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

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
