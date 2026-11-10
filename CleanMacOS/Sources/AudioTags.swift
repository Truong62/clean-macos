import Foundation

struct TrackTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: String?
    var genre: String?
    var artwork: Data?

    static func leadingNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    static func year(_ text: String?) -> String? {
        guard let text, text.count >= 4, Int(text.prefix(4)) != nil else { return nil }
        return String(text.prefix(4))
    }
}

enum ID3Tag {
    static let headerSize = 10
    private static let textFrames: [String: WritableKeyPath<TrackTags, String?>] = [
        "TIT2": \.title, "TPE1": \.artist, "TALB": \.album, "TPE2": \.albumArtist, "TCON": \.genre,
    ]

    static func parse(_ data: Data) -> TrackTags? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              bytes[3] == 3 || bytes[3] == 4 else { return nil }
        let version = bytes[3]
        let end = min(bytes.count, headerSize + syncsafe(bytes, at: 6))
        var offset = headerSize
        if bytes[5] & 0x40 != 0, offset + 4 <= end {
            offset += version == 4 ? syncsafe(bytes, at: offset) : 4 + bigEndian(bytes, at: offset)
        }
        var tags = TrackTags()
        while offset + headerSize <= end, bytes[offset] != 0 {
            let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = version == 4 ? syncsafe(bytes, at: offset + 4) : bigEndian(bytes, at: offset + 4)
            let flags = bytes[offset + 9]
            let bodyStart = offset + headerSize + (version == 4 && flags & 0x01 != 0 ? 4 : 0)
            let bodyEnd = offset + headerSize + size
            guard size > 0, bodyEnd <= end, bodyStart <= bodyEnd else { break }
            let isPacked = version == 4 ? flags & 0x0C != 0 : flags & 0xC0 != 0
            if !isPacked { apply(id: id, body: Array(bytes[bodyStart..<bodyEnd]), to: &tags) }
            offset = bodyEnd
        }
        return tags
    }

    private static func apply(id: String, body: [UInt8], to tags: inout TrackTags) {
        if let key = textFrames[id] {
            tags[keyPath: key] = text(body)
        } else if id == "TRCK" {
            tags.trackNumber = TrackTags.leadingNumber(text(body))
        } else if id == "TPOS" {
            tags.discNumber = TrackTags.leadingNumber(text(body))
        } else if id == "TDRC" || id == "TYER" {
            tags.year = TrackTags.year(text(body))
        } else if id == "APIC", tags.artwork == nil {
            tags.artwork = picture(body)
        }
    }

    private static func text(_ body: [UInt8]) -> String? {
        guard let encoding = body.first else { return nil }
        let value = decode(Array(body.dropFirst()), encoding: encoding)
        let first = value.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init)
        return first?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    private static func picture(_ body: [UInt8]) -> Data? {
        guard let encoding = body.first, let mimeEnd = body.dropFirst().firstIndex(of: 0) else { return nil }
        let descriptionStart = mimeEnd + 2
        guard descriptionStart < body.count else { return nil }
        let wide = encoding == 1 || encoding == 2
        var index = descriptionStart
        while index < body.count {
            if wide {
                if index + 1 < body.count, body[index] == 0, body[index + 1] == 0 { return Data(body[(index + 2)...]) }
                index += 2
            } else {
                if body[index] == 0 { return Data(body[(index + 1)...]) }
                index += 1
            }
        }
        return nil
    }

    private static func decode(_ bytes: [UInt8], encoding: UInt8) -> String {
        switch encoding {
        case 0: String(bytes.map { Character(Unicode.Scalar($0)) })
        case 1: String(data: Data(bytes), encoding: .utf16) ?? ""
        case 2: String(data: Data(bytes), encoding: .utf16BigEndian) ?? ""
        default: String(decoding: bytes, as: UTF8.self)
        }
    }

    static func syncsafe(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
