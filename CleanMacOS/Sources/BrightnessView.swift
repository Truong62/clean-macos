import KeyboardShortcuts
import SwiftUI

struct BrightnessSection: View {
    @EnvironmentObject var brightness: BrightnessController

    var body: some View {
        CardSection(title: "Brightness", icon: "sun.max") {
            Toggle("Control display brightness from MacKit", isOn: $brightness.settings.isEnabled)
            if brightness.settings.isEnabled {
                if brightness.displays.isEmpty {
                    Text(brightness.isScanning ? "Looking for displays…" : "No displays found").foregroundStyle(.secondary)
                }
                ForEach(brightness.displays) { BrightnessRow(display: $0) }
                Divider()
                Toggle("Brightness keys change external displays", isOn: $brightness.settings.handlesKeys)
                Toggle("Brightness keys follow the pointer", isOn: $brightness.settings.keysFollowPointer)
                    .disabled(!brightness.settings.handlesKeys)
                Toggle("Use F14 and F15 as brightness keys", isOn: $brightness.settings.usesFunctionKeys)
                    .disabled(!brightness.settings.handlesKeys)
                Picker("Key step", selection: $brightness.settings.step) {
                    ForEach(LevelStep.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                Toggle("Show the percentage while adjusting", isOn: $brightness.settings.showsPercentage)
                Toggle("Shortcuts change the brightness of the display in front", isOn: $brightness.settings.shortcutsEnabled)
                if brightness.settings.shortcutsEnabled {
                    ShortcutPair(down: .displayBrightnessDown, up: .displayBrightnessUp)
                }
                if !AXIsProcessTrusted() {
                    Text("Brightness keys need Accessibility access for \(AppIdentity.installedName).").font(.caption).foregroundStyle(.orange)
                }
                if XDRBooster.isSupported {
                    Toggle("Extra brightness on the XDR display", isOn: $brightness.settings.xdrEnabled)
                    HStack {
                        Text("Boost")
                        Slider(value: $brightness.settings.xdrLevel, in: 0.1...1, step: 0.05).frame(maxWidth: 240)
                        Text("\(Int((brightness.settings.xdrLevel * 100).rounded()))%").monospacedDigit()
                    }
                    .disabled(!brightness.settings.xdrEnabled)
                } else {
                    Text("Extra brightness needs a MacBook Pro with a Liquid Retina XDR display.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if brightness.keyboard.isAvailable {
                Divider()
                Toggle("Shortcuts change the keyboard light", isOn: $brightness.settings.keyboardShortcutsEnabled)
                if brightness.settings.keyboardShortcutsEnabled {
                    ShortcutPair(down: .keyboardLightDown, up: .keyboardLightUp)
                }
            }
        }
    }
}

struct ShortcutPair: View {
    let down: KeyboardShortcuts.Name
    let up: KeyboardShortcuts.Name

    var body: some View {
        HStack {
            Text("Lower")
            KeyboardShortcuts.Recorder(for: down)
            Spacer()
            Text("Raise")
            KeyboardShortcuts.Recorder(for: up)
        }
    }
}

struct BrightnessRow: View {
    @EnvironmentObject var brightness: BrightnessController
    let display: DisplayBrightness
    var isCompact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.name).lineLimit(1)
                if !isCompact { Text(display.isOn ? display.route.title : "Turned off").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: isCompact ? 90 : 170, alignment: .leading)
            Slider(value: Binding(get: { display.level }, set: { brightness.setLevel($0, for: display.id) }), in: 0...1)
                .disabled(!display.isOn)
            Text("\(Int((display.level * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            if !isCompact && display.route != .system {
                Menu {
                    Toggle("Dim the picture instead of the monitor", isOn: Binding(get: { brightness.settings.picturePreferred.contains(display.key) },
                                                                                set: { _ in brightness.togglePicturePreferred(display) }))
                    Toggle("Extra dimming below the monitor's minimum", isOn: Binding(get: { brightness.settings.extraDimming.contains(display.key) },
                                                                                     set: { _ in brightness.toggleExtraDimming(display) }))
                        .disabled(display.route != .ddc)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !isCompact && DisplayPower.isAvailable {
                Button { brightness.setPower(!display.isOn, for: display.id) } label: {
                    Image(systemName: "power").foregroundStyle(display.isOn ? Color.primary : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(display.isOn ? "Turn this display off until MacKit quits" : "Turn this display back on")
            }
        }
    }
}
