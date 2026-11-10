import AppKit
import ImageIO
import SwiftUI

enum ArtworkLoader {
    private static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func thumbnail(_ url: URL?, pixels: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let key = "\(url.path)#\(Int(pixels))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: .zero)
        cache.setObject(result, forKey: key)
        return result
    }
}

struct ArtworkView: View {
    let url: URL?
    var pixels: CGFloat = 400
    var cornerRadius: CGFloat = 10
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.pink.opacity(0.55), .purple.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: url) { image = await ArtworkLoader.thumbnail(url, pixels: pixels) }
    }
}

struct AlbumGridView: View {
    let albums: [Album]
    let open: (Album) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(albums) { album in
                    AlbumCard(album: album) { open(album) }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 22)
    }
}

private struct AlbumCard: View {
    let album: Album
    let open: () -> Void
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkView(url: library.coverURL(for: album.tracks[0]))
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.12), radius: isHovered ? 12 : 6, y: 4)
                .overlay(alignment: .bottomTrailing) {
                    if isHovered {
                        Button { player.play(album.tracks, startAt: 0) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(MusicFormat.accent))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Play \(album.title)")
                    }
                }
            Text(album.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let format = album.bestFormat { QualityBadge(format: format, showsResolution: false) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering } }
        .pointerCursor()
    }
}

struct AlbumDetailView: View {
    let album: Album
    let back: () -> Void
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 18) {
                ArtworkView(url: library.coverURL(for: album.tracks[0]), pixels: 700, cornerRadius: 14)
                    .frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: back) { Label("Albums", systemImage: "chevron.left").font(.callout) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .pointerCursor()
                    Text(album.title).font(.title.weight(.bold)).lineLimit(2)
                    Text(album.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                    if let format = album.bestFormat { QualityBadge(format: format) }
                    HStack(spacing: 10) {
                        Button { player.play(album.tracks, startAt: 0) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)
                        Button { player.play(album.tracks.shuffled(), startAt: 0) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            MusicTrackTable(tracks: album.tracks)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 22)
    }

    private var details: String {
        [album.year, "\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")", MusicFormat.length(album.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct PlaylistsView: View {
    let search: String
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @State private var selectedID: Playlist.ID?
    @State private var renamingID: Playlist.ID?
    @State private var newName = ""

    private var selected: Playlist? { library.playlists.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 14) {
            sidebar
            if let selected {
                detail(selected)
            } else {
                placeholder
            }
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let renamingID, !name.isEmpty { library.renamePlaylist(renamingID, to: name) }
            }
        }
        .onAppear { if selectedID == nil { selectedID = library.playlists.first?.id } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PLAYLISTS").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.tertiary)
                Spacer()
                Button(action: create) { Image(systemName: "plus").font(.callout.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("New Playlist")
            }
            List(selection: $selectedID) {
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Rename…") { startRename(playlist) }
                            Button("Delete Playlist", role: .destructive) { library.deletePlaylist(playlist.id) }
                        }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(14)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .glassCard(cornerRadius: 22)
    }

    private func detail(_ playlist: Playlist) -> some View {
        let tracks = library.tracks(inPlaylist: playlist.id).filter { track in
            search.isEmpty || [track.title, track.artist, track.album].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.title3.weight(.bold))
                    Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(MusicFormat.length(tracks.reduce(0) { $0 + $1.duration }))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.play(tracks, startAt: 0) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(tracks.isEmpty)
                Button { player.play(tracks.shuffled(), startAt: 0) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)
            }
            MusicTrackTable(tracks: tracks, playlistID: playlist.id)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 22)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(library.playlists.isEmpty ? "No playlists yet" : "Choose a playlist").font(.title3.weight(.semibold))
            Text("Click + to create one, then right-click songs and choose Add to Playlist.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 22)
    }

    private func create() {
        let id = library.createPlaylist(named: "Playlist \(library.playlists.count + 1)")
        selectedID = id
        if let playlist = library.playlists.first(where: { $0.id == id }) { startRename(playlist) }
    }

    private func startRename(_ playlist: Playlist) {
        newName = playlist.name
        renamingID = playlist.id
    }
}
