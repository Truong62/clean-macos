import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var agentRecording: AgentRecordingIndicator
    @ObservedObject var music: MusicPlayer
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var clipboard: ClipboardViewModel
    @ObservedObject var shelf: ShelfController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ControlsStrip()
            Divider()
            if case .recording(let since) = recorder.phase {
                recordingRow(since: since)
                Divider()
            }
            if agentRecording.isRecording {
                agentRecordingRow
                Divider()
            }
            if let session = keepAwake.session {
                keepAwakeRow(session)
                Divider()
            }
            if let track = music.current {
                nowPlayingRow(track)
                Divider()
            }
            if shelf.settings.isEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill").foregroundStyle(.cyan)
                    Text("Shelf · \(shelf.items.count) \(shelf.items.count == 1 ? "item" : "items")").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(shelf.isOpen ? "Close" : "Open") { shelf.toggle() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
            if clipboard.options.showsInMenuPanel && !clipboard.items.isEmpty {
                ClipboardMenuCard(clipboard: clipboard)
                Divider()
            }
            systemStats
        }
        .frame(width: 300)
        .onAppear { monitor.popoverDidOpen() }
        .onDisappear { monitor.popoverDidClose() }
    }

    private func openMain() {
        let popover = NSApp.keyWindow
        openWindow(id: "main")
        DispatchQueue.main.async {
            MainWindowController.show()
            if popover?.title != MainWindowController.title { popover?.close() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill").foregroundStyle(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("MacKit").font(.system(size: 13, weight: .semibold))
            Spacer()
            MenuIconButton(systemImage: "macwindow", help: "Open MacKit") { openMain() }
            MenuIconButton(systemImage: "power", help: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help(monitor.osVersion)
    }

    private func recordingRow(since: Date) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("Recording \(ScreenRecording.elapsed(context.date.timeIntervalSince(since)))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            Spacer()
            Button("Stop") { Task { await recorder.stop() } }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var agentRecordingRow: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("An AI agent is recording the screen").font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func keepAwakeRow(_ session: KeepAwakeSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(session.remaining(now: context.date).map { "Awake · \(KeepAwakeSession.countdown($0)) left" } ?? "Awake until you stop it")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            Spacer()
            Button("Stop") { keepAwake.stop() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            MenuIconButton(systemImage: "backward.fill", help: "Previous") { music.previous() }
            MenuIconButton(systemImage: music.isPlaying ? "pause.fill" : "play.fill", help: music.isPlaying ? "Pause" : "Play") {
                music.togglePlayPause()
            }
            MenuIconButton(systemImage: "forward.fill", help: "Next") { music.next() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var systemStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MenuStatColumn(title: "CPU", value: String(format: "%.0f%%", monitor.cpuUsage),
                               percent: monitor.cpuUsage / 100, color: .blue)
                MenuStatColumn(title: "RAM", value: monitor.memUsedStr, percent: monitor.memPercent / 100, color: .orange)
                MenuStatColumn(title: "Disk", value: monitor.diskUsedStr, percent: monitor.diskPercent / 100, color: .green)
            }
            Text("\(monitor.cpuName) · \(monitor.diskFreeStr) free · up \(monitor.uptime)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct MenuIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(isHovered ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

struct MenuStatColumn: View {
    let title: String
    let value: String
    let percent: Double
    let color: Color

    private var barColor: Color {
        if percent > 0.9 { return .red }
        if percent > 0.75 { return .orange }
        return color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(barColor)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(barColor.gradient).frame(width: geo.size.width * min(max(percent, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}
