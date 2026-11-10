import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let openSidebarPage = Notification.Name("openSidebarPage")
}

enum TypingBadge {
    static func image(_ letter: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.black.setFill()
            box.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.white]
            let size = (letter as NSString).size(withAttributes: attributes)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            (letter as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct TypingMenu: View {
    @ObservedObject var keyboard: VietnameseKeyboard
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Vietnamese", isOn: Binding(get: { keyboard.isVietnamese }, set: { _ in keyboard.toggleMode() }))
        Divider()
        ForEach(TypingMethod.allCases) { method in
            Button {
                keyboard.update { $0.options.method = method }
            } label: {
                if keyboard.preferences.options.method == method { Label(method.title, systemImage: "checkmark") } else { Text(method.title) }
            }
        }
        Divider()
        Button("Typing Settings…") {
            openWindow(id: "main")
            DispatchQueue.main.async {
                MainWindowController.show()
                NotificationCenter.default.post(name: .openSidebarPage, object: SidebarPage.typing)
            }
        }
    }
}

struct TypingView: View {
    @EnvironmentObject var keyboard: VietnameseKeyboard
    @State private var tryText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                status
                section("Input", icon: "keyboard") {
                    Picker("Method", selection: binding(\.options.method)) {
                        ForEach(TypingMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    toggle("Type W as Ư", \.options.wAsU, telexOnly: true)
                    toggle("Type [ and ] as Ơ and Ư", \.options.brackets, telexOnly: true)
                    toggle("Restore English words automatically", \.options.autoRestore, telexOnly: true,
                           detail: "windows, text and user stay in English; tiếng, được stay Vietnamese")
                }
                section("Shortcuts", icon: "command") {
                    HStack {
                        Text("Switch Vietnamese / English")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleVietnamese)
                    }
                    toggle("Esc puts back the keys you typed", \.escRestores, detail: "vieejt⎋ → vieejt")
                }
                section("Rules", icon: "textformat") {
                    toggle("New tone placement", \.options.modernTone,
                           detail: keyboard.preferences.options.modernTone ? "hoà, khoẻ, thuý" : "hòa, khỏe, thúy")
                    toggle("Allow foreign consonants (f, j, w, z)", \.options.foreignConsonants)
                    toggle("Capitalize the start of sentences", \.options.autoCapitalize)
                }
                section("Macros", icon: "text.badge.plus") { MacroTable(keyboard: keyboard) }
                section("Apps", icon: "app.badge") {
                    toggle("Remember Vietnamese or English for each app", \.remembersAppMode)
                    toggle("Play a sound when switching", \.playsSound)
                    ExcludedApps(keyboard: keyboard)
                }
                section("Try it", icon: "character.cursor.ibeam") {
                    TextField("Type here, for example: Tieengs Vieetj", text: $tryText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { keyboard.refreshStatus() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "keyboard").font(.system(size: 18)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text("Vietnamese Typing").font(.title2).fontWeight(.bold)
                Text("Type Vietnamese in every app with Telex or VNI, powered by a Rust engine.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding(\.isEnabled)).toggleStyle(.switch).labelsHidden().controlSize(.large)
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
    }

    @ViewBuilder private var status: some View {
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleVietnamese)?.description ?? "your shortcut"
        if !keyboard.preferences.isEnabled {
            notice("Off. Turn it on to type Vietnamese everywhere.", icon: "pause.circle", color: .secondary)
        } else if !keyboard.hasPermission {
            HStack {
                notice("\(AppIdentity.installedName) needs Accessibility access to read and type keys.", icon: "lock.shield", color: .orange)
                Button("Grant Access") { keyboard.requestPermission() }
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 18)
        } else if let other = keyboard.otherTypingApp {
            notice("\(other) is also running. Quit it so marks are not typed twice.", icon: "exclamationmark.triangle.fill", color: .orange)
        } else if keyboard.isSecureInput {
            notice("Paused while a password field has Secure Input turned on.", icon: "lock.fill", color: .orange)
        } else if !keyboard.inputSourceAllowed {
            notice("Paused because the macOS keyboard is not a Latin layout. Switch it to ABC or U.S.", icon: "globe", color: .orange)
        } else {
            notice("\(keyboard.isVietnamese ? "Vietnamese" : "English") · \(keyboard.preferences.options.method.title) · \(shortcut) switches",
                   icon: "checkmark.circle.fill", color: .green)
        }
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(cornerRadius: 18)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<TypingPreferences, Bool>, telexOnly: Bool = false, detail: String? = nil) -> some View {
        Toggle(isOn: binding(path)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .disabled(telexOnly && keyboard.preferences.options.method != .telex)
    }

    private func binding<Value>(_ path: WritableKeyPath<TypingPreferences, Value>) -> Binding<Value> {
        Binding(get: { keyboard.preferences[keyPath: path] }, set: { value in keyboard.update { $0[keyPath: path] = value } })
    }
}

private struct MacroTable: View {
    @ObservedObject var keyboard: VietnameseKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(keyboard.preferences.macros) { macro in
                HStack(spacing: 8) {
                    Toggle("", isOn: field(macro.id, \.isEnabled)).labelsHidden()
                    TextField("Trigger", text: field(macro.id, \.trigger)).frame(width: 110)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("Expands to", text: field(macro.id, \.expansion))
                    Button {
                        keyboard.update { $0.macros.removeAll { $0.id == macro.id } }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button { keyboard.update { $0.macros.append(TypingMacro(trigger: "", expansion: "")) } } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Button("Import…", action: importMacros)
                Button("Export…", action: exportMacros)
            }
            Text("Macros expand on Space, Enter or punctuation, even in English mode. VN gives VIỆT NAM, Vn gives Việt Nam.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field<Value>(_ id: TypingMacro.ID, _ path: WritableKeyPath<TypingMacro, Value>) -> Binding<Value> {
        Binding(get: { keyboard.preferences.macros.first { $0.id == id }![keyPath: path] }, set: { value in
            keyboard.update { preferences in
                guard let index = preferences.macros.firstIndex(where: { $0.id == id }) else { return }
                preferences.macros[index][keyPath: path] = value
            }
        })
    }

    private func importMacros() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = TypingMacro.parse(text)
        keyboard.update { preferences in
            let existing = Set(preferences.macros.map { $0.trigger.lowercased() })
            preferences.macros += imported.filter { !existing.contains($0.trigger.lowercased()) }
        }
    }

    private func exportMacros() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacKit macros.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? TypingMacro.export(keyboard.preferences.macros).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct ExcludedApps: View {
    @ObservedObject var keyboard: VietnameseKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Never type Vietnamese in")
                Spacer()
                Button { addApp() } label: { Label("Add App", systemImage: "plus") }
            }
            ForEach(keyboard.preferences.excludedApps, id: \.self) { bundleID in
                HStack {
                    Text(name(for: bundleID)).font(.callout)
                    Text(bundleID).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button { keyboard.update { $0.excludedApps.removeAll { $0 == bundleID } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        keyboard.update { preferences in
            if !preferences.excludedApps.contains(bundleID) { preferences.excludedApps.append(bundleID) }
        }
    }
}
