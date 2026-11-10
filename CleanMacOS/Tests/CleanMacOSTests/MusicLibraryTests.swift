import AVFoundation
import Foundation
import Testing
@testable import CleanMacOS

@MainActor
struct MusicLibraryTests {
    private let base: URL
    private let source: URL
    private let root: URL

    init() throws {
        base = try AudioFixture.directory()
        source = base.appendingPathComponent("Downloads/Kind of Blue", isDirectory: true)
        root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    private func makeLibrary() -> MusicLibrary {
        MusicLibrary(root: root, store: MusicLibraryStore(fileURL: base.appendingPathComponent("index.json")),
                     trash: { try FileManager.default.removeItem(at: $0) })
    }

    @Test func importCopiesLosslessFilesIntoArtistAlbumFoldersWithTheCover() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try AudioFixture.write(source.appendingPathComponent("So What.flac"), format: kAudioFormatFLAC, rate: 96000)
        try AudioFixture.write(source.appendingPathComponent("lossy.m4a"), format: kAudioFormatMPEG4AAC, rate: 44100)
        try Data([0xFF, 0xD8, 0xFF]).write(to: source.appendingPathComponent("Folder.JPG"))

        let library = makeLibrary()
        await library.importItems([source])
        let track = try #require(library.tracks.first)
        #expect(library.tracks.count == 1)
        #expect(track.id == "Unknown Artist/Kind of Blue/So What.flac")
        #expect(track.title == "So What" && track.album == "Kind of Blue")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.id).path))
        #expect(library.coverURL(for: track)?.lastPathComponent == "cover.jpg")
        #expect(library.notice?.contains("1") == true && library.notice?.contains("AAC") == true)

        await library.importItems([source.appendingPathComponent("So What.flac")])
        #expect(library.tracks.count == 1)

        let reopened = makeLibrary()
        await reopened.load()
        #expect(reopened.tracks.map(\.id) == [track.id])
    }

    @Test func loadPicksUpFilesAddedToTheFolderAndForgetsDeletedOnes() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let album = root.appendingPathComponent("Band/Live", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try AudioFixture.write(album.appendingPathComponent("one.wav"), format: kAudioFormatLinearPCM, rate: 48000)

        let library = makeLibrary()
        await library.load()
        #expect(library.tracks.map(\.id) == ["Band/Live/one.wav"])
        try FileManager.default.removeItem(at: album.appendingPathComponent("one.wav"))
        await library.load()
        #expect(library.tracks.isEmpty)
    }

    @Test func playlistsKeepTheirOrderAndLoseDeletedTracks() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["a", "b", "c"] {
            try AudioFixture.write(source.appendingPathComponent("\(name).flac"), format: kAudioFormatFLAC, rate: 48000, bits: 16)
        }
        let library = makeLibrary()
        await library.importItems([source])
        let ids = library.tracks.map(\.id).sorted()
        let playlist = library.createPlaylist(named: "Night", trackIDs: [ids[2], ids[0]])
        library.add([ids[1], ids[0]], toPlaylist: playlist)
        #expect(library.tracks(inPlaylist: playlist).map(\.id) == [ids[2], ids[0], ids[1]])
        library.movePlaylistTracks(playlist, from: IndexSet(integer: 2), to: 0)
        #expect(library.tracks(inPlaylist: playlist).map(\.id) == [ids[1], ids[2], ids[0]])
        library.renamePlaylist(playlist, to: "Late")
        library.moveToTrash([ids[2]])
        #expect(library.tracks.count == 2)
        #expect(library.playlists.first?.name == "Late")
        #expect(library.tracks(inPlaylist: playlist).map(\.id) == [ids[1], ids[0]])
        library.deletePlaylist(playlist)
        #expect(library.playlists.isEmpty)
    }

    @Test func destinationNamesAreSafeForTheFileSystem() {
        let url = MusicImporter.destination(root: URL(fileURLWithPath: "/m"), artist: "AC/DC", album: ".Live: 1991 ", fileName: "x.flac")
        #expect(url.path == "/m/AC-DC/Live- 1991/x.flac")
        #expect(MusicImporter.destination(root: URL(fileURLWithPath: "/m"), artist: " ", album: "", fileName: "y.dsf").path == "/m/Unknown Artist/Unknown Album/y.dsf")
    }
}
