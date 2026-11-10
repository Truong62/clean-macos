import AppKit
import KeyboardShortcuts
import SwiftUI

struct LauncherSettingsCards: View {
    @EnvironmentObject var radial: RadialMenuController
    @EnvironmentObject var quick: QuickPanelController

    var body: some View {
        CardSection(title: "Radial menu", icon: "circle.grid.cross") {
            Toggle("Enable radial menus", isOn: $radial.settings.isEnabled)
            Picker("Behavior", selection: $radial.settings.mode) {
                ForEach(RadialSettings.Mode.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 320)
            Toggle("Open at the pointer instead of the screen center", isOn: $radial.settings.opensAtPointer)
            Text("Press or hold: release over a slice to run it, or let go and click one. Screenshot uses Grab Text.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($radial.settings.wheels) { $wheel in
                RadialWheelEditor(wheel: $wheel, actions: radial.actions(), changedShortcut: radial.refreshTriggers,
                                  move: { moveWheel(wheel.id, by: $0) },
                                  remove: { radial.settings.wheels.removeAll { $0.id == wheel.id } })
            }
            ForEach(Array(radial.conflicts.enumerated()), id: \.offset) { _, conflict in
                let first = radial.settings.wheels.first { $0.id == conflict.first }?.name ?? "Wheel"
                let second = radial.settings.wheels.first { $0.id == conflict.second }?.name ?? "Wheel"
                Label("\(first) and \(second) share a \(conflict.keyboard ? "shortcut" : "mouse button"). Change one; both conflicting triggers are disabled.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Menu("Add Wheel") {
                ForEach(RadialSettings.Preset.allCases) { preset in
                    Button(preset.rawValue) { radial.settings.wheels.append(preset.wheel()) }
                }
            }
            .fixedSize()
        }
        CardSection(title: "Quick panel", icon: "square.grid.3x3") {
            Toggle("Open a grid of tools with a shortcut", isOn: $quick.settings.isEnabled)
            if quick.settings.isEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .quickPanel)
                }
                Text("Choose Edit in the panel to hide, add and reorder tiles. Done saves your layout.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(quick.available) { item in
                    Toggle(item.title, isOn: Binding(get: { quick.settings.tiles.contains(item.id) }, set: { isOn in
                        quick.settings.tiles = isOn
                            ? QuickPanelEdits.add(item.id, to: quick.settings.tiles, available: Set(quick.available.map(\.id)))
                            : QuickPanelEdits.hide(item.id, in: quick.settings.tiles)
                    }))
                }
            }
        }
    }

    private func moveWheel(_ id: UUID, by offset: Int) {
        guard let index = radial.settings.wheels.firstIndex(where: { $0.id == id }),
              radial.settings.wheels.indices.contains(index + offset) else { return }
        radial.settings.wheels.swapAt(index, index + offset)
    }
}

private struct RadialWheelEditor: View {
    @Binding var wheel: RadialWheel
    let actions: [CommandItem]
    let changedShortcut: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Wheel name", text: $wheel.name).textFieldStyle(.roundedBorder)
                    Picker("Color", selection: $wheel.accent) {
                        ForEach(RadialAccent.allCases) { accent in
                            Label(accent.rawValue.capitalized, systemImage: "circle.fill").foregroundStyle(accent.color).tag(accent)
                        }
                    }
                    .frame(width: 180)
                }
                HStack {
                    Toggle("Keyboard trigger", isOn: $wheel.keyboardEnabled)
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .radialWheel(wheel.id)) { _ in changedShortcut() }
                        .disabled(!wheel.keyboardEnabled)
                }
                Picker("Mouse button", selection: $wheel.mouseButton) {
                    Text("None").tag(Int?.none)
                    ForEach(Array(RadialMenuController.mouseButtons), id: \.self) { Text("Button \($0)").tag(Int?.some($0)) }
                }
                .frame(maxWidth: 320)
                Text("Mouse triggers need Accessibility access and consume both press and release.").font(.caption).foregroundStyle(.secondary)
                RadialSliceListEditor(slices: $wheel.slices, actions: actions, allowsSubmenu: true)
                HStack {
                    Button("Move Up") { move(-1) }
                    Button("Move Down") { move(1) }
                    Spacer()
                    Button("Delete Wheel", role: .destructive, action: remove)
                }
            }
            .padding(.vertical, 10)
        } label: {
            Label(wheel.name.isEmpty ? "Untitled wheel" : wheel.name, systemImage: "circle.fill").foregroundStyle(wheel.accent.color)
        }
    }
}

