import AppKit
import SwiftUI

enum MusicSection: String, CaseIterable, Identifiable {
    case songs, albums, playlists

    static let storageKey = "music.section"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .songs: "music.note.list"
        case .albums: "square.stack.fill"
        case .playlists: "list.bullet.rectangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .songs: .pink
        case .albums: .purple
        case .playlists: .orange
        }
    }
}

enum MusicFormat {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    static let accent = LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct MusicSidebarSection: View {
    @AppStorage(MusicSection.storageKey) private var section = MusicSection.songs

    var body: some View {
        VStack(spacing: 2) {
            ForEach(MusicSection.allCases) { item in
                SidebarSubRow(label: item.title, icon: item.icon, color: item.color, isSelected: section == item) {
                    section = item
                }
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 4)
    }
}

struct MusicView: View {
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @AppStorage(MusicSection.storageKey) private var section = MusicSection.songs
    @State private var search = ""
    @State private var openAlbumID: Album.ID?
    @State private var isDropTargeted = false

    private var filteredTracks: [Track] {
        guard !search.isEmpty else { return library.songs }
        return library.songs.filter { track in
            [track.title, track.artist, track.album].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var filteredAlbums: [Album] {
        guard !search.isEmpty else { return library.albums }
        return library.albums.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                header
                if library.isLoaded && library.tracks.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            MusicPlayerBar()
        }
        .background(background)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importItems(urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { dropOverlay } }
        .task {
            if !library.isLoaded { await library.load() }
            player.refreshDevices()
        }
        .onChange(of: section) { openAlbumID = nil }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .songs:
            MusicTrackTable(tracks: filteredTracks)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(cornerRadius: 22)
        case .albums:
            if let album = library.albums.first(where: { $0.id == openAlbumID }) {
                AlbumDetailView(album: album) { openAlbumID = nil }
            } else {
                AlbumGridView(albums: filteredAlbums) { openAlbumID = $0.id }
            }
        case .playlists:
            PlaylistsView(search: search)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(MusicFormat.accent)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "music.note").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: .pink.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Music").font(.title2).fontWeight(.bold)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: showImportPanel) {
                    Label("Import", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(MusicFormat.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(library.importProgress != nil)
                .help("Copy lossless music into ~/Music/Clean macOS")
            }
            HStack(spacing: 12) {
                searchField
                if let progress = library.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 140)
                    Text("Importing \(progress.done + 1) of \(progress.total)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let notice = player.message ?? library.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        player.message = nil
                        library.notice = nil
                    } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain)
                        .pointerCursor()
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
    }

    private var subtitle: String {
        let hiRes = library.tracks.filter(\.format.isHiRes).count
        return "\(library.tracks.count) songs · \(library.albums.count) albums · \(hiRes) Hi-Res"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("Search songs, artists, albums", text: $search)
                .textFieldStyle(.plain).font(.callout)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.callout)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 22)
                .fill(MusicFormat.accent)
                .frame(width: 88, height: 88)
                .overlay(Image(systemName: "hifispeaker.2.fill").font(.system(size: 34)).foregroundStyle(.white))
                .shadow(color: .pink.opacity(0.3), radius: 12, y: 6)
            Text("Your hi-res library is empty").font(.title3).fontWeight(.semibold)
            Text("Drop FLAC, ALAC, WAV, AIFF, DSF or DFF files here, or click Import.\nThey are copied into ~/Music/Clean macOS and play at their native resolution.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: showImportPanel) { Label("Import Music", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .glassCard(cornerRadius: 22)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .foregroundStyle(.pink)
            .background(RoundedRectangle(cornerRadius: 22).fill(.pink.opacity(0.06)))
            .overlay(Label("Drop to import", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold)).foregroundStyle(.pink))
            .padding(12)
            .allowsHitTesting(false)
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack {
                Spacer()
                appPastelGradient
                    .frame(height: 320)
                    .blur(radius: 90)
                    .opacity(0.35)
            }
            .ignoresSafeArea()
        }
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose lossless music files or folders. They are copied into ~/Music/Clean macOS."
        let library = library
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await library.importItems(urls) }
        }
    }
}
