import Foundation

struct VideoGIFChunk {
    let header: Data
    let records: Data

    init(data: Data, includesLoop: Bool) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, String(bytes: bytes.prefix(6), encoding: .ascii)?.hasPrefix("GIF8") == true else { throw RecordingError.failed("Invalid GIF chunk.") }
        var offset = 13
        let globalSize = bytes[10] & 0x80 == 0 ? 0 : 3 * (1 << (Int(bytes[10] & 7) + 1))
        guard offset + globalSize <= bytes.count else { throw RecordingError.failed("Truncated GIF palette.") }
        let palette = Array(bytes[offset..<(offset + globalSize)])
        offset += globalSize
        var header = Array(bytes.prefix(13))
        header[10] &= 0x7F
        header[11] = 0
        self.header = Data(header)
        var records: [UInt8] = []
        func subblocks(_ start: Int) throws -> Int {
            var cursor = start
            while cursor < bytes.count {
                let count = Int(bytes[cursor])
                cursor += 1
                guard cursor + count <= bytes.count else { throw RecordingError.failed("Truncated GIF data.") }
                cursor += count
                if count == 0 { return cursor }
            }
            throw RecordingError.failed("Unterminated GIF data.")
        }
        var foundTrailer = false
        while offset < bytes.count {
            let start = offset
            switch bytes[offset] {
            case 0x21:
                guard offset + 2 < bytes.count else { throw RecordingError.failed("Truncated GIF extension.") }
                let label = bytes[offset + 1]
                offset = try subblocks(offset + 2)
                if label != 0xFF || includesLoop { records += bytes[start..<offset] }
            case 0x2C:
                guard offset + 10 < bytes.count else { throw RecordingError.failed("Truncated GIF frame.") }
                var descriptor = Array(bytes[offset..<(offset + 10)])
                offset += 10
                if descriptor[9] & 0x80 != 0 {
                    let size = 3 * (1 << (Int(descriptor[9] & 7) + 1))
                    guard offset + size < bytes.count else { throw RecordingError.failed("Truncated GIF local palette.") }
                    records += descriptor
                    records += bytes[offset..<(offset + size)]
                    offset += size
                } else {
                    guard !palette.isEmpty else { throw RecordingError.failed("GIF frame has no palette.") }
                    descriptor[9] = descriptor[9] & 0x78 | 0x80 | bytes[10] & 7
                    records += descriptor
                    records += palette
                }
                let compressedStart = offset
                offset = try subblocks(offset + 1)
                records += bytes[compressedStart..<offset]
            case 0x3B:
                foundTrailer = true
                offset = bytes.count
            default: throw RecordingError.failed("Unknown GIF record.")
            }
        }
        guard foundTrailer else { throw RecordingError.failed("GIF chunk has no trailer.") }
        self.records = Data(records)
    }
}