private struct RadialSliceListEditor: View {
    @Binding var slices: [RadialSlice]
    let actions: [CommandItem]
    let allowsSubmenu: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($slices) { $slice in
                DisclosureGroup {
                    RadialSliceEditor(slice: $slice, actions: actions, allowsSubmenu: allowsSubmenu)
                } label: {
                    HStack {
                        Label(slice.title.isEmpty ? "Untitled slice" : slice.title, systemImage: slice.symbol)
                        Spacer()
                        Button { move(slice.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .help("Move slice earlier").disabled(slices.first?.id == slice.id)
                        Button { move(slice.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .help("Move slice later").disabled(slices.last?.id == slice.id)
                        Button { slices.removeAll { $0.id == slice.id } } label: { Image(systemName: "minus.circle") }
                            .help("Remove slice")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Slice") { slices.append(RadialSlice(title: "New Slice", symbol: "star", action: .command("pickColor"))) }
                    .disabled(slices.count >= RadialSettings.maxSlices)
                Text("\(slices.count)/\(RadialSettings.maxSlices)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = slices.firstIndex(where: { $0.id == id }), slices.indices.contains(index + offset) else { return }
        slices.swapAt(index, index + offset)
    }
}

private enum RadialSliceKind: String, CaseIterable, Identifiable {
    case app = "App", file = "File or Folder", url = "URL", keystroke = "Keystroke", command = "App Tool"
    case toggle = "Quick Toggle", window = "Window Action", media = "Media Key", submenu = "Submenu"
    var id: String { rawValue }

    init(_ action: RadialSlice.Action) {
        switch action {
        case .app: self = .app
        case .folder: self = .file
        case .link: self = .url
        case .keystroke: self = .keystroke
        case .command: self = .command
        case .toggle: self = .toggle
        case .window: self = .window
        case .media: self = .media
        case .submenu: self = .submenu
        }
    }

    var initialAction: RadialSlice.Action {
        switch self {
        case .app: .app("")
        case .file: .folder("")
        case .url: .link("")
        case .keystroke: .keystroke(RadialKeystroke())
        case .command: .command("pickColor")
        case .toggle: .toggle("darkMode")
        case .window: .window(.maximize)
        case .media: .media(RadialSettings.mediaPlay)
        case .submenu: .submenu([])
        }
    }
}

private struct RadialSliceEditor: View {
    @Binding var slice: RadialSlice
    let actions: [CommandItem]
    let allowsSubmenu: Bool

    private var kind: RadialSliceKind { RadialSliceKind(slice.action) }
    private var textTarget: Binding<String> {
        Binding(get: {
            switch slice.action {
            case .app(let value), .folder(let value), .link(let value), .command(let value), .toggle(let value): value
            default: ""
            }
        }, set: { value in
            switch kind {
            case .app: slice.action = .app(value)
            case .file: slice.action = .folder(value)
            case .url: slice.action = .link(value)
            case .toggle: slice.action = .toggle(value)
            default: slice.action = .command(value)
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Custom name", text: $slice.title)
            TextField("SF Symbol", text: $slice.symbol)
            Picker("Kind", selection: Binding(get: { kind }, set: { slice.action = $0.initialAction })) {
                ForEach(RadialSliceKind.allCases.filter { allowsSubmenu || $0 != .submenu }) { Text($0.rawValue).tag($0) }
            }
            targetEditor
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var targetEditor: some View {
        switch slice.action {
        case .app, .folder:
            HStack {
                TextField("Path (supports ~)", text: textTarget)
                Button("Choose…") { choosePath() }
            }
        case .link:
            TextField("URL, including scheme", text: textTarget)
        case .command, .toggle:
            TextField("Action ID", text: textTarget)
            Picker("Action", selection: textTarget) {
                let choices = actions.filter { kind != .toggle || $0.kind == .toggle }
                if !choices.contains(where: { $0.id == textTarget.wrappedValue }) {
                    Text("Unavailable: \(textTarget.wrappedValue)").tag(textTarget.wrappedValue)
                }
                ForEach(choices) { Text($0.title).tag($0.id) }
            }
        case .media(let code):
            Picker("Media key", selection: Binding(get: { code }, set: { slice.action = .media($0) })) {
                Text("Play/Pause").tag(16)
                Text("Next").tag(17)
                Text("Previous").tag(18)
                Text("Volume Up").tag(0)
                Text("Volume Down").tag(1)
                Text("Mute").tag(7)
            }
        case .window(let action):
            Picker("Layout", selection: Binding(get: { action }, set: { slice.action = .window($0) })) {
                ForEach(WindowAction.allCases) { Text($0.title).tag($0) }
            }
        case .keystroke(let stroke):
            RadialKeystrokeRecorder(stroke: stroke) { slice.action = .keystroke($0) }
            Text("Sent after you release the trigger modifiers. Requires Accessibility access.").font(.caption).foregroundStyle(.secondary)
        case .submenu:
            AnyView(RadialSliceListEditor(slices: Binding(get: {
                if case .submenu(let children) = slice.action { return children }
                return []
            }, set: { slice.action = .submenu($0) }), actions: actions, allowsSubmenu: false))
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        if kind == .app {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        } else {
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        textTarget.wrappedValue = url.path
    }
}

private struct RadialKeystrokeRecorder: View {
    let stroke: RadialKeystroke
    let update: (RadialKeystroke) -> Void
    @State private var monitor: Any?
    @State private var isRecording = false

    private var title: String {
        if isRecording { return "Press a key combination…" }
        guard stroke.keyCode <= 127 else { return "Record Keystroke" }
        return KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: Int(stroke.keyCode)),
                                         modifiers: NSEvent.ModifierFlags(rawValue: UInt(stroke.modifiers))).description
    }

    var body: some View {
        HStack {
            Button(title) { if isRecording { stop() } else { start() } }
            if stroke.keyCode <= 127 {
                Button("Clear") { stop(); update(RadialKeystroke()) }
            }
            if isRecording { Text("Esc cancels").font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        isRecording = true
        let windowNumber = NSApp.keyWindow?.windowNumber
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.windowNumber == windowNumber else { return event }
            MainActor.assumeIsolated {
                if event.keyCode != PanelKeys.escapeKey {
                    update(RadialKeystroke(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue) & RadialKeystroke.modifierMask))
                }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
