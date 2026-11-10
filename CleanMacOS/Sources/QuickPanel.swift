import AppKit
import KeyboardShortcuts
import SwiftUI

struct QuickPanelSettings: Codable, Equatable {
    static let defaultTiles = ["keepAwake", "pickColor", "grabText", "clipboardHistory", "snippetLibrary", "micMute", "cycleOutput", "darkMode", "plainPaste", "lock",
                               "displaySleep", "screenSaver", "hiddenFiles", "desktopIcons", "shelf"]

    var isEnabled = false
    var tiles = QuickPanelSettings.defaultTiles
}

@MainActor
final class QuickPanelController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "quickPanel.settings"
    static let width: CGFloat = 420
    static let columns = 3
    static let tileHeight: CGFloat = 86
    static let chrome: CGFloat = 70
    static let heightShare: CGFloat = 0.62

    @Published var settings: QuickPanelSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if oldValue.isEnabled != settings.isEnabled {
                if settings.isEnabled { KeyboardShortcuts.enable([.quickPanel]) } else { KeyboardShortcuts.disable([.quickPanel]) }
            }
        }
    }
    @Published private(set) var tiles: [CommandItem] = []
    @Published var selection = 0
    @Published private(set) var isOpen = false

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let context: CommandContext

    init(context: CommandContext) {
        self.context = context
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(QuickPanelSettings.self, from: $0) }
            ?? QuickPanelSettings()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .quickPanel) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        if !settings.isEnabled { KeyboardShortcuts.disable([.quickPanel]) }
    }

    var available: [CommandItem] {
        CommandSources.actions(context).filter { ($0.kind == .action || $0.kind == .toggle) && !$0.needsConfirmation && $0.numberRange == nil }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        reload()
        selection = 0
        let rows = CGFloat((tiles.count + Self.columns - 1) / Self.columns)
        let size = NSSize(width: Self.width, height: rows * Self.tileHeight + Self.chrome)
        let panel = self.panel ?? KeyablePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: QuickPanelView(controller: self))
            host.sizingOptions = []
            panel.contentViewController = host
        }
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * Self.heightShare - size.height / 2))
        }
        panel.delegate = self
        self.panel = panel
        isOpen = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated { self?.handleKey(keyCode, windowNumber: windowNumber) ?? false }
            return isHandled ? nil : event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        isOpen = false
    }

    func run(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        let tile = tiles[index]
        if tile.kind == .toggle {
            tile.run(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload() }
            return
        }
        close()
        DispatchQueue.main.async { tile.run(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func reload() {
        let all = available
        tiles = settings.tiles.compactMap { id in all.first { $0.id == id } }
    }

    private func handleKey(_ keyCode: UInt16, windowNumber: Int) -> Bool {
        guard isOpen, panel?.windowNumber == windowNumber else { return false }
        let moves: [UInt16: GridMove.Key] = [CommandBarKeys.leftKey: .left, CommandBarKeys.rightKey: .right, PanelKeys.upKey: .up, PanelKeys.downKey: .down]
        if let move = moves[keyCode] {
            selection = GridMove.next(from: selection, key: move, count: tiles.count, columns: Self.columns)
        } else if keyCode == PanelKeys.returnKey || keyCode == PanelKeys.enterKey {
            run(selection)
        } else if keyCode == PanelKeys.escapeKey {
            close()
        } else if let digit = PanelKeys.digitKeys[keyCode] {
            run(digit - 1)
        } else {
            return false
        }
        return true
    }
}

struct QuickPanelView: View {
    @ObservedObject var controller: QuickPanelController

    var body: some View {
        VStack(spacing: 10) {
            Text("Quick Panel").font(.headline).padding(.top, 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: QuickPanelController.columns), spacing: 8) {
                ForEach(Array(controller.tiles.enumerated()), id: \.element.id) { index, tile in
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            if case .symbol(let name) = tile.icon {
                                Image(systemName: name).font(.system(size: 22)).frame(width: 40, height: 32)
                            }
                            if tile.isActive { Circle().fill(Color.green).frame(width: 7, height: 7) }
                        }
                        Text(tile.title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: QuickPanelController.tileHeight - 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(index == controller.selection ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                    .overlay(alignment: .topLeading) {
                        if index < PanelKeys.digitKeys.count { Text("\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary).padding(6) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { controller.run(index) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct LauncherSettingsCards: View {
    @EnvironmentObject var radial: RadialMenuController
    @EnvironmentObject var quick: QuickPanelController
    @State private var newLink = ""

    var body: some View {
        CardSection(title: "Radial menu", icon: "circle.grid.cross") {
            Toggle("Open a wheel of actions with a shortcut", isOn: $radial.settings.isEnabled)
            if radial.settings.isEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .radialMenu)
                }
                Picker("Mouse button", selection: $radial.settings.mouseButton) {
                    Text("None").tag(Int?.none)
                    ForEach(Array(RadialMenuController.mouseButtons.prefix(8)), id: \.self) { Text("Button \($0)").tag(Int?.some($0)) }
                }
                .frame(maxWidth: 320)
                Picker("Behavior", selection: $radial.settings.mode) {
                    ForEach(RadialSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                Toggle("Open at the pointer instead of the screen center", isOn: $radial.settings.opensAtPointer)
                Text("Press or hold: release over a slice to run it, or let go and click one.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(radial.settings.slices.enumerated()), id: \.element.id) { index, slice in
                    HStack {
                        Image(systemName: slice.symbol).frame(width: 22)
                        Text(slice.title)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            .disabled(index == radial.settings.slices.count - 1)
                        Button { radial.settings.slices.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Slice") {
                        Menu("MacKit Action") {
                            ForEach(radial.actions()) { action in
                                Button(action.title) { add(RadialSlice(title: action.title, symbol: symbol(of: action), action: .command(action.id))) }
                            }
                        }
                        Menu("Media") {
                            Button("Play/Pause") { add(RadialSlice(title: "Play/Pause", symbol: "playpause.fill", action: .media(RadialSettings.mediaPlay))) }
                            Button("Next") { add(RadialSlice(title: "Next", symbol: "forward.fill", action: .media(RadialSettings.mediaNext))) }
                            Button("Previous") { add(RadialSlice(title: "Previous", symbol: "backward.fill", action: .media(RadialSettings.mediaPrevious))) }
                        }
                        Button("App…") { chooseApp() }
                        Button("Folder…") { chooseFolder() }
                    }
                    .fixedSize()
                    .disabled(radial.settings.slices.count >= RadialSettings.maxSlices)
                    Spacer()
                    Button("General") { radial.settings.slices = RadialSettings.general }
                    Button("Media") { radial.settings.slices = RadialSettings.media }
                    Button("Clear") { radial.settings.slices = [] }
                }
                HStack {
                    TextField("https://… link slice", text: $newLink).textFieldStyle(.roundedBorder)
                    Button("Add Link") {
                        guard let url = URL(string: newLink), url.scheme != nil else { return NSSound.beep() }
                        add(RadialSlice(title: url.host ?? "Link", symbol: "link", action: .link(newLink)))
                        newLink = ""
                    }
                }
            }
        }
        CardSection(title: "Quick panel", icon: "square.grid.3x3") {
            Toggle("Open a grid of tools with a shortcut", isOn: $quick.settings.isEnabled)
            if quick.settings.isEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .quickPanel)
                }
                ForEach(quick.available) { item in
                    Toggle(item.title, isOn: Binding(get: { quick.settings.tiles.contains(item.id) }, set: { isOn in
                        quick.settings.tiles.removeAll { $0 == item.id }
                        if isOn { quick.settings.tiles.append(item.id) }
                    }))
                }
            }
        }
    }

    private func symbol(of item: CommandItem) -> String {
        if case .symbol(let name) = item.icon { return name }
        return "app"
    }

    private func add(_ slice: RadialSlice) {
        guard radial.settings.slices.count < RadialSettings.maxSlices else { return NSSound.beep() }
        radial.settings.slices.append(slice)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard radial.settings.slices.indices.contains(target) else { return }
        radial.settings.slices.swapAt(index, target)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(RadialSlice(title: url.deletingPathExtension().lastPathComponent, symbol: "app", action: .app(url.path)))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(RadialSlice(title: url.lastPathComponent, symbol: "folder", action: .folder(url.path)))
    }
}
