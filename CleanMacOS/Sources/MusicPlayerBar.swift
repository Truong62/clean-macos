import SwiftUI

struct MusicPlayerBar: View {
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @State private var isShowingQueue = false

    private var isDoP: Bool { player.output?.kind == .dop }

    var body: some View {
        HStack(spacing: 18) {
            nowPlaying.frame(minWidth: 160, maxWidth: 270, alignment: .leading)
            VStack(spacing: 4) {
                transport
                PlaybackScrubber()
            }
            .frame(minWidth: 200, maxWidth: .infinity)
            HStack(spacing: 12) {
                OutputMenu()
                Button { isShowingQueue.toggle() } label: { Image(systemName: "list.bullet").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Up Next")
                    .popover(isPresented: $isShowingQueue, arrowEdge: .top) { QueuePopover() }
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .disabled(isDoP)
                    .help(isDoP ? "DSD over DoP must stay at 100%. Set the volume on the DAC." : "App volume \(Int((player.volume * 100).rounded()))%")
            }
            .frame(minWidth: 190, maxWidth: 270, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            ArtworkView(url: player.current.flatMap(library.coverURL(for:)), pixels: 140, cornerRadius: 7)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Not Playing").font(.callout.weight(.semibold)).lineLimit(1)
                Text(player.current.map { "\($0.artist) — \($0.album)" } ?? "Pick a song to start").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                qualityLine
            }
        }
    }

    @ViewBuilder private var qualityLine: some View {
        if let track = player.current {
            if let output = player.output {
                let quality = OutputQuality.evaluate(track: track.format, status: output, volume: player.volume)
                Label(quality.title, systemImage: icon(quality.level))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(quality.level))
                    .lineLimit(1)
                    .help("\(quality.detail)\nFile: \(track.format.codec) \(track.format.resolution)\nOutput: \(output.deviceName), \(TrackFormat.kilohertz(output.device.sampleRate)) kHz \(output.device.isFloat ? "32-bit float" : "\(output.device.bitDepth)-bit")")
            } else {
                QualityBadge(format: track.format)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle").foregroundStyle(player.queue.isShuffled ? Color.pink : Color.secondary)
            }
            .help(player.queue.isShuffled ? "Shuffle is on" : "Shuffle is off")
            Button(action: player.previous) { Image(systemName: "backward.fill") }
                .help("Previous")
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(MusicFormat.accent))
                    .shadow(color: .pink.opacity(0.35), radius: 5, y: 2)
            }
            .disabled(player.current == nil)
            .help(player.isPlaying ? "Pause" : "Play")
            Button(action: player.next) { Image(systemName: "forward.fill") }
                .help("Next")
            Button(action: player.cycleRepeat) {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.queue.repeatMode == .off ? Color.secondary : Color.pink)
            }
            .help("Repeat: \(player.queue.repeatMode.rawValue)")
        }
        .font(.system(size: 14, weight: .semibold))
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func icon(_ level: OutputQuality.Level) -> String {
        switch level {
        case .bitPerfect: "checkmark.seal.fill"
        case .altered: "slider.horizontal.3"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ level: OutputQuality.Level) -> Color {
        switch level {
        case .bitPerfect: .green
        case .altered: .orange
        case .degraded: .red
        }
    }
}

struct PlaybackScrubber: View {
    static let refresh: TimeInterval = 0.5
    static let seekHold: TimeInterval = 1

    @EnvironmentObject var player: MusicPlayer
    @State private var dragValue: Double?
    @State private var heldValue: (value: Double, until: Date)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refresh)) { context in
            let duration = player.current?.duration ?? 0
            let held = heldValue.flatMap { context.date < $0.until ? $0.value : nil }
            let shown = dragValue ?? held ?? min(player.currentTime, duration)
            HStack(spacing: 8) {
                Text(MusicFormat.time(shown))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Slider(value: Binding(get: { shown }, set: { dragValue = $0 }), in: 0...max(duration, 0.1)) { editing in
                    guard !editing, let value = dragValue else { return }
                    player.seek(to: value)
                    heldValue = (value, Date().addingTimeInterval(Self.seekHold))
                    dragValue = nil
                }
                .controlSize(.mini)
                .disabled(player.current == nil)
                Text(MusicFormat.time(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
            }
        }
    }
}

struct OutputMenu: View {
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        Menu {
            Button { player.selectOutput(nil) } label: { choice("System Default", isOn: player.outputUID == nil) }
            Divider()
            ForEach(player.devices) { device in
                Button { player.selectOutput(device.uid) } label: { choice(device.name, isOn: player.outputUID == device.uid) }
            }
            if let device = player.selectedDevice, device.canCarryDoP {
                Divider()
                Toggle("\(device.name) plays DSD over DoP", isOn: Binding(get: { player.dopDevices.contains(device.uid) },
                                                                        set: { player.setDoP($0, for: device.uid) }))
            }
        } label: {
            Image(systemName: "hifispeaker.2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output: \(player.selectedDevice?.name ?? "System Default")")
    }

    @ViewBuilder private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct QueuePopover: View {
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").font(.headline)
            if player.queue.upcoming.isEmpty {
                Text("Nothing is queued after this song.").font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(player.queue.upcoming.enumerated()), id: \.offset) { offset, track in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(MusicFormat.time(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { player.removeFromQueue(at: offset) } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(.plain)
                                .help("Remove from Up Next")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.jump(toUpcoming: offset) }
                    }
                }
                .frame(height: 300)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
