import SwiftUI

struct ScreenRecordView: View {
    @EnvironmentObject var recorder: ScreenRecorder
    @AppStorage(ScreenRecording.systemAudioKey) private var systemAudio = true
    @AppStorage(ScreenRecording.microphoneKey) private var microphone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if ScreenRecorder.isSupported {
                    recordCard
                    if let url = recorder.lastRecording { LastRecordingRow(url: url) }
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
            Text("Record a screen, a window or an app with sound. Videos are saved to Movies.")
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
                Task { await recorder.chooseAndRecord(systemAudio: systemAudio, microphone: microphone) }
            } label: {
                Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        case .choosing:
            Label("Choose a screen, window or app to record…", systemImage: "rectangle.dashed")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
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
