import AppKit
import KeyboardShortcuts
import SwiftUI

struct QuickPanelSettings: Codable, Equatable {
    static let defaultTiles = ["keepAwake", "pickColor", "grabText", "clipboardHistory", "snippetLibrary", "micMute", "cycleOutput", "darkMode", "plainPaste", "lock",
                               "displaySleep", "screenSaver", "hiddenFiles", "desktopIcons", "shelf", "scratchpad", "cameraPreview", "quitAll"]

    var isEnabled = false
    var tiles = QuickPanelSettings.defaultTiles

    init() {}

    private enum CodingKeys: String, CodingKey { case isEnabled, tiles }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        tiles = QuickPanelEdits.normalized(try values.decodeIfPresent([String].self, forKey: .tiles) ?? Self.defaultTiles)
    }
}

@MainActor
final class QuickPanelController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "quickPanel.settings"
    static let width: CGFloat = 420
    static let columns = 3
    static let tileHeight: CGFloat = 86
    static let chrome: CGFloat = 116
    static let heightShare: CGFloat = 0.62

    @Published var settings: QuickPanelSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if oldValue.isEnabled != settings.isEnabled {
                if settings.isEnabled { KeyboardShortcuts.enable([.quickPanel]) } else { KeyboardShortcuts.disable([.quickPanel]); close() }
            }
            if isOpen { reload() }
        }
    }
    @Published private(set) var tiles: [CommandItem] = []
    @Published var selection = 0
    @Published private(set) var isOpen = false

    @Published private(set) var isEditing = false
    private var draftTiles: [String] = []

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let context: CommandContext

    init(context: CommandContext) {
        self.context = context
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(QuickPanelSettings.self, from: $0) }
            ?? QuickPanelSettings()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .quickPanel) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        if settings.isEnabled { KeyboardShortcuts.enable([.quickPanel]) } else { KeyboardShortcuts.disable([.quickPanel]) }
    }

    var available: [CommandItem] {
        CommandSources.actions(context).filter { ($0.kind == .action || $0.kind == .toggle) && !$0.needsConfirmation && $0.numberRange == nil }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard settings.isEnabled, !isOpen else { return }
        reload()
        selection = 0
        let rows = CGFloat((tiles.count + Self.columns - 1) / Self.columns)
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        let size = NSSize(width: Self.width, height: min(maxHeight, max(220, rows * Self.tileHeight + Self.chrome)))
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
            let isHandled = MainActor.assumeIsolated { self?.handleKey(keyCode, modifiers: event.modifierFlags, windowNumber: windowNumber) ?? false }
            return isHandled ? nil : event
        }
    }

    func close() {
        isEditing = false
        draftTiles = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        isOpen = false
    }

    func run(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        if isEditing { selection = index; return }
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

    var hiddenTiles: [CommandItem] {
        available.filter { !draftTiles.contains($0.id) }
    }

    func beginEditing() {
        draftTiles = QuickPanelEdits.normalized(settings.tiles)
        isEditing = true
        reload()
    }

    func finishEditing(save: Bool) {
        let edited = draftTiles
        isEditing = false
        draftTiles = []
        if save { settings.tiles = edited }
        reload()
    }

    func hide(_ id: String) {
        guard isEditing else { return }
        draftTiles = QuickPanelEdits.hide(id, in: draftTiles)
        reload()
    }

    func add(_ id: String) {
        guard isEditing else { return }
        draftTiles = QuickPanelEdits.add(id, to: draftTiles, available: Set(available.map(\.id)))
        reload()
        selection = tiles.firstIndex(where: { $0.id == id }) ?? selection
    }

    func moveSelection(_ move: GridMove.Key) {
        guard isEditing, tiles.indices.contains(selection) else { return }
        let target = GridMove.next(from: selection, key: move, count: tiles.count, columns: Self.columns)
        let id = tiles[selection].id
        guard let draftTarget = draftTiles.firstIndex(of: tiles[target].id) else { return }
        draftTiles = QuickPanelEdits.move(id, to: draftTarget, in: draftTiles)
        reload()
        selection = target
    }

    private func reload() {
        let all = available
        tiles = (isEditing ? draftTiles : settings.tiles).compactMap { id in all.first { $0.id == id } }
        selection = min(selection, max(0, tiles.count - 1))
    }

    private func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard isOpen, panel?.windowNumber == windowNumber else { return false }
        let moves: [UInt16: GridMove.Key] = [CommandBarKeys.leftKey: .left, CommandBarKeys.rightKey: .right, PanelKeys.upKey: .up, PanelKeys.downKey: .down]
        if let move = moves[keyCode] {
            if isEditing && modifiers.contains(.option) { moveSelection(move) } else {
                selection = GridMove.next(from: selection, key: move, count: tiles.count, columns: Self.columns)
            }
        } else if keyCode == PanelKeys.returnKey || keyCode == PanelKeys.enterKey {
            run(selection)
        } else if keyCode == PanelKeys.escapeKey {
            if isEditing { finishEditing(save: false) } else { close() }
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
            HStack {
                Text(controller.isEditing ? "Edit Quick Panel" : "Quick Panel").font(.headline)
                Spacer()
                if controller.isEditing {
                    Button("Done") { controller.finishEditing(save: true) }
                } else {
                    Button("Edit") { controller.beginEditing() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    if controller.tiles.isEmpty {
                        Text("No tiles. Choose Edit to add actions.").foregroundStyle(.secondary).padding()
                    }
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
                            .overlay(alignment: .topTrailing) {
                                if controller.isEditing {
                                    Button { controller.hide(tile.id) } label: { Image(systemName: "minus.circle.fill") }
                                        .buttonStyle(.borderless)
                                        .padding(6)
                                        .help("Hide " + tile.title)
                                }
                            }
                            .id(tile.id)
                            .contentShape(Rectangle())
                            .onTapGesture { controller.run(index) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .onChange(of: controller.selection) { _, index in
                    if controller.tiles.indices.contains(index) { proxy.scrollTo(controller.tiles[index].id) }
                }
            }
            if controller.isEditing {
                HStack {
                    Menu("Add Tile") {
                        ForEach(controller.hiddenTiles) { tile in
                            Button(tile.title) { controller.add(tile.id) }
                        }
                    }
                    .disabled(controller.hiddenTiles.isEmpty)
                    Button { controller.moveSelection(.left) } label: { Image(systemName: "arrow.left") }
                        .help("Move selected tile earlier")
                    Button { controller.moveSelection(.right) } label: { Image(systemName: "arrow.right") }
                        .help("Move selected tile later")
                    Spacer()
                    Text("⌥ arrows reorder · Esc cancels").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
