import Foundation

struct TrackFormat: Codable, Hashable, Sendable {
    static let dsdBaseRate = 2_822_400.0
    static let cdSampleRate = 48_000.0
    static let hiResBitDepth = 24

    let codec: String
    let sampleRate: Double
    let bitDepth: Int
    let channels: Int

    var isDSD: Bool { bitDepth == 1 }
    var isHiRes: Bool { isDSD || bitDepth >= Self.hiResBitDepth || sampleRate > Self.cdSampleRate }
    var qualityLabel: String { isHiRes ? "Hi-Res" : "Lossless" }

    var resolution: String {
        if isDSD {
            let multiple = Int((sampleRate / 44_100).rounded())
            let megahertz = (sampleRate / 100_000).rounded(.down) / 10
            return "DSD\(multiple) / \(String(format: "%g", megahertz)) MHz"
        }
        return "\(bitDepth)-bit / \(Self.kilohertz(sampleRate)) kHz"
    }

    static func kilohertz(_ rate: Double) -> String {
        String(format: "%g", (rate / 100).rounded() / 10)
    }
}

struct Track: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var discNumber: Int?
    var year: String?
    var genre: String?
    var duration: Double
    var format: TrackFormat
    var fileSize: Int64
    var addedAt: Date
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [String]
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    var year: String? { tracks.compactMap(\.year).first }
    var bestFormat: TrackFormat? { tracks.map(\.format).max { ($0.isDSD ? 1 : 0, $0.bitDepth, $0.sampleRate) < ($1.isDSD ? 1 : 0, $1.bitDepth, $1.sampleRate) } }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }

    static func group(_ tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks) { "\($0.albumArtist.lowercased())\u{1F}\($0.album.lowercased())" }
            .map { key, tracks in
                let sorted = tracks.sorted(by: Track.albumOrder)
                return Album(id: key, title: sorted[0].album, artist: sorted[0].albumArtist, tracks: sorted)
            }
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }
}

extension Track {
    static func albumOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        (lhs.discNumber ?? 1, lhs.trackNumber ?? Int.max, lhs.title.lowercased()) < (rhs.discNumber ?? 1, rhs.trackNumber ?? Int.max, rhs.title.lowercased())
    }
}
