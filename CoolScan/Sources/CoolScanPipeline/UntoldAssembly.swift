import CryptoKit
import Foundation
import UntoldEngine

/// Chunk/string-table/file assembly for the cooked `.untold` container.
/// Ported from the engine's NativeFormatTests fixture builders — uses only
/// public AssetFormat API (`UntoldBinaryWriter`, `UntoldBinaryEncodable`).
enum UntoldAssembly {
    typealias ChunkPayload = (type: UntoldChunkType, data: Data, elementCount: UInt32)

    static func makeStringTable(_ strings: [String]) -> (data: Data, offsets: [String: UInt32]) {
        let writer = UntoldBinaryWriter()
        var offsets: [String: UInt32] = [:]
        for string in strings where offsets[string] == nil {
            offsets[string] = UInt32(writer.count)
            writer.writeNullTerminatedUTF8(string)
        }
        return (writer.data, offsets)
    }

    static func encodeChunk(_ records: [some UntoldBinaryEncodable]) -> Data {
        let writer = UntoldBinaryWriter()
        for record in records {
            record.encode(to: writer)
        }
        return writer.data
    }

    static func buildChunkPayloads(
        stringTableData: Data,
        entities: [UntoldEntityRecordV1],
        meshes: [UntoldMeshRecordV1],
        materials: [UntoldMaterialRecordV1],
        textures: [UntoldTextureRefRecordV1],
        vertexData: Data,
        indexData: Data
    ) -> [ChunkPayload] {
        [
            (.stringTable, stringTableData, 0),
            (.entityTable, encodeChunk(entities), UInt32(entities.count)),
            (.meshTable, encodeChunk(meshes), UInt32(meshes.count)),
            (.materialTable, encodeChunk(materials), UInt32(materials.count)),
            (.textureTable, encodeChunk(textures), UInt32(textures.count)),
            (.vertexData, vertexData, 0),
            (.indexData, indexData, 0),
        ]
    }

    /// SHA-256 of all chunk payloads concatenated in ascending chunk-type
    /// order with no padding — the same rule the engine exporter uses.
    static func computeContentHash(for chunkPayloads: [ChunkPayload]) -> [UInt8] {
        let sorted = chunkPayloads.sorted { $0.type.rawValue < $1.type.rawValue }
        let hashInput = sorted.reduce(Data()) { $0 + $1.data }
        return Array(SHA256.hash(data: hashInput))
    }

    static func buildFileData(
        header: UntoldFileHeaderV1,
        chunkPayloads: [ChunkPayload]
    ) -> Data {
        var header = header
        header.chunkCount = UInt32(chunkPayloads.count)
        header.contentHash = computeContentHash(for: chunkPayloads)

        let headerWriter = UntoldBinaryWriter()
        header.encode(to: headerWriter)
        let headerData = headerWriter.data

        let chunkTableSize = MemoryLayout<UInt32>.size * 2 +
            MemoryLayout<UInt64>.size * 3 +
            MemoryLayout<UInt32>.size * 2
        let chunkTableBytes = chunkTableSize * chunkPayloads.count

        var runningOffset = headerData.count + chunkTableBytes
        var chunkEntries: [UntoldChunkEntryV1] = []
        chunkEntries.reserveCapacity(chunkPayloads.count)

        for chunk in chunkPayloads {
            runningOffset = align(runningOffset, to: Int(UntoldFormat.fileAlignment))
            chunkEntries.append(
                UntoldChunkEntryV1(
                    chunkType: chunk.type,
                    compressionType: .none,
                    fileOffset: UInt64(runningOffset),
                    compressedSize: UInt64(chunk.data.count),
                    uncompressedSize: UInt64(chunk.data.count),
                    elementCount: chunk.elementCount
                )
            )
            runningOffset += chunk.data.count
        }

        let fileWriter = UntoldBinaryWriter()
        header.encode(to: fileWriter)
        for entry in chunkEntries {
            entry.encode(to: fileWriter)
        }
        for chunk in chunkPayloads {
            fileWriter.align(to: Int(UntoldFormat.fileAlignment))
            fileWriter.writeData(chunk.data)
        }
        return fileWriter.data
    }

    static func align(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }
}
