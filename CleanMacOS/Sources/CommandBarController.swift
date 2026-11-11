import AppKit
import KeyboardShortcuts
import SwiftUI

struct CommandBarSettings: Codable, Equatable {
    var isEnabled = false
    var searchesWindows = true
    var searchesMenus = true
    var searchesSnippets = true
    var searchesClipboard = true
    var links: [CommandLink] = []
    var fileFolders: [String] = []
    var scripts: [CommandScript] = []
    var searchesScripts = false

    func holdsShortcut(for script: CommandScript) -> Bool {
        isEnabled && searchesScripts && script.shortcutEnabled && !script.hidden && script.normalized != nil
    }
}

extension CommandBarSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CommandBarSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        searchesWindows = try container.decodeIfPresent(Bool.self, forKey: .searchesWindows) ?? defaults.searchesWindows
        searchesMenus = try container.decodeIfPresent(Bool.self, forKey: .searchesMenus) ?? defaults.searchesMenus
        searchesSnippets = try container.decodeIfPresent(Bool.self, forKey: .searchesSnippets) ?? defaults.searchesSnippets
        searchesClipboard = try container.decodeIfPresent(Bool.self, forKey: .searchesClipboard) ?? defaults.searchesClipboard
        links = try container.decodeIfPresent([CommandLink].self, forKey: .links) ?? defaults.links
        scripts = try container.decodeIfPresent([CommandScript].self, forKey: .scripts) ?? defaults.scripts
        searchesScripts = try container.decodeIfPresent(Bool.self, forKey: .searchesScripts) ?? defaults.searchesScripts
        fileFolders = try container.decodeIfPresent([String].self, forKey: .fileFolders) ?? defaults.fileFolders
    }
}

enum CommandCategory: String, CaseIterable, Identifiable {
    case all, actions, apps, windows, menus, macSettings, snippets, clipboard, emoji, folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .actions: "Actions"
        case .apps: "Apps"
        case .windows: "Windows"
        case .menus: "Menus"
        case .macSettings: "Mac Settings"
        case .snippets: "Snippets"
        case .clipboard: "Clipboard"
        case .emoji: "Emoji"
        case .folders: "Folders"
        }
    }

    var kinds: Set<CommandKind> {
        switch self {
        case .all: Set(CommandKind.allCases)
        case .actions: [.action, .toggle, .setting, .fact, .quit]
        case .apps: [.app]
        case .windows: [.window]
        case .menus: [.menu]
        case .macSettings: [.macSetting]
        case .snippets: [.snippet]
        case .clipboard: [.clipboard]
        case .emoji: [.emoji]
        case .folders: [.folder]
        }
    }
}

enum CommandRow: Identifiable {
    case answer(CommandAnswer)
    case link(CommandLink, String)
    case item(CommandItem, argument: Int?)

    var id: String {
        switch self {
        case .answer(let answer): "answer.\(answer.kind).\(answer.title)"
        case .link(let link, _): "link.\(link.id)"
        case .item(let item, let argument): "\(item.id)#\(argument.map(String.init) ?? "")"
        }
    }
}

