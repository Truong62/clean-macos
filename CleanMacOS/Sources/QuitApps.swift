import AppKit
import KeyboardShortcuts
import SwiftUI

struct QuitAppsSettings: Codable, Equatable {
    var isEnabled = false
    var kept: [String] = []
}

@MainActor
final class QuitAppsController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "quitApps.settings"
    static let width: CGFloat = 460
    static let rowHeight: CGFloat = 36
    static let visibleRows = 8
    static let chrome: CGFloat = 104
    static let quitTimeout: TimeInterval = 4
    static let typingPause: TimeInterval = 1

    @Published var settings: QuitAppsSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.isEnabled { KeyboardShortcuts.enable([.quitApps]) } else { KeyboardShortcuts.disable([.quitApps]) }
        }
    }
    @Published private(set) var apps: [RunningAppInfo] = []
    @Published private(set) var front: RunningAppInfo?
    @Published var selection = 0
    @Published private(set) var quitting: Set<String> = []

    private var panel: NSPanel?
    private var frontID: String?
    private var keyMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var typed = ""
    private var lastTyped = Date.distantPast

    override init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(QuitAppsSettings.self, from: $0) }
            ?? QuitAppsSettings()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .quitApps) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        if !settings.isEnabled { KeyboardShortcuts.disable([.quitApps]) }
    }

    var isOpen: Bool { panel?.isVisible == true }

    var keptIDs: Set<String> { QuitList.alwaysKept.union(settings.kept) }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        selection = 0
        reload()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = panelHeight
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - Self.width / 2, y: visible.midY - height / 2 + visible.height / 8, width: Self.width, height: height),
                           display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    func quit(_ app: RunningAppInfo) {
        quitting.insert(app.bundleID)
        QuickControls.quit([app])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitTimeout) { [weak self] in self?.quitting.remove(app.bundleID) }
    }

    func quitAll(exceptFront: Bool) {
        let batch = QuitList.batch(apps, kept: Set(settings.kept), exceptFront: exceptFront ? front?.bundleID : nil)
        close()
        QuickControls.quit(batch)
    }

    func toggleKept(_ bundleID: String) {
        if let index = settings.kept.firstIndex(of: bundleID) { settings.kept.remove(at: index) } else { settings.kept.append(bundleID) }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private var panelHeight: CGFloat {
        Self.chrome + CGFloat(max(1, min(apps.count, Self.visibleRows))) * Self.rowHeight
    }

    private func reload() {
        apps = QuitList.ordered(QuickControls.runningApps(), front: frontID, own: Bundle.main.bundleIdentifier)
        front = apps.first { $0.bundleID == frontID }
        selection = min(selection, max(apps.count - 1, 0))
        quitting.formIntersection(apps.map(\.bundleID))
    }

    private func appsChanged() {
        guard isOpen, let panel else { return }
        reload()
        var frame = panel.frame
        frame.origin.y += frame.height - panelHeight
        frame.size.height = panelHeight
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: panelHeight), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: QuitAppsView(controller: self))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.delegate = self
        return panel
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let characters = event.charactersIgnoringModifiers ?? ""
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated {
                self?.handleKey(keyCode, modifiers: modifiers, characters: characters, windowNumber: windowNumber) ?? false
            }
            return isHandled ? nil : event
        }
        let center = NSWorkspace.shared.notificationCenter
        appObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appsChanged() }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        appObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        appObservers = []
    }

    private func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String, windowNumber: Int) -> Bool {
        guard let panel, panel.windowNumber == windowNumber else { return false }
        if let command = QuitKeys.command(keyCode: keyCode, modifiers: modifiers) {
            run(command)
            return true
        }
        if PanelKeys.isAppCommand(keyCode: keyCode, modifiers: modifiers) {
            if keyCode == PanelKeys.closeKey { close() } else { NSSound.beep() }
            return true
        }
        let isTyping = modifiers.intersection([.command, .control, .option]).isEmpty && !characters.isEmpty
            && !characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard isTyping else { return false }
        typed = Date().timeIntervalSince(lastTyped) > Self.typingPause ? characters : typed + characters
        lastTyped = Date()
        if let index = QuitList.jump(to: typed, in: apps) { selection = index }
        return true
    }

    private func run(_ command: QuitCommand) {
        switch command {
        case .move(let step):
            guard !apps.isEmpty else { return }
            selection = (selection + step + apps.count) % apps.count
        case .quitSelected:
            if apps.indices.contains(selection) { quit(apps[selection]) }
        case .quitAll:
            quitAll(exceptFront: false)
        case .quitAllExceptFront:
            if front != nil { quitAll(exceptFront: true) } else { NSSound.beep() }
        case .cancel:
            close()
        }
    }
}

struct QuitAppsView: View {
    @ObservedObject var controller: QuitAppsController

    var body: some View {
        VStack(spacing: 10) {
            Text("Quit Apps").font(.headline).padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(controller.apps.enumerated()), id: \.element.id) { index, app in
                            row(app, index: index).id(app.id)
                        }
                        if controller.apps.isEmpty {
                            Text("No other apps are open").foregroundStyle(.secondary).frame(height: QuitAppsController.rowHeight)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: controller.selection) { _, index in
                    if controller.apps.indices.contains(index) { proxy.scrollTo(controller.apps[index].id) }
                }
            }
            HStack(spacing: 8) {
                Button("Cancel") { controller.close() }
                Spacer()
                if let front = controller.front {
                    Button("Quit All Except \(front.name)") { controller.quitAll(exceptFront: true) }.help("⌥⌘↩")
                }
                Button("Quit All") { controller.quitAll(exceptFront: false) }
                    .buttonStyle(.borderedProminent)
                    .help("⌘↩")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ app: RunningAppInfo, index: Int) -> some View {
        HStack(spacing: 10) {
            if let icon = AppIconCache.image(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").frame(width: 22, height: 22)
            }
            Text(app.name).lineLimit(1)
            if app.bundleID == controller.front?.bundleID { badge("Front", color: .blue) }
            if controller.keptIDs.contains(app.bundleID) { badge("Kept", color: .green) }
            Spacer()
            if controller.quitting.contains(app.bundleID) {
                ProgressView().controlSize(.small)
            } else {
                Button { controller.quit(app) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Quit \(app.name) (⌘⌫)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: QuitAppsController.rowHeight - 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(index == controller.selection ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = index }
        .contextMenu {
            if !QuitList.alwaysKept.contains(app.bundleID) {
                Button(controller.settings.kept.contains(app.bundleID) ? "Stop Keeping \(app.name)" : "Always Keep \(app.name)") {
                    controller.toggleKept(app.bundleID)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct QuitAppsSettingsCard: View {
    @EnvironmentObject var quitApps: QuitAppsController

    var body: some View {
        CardSection(title: "Quit apps", icon: "xmark.app") {
            HStack {
                Button { quitApps.open() } label: { Label("Choose Apps to Quit…", systemImage: "xmark.app") }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            Text("Lists the open apps first, then quits them politely so they can ask to save. Finder and Phone always stay open.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open the list with a shortcut", isOn: $quitApps.settings.isEnabled)
            if quitApps.settings.isEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .quitApps)
                }
            }
            if !quitApps.settings.kept.isEmpty {
                Text("Always kept").font(.subheadline.weight(.semibold))
                ForEach(quitApps.settings.kept, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppIconCache.image(for: bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(Self.name(for: bundleID))
                        Spacer()
                        Button { quitApps.toggleKept(bundleID) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Text("Right-click an app in the list to always keep it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}
