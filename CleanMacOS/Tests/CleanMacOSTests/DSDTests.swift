import Foundation
import Testing
@testable import CleanMacOS

enum DSDBuilder {
    static let blockSize = 4096

    static func dsf(channelBlocks: [[UInt8]], sampleCount: UInt64, rate: UInt32 = 2_822_400, tag: Data? = nil) -> Data {
        let channels = channelBlocks.count
        var payload = Data()
        let blocks = channelBlocks[0].count / blockSize
        for block in 0..<blocks {
            for channel in 0..<channels {
                payload.append(contentsOf: channelBlocks[channel][(block * blockSize)..<((block + 1) * blockSize)])
            }
        }
        let headerSize = 28 + 52 + 12
        let total = UInt64(headerSize + payload.count + (tag?.count ?? 0))
        var data = Data()
        data.ascii("DSD ")
        data.le(UInt64(28))
        data.le(total)
        data.le(UInt64(tag == nil ? 0 : headerSize + payload.count))
        data.ascii("fmt ")
        data.le(UInt64(52))
        data.le(UInt32(1))
        data.le(UInt32(0))
        data.le(UInt32(2))
        data.le(UInt32(channels))
        data.le(rate)
        data.le(UInt32(1))
        data.le(sampleCount)
        data.le(UInt32(blockSize))
        data.le(UInt32(0))
        data.ascii("data")
        data.le(UInt64(12 + payload.count))
        data.append(payload)
        if let tag { data.append(tag) }
        return data
    }

    static func dff(interleaved: [UInt8], channels: Int, rate: UInt32 = 2_822_400, compression: String = "DSD ", tag: Data? = nil) -> Data {
        var prop = Data()
        prop.ascii("SND ")
        prop.ascii("FS  ")
        prop.be(UInt64(4))
        prop.be(rate)
        prop.ascii("CHNL")
        prop.be(UInt64(2 + 4 * channels))
        prop.be(UInt16(channels))
        for index in 0..<channels { prop.ascii(index == 0 ? "SLFT" : "SRGT") }
        prop.ascii("CMPR")
        prop.be(UInt64(6))
        prop.ascii(compression)
        prop.append(contentsOf: [1, 0x41])
        var body = Data()
        body.ascii("DSD ")
        body.ascii("FVER")
        body.be(UInt64(4))
        body.be(UInt32(0x0105_0000))
        body.ascii("PROP")
        body.be(UInt64(prop.count))
        body.append(prop)
        body.ascii(compression == "DST " ? "DST " : "DSD ")
        body.be(UInt64(interleaved.count))
        body.append(contentsOf: interleaved)
        if interleaved.count % 2 == 1 { body.append(0) }
        if let tag {
            body.ascii("ID3 ")
            body.be(UInt64(tag.count))
            body.append(tag)
        }
        var data = Data()
        data.ascii("FRM8")
        data.be(UInt64(body.count))
        data.append(body)
        return data
    }

    static func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dsd-\(UUID()).\(ext)")
        try data.write(to: url)
        return url
    }

    static func sigmaDelta(frequency: Double, amplitude: Double, rate: Double, bytes: Int) -> [UInt8] {
        var first = 0.0
        var second = 0.0
        var output = -1.0
        var result = [UInt8](repeating: 0, count: bytes)
        for index in 0..<(bytes * 8) {
            let input = amplitude * sin(2 * .pi * frequency * Double(index) / rate)
            first += input - output
            second += first - output
            output = second >= 0 ? 1 : -1
            if output > 0 { result[index / 8] |= UInt8(0x80 >> (index % 8)) }
        }
        return result
    }
}

struct DSDFileTests {
    @Test func readsADSFFileAsMSBFirstBytesPerChannel() throws {
        let size = DSDBuilder.blockSize
        let left = [UInt8](repeating: 0x01, count: size) + [UInt8](repeating: 0x03, count: size)
        let right = [UInt8](repeating: 0x02, count: size) + [UInt8](repeating: 0x04, count: size)
        let url = try DSDBuilder.write(DSDBuilder.dsf(channelBlocks: [left, right], sampleCount: UInt64(size * 8 + 800 * 8)), ext: "dsf")
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try DSDReader(url: url)
        #expect(reader.info.sampleRate == 2_822_400)
        #expect(reader.info.channels == 2)
        #expect(reader.info.bytesPerChannel == Int64(size + 800))
        let first = try reader.read(maxBytes: 4100)
        #expect(first[0].count == 4100)
        #expect(first[0][0] == 0x80 && first[0][4095] == 0x80 && first[0][4096] == 0xC0)
        #expect(first[1][0] == 0x40 && first[1][4099] == 0x20)
        let rest = try reader.read(maxBytes: 10_000)
        #expect(rest[0].count == 796)
        #expect(try reader.read(maxBytes: 10)[0].isEmpty)
        try reader.seek(toByte: 4098)
        #expect(try reader.read(maxBytes: 2) == [[0xC0, 0xC0], [0x20, 0x20]])
    }

