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
