import Foundation

struct MusicLibraryIndex: Codable, Equatable {
    var tracks: [Track] = []
    var playlists: [Playlist] = []
}

struct MusicLibraryStore: Sendable {
    let fileURL: URL

    func load() -> MusicLibraryIndex {
        guard let data = try? Data(contentsOf: fileURL) else { return MusicLibraryIndex() }
        return (try? JSONDecoder().decode(MusicLibraryIndex.self, from: data)) ?? MusicLibraryIndex()
    }

    func save(_ index: MusicLibraryIndex) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: fileURL, options: .atomic)
    }
}

struct MusicImporter: Sendable {
    enum Outcome: Sendable {
        case added(Track)
        case duplicate
        case rejected(String)
    }

    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"
    static let coverNames: Set<String> = ["cover", "folder", "front", "album", "artwork"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    let root: URL

    static func audioFiles(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return TrackInspector.isAudioFile(url) ? [url] : [] }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let files = (enumerator?.allObjects as? [URL]) ?? []
            return files.filter(TrackInspector.isAudioFile).sorted { $0.path < $1.path }
        }
    }

    static func destination(root: URL, artist: String, album: String, fileName: String) -> URL {
        root.appendingPathComponent(folderName(artist, fallback: unknownArtist), isDirectory: true)
            .appendingPathComponent(folderName(album, fallback: unknownAlbum), isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func coverFile(in folder: URL) -> URL? {
        ["cover.jpg", "cover.png"].map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func importFile(_ url: URL) async -> Outcome {
        if url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { return .duplicate }
        let inspected: InspectedTrack
        do {
            inspected = try await TrackInspector.inspect(url)
        } catch {
            return .rejected(Self.reason(error))
        }
        let size = Self.fileSize(url)
        let makeTrack = { (id: String) in
            Self.track(id: id, inspected: inspected, fallbackTitle: url.deletingPathExtension().lastPathComponent,
                       fallbackArtist: Self.unknownArtist, fallbackAlbum: url.deletingLastPathComponent().lastPathComponent, fileSize: size)
        }
        guard let destination = availableDestination(for: makeTrack(""), fileName: url.lastPathComponent, size: size) else { return .duplicate }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return .rejected("could not copy \(url.lastPathComponent)")
        }
        writeCover(near: url, artwork: inspected.tags.artwork, albumFolder: destination.deletingLastPathComponent())
        return .added(makeTrack(relativeID(destination)))
    }

    func scan(known: Set<String>) async -> (added: [Track], present: Set<String>) {
        var present = Set<String>()
        var added: [Track] = []
        for file in Self.audioFiles(in: [root]) where TrackInspector.lossyExtensions[file.pathExtension.lowercased()] == nil {
            let id = relativeID(file)
            present.insert(id)
            guard !known.contains(id), let inspected = try? await TrackInspector.inspect(file) else { continue }
            let folder = file.deletingLastPathComponent()
            added.append(Self.track(id: id, inspected: inspected, fallbackTitle: file.deletingPathExtension().lastPathComponent,
                                    fallbackArtist: folder.deletingLastPathComponent().lastPathComponent,
                                    fallbackAlbum: folder.lastPathComponent, fileSize: Self.fileSize(file)))
        }
        return (added, present)
    }

    func relativeID(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func availableDestination(for track: Track, fileName: String, size: Int64) -> URL? {
        let first = Self.destination(root: root, artist: track.albumArtist, album: track.album, fileName: fileName)
        let stem = first.deletingPathExtension().lastPathComponent
        var candidate = first
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            if Self.fileSize(candidate) == size { return nil }
            candidate = first.deletingLastPathComponent().appendingPathComponent("\(stem) \(number)").appendingPathExtension(first.pathExtension)
            number += 1
        }
        return candidate
    }

    private func writeCover(near source: URL, artwork: Data?, albumFolder: URL) {
        guard Self.coverFile(in: albumFolder) == nil else { return }
        if let artwork, !artwork.isEmpty {
            let isPNG = artwork.prefix(4).elementsEqual(Self.pngSignature)
            try? artwork.write(to: albumFolder.appendingPathComponent(isPNG ? "cover.png" : "cover.jpg"))
        } else if let image = Self.folderImage(near: source) {
            let name = image.pathExtension.lowercased() == "png" ? "cover.png" : "cover.jpg"
            try? FileManager.default.copyItem(at: image, to: albumFolder.appendingPathComponent(name))
        }
    }

    private static func folderImage(near file: URL) -> URL? {
        let folder = file.deletingLastPathComponent()
        let images = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return images.first { coverNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) } ?? images.first
    }

    private static func track(id: String, inspected: InspectedTrack, fallbackTitle: String, fallbackArtist: String,
                              fallbackAlbum: String, fileSize: Int64) -> Track {
        let tags = inspected.tags
        let artist = tags.artist ?? tags.albumArtist ?? fallbackArtist
        return Track(id: id, title: tags.title ?? fallbackTitle, artist: artist, album: tags.album ?? fallbackAlbum,
                     albumArtist: tags.albumArtist ?? artist, trackNumber: tags.trackNumber, discNumber: tags.discNumber,
                     year: tags.year, genre: tags.genre, duration: inspected.duration, format: inspected.format,
                     fileSize: fileSize, addedAt: Date())
    }

    private static func folderName(_ name: String, fallback: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func reason(_ error: Error) -> String {
        switch error as? TrackInspectionError {
        case .lossy(let codec): "\(codec) is lossy"
        case .unsupported(let ext): ".\(ext) is not supported"
        case .compressedDSD: "DST-compressed DSD is not supported"
        default: "a file could not be read"
        }
    }
}

struct ImportProgress: Equatable {
    let done: Int
    let total: Int
    let fileName: String
}

@MainActor
final class MusicLibrary: ObservableObject {
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("MacKit", isDirectory: true)
    }

    nonisolated static var legacyRoot: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Clean macOS", isDirectory: true)
    }

    nonisolated static var defaultIndex: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS", isDirectory: true).appendingPathComponent("music-library.json")
    }

    @Published private(set) var tracks: [Track] = [] {
        didSet {
            albums = Album.group(tracks)
            songs = albums.flatMap(\.tracks)
        }
    }
    @Published private(set) var albums: [Album] = []
    @Published private(set) var songs: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var isLoaded = false
    @Published var notice: String?

    let root: URL
    private let legacyRoot: URL?
    private let store: MusicLibraryStore
    private let trash: (URL) throws -> Void
    private var covers: [String: URL] = [:]
    private var importer: MusicImporter { MusicImporter(root: root) }

    init(root: URL = MusicLibrary.defaultRoot, legacyRoot: URL? = nil,
         store: MusicLibraryStore = MusicLibraryStore(fileURL: MusicLibrary.defaultIndex),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.root = root
        self.legacyRoot = legacyRoot
        self.store = store
        self.trash = trash
    }

    func load() async {
        moveLegacyFolder()
        let index = store.load()
        let scan = await importer.scan(known: Set(index.tracks.map(\.id)))
        tracks = index.tracks.filter { scan.present.contains($0.id) } + scan.added
        playlists = index.playlists
        prunePlaylists()
        refreshCovers()
        isLoaded = true
        if tracks.count != index.tracks.count || !scan.added.isEmpty || playlists != index.playlists { persist() }
    }

    func importItems(_ urls: [URL]) async {
        guard importProgress == nil else { return }
        let files = await Task.detached { MusicImporter.audioFiles(in: urls) }.value
        guard !files.isEmpty else {
            notice = "No audio files found."
            return
        }
        var added = 0
        var duplicates = 0
        var reasons: [String] = []
        for (index, file) in files.enumerated() {
            importProgress = ImportProgress(done: index, total: files.count, fileName: file.lastPathComponent)
            switch await importer.importFile(file) {
            case .added(let track):
                tracks.removeAll { $0.id == track.id }
                tracks.append(track)
                added += 1
            case .duplicate:
                duplicates += 1
            case .rejected(let reason):
                reasons.append(reason)
            }
        }
        importProgress = nil
        refreshCovers()
        persist()
        notice = Self.summary(added: added, duplicates: duplicates, reasons: reasons)
    }

    func url(for track: Track) -> URL {
        root.appendingPathComponent(track.id)
    }

    func coverURL(for track: Track) -> URL? {
        covers[Self.folderID(track.id)]
    }

    func moveToTrash(_ ids: Set<String>) {
        let folders = Set(ids.map(Self.folderID))
        for id in ids { try? trash(root.appendingPathComponent(id)) }
        tracks.removeAll { ids.contains($0.id) }
        let remaining = Set(tracks.map { Self.folderID($0.id) })
        for folder in folders.subtracting(remaining) { try? trash(root.appendingPathComponent(folder, isDirectory: true)) }
        prunePlaylists()
        refreshCovers()
        persist()
    }

    @discardableResult
    func createPlaylist(named name: String, trackIDs: [String] = []) -> Playlist.ID {
        let playlist = Playlist(id: UUID(), name: name, trackIDs: Self.unique(trackIDs))
        playlists.append(playlist)
        persist()
        return playlist.id
    }

    func renamePlaylist(_ id: Playlist.ID, to name: String) {
        updatePlaylist(id) { $0.name = name }
    }

    func deletePlaylist(_ id: Playlist.ID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func add(_ trackIDs: [String], toPlaylist id: Playlist.ID) {
        updatePlaylist(id) { $0.trackIDs = Self.unique($0.trackIDs + trackIDs) }
    }

    func removeFromPlaylist(_ id: Playlist.ID, at offsets: IndexSet) {
        updatePlaylist(id) { $0.trackIDs.remove(atOffsets: offsets) }
    }

    func movePlaylistTracks(_ id: Playlist.ID, from source: IndexSet, to destination: Int) {
        updatePlaylist(id) { $0.trackIDs.move(fromOffsets: source, toOffset: destination) }
    }

    func tracks(inPlaylist id: Playlist.ID) -> [Track] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    private func moveLegacyFolder() {
        let manager = FileManager.default
        guard let legacyRoot, manager.fileExists(atPath: legacyRoot.path), !manager.fileExists(atPath: root.path) else { return }
        try? manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.moveItem(at: legacyRoot, to: root)
    }

    private func updatePlaylist(_ id: Playlist.ID, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[index])
        persist()
    }

    private func prunePlaylists() {
        let valid = Set(tracks.map(\.id))
        playlists = playlists.map { Playlist(id: $0.id, name: $0.name, trackIDs: $0.trackIDs.filter(valid.contains)) }
    }

    private func refreshCovers() {
        covers = Dictionary(uniqueKeysWithValues: Set(tracks.map { Self.folderID($0.id) }).compactMap { folder in
            MusicImporter.coverFile(in: root.appendingPathComponent(folder, isDirectory: true)).map { (folder, $0) }
        })
    }

    private func persist() {
        do {
            try store.save(MusicLibraryIndex(tracks: tracks, playlists: playlists))
        } catch {
            notice = "Could not save the music library: \(error.localizedDescription)"
        }
    }

    private static func folderID(_ id: String) -> String {
        (id as NSString).deletingLastPathComponent
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func summary(added: Int, duplicates: Int, reasons: [String]) -> String {
        var parts = ["Added \(added) \(added == 1 ? "song" : "songs")."]
        if duplicates > 0 { parts.append("\(duplicates) already in your library.") }
        if !reasons.isEmpty {
            let unique = reasons.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            parts.append("Skipped \(reasons.count) \(reasons.count == 1 ? "file" : "files"): \(unique.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
