import AppKit
import SwiftUI

extension Track {
    var listNumber: Int { (discNumber ?? 1) * 1000 + (trackNumber ?? 0) }
    var qualityRank: Double { format.isDSD ? 1e9 + format.sampleRate : Double(format.bitDepth) * 1e7 + format.sampleRate }
}

struct MusicTrackTable: View {
    let tracks: [Track]
    var playlistID: Playlist.ID?

    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @State private var selection = Set<Track.ID>()
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var pendingTrash = Set<Track.ID>()
    @State private var isConfirmingTrash = false

    private var rows: [Track] { sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (track: Track) in
                if player.current?.id == track.id {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
            .width(16)
            TableColumn("#", value: \Track.listNumber) { (track: Track) in
                Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(28)
            TableColumn("Title", value: \Track.title)
            TableColumn("Artist", value: \Track.artist)
            TableColumn("Album", value: \Track.album)
            TableColumn("Quality", value: \Track.qualityRank) { (track: Track) in
                QualityBadge(format: track.format)
            }
            .width(min: 150, ideal: 180)
            TableColumn("Time", value: \Track.duration) { (track: Track) in
                Text(MusicFormat.time(track.duration)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(52)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            play(ids)
        }
        .alert("Move \(pendingTrash.count) \(pendingTrash.count == 1 ? "song" : "songs") to the Trash?", isPresented: $isConfirmingTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { library.moveToTrash(pendingTrash) }
        } message: {
            Text("The files are removed from ~/Music/MacKit. You can put them back from the Trash.")
        }
    }

    @ViewBuilder private func menu(for ids: Set<Track.ID>) -> some View {
        let chosen = rows.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Play") { play(ids) }
            Button("Play Next") { player.playNext(chosen) }
            Button("Add to Queue") { player.addToQueue(chosen) }
            Menu("Add to Playlist") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { library.add(chosen.map(\.id), toPlaylist: playlist.id) }
                }
                if !library.playlists.isEmpty { Divider() }
                Button("New Playlist") { library.createPlaylist(named: "Playlist \(library.playlists.count + 1)", trackIDs: chosen.map(\.id)) }
            }
            if let playlistID {
                Divider()
                if chosen.count == 1, sortOrder.isEmpty {
                    Button("Move Up") { move(chosen[0], in: playlistID, by: -1) }
                    Button("Move Down") { move(chosen[0], in: playlistID, by: 1) }
                }
                Button("Remove from Playlist") { remove(ids, from: playlistID) }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(library.url(for:))) }
            Button("Move to Trash…", role: .destructive) {
                pendingTrash = ids
                isConfirmingTrash = true
            }
        }
    }

    private func play(_ ids: Set<Track.ID>) {
        guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }
        player.play(rows, startAt: index)
    }

    private func move(_ track: Track, in playlistID: Playlist.ID, by step: Int) {
        guard let ids = library.playlists.first(where: { $0.id == playlistID })?.trackIDs,
              let index = ids.firstIndex(of: track.id), ids.indices.contains(index + step) else { return }
        library.movePlaylistTracks(playlistID, from: IndexSet(integer: index), to: step > 0 ? index + 2 : index - 1)
    }

    private func remove(_ ids: Set<Track.ID>, from playlistID: Playlist.ID) {
        guard let trackIDs = library.playlists.first(where: { $0.id == playlistID })?.trackIDs else { return }
        library.removeFromPlaylist(playlistID, at: IndexSet(trackIDs.indices.filter { ids.contains(trackIDs[$0]) }))
    }
}

struct QualityBadge: View {
    static let gold = LinearGradient(colors: [Color(red: 0.99, green: 0.83, blue: 0.40), Color(red: 0.93, green: 0.62, blue: 0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    let format: TrackFormat
    var showsResolution = true

    var body: some View {
        HStack(spacing: 6) {
            Text(format.qualityLabel)
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(format.isHiRes ? Color.black.opacity(0.75) : Color.secondary)
                .background(format.isHiRes ? AnyShapeStyle(Self.gold) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 4))
            if showsResolution {
                Text("\(format.codec) · \(format.resolution)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("\(format.codec), \(format.resolution), \(format.channels) channels")
    }
}
