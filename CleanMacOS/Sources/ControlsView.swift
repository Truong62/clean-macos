import AppKit
import SwiftUI

@MainActor
final class ControlsModel: ObservableObject {
    static let keptAppsKey = "controls.keptApps"

    @Published private(set) var flags: [FinderFlag: Bool] = [:]
    @Published private(set) var isDark = false
    @Published private(set) var volumes: [URL] = []
    @Published var keptApps: [String] {
        didSet { UserDefaults.standard.set(keptApps, forKey: Self.keptAppsKey) }
    }
    @Published var message: String?
    @Published var backlight: Float = 0

    let controls: QuickControls
    let keyboardLight = KeyboardBacklight()

    init(controls: QuickControls = QuickControls()) {
        self.controls = controls
        keptApps = UserDefaults.standard.stringArray(forKey: Self.keptAppsKey) ?? []
    }

    func refresh() {
        let controls = controls
        Task.detached {
            let flags = Dictionary(uniqueKeysWithValues: FinderFlag.allCases.map { ($0, controls.isOn($0)) })
            let volumes = QuickControls.ejectableVolumes()
            await MainActor.run {
                self.flags = flags
                self.volumes = volumes
                self.isDark = controls.isDarkMode
                self.backlight = self.keyboardLight.brightness ?? 0
            }
        }
    }

    func toggle(_ flag: FinderFlag) {
        let next = !(flags[flag] ?? flag.defaultValue)
        flags[flag] = next
        let controls = controls
        Task.detached { controls.set(flag, next) }
    }

    func toggleDark() {
        isDark.toggle()
        let controls = controls
        let dark = isDark
        Task.detached { controls.setDarkMode(dark) }
    }

    func ejectAll() {
        let failed = QuickControls.ejectAll()
        message = failed.isEmpty ? "Ejected every disk." : "Could not eject \(failed.joined(separator: ", "))."
        refresh()
    }

    var appsToQuit: [RunningAppInfo] {
        QuickControls.appsToQuit(QuickControls.runningApps(), keep: Set(keptApps), own: Bundle.main.bundleIdentifier)
    }

    func quitApps() {
        let apps = appsToQuit
        QuickControls.quit(apps)
        message = apps.isEmpty ? "Nothing to quit." : "Asked \(apps.count) \(apps.count == 1 ? "app" : "apps") to quit."
    }
}

struct ControlsView: View {
    @StateObject private var model = ControlsModel()
    @State private var confirmTrash = false
    @State private var confirmQuit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "switch.2", title: "Quick Controls", subtitle: "One-click switches for things buried in System Settings.",
                           colors: [.teal, .blue])
                CardSection(title: "Switches", icon: "togglepower") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ControlTile(icon: "moon.fill", title: "Dark Mode", isOn: model.isDark) { model.toggleDark() }
                        ControlTile(icon: "eye", title: "Hidden Files", isOn: model.flags[.hiddenFiles] ?? false) { model.toggle(.hiddenFiles) }
                        ControlTile(icon: "menubar.dock.rectangle", title: "Desktop Icons", isOn: model.flags[.desktopIcons] ?? true) {
                            model.toggle(.desktopIcons)
                        }
                    }
                    if model.keyboardLight.isAvailable {
                        HStack {
                            Label("Keyboard light", systemImage: "light.max")
                            Slider(value: Binding(get: { model.backlight }, set: { model.backlight = $0; model.keyboardLight.set($0) }), in: 0...1)
                        }
                    }
                }
                CardSection(title: "Actions", icon: "bolt.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ControlTile(icon: "lock.fill", title: "Lock Screen") { model.controls.lockScreen() }
                        ControlTile(icon: "display", title: "Sleep Display") { model.controls.sleepDisplay() }
                        ControlTile(icon: "sparkles.tv", title: "Screen Saver") { model.controls.startScreenSaver() }
                        ControlTile(icon: "trash.fill", title: "Empty Trash") { confirmTrash = true }
                        ControlTile(icon: "eject.fill", title: model.volumes.isEmpty ? "Eject Disks" : "Eject \(model.volumes.count) Disks") {
                            model.ejectAll()
                        }
                        ControlTile(icon: "xmark.circle.fill", title: "Quit All Apps") { confirmQuit = true }
                    }
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                CardSection(title: "Quit All Apps keeps", icon: "pin.fill") {
                    AppListEditor(title: "Never quit these apps", bundleIDs: $model.keptApps)
                    Text("Finder and MacKit are always kept.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .alert("Empty the Trash?", isPresented: $confirmTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) { model.controls.emptyTrash() }
        } message: {
            Text("Everything in the Trash is deleted for good.")
        }
        .alert("Quit \(model.appsToQuit.count) apps?", isPresented: $confirmQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) { model.quitApps() }
        } message: {
            Text(model.appsToQuit.map(\.name).joined(separator: ", "))
        }
    }
}

struct ControlTile: View {
    let icon: String
    let title: String
    var isOn: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isOn == true ? .white : .primary)
                    .background(Circle().fill(isOn == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08))))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    if let isOn { Text(isOn ? "On" : "Off").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct ControlsStrip: View {
    private let controls = QuickControls()

    var body: some View {
        HStack(spacing: 4) {
            MenuIconButton(systemImage: "moon.fill", help: "Toggle Dark Mode") {
                let controls = controls
                Task.detached { controls.setDarkMode(!controls.isDarkMode) }
            }
            MenuIconButton(systemImage: "lock.fill", help: "Lock Screen") { controls.lockScreen() }
            MenuIconButton(systemImage: "display", help: "Sleep Display") { controls.sleepDisplay() }
            MenuIconButton(systemImage: "sparkles.tv", help: "Screen Saver") { controls.startScreenSaver() }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
