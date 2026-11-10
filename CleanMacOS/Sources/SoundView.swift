import AppKit
import KeyboardShortcuts
import SwiftUI

struct SoundView: View {
    @EnvironmentObject var sound: SoundController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "speaker.wave.2.fill", title: "Sound", subtitle: "Switch devices fast, keep a priority order and mute every microphone at once.",
                           colors: [.pink, .orange])
                devicesCard
                MixerSection()
                CardSection(title: "Output switcher", icon: "arrow.triangle.2.circlepath") {
                    Toggle("A shortcut cycles through chosen outputs", isOn: $sound.settings.cycleEnabled)
                    if sound.settings.cycleEnabled {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .cycleOutput)
                        }
                        Text("Outputs in the cycle").font(.caption).foregroundStyle(.secondary)
                        ForEach(sound.outputs) { device in
                            Toggle(device.name, isOn: Binding(get: { sound.settings.cycleOutputs.contains(device.uid) }, set: { isOn in
                                sound.settings.cycleOutputs.removeAll { $0 == device.uid }
                                if isOn { sound.settings.cycleOutputs.append(device.uid) }
                            }))
                        }
                    }
                }
                CardSection(title: "Priority", icon: "list.number") {
                    Toggle("Switch output to the highest available device", isOn: $sound.settings.outputPriorityEnabled)
                    if sound.settings.outputPriorityEnabled {
                        PriorityList(uids: sound.settings.outputPriority, current: sound.outputs.first { $0.id == sound.defaultOutput }?.uid,
                                     available: Set(sound.outputs.map(\.uid)), isOutput: true)
                    }
                    Toggle("Switch microphone to the highest available device", isOn: $sound.settings.inputPriorityEnabled)
                    if sound.settings.inputPriorityEnabled {
                        PriorityList(uids: sound.settings.inputPriority, current: sound.inputs.first { $0.id == sound.defaultInput }?.uid,
                                     available: Set(sound.inputs.map(\.uid)), isOutput: false)
                    }
                    Text("A device you pick by hand stays until devices are plugged in or out.").font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Mic Mute", icon: "mic.slash") {
                    HStack {
                        Label(sound.isMicMuted ? "Every microphone is muted" : "Microphones are on",
                              systemImage: sound.isMicMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(sound.isMicMuted ? Color.red : .primary)
                        Spacer()
                        Button(sound.isMicMuted ? "Unmute" : "Mute All") { sound.toggleMicMute() }
                    }
                    Toggle("Mute and unmute with a shortcut", isOn: $sound.settings.micShortcutEnabled)
                    if sound.settings.micShortcutEnabled {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .toggleMicMute)
                        }
                    }
                    Toggle("Show a red microphone in the menu bar while muted", isOn: $sound.settings.showsMicBadge)
                    Text("Sets every microphone's mute and volume to off and puts them back afterwards. It is a convenience, not a privacy lock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Keys", icon: "speaker.plus") {
                    Toggle("Handle the volume keys and show MacKit's volume display", isOn: $sound.settings.handlesVolumeKeys)
                    Picker("Volume step", selection: $sound.settings.volumeStep) {
                        ForEach(LevelStep.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    .disabled(!sound.settings.handlesVolumeKeys)
                    Toggle("Play a click when the volume changes", isOn: $sound.settings.playsFeedback)
                        .disabled(!sound.settings.handlesVolumeKeys)
                    Toggle("Change a monitor's own speakers over DDC when macOS can't", isOn: $sound.settings.usesMonitorSpeakers)
                        .disabled(!sound.settings.handlesVolumeKeys)
                    Text("⌥⇧ with a volume key takes a quarter step. Keys need Accessibility access.").font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Headphones", icon: "headphones") {
                    Toggle("Lower the volume when headphones disconnect", isOn: $sound.settings.guardsHeadphones)
                    HStack {
                        Text("Lower to")
                        Slider(value: $sound.settings.headphoneTarget, in: 0...1, step: 0.05).frame(maxWidth: 220)
                        Text("\(Int((sound.settings.headphoneTarget * 100).rounded()))%").monospacedDigit()
                    }
                    .disabled(!sound.settings.guardsHeadphones)
                }
                CardSection(title: "Music app", icon: "music.note") {
                    Toggle("Stop the Music app from opening when you press play", isOn: $sound.settings.blocksMusic)
                    if sound.settings.blocksMusic {
                        HStack {
                            Text("Open instead")
                            Spacer()
                            Text(sound.settings.musicReplacement.map(AppListEditor.name(for:)) ?? "Nothing").foregroundStyle(.secondary)
                            Button("Choose…") { chooseReplacement() }
                            if sound.settings.musicReplacement != nil { Button("Clear") { sound.settings.musicReplacement = nil } }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var devicesCard: some View {
        CardSection(title: "Devices", icon: "hifispeaker.2") {
            Picker("Output", selection: Binding(get: { sound.defaultOutput ?? 0 }, set: { id in
                if let device = sound.outputs.first(where: { $0.id == id }) { sound.setDefaultOutput(device) }
            })) {
                ForEach(sound.outputs) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 420)
            if let volume = sound.outputVolume {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volume }, set: { sound.setOutputVolume($0) }), in: 0...1)
                    Text("\(Int((volume * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("System sounds", selection: Binding(get: { sound.systemOutput ?? 0 }, set: { id in
                if let device = sound.outputs.first(where: { $0.id == id }) { sound.setSystemOutput(device) }
            })) {
                ForEach(sound.outputs) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 420)
            if sound.inputs.isEmpty {
                Text("No microphone connected").foregroundStyle(.secondary)
            } else {
                Picker("Microphone", selection: Binding(get: { sound.defaultInput ?? 0 }, set: { id in
                    if let device = sound.inputs.first(where: { $0.id == id }) { sound.setDefaultInput(device) }
                })) {
                    ForEach(sound.inputs) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 420)
                if let volume = sound.inputVolume {
                    HStack {
                        Image(systemName: "mic.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { volume }, set: { sound.setInputVolume($0) }), in: 0...1).disabled(sound.isMicMuted)
                        Text("\(Int((volume * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func chooseReplacement() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        sound.settings.musicReplacement = bundleID
    }
}

private struct PriorityList: View {
    @EnvironmentObject var sound: SoundController
    let uids: [String]
    let current: String?
    let available: Set<String>
    let isOutput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(uids.enumerated()), id: \.element) { index, uid in
                HStack(spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    Text(sound.name(for: uid)).foregroundStyle(available.contains(uid) ? Color.primary : .secondary)
                    if uid == current { Text("Current").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.green.opacity(0.2))) }
                    if !available.contains(uid) { Text("Unavailable").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button { sound.moveInPriority(uid, by: -1, isOutput: isOutput) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                    Button { sound.moveInPriority(uid, by: 1, isOutput: isOutput) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == uids.count - 1)
                }
            }
        }
        .padding(.leading, 18)
    }
}

enum MicBadge {
    static let image: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")?.withSymbolConfiguration(configuration)
            ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

struct MicBadgeMenu: View {
    @ObservedObject var sound: SoundController

    var body: some View {
        Button("Unmute Microphones") { sound.toggleMicMute() }
        Divider()
        Button("Hide This Badge") { sound.settings.showsMicBadge = false }
    }
}

struct MixerSection: View {
    @EnvironmentObject var mixer: MixerController
    @EnvironmentObject var sound: SoundController

    var body: some View {
        CardSection(title: "Volume mixer", icon: "slider.horizontal.3") {
            if !MixerController.isAvailable {
                Text("Per-app volume needs macOS 14.4 or later.").foregroundStyle(.secondary)
            } else {
                Toggle("Set the volume of each app", isOn: $mixer.settings.isEnabled)
                if mixer.settings.isEnabled {
                    Toggle("Hide apps that aren't playing", isOn: $mixer.settings.hidesInactive)
                    if let problem = mixer.problem {
                        Text(problem.message).font(.caption).foregroundStyle(.orange)
                    }
                    if mixer.visibleApps.isEmpty {
                        Text("No apps are using sound right now.").foregroundStyle(.secondary)
                    }
                    ForEach(mixer.visibleApps) { MixerRow(app: $0) }
                    Text("The first change asks for Screen & System Audio Recording access. Above 100% a limiter keeps loud apps from clipping.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MixerRow: View {
    static let iconSize: CGFloat = 28

    @EnvironmentObject var mixer: MixerController
    @EnvironmentObject var sound: SoundController
    let app: AudioApp

    var body: some View {
        let mix = mixer.mix(for: app)
        let canTap = AudioAppPolicy.canTap(app.id)
        HStack(spacing: 10) {
            Image(nsImage: NSRunningApplication(processIdentifier: app.pid)?.icon ?? NSImage()).resizable().frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name).lineLimit(1)
                    if app.isPlaying { Circle().fill(Color.green).frame(width: 6, height: 6) }
                }
                if !canTap { Text("Left alone so its calls keep working").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 160, alignment: .leading)
            Button { mixer.toggleMute(app) } label: {
                Image(systemName: mix.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!canTap)
            Slider(value: Binding(get: { mix.volume }, set: { mixer.setVolume($0, for: app) }), in: 0...MixerGain.maximum)
                .tint(mix.volume > AppMix.unity ? .orange : .accentColor)
                .disabled(!canTap || mix.isMuted)
            Text("\(Int((mix.volume * 100).rounded()))%").monospacedDigit().frame(width: 46, alignment: .trailing)
                .foregroundStyle(mix.volume > AppMix.unity ? Color.orange : .primary)
            Button { mixer.reset(app) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Back to 100%")
                .disabled(!canTap || (!mix.isMuted && abs(mix.volume - AppMix.unity) < AppMix.tolerance))
            Picker("", selection: Binding(get: { mix.route }, set: { mixer.setRoute($0, for: app) })) {
                Text("Default output").tag(String?.none)
                ForEach(sound.outputs) { Text($0.name).tag(String?.some($0.uid)) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(!canTap)
        }
    }
}