@MainActor
final class CommandBarController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "commandBar.settings"
    static let memoryKey = "commandBar.memory"
    static let size = NSSize(width: 560, height: 470)
    static let topShare: CGFloat = 0.72
    static let suggestionCount = 7
    static let homeActions = 12
    static let homeClipboard = 6
    static let categoryLimit = 40
    static let activeBonus = 20
    static let pinnedBonus = 60
    static let menuMinimum = 2
    static let previewLength = 40
    static let messageTime: TimeInterval = 1.4
    static let curated = ["clipboardHistory", "keepAwake", "darkMode", "snippetLibrary", "lock", "micMute", "cycleOutput"]

    @Published var settings: CommandBarSettings {
        didSet {
            scriptIntent += 1
            var saved = settings
            saved.scripts = Array(settings.scripts.compactMap(\.normalized).prefix(max(0, 60 - settings.links.count)))
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.settingsKey)
            configureScriptShortcuts()
            scheduleScript()
            if oldValue.isEnabled != settings.isEnabled {
                if settings.isEnabled { KeyboardShortcuts.enable([.commandBar]) } else { KeyboardShortcuts.disable([.commandBar]) }
            }
        }
    }
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scriptIntent += 1
            selection = 0
            confirming = nil
            rowActions = []
            rebuild()
            scheduleFileSearch()
            scheduleScript()
        }
    }
    @Published var category = CommandCategory.all {
        didSet {
            scriptIntent += 1
            selection = 0
            rebuild()
            scheduleScript()
        }
    }
    @Published private(set) var rows: [CommandRow] = []
    @Published var selection = 0 { didSet { if oldValue != selection { scriptIntent += 1 } } }
    @Published private(set) var confirming: String?
    @Published private(set) var isOpen = false
    @Published private(set) var rowActions: [CommandRowActionKind] = []
    @Published var actionSelection = 0

    private(set) var memory: CommandMemory
    private var items: [CommandItem] = []
    private var liveItems: [CommandItem] = []
    private var fileItems: [CommandItem] = []
    private var selectedText: String?
    private lazy var emojiItems = CommandSources.emoji(context.clipboard)
    private var fileSearch: DispatchWorkItem?
    private var fileToken = 0
    private var openToken = 0
    private var scriptIntent = 0
    private var scriptDebounce: DispatchWorkItem?
    private var scriptRuns = ScriptRunState()
    private var scriptWaiters: [ScriptRunKey: () -> Void] = [:]
    private var registeredScripts: Set<UUID> = []
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let context: CommandContext
    private let hud = InputHUD()

    init(context: CommandContext) {
        self.context = context
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(CommandBarSettings.self, from: $0) } ?? CommandBarSettings()
        memory = defaults.data(forKey: Self.memoryKey).flatMap { try? JSONDecoder().decode(CommandMemory.self, from: $0) } ?? CommandMemory()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .commandBar) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        configureScriptShortcuts()
        if !settings.isEnabled { KeyboardShortcuts.disable([.commandBar]) }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        openToken += 1
        let token = openToken
        scriptRuns.open()
        scriptWaiters = [:]
        let front = NSWorkspace.shared.frontmostApplication
        items = CommandSources.actions(context) + CommandSources.apps() + CommandSources.macSettings() + CommandSources.folders()
            + (settings.searchesSnippets ? CommandSources.snippets(context) : []) + (settings.searchesClipboard ? CommandSources.clipboard(context) : [])
        liveItems = []
        fileItems = []
        selectedText = nil
        rowActions = []
        query = ""
        category = .all
        confirming = nil
        rebuild()
        showPanel()
        let wantsWindows = settings.searchesWindows
        let isOtherAppInFront = front?.processIdentifier != getpid()
        let wantsMenus = settings.searchesMenus && isOtherAppInFront
        let wantsSelection = isOtherAppInFront && AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInitiated).async {
            let windows = wantsWindows ? CommandSources.windows() : []
            let menus = wantsMenus ? front.map(CommandSources.menus) ?? [] : []
            let selected = wantsSelection ? front.flatMap(TextInsertion.selectedText) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.openToken, self.isOpen else { return }
                    self.liveItems = windows + menus
                    self.selectedText = selected
                    let selected = self.selection
                    self.rebuild()
                    self.selection = min(selected, max(self.rows.count - 1, 0))
                }
            }
        }
    }

    func close() {
        scriptDebounce?.cancel()
        scriptWaiters = [:]
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = panel
        panel = nil
        closing?.orderOut(nil)
        isOpen = false
    }

    func resetRanking() {
        memory = CommandMemory()
        saveMemory()
    }

    func isPinned(_ row: CommandRow) -> Bool {
        if case .item(let item, _) = row { return memory.pins.contains(item.id) }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func run(_ index: Int, reveal: Bool = false) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .answer(let answer):
            close()
            if answer.kind == .link, let url = URL(string: answer.copyText) {
                NSWorkspace.shared.open(url)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.copyText, forType: .string)
                hud.show("Copied \(answer.title)", for: 1.4)
            }
        case .link(let link, let text):
            close()
            if let url = link.url(query: text, clipboard: NSPasteboard.general.string(forType: .string), selection: nil, date: Date()) {
                NSWorkspace.shared.open(url)
            }
        case .item(let item, let argument):
            if reveal {
                guard let url = item.revealURL else { return NSSound.beep() }
                close()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            if item.needsConfirmation && confirming != item.id {
                confirming = item.id
                return
            }
            memory.recordRun(item.id, query: query, at: Date())
            saveMemory()
            if item.keepsBarOpen { return item.run(argument) }
            close()
            DispatchQueue.main.async { item.run(argument) }
        }
    }

    func runRowAction(_ kind: CommandRowActionKind) {
        rowActions = []
        guard rows.indices.contains(selection) else { return }
        let row = rows[selection]
        guard case .item(let item, _) = row else { return run(selection) }
        switch kind {
        case .run:
            run(selection)
        case .reveal:
            run(selection, reveal: true)
        case .copyPath:
            copy(item.revealURL?.path ?? item.title)
        case .copyTitle:
            copy(item.title)
        case .quit:
            close()
            CommandRowActions.runningApp(at: item.revealURL)?.terminate()
        case .pin, .unpin:
            memory.togglePin(item.id)
            saveMemory()
            objectWillChange.send()
        }
    }

    private func copy(_ text: String) {
        close()
        ScreenTools.copy(text)
        hud.show("Copied \(text.prefix(Self.previewLength))", for: Self.messageTime)
    }

    private func showRowActions() {
        guard rows.indices.contains(selection) else { return NSSound.beep() }
        let row = rows[selection]
        var url: URL?
        if case .item(let item, _) = row { url = item.revealURL }
        rowActions = CommandRowActions.kinds(for: row, isPinned: isPinned(row), isRunning: CommandRowActions.runningApp(at: url) != nil)
        actionSelection = 0
    }

    private func performInActions(_ command: CommandBarCommand) {
        switch command {
        case .move(let delta):
            actionSelection = (actionSelection + delta + rowActions.count) % rowActions.count
        case .run:
            runRowAction(rowActions[actionSelection])
        case .escape, .actions:
            rowActions = []
        case .blocked:
            NSSound.beep()
        default:
            break
        }
    }

    private func perform(_ command: CommandBarCommand) {
        guard rowActions.isEmpty else { return performInActions(command) }
        switch command {
        case .move(let delta):
            guard !rows.isEmpty else { return }
            selection = (selection + delta + rows.count) % rows.count
        case .run:
            if rows.isEmpty { query = "" } else { run(selection) }
        case .reveal:
            run(selection, reveal: true)
        case .runNumber(let number):
            run(number - 1)
        case .complete:
            guard rows.indices.contains(selection) else { return }
            switch rows[selection] {
            case .answer(let answer): query = answer.kind == .calculation ? answer.copyText.filter { !$0.isWhitespace } : answer.title
            case .item(let item, _): query = item.title
            case .link(let link, _): query = link.keyword + " "
            }
        case .pin:
            guard rows.indices.contains(selection), case .item(let item, _) = rows[selection] else { return }
            memory.togglePin(item.id)
            saveMemory()
            objectWillChange.send()
        case .actions:
            showRowActions()
        case .escape:
            if !query.isEmpty { query = "" } else if category != .all { category = .all } else { close() }
        case .category(let step):
            let all = CommandCategory.allCases
            let index = all.firstIndex(of: category) ?? 0
            category = all[(index + step + all.count) % all.count]
        case .blocked:
            NSSound.beep()
        }
    }

    private func rebuild() {
        let text = query.trimmingCharacters(in: .whitespaces)
        if let emoji = EmojiCatalog.query(text) ?? (category == .emoji ? text : nil) {
            rows = emojiRows(emoji)
            return
        }
        let all = scriptItems() + items + liveItems + fileItems + CommandSources.quitRows(query) + CommandSources.facts(query)
        let pool = category == .all ? all : all.filter { category.kinds.contains($0.kind) }
        guard !text.isEmpty else {
            rows = home(pool)
            return
        }
        var result: [CommandRow] = []
        if category == .all {
            result += CommandAnswers.answers(for: text).map(CommandRow.answer)
            if settings.searchesScripts, let match = CommandScript.match(text, scripts: settings.scripts),
               let output = scriptRuns.results[ScriptRunKey(id: match.script.id, path: match.script.path, argument: match.argument)], let title = output.rowText {
                result.append(.answer(CommandAnswer(kind: .script, title: title, detail: match.script.name, copyText: title)))
            }
            if let match = CommandLink.match(text, links: settings.links) { result.append(.link(match.link, match.query)) }
            if let argument = CommandArgument.split(text) {
                let numbered = pool.filter { $0.numberRange != nil }
                for ranked in RustCore.rank(argument.text, numbered.map { RankRow(title: $0.title, keywords: $0.keywords) }).prefix(2) {
                    let item = numbered[ranked.index]
                    guard let range = item.numberRange else { continue }
                    result.append(.item(item, argument: min(max(argument.number, range.lowerBound), range.upperBound)))
                }
            }
        }
        if category == .all, settings.searchesScripts, let match = CommandScript.match(text, scripts: settings.scripts),
           let item = pool.first(where: { $0.id == "script.\(match.script.id)" }) {
            result.append(.item(item, argument: nil))
        }
        let present = Set(result.compactMap { row -> String? in if case .item(let item, _) = row { return item.id }; return nil })
        let candidates = pool.filter { !present.contains($0.id) }.filter { text.count >= Self.menuMinimum || $0.kind != .menu }
        let now = Date()
        let rankRows = candidates.map { item in
            RankRow(title: item.title, keywords: item.keywords,
                    bias: item.kind.bias + memory.usageBoost(for: item.id, now: now) + (item.isActive ? Self.activeBonus : 0)
                        + (memory.pins.contains(item.id) ? Self.pinnedBonus : 0),
                    priority: memory.priority(for: item.id, query: text))
        }
        let ranked = RustCore.rank(text, rankRows).map { candidates[$0.index] }
        let kept = category == .all ? CommandRanking.capped(ranked.map(\.kind)).map { ranked[$0] } : Array(ranked.prefix(Self.categoryLimit))
        rows = result + kept.map { .item($0, argument: nil) }
    }

    private func emojiRows(_ text: String) -> [CommandRow] {
        let limit = category == .emoji ? Self.categoryLimit : CommandRanking.totalLimit
        guard !text.isEmpty else { return emojiItems.prefix(limit).map { .item($0, argument: nil) } }
        let ranked = RustCore.rank(text, emojiItems.map { RankRow(title: $0.title, keywords: $0.keywords) })
        return ranked.prefix(limit).map { .item(emojiItems[$0.index], argument: nil) }
    }

    private func scheduleFileSearch() {
        fileSearch?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        let folders = settings.fileFolders
        guard !folders.isEmpty, EmojiCatalog.query(text) == nil, FileSearch.spotlightQuery(text) != nil else {
            fileItems = []
            return
        }
        fileToken += 1
        let token = fileToken
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let paths = FileSearch.search(text, in: folders)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, token == self.fileToken, self.isOpen else { return }
                        self.fileItems = paths.map(CommandSources.file)
                        let selected = self.selection
                        self.rebuild()
                        self.selection = min(selected, max(self.rows.count - 1, 0))
                    }
                }
            }
        }
        fileSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FileSearch.pause, execute: work)
    }

    private func home(_ pool: [CommandItem]) -> [CommandRow] {
        let now = Date()
        if category == .all, let selectedText {
            let actions = CommandSources.selection(selectedText, context: context) { [weak self] text in self?.query = text }
            return actions.map { .item($0, argument: nil) } + homeRows(pool, now: now)
        }
        return homeRows(pool, now: now)
    }

    private func homeRows(_ pool: [CommandItem], now: Date) -> [CommandRow] {
        guard category == .all else {
            return pool.sorted { memory.usageBoost(for: $0.id, now: now) > memory.usageBoost(for: $1.id, now: now) }
                .prefix(Self.categoryLimit).map { .item($0, argument: nil) }
        }
        let pinned = memory.pins.compactMap { id in pool.first { $0.id == id } }
        var shown = Set(pinned.map(\.id))
        let used = pool.filter { memory.usage[$0.id] != nil && !shown.contains($0.id) }.sorted { lhs, rhs in
            let left = memory.usage[lhs.id]!
            let right = memory.usage[rhs.id]!
            return left.count != right.count ? left.count > right.count : left.lastUsed > right.lastUsed
        }
        var suggestions = Array(used.prefix(max(0, Self.suggestionCount - pinned.count)))
        for id in Self.curated where suggestions.count + pinned.count < Self.suggestionCount {
            if let item = pool.first(where: { $0.id == id }), !shown.contains(id), !suggestions.contains(where: { $0.id == id }) { suggestions.append(item) }
        }
        shown.formUnion(suggestions.map(\.id))
        let actions = pool.filter { ($0.kind == .action || $0.kind == .toggle) && !shown.contains($0.id) }.prefix(Self.homeActions)
        let clips = pool.filter { $0.kind == .clipboard }.prefix(Self.homeClipboard)
        return (pinned + suggestions + actions + clips).map { .item($0, argument: nil) }
    }

    private func scriptItems() -> [CommandItem] {
        guard settings.searchesScripts else { return [] }
        return settings.scripts.compactMap(\.normalized).filter { !$0.hidden }.map { script in
            CommandItem(id: "script.\(script.id)", kind: .action, title: script.name, subtitle: script.path,
                        icon: .symbol("terminal"), keepsBarOpen: true) { [weak self] _ in self?.runScriptRow(script) }
        }
    }

    private func runScriptRow(_ script: CommandScript) {
        guard let argument = script.argument(in: query) ?? (script.runOnBareName ? "" : nil) else {
            query = script.name + " "
            return
        }
        let key = ScriptRunKey(id: script.id, path: script.path, argument: argument)
        if let result = scriptRuns.results[key] {
            if let text = result.rowText { copy(text) }
            return
        }
        let token = openToken
        let intent = scriptIntent
        let originalQuery = query
        let originalCategory = category
        let originalSelection = selection
        scriptWaiters[key] = { [weak self] in
            guard let self, self.isOpen, self.openToken == token, self.scriptIntent == intent, self.settings.searchesScripts, self.query == originalQuery,
                  self.category == originalCategory, self.selection == originalSelection,
                  let text = self.scriptRuns.results[key]?.rowText else { return }
            self.copy(text)
        }
        startScript(script, argument: argument)
    }

    private func scheduleScript() {
        scriptDebounce?.cancel()
        guard isOpen, category == .all, settings.searchesScripts, EmojiCatalog.query(query) == nil,
              let match = CommandScript.match(query, scripts: settings.scripts) else { return }
        let work = DispatchWorkItem { [weak self] in self?.startScript(match.script, argument: match.argument) }
        scriptDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startScript(_ script: CommandScript, argument: String) {
        let key = ScriptRunKey(id: script.id, path: script.path, argument: argument)
        guard scriptRuns.begin(key) else { return }
        let opening = scriptRuns.opening
        let token = openToken
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CommandScriptRunner.run(path: script.path, argument: argument)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scriptRuns.finish(key, result: result, opening: opening)
                guard self.openToken == token else { self.scheduleScript(); return }
                let waiter = self.scriptWaiters.removeValue(forKey: key)
                waiter?()
                self.rebuild()
            }
        }
    }

    private func configureScriptShortcuts() {
        for id in registeredScripts { KeyboardShortcuts.disable([.commandScript(id)]) }
        registeredScripts = Set(settings.scripts.map(\.id))
        for script in settings.scripts.compactMap(\.normalized) {
            let name = KeyboardShortcuts.Name.commandScript(script.id)
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.settings.holdsShortcut(for: script) else { return }
                    if script.directShortcut {
                        let key = ScriptRunKey(id: script.id, path: script.path, argument: "")
                        guard self.scriptRuns.begin(key, direct: true) else { return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = CommandScriptRunner.run(path: script.path, argument: "")
                            DispatchQueue.main.async {
                                self.scriptRuns.finish(key, result: result, opening: nil)
                                if result.failed { NSSound.beep() }
                            }
                        }
                    } else {
                        self.open()
                        self.query = script.name + " "
                    }
                }
            }
            if settings.holdsShortcut(for: script) { KeyboardShortcuts.enable([name]) }
            else { KeyboardShortcuts.disable([name]) }
        }
    }

    private func saveMemory() {
        UserDefaults.standard.set(try? JSONEncoder().encode(memory), forKey: Self.memoryKey)
    }

    private func showPanel() {
        let panel = self.panel ?? KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: CommandBarView(bar: self))
            host.sizingOptions = []
            panel.contentViewController = host
        }
        panel.setContentSize(Self.size)
        panel.delegate = self
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            let top = visible.minY + visible.height * Self.topShare
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: max(visible.minY, top - Self.size.height)))
        }
        self.panel = panel
        isOpen = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.windowNumber == windowNumber else { return false }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                guard let command = CommandBarKeys.command(keyCode: keyCode, modifiers: modifiers, queryIsEmpty: self.query.isEmpty) else { return false }
                self.perform(command)
                return true
            }
            return isHandled ? nil : event
        }
    }
}
