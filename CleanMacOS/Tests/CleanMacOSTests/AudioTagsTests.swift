import Foundation
import Testing
@testable import CleanMacOS

extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func be<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func ascii(_ text: String) { append(contentsOf: Array(text.utf8)) }
}

enum ID3Builder {
    static func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    static func frame(_ id: String, _ body: [UInt8], version: UInt8 = 4) -> [UInt8] {
        let size = version == 4 ? syncsafe(body.count) : withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init)
        return Array(id.utf8) + size + [0, 0] + body
    }

    static func text(_ value: String, encoding: UInt8 = 3) -> [UInt8] {
        switch encoding {
        case 0: [0] + value.unicodeScalars.map { UInt8($0.value) }
        case 1: [1, 0xFF, 0xFE] + value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        default: [3] + Array(value.utf8)
        }
    }

    static func tag(version: UInt8 = 4, frames: [[UInt8]]) -> Data {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: 10)
        return Data(Array("ID3".utf8) + [version, 0, 0] + syncsafe(body.count) + body)
    }
}

struct ID3TagTests {
    private let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]

    @Test func readsTextFramesAndTheCoverFromAVersion4Tag() {
        let picture: [UInt8] = [0] + Array("image/jpeg".utf8) + [0, 3] + Array("cover".utf8) + [0] + jpeg
        let data = ID3Builder.tag(frames: [
            ID3Builder.frame("TIT2", ID3Builder.text("Sóng")),
            ID3Builder.frame("TPE1", ID3Builder.text("Nghệ Sĩ", encoding: 1)),
            ID3Builder.frame("TALB", ID3Builder.text("Album", encoding: 0)),
            ID3Builder.frame("TPE2", ID3Builder.text("Various")),
            ID3Builder.frame("TRCK", ID3Builder.text("3/12")),
            ID3Builder.frame("TPOS", ID3Builder.text("2/2")),
            ID3Builder.frame("TDRC", ID3Builder.text("2024-05-01")),
            ID3Builder.frame("TCON", ID3Builder.text("Jazz")),
            ID3Builder.frame("APIC", picture),
        ])
        #expect(ID3Tag.parse(data) == TrackTags(title: "Sóng", artist: "Nghệ Sĩ", album: "Album", albumArtist: "Various",
                                                 trackNumber: 3, discNumber: 2, year: "2024", genre: "Jazz", artwork: Data(jpeg)))
    }

    @Test func readsAVersion3TagWithPlainFrameSizesAndUTF16Description() {
        let picture: [UInt8] = [1] + Array("image/jpeg".utf8) + [0, 3, 0xFF, 0xFE, 0x61, 0, 0, 0] + jpeg
        let data = ID3Builder.tag(version: 3, frames: [
            ID3Builder.frame("TIT2", ID3Builder.text("Old", encoding: 0), version: 3),
            ID3Builder.frame("TYER", ID3Builder.text("1999", encoding: 0), version: 3),
            ID3Builder.frame("APIC", picture, version: 3),
        ])
        let tags = ID3Tag.parse(data)
        #expect(tags?.title == "Old")
        #expect(tags?.year == "1999")
        #expect(tags?.artwork == Data(jpeg))
    }

    @Test func ignoresDataWithoutAnID3Header() {
        #expect(ID3Tag.parse(Data("RIFF0000WAVE".utf8)) == nil)
        #expect(ID3Tag.parse(Data()) == nil)
    }
}
