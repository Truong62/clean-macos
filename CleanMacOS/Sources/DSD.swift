import Foundation

enum DSDFileError: Error, Equatable {
    case notDSD
    case compressed
    case damaged
}

struct DSDStreamInfo: Equatable, Sendable {
    enum Layout: Equatable, Sendable {
        case blocks(size: Int, lsbFirst: Bool)
        case interleavedBytes
    }

    let sampleRate: Int
    let channels: Int
    let bytesPerChannel: Int64
    let dataOffset: Int64
    let layout: Layout
    let tagOffset: Int64?
    let tagLength: Int64?

    var duration: Double { Double(bytesPerChannel * 8) / Double(sampleRate) }
}

enum DSDFile {
    static let extensions: Set<String> = ["dsf", "dff"]
    static let silence: UInt8 = 0x69
    private static let dsfHeaderSize = 92

    static func info(url: URL) throws -> DSDStreamInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let header = [UInt8](try handle.read(upToCount: dsfHeaderSize) ?? Data())
        switch header.count >= 4 ? String(decoding: header[0..<4], as: UTF8.self) : "" {
        case "DSD ": return try dsfInfo(header, fileSize: fileSize)
        case "FRM8": return try dffInfo(handle, fileSize: fileSize)
        default: throw DSDFileError.notDSD
        }
    }

    static func tags(url: URL, info: DSDStreamInfo) -> TrackTags? {
        guard let offset = info.tagOffset, offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let header = try? handle.read(upToCount: ID3Tag.headerSize), header.count == ID3Tag.headerSize else { return nil }
        let length = info.tagLength ?? Int64(ID3Tag.headerSize + ID3Tag.syncsafe([UInt8](header), at: 6))
        let body = (try? handle.read(upToCount: Int(max(0, length - Int64(ID3Tag.headerSize))))) ?? Data()
        return ID3Tag.parse(header + body)
    }

    private static func dsfInfo(_ header: [UInt8], fileSize: Int64) throws -> DSDStreamInfo {
        guard header.count == dsfHeaderSize, text(header, 28) == "fmt ", text(header, 80) == "data",
              little(header, 44, 4) == 0 else { throw DSDFileError.notDSD }
        let channels = Int(little(header, 52, 4))
        let rate = Int(little(header, 56, 4))
        let bits = little(header, 60, 4)
        let samples = Int64(little(header, 64, 8))
        let blockSize = Int(little(header, 72, 4))
        let dataLength = Int64(little(header, 84, 8)) - 12
        let tagOffset = Int64(little(header, 20, 8))
        guard channels > 0, rate > 0, blockSize > 0, bits == 1 || bits == 8, dataLength > 0 else { throw DSDFileError.damaged }
        let bytes = min((samples + 7) / 8, dataLength / Int64(channels))
        return DSDStreamInfo(sampleRate: rate, channels: channels, bytesPerChannel: bytes, dataOffset: Int64(dsfHeaderSize),
                             layout: .blocks(size: blockSize, lsbFirst: bits == 1),
                             tagOffset: tagOffset > 0 && tagOffset < fileSize ? tagOffset : nil, tagLength: nil)
    }

    private static func dffInfo(_ handle: FileHandle, fileSize: Int64) throws -> DSDStreamInfo {
        try handle.seek(toOffset: 12)
        guard String(decoding: try handle.read(upToCount: 4) ?? Data(), as: UTF8.self) == "DSD " else { throw DSDFileError.notDSD }
        var rate = 0
        var channels = 0
        var sound: (offset: Int64, length: Int64)?
        var tag: (offset: Int64, length: Int64)?
        var offset: Int64 = 16
        while offset + 12 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = [UInt8](try handle.read(upToCount: 12) ?? Data())
            guard chunk.count == 12 else { break }
            let id = text(chunk, 0)
            let length = Int64(big(chunk, 4, 8))
            let body = offset + 12
            switch id {
            case "PROP":
                let properties = [UInt8](try handle.read(upToCount: Int(min(length, 4096))) ?? Data())
                if try soundProperties(properties, rate: &rate, channels: &channels) { throw DSDFileError.compressed }
            case "DSD ": sound = (body, length)
            case "DST ": throw DSDFileError.compressed
            case "ID3 ": tag = (body, length)
            default: break
            }
            offset = body + length + length % 2
        }
        guard let sound, rate > 0, channels > 0 else { throw DSDFileError.damaged }
        return DSDStreamInfo(sampleRate: rate, channels: channels, bytesPerChannel: sound.length / Int64(channels),
                             dataOffset: sound.offset, layout: .interleavedBytes, tagOffset: tag?.offset, tagLength: tag?.length)
    }

    private static func soundProperties(_ bytes: [UInt8], rate: inout Int, channels: inout Int) throws -> Bool {
        guard bytes.count >= 4, text(bytes, 0) == "SND " else { throw DSDFileError.damaged }
        var isCompressed = false
        var offset = 4
        while offset + 12 <= bytes.count {
            let length = Int(big(bytes, offset + 4, 8))
            let body = offset + 12
            switch text(bytes, offset) {
            case "FS  ": rate = Int(big(bytes, body, 4))
            case "CHNL": channels = Int(big(bytes, body, 2))
            case "CMPR": isCompressed = text(bytes, body) != "DSD "
            default: break
            }
            offset = body + length + length % 2
        }
        return isCompressed
    }

    private static func text(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func little(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        guard offset + count <= bytes.count else { return 0 }
        return bytes[offset..<(offset + count)].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func big(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        guard offset + count <= bytes.count else { return 0 }
        return bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

final class DSDReader {
    static let reversedBits: [UInt8] = (0..<256).map { (value: Int) -> UInt8 in
        var reversed: UInt8 = 0
        for bit in 0..<8 where value & (1 << bit) != 0 { reversed |= UInt8(0x80 >> bit) }
        return reversed
    }

    let info: DSDStreamInfo
    private let handle: FileHandle
    private(set) var position: Int64 = 0

    init(url: URL) throws {
        info = try DSDFile.info(url: url)
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func seek(toByte byte: Int64) throws {
        position = min(max(0, byte), info.bytesPerChannel)
    }

    func read(maxBytes: Int) throws -> [[UInt8]] {
        let count = Int(min(Int64(maxBytes), info.bytesPerChannel - position))
        guard count > 0 else { return Array(repeating: [], count: info.channels) }
        let result: [[UInt8]]
        switch info.layout {
        case .interleavedBytes: result = try readInterleaved(count)
        case .blocks(let size, let lsbFirst): result = try readBlocks(count, size: size, lsbFirst: lsbFirst)
        }
        position += Int64(result[0].count)
        return result
    }

    private func readInterleaved(_ count: Int) throws -> [[UInt8]] {
        let channels = info.channels
        try handle.seek(toOffset: UInt64(info.dataOffset + position * Int64(channels)))
        let raw = [UInt8](try handle.read(upToCount: count * channels) ?? Data())
        let frames = raw.count / channels
        return (0..<channels).map { channel in stride(from: channel, to: frames * channels, by: channels).map { raw[$0] } }
    }

    private func readBlocks(_ count: Int, size: Int, lsbFirst: Bool) throws -> [[UInt8]] {
        let channels = info.channels
        var result = [[UInt8]](repeating: [], count: channels)
        var remaining = count
        var cursor = position
        while remaining > 0 {
            let block = cursor / Int64(size)
            let within = Int(cursor % Int64(size))
            let take = min(size - within, remaining)
            try handle.seek(toOffset: UInt64(info.dataOffset + block * Int64(size * channels)))
            let group = [UInt8](try handle.read(upToCount: size * channels) ?? Data())
            guard group.count >= (channels - 1) * size + within + take else { throw DSDFileError.damaged }
            for channel in 0..<channels {
                let slice = group[(channel * size + within)..<(channel * size + within + take)]
                result[channel] += lsbFirst ? slice.map { Self.reversedBits[Int($0)] } : Array(slice)
            }
            remaining -= take
            cursor += Int64(take)
        }
        return result
    }
}

final class DSDDecimator {
    static let passband = 30_000.0
    static let stopband = 80_000.0
    static let attenuation = 100.0

    let bytesPerOutput: Int
    private let tableCount: Int
    private let tables: [Float]
    private var history: [[UInt8]]

    init(dsdRate: Int, outputRate: Int, channels: Int) {
        bytesPerOutput = max(1, dsdRate / outputRate / 8)
        let taps = Self.taps(dsdRate: Double(dsdRate), outputRate: Double(outputRate))
        tableCount = taps.count / 8
        tables = Self.tables(taps)
        history = Array(repeating: Array(repeating: DSDFile.silence, count: tableCount - 1), count: channels)
    }

    func reset() {
        history = history.map { Array(repeating: DSDFile.silence, count: $0.count) }
    }

    func process(_ channelBytes: [[UInt8]]) -> [[Float]] {
        channelBytes.indices.map { convert(channel: $0, bytes: channelBytes[$0]) }
    }

    private func convert(channel: Int, bytes: [UInt8]) -> [Float] {
        let span = tableCount
        let step = bytesPerOutput
        let input = history[channel] + bytes
        let count = bytes.count / step
        var output = [Float](repeating: 0, count: count)
        tables.withUnsafeBufferPointer { table in
            input.withUnsafeBufferPointer { source in
                for frame in 0..<count {
                    let newest = span - 1 + (frame + 1) * step - 1
                    var sum: Float = 0
                    for back in 0..<span { sum += table[back &* 256 &+ Int(source[newest - back])] }
                    output[frame] = min(max(sum, -1), 1)
                }
            }
        }
        history[channel] = Array(input[(count * step)..<(count * step + span - 1)])
        return output
    }

    static func taps(dsdRate: Double, outputRate: Double) -> [Double] {
        let pass = min(passband, 0.45 * outputRate)
        let stop = min(stopband, outputRate - pass)
        let width = 2 * Double.pi * (stop - pass) / dsdRate
        let length = Int(((attenuation - 8) / (2.285 * width)).rounded(.up)) + 1
        let count = (length + 7) / 8 * 8
        let cutoff = (pass + stop) / 2 / dsdRate
        let beta = 0.1102 * (attenuation - 8.7)
        let center = Double(count - 1) / 2
        let window = besselI0(beta)
        let raw = (0..<count).map { index -> Double in
            let offset = Double(index) - center
            let ratio = 2 * Double(index) / Double(count - 1) - 1
            return sin(2 * .pi * cutoff * offset) / (.pi * offset) * besselI0(beta * (1 - ratio * ratio).squareRoot()) / window
        }
        let total = raw.reduce(0, +)
        return raw.map { $0 / total }
    }

    private static func tables(_ taps: [Double]) -> [Float] {
        let count = taps.count / 8
        var result = [Float](repeating: 0, count: count * 256)
        for group in 0..<count {
            for value in 0..<256 {
                let sum = (0..<8).reduce(0.0) { $0 + taps[group * 8 + $1] * ((value >> $1) & 1 == 1 ? 1 : -1) }
                result[group * 256 + value] = Float(sum)
            }
        }
        return result
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }
}

struct DoPEncoder {
    static let markers: (first: Int32, second: Int32) = (0x05, 0xFA)
    static let fullScale: Float = 8_388_608
    private var isSecondMarker = false

    mutating func encode(_ channelBytes: [[UInt8]]) -> [[Float]] {
        let frames = (channelBytes.first?.count ?? 0) / 2
        var output = channelBytes.map { _ in [Float](repeating: 0, count: frames) }
        for frame in 0..<frames {
            let marker = isSecondMarker ? Self.markers.second : Self.markers.first
            isSecondMarker.toggle()
            for channel in channelBytes.indices {
                let word = marker << 16 | Int32(channelBytes[channel][2 * frame]) << 8 | Int32(channelBytes[channel][2 * frame + 1])
                output[channel][frame] = Float(word >= 0x80_0000 ? word - 0x100_0000 : word) / Self.fullScale
            }
        }
        return output
    }
}
