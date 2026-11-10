import Foundation

struct IslandSong: Hashable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

struct IslandLyricLine: Equatable, Identifiable {
    var id: Int
    var time: Double
    var text: String
}

struct IslandLyrics: Equatable {
    enum Failure: Error { case tooLarge, invalidText }
    var lines: [IslandLyricLine]
    var plain: String

    init(data: Data) throws {
        guard data.count <= 128 * 1024 else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidText }
        self.init(text: text)
    }

    init(text: String) {
        let expression = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#)
        var parsed: [(Double, String)] = []
        var untimed: [String] = []
        var offset = 0.0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("[offset:"), line.hasSuffix("]"),
               let value = Double(line.dropFirst(8).dropLast()), value.isFinite {
                offset = value / 1000
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            let matches = expression?.matches(in: line, range: range) ?? []
            if matches.isEmpty {
                if !line.hasPrefix("[") && !line.isEmpty { untimed.append(line) }
                continue
            }
            let body = expression?.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces) ?? ""
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: line), let secondsRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minutesRange]), let seconds = Double(line[secondsRange]), seconds < 60 else { continue }
                parsed.append((minutes * 60 + seconds, body))
            }
        }
        lines = parsed.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .enumerated().map { IslandLyricLine(id: $0.offset, time: max(0, $0.element.element.0 + offset), text: $0.element.element.1) }
        plain = untimed.joined(separator: "\n")
    }

    func active(position: Double, offset: Double) -> Int? {
        guard position.isFinite, offset.isFinite else { return nil }
        return lines.last { $0.time <= position - offset }?.id
    }

    func nextDelay(position: Double, offset: Double, rate: Double) -> Double? {
        guard position.isFinite, offset.isFinite, rate.isFinite, rate > 0,
              let line = lines.first(where: { $0.time > position - offset }) else { return nil }
        return (line.time + offset - position) / rate
    }

    static func offset(_ value: Double) -> Double {
        value.isFinite ? min(10, max(-10, (value * 4).rounded() / 4)) : 0
    }
}

struct IslandLyricCandidate: Decodable, Equatable {
    var trackName: String
    var artistName: String
    var albumName: String?
    var duration: Double
    var plainLyrics: String?
    var syncedLyrics: String?

    var lyrics: IslandLyrics { IslandLyrics(text: syncedLyrics.flatMap { $0.isEmpty ? nil : $0 } ?? plainLyrics ?? "") }
}

enum IslandLyricMatching {
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func title(_ text: String) -> String {
        let folded = folded(text)
        let bracketed = folded.replacingOccurrences(of: #"[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return bracketed.replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func best(_ candidates: [IslandLyricCandidate], song: IslandSong) -> IslandLyricCandidate? {
        candidates.filter { $0.duration.isFinite && song.duration.isFinite && song.duration > 0 && abs($0.duration - song.duration) <= 2 && title($0.trackName) == title(song.title) }
            .enumerated().max { lhs, rhs in
                let left = rank(lhs.element, song: song)
                let right = rank(rhs.element, song: song)
                return left == right ? lhs.offset > rhs.offset : left < right
            }?.element
    }

    static func rank(_ candidate: IslandLyricCandidate, song: IslandSong) -> Int {
        (folded(candidate.albumName ?? "") == folded(song.album) && !song.album.isEmpty ? 8 : 0)
        + (folded(candidate.artistName) == folded(song.artist) ? 4 : 0)
        + (folded(candidate.trackName) == folded(song.title) ? 2 : 0)
        + (!candidate.lyrics.lines.isEmpty ? 1 : 0)
    }

    static func queries(_ song: IslandSong) -> [[URLQueryItem]] {
        var result = [[URLQueryItem(name: "track_name", value: song.title), URLQueryItem(name: "artist_name", value: song.artist)]]
        let cleanTitle = title(song.title)
        let cleanArtist = title(song.artist)
        if cleanTitle != folded(song.title) { result.append([URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: song.artist)]) }
        if cleanArtist != folded(song.artist) { result.append([URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: cleanArtist)]) }
        return Array(result.prefix(3)) + [[URLQueryItem(name: "q", value: song.title)]]
    }
}

