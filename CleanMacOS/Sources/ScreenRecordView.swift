import SwiftUI

struct ScreenRecordView: View {
    @EnvironmentObject var recorder: ScreenRecorder
    @AppStorage(ScreenRecording.systemAudioKey) private var systemAudio = true
    @AppStorage(ScreenRecording.microphoneKey) private var microphone = false
    @AppStorage(ScreenRecording.framesPerSecondKey) private var framesPerSecond = 30
    @AppStorage(ScreenRecording.resolutionKey) private var resolution = ScreenRecording.Resolution.full
    @AppStorage(ScreenRecording.folderKey) private var folderPath = ""

    private var options: RecordingOptions {
        RecordingOptions(systemAudio: systemAudio, microphone: microphone, framesPerSecond: framesPerSecond,
                         resolution: resolution, folder: ScreenRecording.folder(atPath: folderPath))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if ScreenRecorder.isSupported {
                    PreviewCanvas(layer: recorder.preview, phase: recorder.phase)
                    recordCard
                    RecordingSettingsCard(framesPerSecond: $framesPerSecond, resolution: $resolution, folderPath: $folderPath)
                        .disabled(recorder.phase != .idle)
                    if let url = recorder.lastRecording { LastRecordingRow(url: url) }
                    AgentSetupCard()
                } else {
                    Label("Screen recording needs macOS 15 or later.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }
                if let message = recorder.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screen Record").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Record a screen, a window or an app with sound.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var recordCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                SoundToggle(icon: "speaker.wave.2.fill", title: "System audio", detail: "Sound from apps and videos",
                            color: .blue, isOn: $systemAudio)
                SoundToggle(icon: "mic.fill", title: "Microphone", detail: "Your voice",
                            color: .orange, isOn: $microphone)
            }
            .disabled(recorder.phase != .idle)
            OutputPreview(options: options)
            recordButton
        }
        .padding(20)
        .glassCard()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.phase {
        case .idle:
            Button {
                Task { await recorder.chooseSource(options) }
            } label: {
                Label("Choose Source", systemImage: "rectangle.dashed").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .choosing:
            Label("Choose a screen, window or app to record…", systemImage: "rectangle.dashed")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
        case .previewing:
            HStack(spacing: 10) {
                Button {
                    recorder.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Change Source") { Task { await recorder.changeSource() } }
                Button("Cancel") { Task { await recorder.stop() } }
            }
            .controlSize(.large)
        case .recording(let since):
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(ScreenRecording.elapsed(context.date.timeIntervalSince(since)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Spacer()
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        case .saving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
    }
}

private struct PreviewCanvas: View {
    let layer: CALayer
    let phase: ScreenRecorder.Phase

    private var hint: String? {
        switch phase {
        case .idle: "Choose a screen, window or app to see it here"
        case .choosing: "Waiting for you to pick a source…"
        case .saving: "Saving…"
        case .previewing, .recording: nil
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            LayerView(layer: layer)
            if let hint {
                Label(hint, systemImage: "display")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            badge.padding(12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: 460)
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .previewing:
            Text("PREVIEW").badgeStyle(.gray)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Label("REC \(ScreenRecording.elapsed(context.date.timeIntervalSince(since)))", systemImage: "circle.fill")
                    .badgeStyle(.red)
            }
        default:
            EmptyView()
        }
    }
}

private extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.85), in: Capsule())
    }
}

private struct LayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> HostView { HostView(hosted: layer) }
    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private let hosted: CALayer

        init(hosted: CALayer) {
            self.hosted = hosted
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(hosted)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}

private struct SoundToggle: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OutputPreview: View {
    let options: RecordingOptions

    private var sound: String {
        switch (options.systemAudio, options.microphone) {
        case (true, true): "system audio + mic"
        case (true, false): "system audio"
        case (false, true): "mic"
        case (false, false): "no sound"
        }
    }

    var body: some View {
        let limit = options.resolution.limit
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(.secondary)
            Text(verbatim: "Up to \(Int(limit.width))×\(Int(limit.height)) · \(options.framesPerSecond) fps · \(sound) · MP4 → \(options.folder.lastPathComponent)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

private struct RecordingSettingsCard: View {
    @Binding var framesPerSecond: Int
    @Binding var resolution: ScreenRecording.Resolution
    @Binding var folderPath: String

    private var folder: URL { ScreenRecording.folder(atPath: folderPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SETTINGS").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            row("Resolution", icon: "rectangle.on.rectangle", color: .purple) {
                Picker("", selection: $resolution) {
                    ForEach(ScreenRecording.Resolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            row("Frame rate", icon: "speedometer", color: .teal) {
                Picker("", selection: $framesPerSecond) {
                    ForEach(ScreenRecording.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            row("Save to", icon: "folder.fill", color: .blue) {
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !folderPath.isEmpty {
                    Button("Reset") { folderPath = "" }
                }
                Button("Change…", action: chooseFolder)
            }
        }
        .padding(20)
        .glassCard()
    }

    private func row(_ title: String, icon: String, color: Color, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
    }
}

private struct AgentSetupCard: View {
    @State private var isCopied = false
    @State private var signInURL = ""
    @State private var isSigningIn = false

    private var command: String {
        "claude mcp add screen-record -s user -- \"\(Bundle.main.executablePath ?? "")\" \(RecordingMCPServer.flag)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use with AI agents").font(.system(size: 13, weight: .semibold))
                    Text("Let Claude Code record demo videos in the background, with captions, arrows, clicks and smooth zoom. Web apps run in a hidden browser, so your screen is never touched. Run this once in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                Button(isCopied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    isCopied = true
                }
            }
            HStack(spacing: 8) {
                TextField("Sign in once for web demos, e.g. https://localhost:3000/login", text: $signInURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button(isSigningIn ? "Waiting…" : "Sign In…") {
                    isSigningIn = true
                    Task {
                        _ = try? await SignInBrowser.run(url: signInURL, browser: nil, timeout: SignInBrowser.maxTimeout)
                        isSigningIn = false
                    }
                }
                .disabled(isSigningIn || !BrowserURL.isAllowed(signInURL))
            }
        }
        .padding(16)
        .glassCard()
    }
}

private struct LastRecordingRow: View {
    let url: URL

    private var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.fill")
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .padding(14)
        .glassCard()
    }
}
