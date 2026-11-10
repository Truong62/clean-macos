import SwiftUI
import KeyboardShortcuts

struct ScreenRecordView: View {
    @EnvironmentObject var recorder: ScreenRecorder
    @EnvironmentObject var studio: RecordingStudio
    @EnvironmentObject var editors: VideoEditors

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "record.circle", title: "Screen Record", subtitle: "Record a display, window or area. Everything stays on your Mac.", colors: [.red, .pink])
                CardSection(title: "Recording", icon: "record.circle") {
                    HStack {
                        Button(studio.title, action: studio.trigger).buttonStyle(.borderedProminent)
                        if recorder.isRecording {
                            Button(studio.paused ? "Resume" : "Pause", action: studio.togglePause)
                            Text(ScreenRecording.elapsed(studio.elapsed)).monospacedDigit()
                        }
                        Spacer()
                        Button("Open Movie…", action: editors.chooseMovie)
                    }
                    if let message = studio.message ?? recorder.message { Text(message).foregroundStyle(.red).font(.caption) }
                }
                CardSection(title: "Capture settings", icon: "slider.horizontal.3") {
                    Toggle("Mac sound", isOn: $studio.settings.systemAudio)
                    Toggle("Microphone", isOn: $studio.settings.microphone)
                    Toggle("Open editor after recording", isOn: $studio.settings.opensEditor)
                    Toggle("Record pointer track", isOn: $studio.settings.pointer)
                    Toggle("Record typing times only", isOn: $studio.settings.typing)
                    Toggle("Generate automatic zooms", isOn: $studio.settings.automaticZooms)
                    Picker("Countdown", selection: $studio.settings.countdown) {
                        ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                    }
                    Picker("Frame rate", selection: $studio.settings.framesPerSecond) {
                        Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                    Picker("Export quality", selection: $studio.settings.quality) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("GIF frame rate", selection: $studio.settings.gifFPS) {
                        ForEach([8, 12, 15], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    HStack {
                        Text(studio.saveFolder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Save Folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { studio.settings.folder = url.path }
                        }
                    }
                }.disabled(studio.active)
                CardSection(title: "Triggers", icon: "keyboard") {
                    Toggle("Enable recording shortcut", isOn: $studio.settings.shortcut)
                    if studio.settings.shortcut { KeyboardShortcuts.Recorder(for: .recordScreen) }
                    Toggle("Show recording tile in menu panel", isOn: $studio.settings.menuTile)
                }
                AgentSetupCard()
            }.padding(20)
        }
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