final class IslandLyricsTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func get(host: String, path: String, query: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("MacKit/1.0 (macOS lyrics lookup)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

actor IslandLyricsLookup {
    typealias Request = @Sendable (String, String, [URLQueryItem]) async throws -> Data?
    private let request: Request
    private var aliasReservation = Date.distantPast

    init(request: @escaping Request = { host, path, query in try await IslandLyricsTransport().get(host: host, path: path, query: query) }) {
        self.request = request
    }

    func lookup(_ song: IslandSong) async throws -> IslandLyrics? {
        guard song.duration.isFinite, song.duration > 0, !song.title.isEmpty else { return nil }
        let exact = [URLQueryItem(name: "track_name", value: song.title), URLQueryItem(name: "artist_name", value: song.artist),
                     URLQueryItem(name: "album_name", value: song.album), URLQueryItem(name: "duration", value: String(song.duration))]
        var hadResults = false
        if let data = try await request("lrclib.net", "/api/get", exact) {
            let candidate = try JSONDecoder().decode(IslandLyricCandidate.self, from: data)
            hadResults = true
            if let match = IslandLyricMatching.best([candidate], song: song), !match.lyrics.lines.isEmpty || !match.lyrics.plain.isEmpty { return match.lyrics }
        }
        for query in IslandLyricMatching.queries(song) {
            try Task.checkCancellation()
            let candidates = try await search(query)
            hadResults = hadResults || !candidates.isEmpty
            if let match = IslandLyricMatching.best(candidates, song: song), !match.lyrics.lines.isEmpty || !match.lyrics.plain.isEmpty { return match.lyrics }
        }
        guard !hadResults else { return nil }
        let reserved = max(Date(), aliasReservation.addingTimeInterval(1.05))
        aliasReservation = reserved
        let delay = reserved.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        let escaped = song.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let data = try await request("musicbrainz.org", "/ws/2/artist", [URLQueryItem(name: "query", value: "artist:\"\(escaped)\""), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "3")]) else { return nil }
        struct Alias: Decodable { var name: String }
        struct Artist: Decodable { var name: String; var aliases: [Alias]? }
        struct Artists: Decodable { var artists: [Artist] }
        let artists = try JSONDecoder().decode(Artists.self, from: data).artists
        let aliases = artists.filter { IslandLyricMatching.folded($0.name) == IslandLyricMatching.folded(song.artist) }.flatMap { $0.aliases ?? [] }
        var seen = Set([IslandLyricMatching.folded(song.artist)])
        for alias in aliases.filter({ seen.insert(IslandLyricMatching.folded($0.name)).inserted }).prefix(3) {
            try Task.checkCancellation()
            let candidates = try await search([URLQueryItem(name: "track_name", value: song.title), URLQueryItem(name: "artist_name", value: alias.name)])
            if let match = IslandLyricMatching.best(candidates, song: song), !match.lyrics.lines.isEmpty || !match.lyrics.plain.isEmpty { return match.lyrics }
        }
        return nil
    }

    private func search(_ query: [URLQueryItem]) async throws -> [IslandLyricCandidate] {
        guard let data = try await request("lrclib.net", "/api/search", query) else { return [] }
        return try JSONDecoder().decode([IslandLyricCandidate].self, from: data)
    }
}

@MainActor
final class IslandLyricsController: ObservableObject {
    enum Status: Equatable { case idle, loading, ready(IslandLyrics), noMatch, failed, offline }
    @Published private(set) var status = Status.idle
    @Published private(set) var active: Int?
    @Published private(set) var offset = 0.0
    private var song: IslandSong?
    private var sample: IslandMediaSample?
    private var imported: [IslandSong: IslandLyrics] = [:]
    private var offsets: [IslandSong: Double] = [:]
    private var cache: [IslandSong: (Status, Date)] = [:]
    private let lookup: IslandLyricsLookup
    private var request: Task<Void, Never>?
    private var boundary: Task<Void, Never>?
    private var generation = 0
    private var online = false
    private var visible = false

    init(lookup: IslandLyricsLookup = IslandLyricsLookup()) { self.lookup = lookup }

    func update(song: IslandSong?, sample: IslandMediaSample?, visible: Bool, online: Bool) {
        let reload = self.song != song || self.online != online || self.visible != visible
        self.song = song
        self.sample = sample
        self.online = online
        self.visible = visible
        let nextOffset = song.flatMap { offsets[$0] } ?? 0
        if offset != nextOffset { offset = nextOffset }
        if reload { load() }
        schedule()
    }

    func close() {
        visible = false
        generation += 1
        request?.cancel()
        request = nil
        boundary?.cancel()
        boundary = nil
    }

    func retry() { if let song { cache.removeValue(forKey: song) }; load() }

    func importLyrics(_ data: Data) throws {
        guard let song, visible else { return }
        let lyrics = try IslandLyrics(data: data)
        guard !lyrics.lines.isEmpty || !lyrics.plain.isEmpty else { throw IslandLyrics.Failure.invalidText }
        imported[song] = lyrics
        load()
    }

    func adjustOffset(_ delta: Double) {
        guard let song else { return }
        offset = IslandLyrics.offset(offset + delta)
        offsets[song] = offset
        schedule()
    }

    private func load() {
        generation += 1
        request?.cancel()
        request = nil
        guard visible, let song else { status = .idle; return }
        if let lyrics = imported[song] { status = .ready(lyrics); return }
        guard online else { status = .offline; return }
        if let (value, expires) = cache[song], expires > Date() { status = value; return }
        cache = cache.filter { $0.value.1 > Date() }
        status = .loading
        let token = generation
        request = Task { [weak self, lookup] in
            let result: Status
            do { result = try await lookup.lookup(song).map(Status.ready) ?? .noMatch }
            catch { if Task.isCancelled { return }; result = .failed }
            guard let self, !Task.isCancelled, token == self.generation, self.visible, self.song == song else { return }
            self.status = result
            let ttl: Double
            switch result { case .failed: ttl = 15; case .noMatch: ttl = 60; default: ttl = 3600 }
            if self.cache.count >= 32 { self.cache.removeAll() }
            self.cache[song] = (result, Date().addingTimeInterval(ttl))
            self.schedule()
        }
    }

    private func schedule() {
        boundary?.cancel()
        boundary = nil
        guard visible, case .ready(let lyrics) = status, let sample else { active = nil; return }
        let position = sample.position(at: Date())
        let nextActive = lyrics.active(position: position, offset: offset)
        if active != nextActive { active = nextActive }
        guard sample.playing, let delay = lyrics.nextDelay(position: position, offset: offset, rate: sample.rate) else { return }
        boundary = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, delay))) } catch { return }
            self?.schedule()
        }
    }
}
