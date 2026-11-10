import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IslandMusicPanel { case lyrics, queue }

struct IslandMusicView: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var player: MusicPlayer
    @ObservedObject var remote: IslandMediaRemote
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text(player.current?.title ?? remote.sample?.title ?? "Nothing playing").font(.headline).lineLimit(2)
                Text(player.current?.artist ?? remote.sample?.artist ?? "Play music in MacKit or another player").foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 28) {
                    Button { controller.skipMusic(next: false) } label: { Image(systemName: "backward.end.fill") }
                    Button { controller.toggleMusic() } label: { Image(systemName: controller.musicSample?.playing == true ? "pause.fill" : "play.fill") }
                    Button { controller.skipMusic(next: true) } label: { Image(systemName: "forward.end.fill") }
                }.buttonStyle(.borderless).font(.title2).disabled(controller.song == nil)
                if let sample = controller.musicSample, sample.duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        HStack {
                            Text(IslandTimer.clock(sample.position(at: timeline.date), countdown: false)).monospacedDigit()
                            if player.current != nil {
                                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...sample.duration)
                            } else { ProgressView(value: sample.position(at: timeline.date), total: sample.duration) }
                            Text(IslandTimer.clock(sample.duration, countdown: false)).monospacedDigit()
                        }.font(.caption)
                    }
                }
            }.offset(x: controller.musicNudge).animation(.easeOut(duration: 0.15), value: controller.musicNudge)
            HStack {
                if controller.settings.lyrics {
                    Button { controller.musicPanel = controller.musicPanel == .lyrics ? nil : .lyrics } label: { Label("Lyrics", systemImage: "quote.bubble") }
                }
                if controller.settings.queue {
                    Button { controller.musicPanel = controller.musicPanel == .queue ? nil : .queue } label: { Label("Up Next", systemImage: "list.bullet") }
                }
                Spacer()
                if player.current != nil {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(player.queue.isShuffled ? .orange : .white) }.help("Shuffle MacKit queue")
                    Menu {
                        Button("System Default") { player.selectOutput(nil) }
                        ForEach(player.devices) { device in Button(device.name) { player.selectOutput(device.uid) } }
                    } label: { Image(systemName: "hifispeaker") }.onAppear { player.refreshDevices() }
                }
            }
            if controller.settings.musicVolume { IslandVolume(sound: controller.context.sound) }
            if controller.musicPanel == .lyrics {
                VStack(spacing: 8) {
                    IslandLyricsView(lyrics: controller.lyrics)
                    HStack {
                        Button("Import LRC…") { importing = true }
                        if controller.settings.onlineLyrics { Button("Retry") { controller.lyrics.retry() } }
                        Spacer()
                        Button { controller.lyrics.adjustOffset(-0.25) } label: { Image(systemName: "minus") }
                        IslandLyricsOffset(lyrics: controller.lyrics)
                        Button { controller.lyrics.adjustOffset(0.25) } label: { Image(systemName: "plus") }
                    }.font(.caption)
                    if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
                }.frame(height: 216)
            }
            if controller.musicPanel == .queue { queue.frame(height: 216) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 128 * 1024 + 1) ?? Data()
                try controller.lyrics.importLyrics(data)
                importError = nil
            } catch { importError = "Choose a UTF-8 LRC file of at most 128 KiB." }
        }
    }

    @ViewBuilder private var queue: some View {
        if player.current != nil {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let track = player.current { queueRow(track, current: true) }
                    ForEach(Array(player.queue.upcoming.prefix(20).enumerated()), id: \.offset) { index, track in
                        Button { player.jump(toUpcoming: index) } label: { queueRow(track, current: false) }.buttonStyle(.plain)
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("This player's queue is unavailable in Island.").foregroundStyle(.secondary)
                Text("The MacKit music queue is available here.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
    }

    private func queueRow(_ track: Track, current: Bool) -> some View {
        HStack {
            Image(systemName: current ? "speaker.wave.2" : "music.note").frame(width: 34, height: 34).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(track.title).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if current { Text("Playing").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct IslandLyricsOffset: View {
    @ObservedObject var lyrics: IslandLyricsController
    var body: some View { Text(String(format: "%+.2f s", lyrics.offset)).monospacedDigit().frame(width: 64) }
}

struct IslandLyricsView: View {
    @ObservedObject var lyrics: IslandLyricsController
    var body: some View {
        Group {
            switch lyrics.status {
            case .idle: Text("Play a song to show lyrics.")
            case .offline: Text("Import an LRC file, or enable online lyrics in Island settings.")
            case .loading: ProgressView("Finding lyrics…")
            case .noMatch: Text("No matching lyrics. Retry or import an LRC file.")
            case .failed: Text("Lyrics lookup failed. Retry or import an LRC file.")
            case .ready(let document):
                if document.lines.isEmpty {
                    ScrollView { Text(document.plain).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(document.lines) { line in
                                    Text(line.text.isEmpty ? "♪" : line.text).foregroundStyle(.white.opacity(lyrics.active == line.id ? 1 : 0.35))
                                        .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                                }
                            }.padding(.vertical, 60)
                        }
                        .onChange(of: lyrics.active) { _, value in
                            if let value { withAnimation(.easeInOut(duration: 0.28)) { reader.scrollTo(value, anchor: .center) } }
                        }
                        .onAppear { if let value = lyrics.active { reader.scrollTo(value, anchor: .center) } }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