    @Test func readsADFFFileAndItsID3Tag() throws {
        let tag = ID3Builder.tag(frames: [ID3Builder.frame("TIT2", ID3Builder.text("Live"))])
        let url = try DSDBuilder.write(DSDBuilder.dff(interleaved: [0x11, 0xAA, 0x22, 0xBB, 0x33, 0xCC], channels: 2, rate: 5_644_800, tag: tag), ext: "dff")
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try DSDReader(url: url)
        #expect(reader.info.sampleRate == 5_644_800)
        #expect(reader.info.bytesPerChannel == 3)
        #expect(try reader.read(maxBytes: 8) == [[0x11, 0x22, 0x33], [0xAA, 0xBB, 0xCC]])
        #expect(DSDFile.tags(url: url, info: reader.info)?.title == "Live")
    }

    @Test func readsTheID3TagAtTheEndOfADSFFile() throws {
        let tag = ID3Builder.tag(frames: [ID3Builder.frame("TPE1", ID3Builder.text("Band"))])
        let block = [UInt8](repeating: 0x69, count: DSDBuilder.blockSize)
        let url = try DSDBuilder.write(DSDBuilder.dsf(channelBlocks: [block, block], sampleCount: 8 * 4096, tag: tag), ext: "dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try DSDFile.info(url: url)
        #expect(DSDFile.tags(url: url, info: info)?.artist == "Band")
    }

    @Test func refusesCompressedDSTAndNonDSDFiles() throws {
        let dst = try DSDBuilder.write(DSDBuilder.dff(interleaved: [0, 0], channels: 2, compression: "DST "), ext: "dff")
        let wav = try DSDBuilder.write(Data("RIFF0000WAVEfmt ".utf8), ext: "dsf")
        defer {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.removeItem(at: wav)
        }
        #expect(throws: DSDFileError.compressed) { try DSDFile.info(url: dst) }
        #expect(throws: DSDFileError.notDSD) { try DSDFile.info(url: wav) }
    }
}

struct DSDConversionTests {
    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    @Test func convertsADSD64SineToPCMAtTheSameLevel() {
        let bytes = DSDBuilder.sigmaDelta(frequency: 1000, amplitude: 0.5, rate: 2_822_400, bytes: 35_280)
        let decimator = DSDDecimator(dsdRate: 2_822_400, outputRate: 176_400, channels: 1)
        let output = decimator.process([bytes])[0]
        #expect(output.count == 17_640)
        let settled = output[2000...]
        #expect(abs(rms(settled) - 0.5 / 2.0.squareRoot()) < 0.01)
        let crossings = zip(settled, settled.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(Double(crossings) - 2 * 1000 * Double(settled.count) / 176_400) <= 2)
    }

    @Test func keepsDCAndSilenceAcrossChunks() {
        let decimator = DSDDecimator(dsdRate: 2_822_400, outputRate: 88_200, channels: 2)
        let first = decimator.process([[UInt8](repeating: 0xFF, count: 4096), [UInt8](repeating: 0x69, count: 4096)])
        let second = decimator.process([[UInt8](repeating: 0xFF, count: 4096), [UInt8](repeating: 0x69, count: 4096)])
        #expect(first[0].count == 1024)
        #expect(abs(second[0][0] - 1) < 0.001 && abs(second[0][1023] - 1) < 0.001)
        #expect((first[1] + second[1]).allSatisfy { abs($0) < 0.001 })
    }

    @Test func choosesTheDecimationFromTheRates() {
        #expect(DSDDecimator(dsdRate: 5_644_800, outputRate: 176_400, channels: 2).bytesPerOutput == 4)
        #expect(DSDDecimator(dsdRate: 2_822_400, outputRate: 352_800, channels: 2).bytesPerOutput == 1)
    }
}

struct DoPEncoderTests {
    private func word(_ value: Float) -> Int32 { Int32(value * 8_388_608) }

    @Test func packsTwoDSDBytesPerFrameWithAlternatingMarkers() {
        var encoder = DoPEncoder()
        let first = encoder.encode([[0x11, 0x22, 0x33, 0x44, 0x55, 0x66], [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]])
        #expect(first[0].map(word) == [0x05_1122, 0xFA_3344 - 0x100_0000, 0x05_5566])
        #expect(first[1].map(word) == [0x05_AABB, 0xFA_CCDD - 0x100_0000, 0x05_EEFF])
        let next = encoder.encode([[0x01, 0x02], [0x03, 0x04]])
        #expect(next[0].map(word) == [0xFA_0102 - 0x100_0000])
    }
}
