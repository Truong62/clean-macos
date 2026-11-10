import AppKit
import ApplicationServices
import IOKit.ps

struct CommandItem: Identifiable {
    enum Icon {
        case symbol(String)
        case file(String)
        case text(String)
    }

    let id: String
    let kind: CommandKind
    let title: String
    var subtitle: String
    var keywords = ""
    var icon: Icon
    var isActive = false
    var shortcut: String?
    var numberRange: ClosedRange<Int>?
    var needsConfirmation = false
    var revealURL: URL?
    var keepsBarOpen = false
    let run: @MainActor (Int?) -> Void
}

@MainActor
struct CommandContext {
    let keepAwake: KeepAwake
    let sound: SoundController
    let brightness: BrightnessController
    let clipboard: ClipboardViewModel
    let snippets: SnippetExpander
    let shelf: ShelfController
    let screenTools: ScreenTools
    let scratchpad: ScratchpadController
    let camera: CameraPreviewController
    let quitApps: QuitAppsController
    let openPage: (SidebarPage) -> Void
}

@MainActor
enum CommandSources {
    static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
    nonisolated static let menuDepth = 4
    nonisolated static let menuLimit = 400
    nonisolated static let windowLimit = 60
    nonisolated static let skippedMenus: Set<String> = ["Apple", "Window", "Help"]
    static let quitWords = ["quit", "close", "thoat"]
    static let keepAwakeMinutes = [15, 30, 120, 240, 480]
    nonisolated(unsafe) private static var cachedApps: (date: Date, apps: [(name: String, url: URL, bundleID: String?)])?
    static let appCacheLife: TimeInterval = 60

    static func actions(_ context: CommandContext) -> [CommandItem] {
        let controls = QuickControls()
        var items: [CommandItem] = ToolGroup.allTools.map { tool in
            CommandItem(id: "page.\(tool.page)", kind: .setting, title: tool.title, subtitle: "MacKit · \(tool.summary)",
                        keywords: tool.summary, icon: .symbol(tool.icon)) { _ in context.openPage(tool.page) }
        }
        items += [
            CommandItem(id: "keepAwake", kind: .toggle, title: context.keepAwake.isActive ? "Turn off Keep Awake" : "Turn on Keep Awake",
                        subtitle: "Keep the Mac awake", keywords: "caffeinate sleep awake", icon: .symbol("cup.and.saucer.fill"),
                        isActive: context.keepAwake.isActive) { _ in context.keepAwake.toggle() },
            CommandItem(id: "darkMode", kind: .toggle, title: controls.isDarkMode ? "Turn off Dark Mode" : "Turn on Dark Mode", subtitle: "Appearance",
                        keywords: "dark light appearance theme", icon: .symbol("circle.lefthalf.filled")) { _ in controls.setDarkMode(!controls.isDarkMode) },
            CommandItem(id: "hiddenFiles", kind: .toggle, title: "Show or Hide Hidden Files", subtitle: "Finder", keywords: "dotfiles invisible",
                        icon: .symbol("eye")) { _ in controls.set(.hiddenFiles, !controls.isOn(.hiddenFiles)) },
            CommandItem(id: "desktopIcons", kind: .toggle, title: "Show or Hide Desktop Icons", subtitle: "Finder", keywords: "clean desktop",
                        icon: .symbol("menubar.dock.rectangle")) { _ in controls.set(.desktopIcons, !controls.isOn(.desktopIcons)) },
            CommandItem(id: "lock", kind: .action, title: "Lock Screen", subtitle: "Security", keywords: "lock away", icon: .symbol("lock.fill")) { _ in
                controls.lockScreen()
            },
            CommandItem(id: "displaySleep", kind: .action, title: "Sleep Display", subtitle: "Displays", keywords: "screen off", icon: .symbol("moon.fill")) { _ in
                controls.sleepDisplay()
            },
            CommandItem(id: "screenSaver", kind: .action, title: "Start Screen Saver", subtitle: "Displays", keywords: "screensaver",
                        icon: .symbol("sparkles.tv")) { _ in controls.startScreenSaver() },
            CommandItem(id: "emptyTrash", kind: .action, title: "Empty Trash", subtitle: "Finder · asks first", keywords: "bin delete",
                        icon: .symbol("trash.fill"), needsConfirmation: true) { _ in controls.emptyTrash() },
            CommandItem(id: "quitAll", kind: .action, title: "Quit Apps…", subtitle: "Pick which open apps to quit", keywords: "quit all close everything",
                        icon: .symbol("xmark.app.fill")) { _ in context.quitApps.open() },
            CommandItem(id: "micMute", kind: .toggle, title: context.sound.isMicMuted ? "Unmute Microphones" : "Mute Microphones", subtitle: "Sound",
                        keywords: "mic mute microphone", icon: .symbol("mic.slash.fill"), isActive: context.sound.isMicMuted) { _ in
                context.sound.toggleMicMute()
            },
            CommandItem(id: "cycleOutput", kind: .action, title: "Switch Sound Output", subtitle: "Sound", keywords: "speakers headphones output device",
                        icon: .symbol("hifispeaker.2.fill")) { _ in context.sound.cycleOutput() },
            CommandItem(id: "volume", kind: .action, title: "Set Volume", subtitle: "Type a number, like volume 40", keywords: "sound loudness",
                        icon: .symbol("speaker.wave.2.fill"), numberRange: 0...100) { number in
                context.sound.setOutputVolume(Double(number ?? 50) / 100)
            },
            CommandItem(id: "clipboardHistory", kind: .action, title: "Clipboard History", subtitle: "Clipboard", keywords: "paste copied",
                        icon: .symbol("doc.on.clipboard")) { _ in NotificationCenter.default.post(name: .toggleClipboardPanel, object: nil) },
            CommandItem(id: "plainPaste", kind: .action, title: "Paste as Plain Text", subtitle: "Clipboard", keywords: "unformatted",
                        icon: .symbol("textformat")) { _ in context.clipboard.pastePlainText() },
            CommandItem(id: "pickColor", kind: .action, title: "Pick a Color", subtitle: "Tools · copies HEX, RGB, HSL or SwiftUI",
                        keywords: "eyedropper color picker sample", icon: .symbol("eyedropper")) { _ in context.screenTools.pickColor() },
            CommandItem(id: "grabText", kind: .action, title: "Grab Text from the Screen", subtitle: "Tools · OCR and QR codes",
                        keywords: "ocr recognize scan qr", icon: .symbol("text.viewfinder")) { _ in context.screenTools.grabText() },
            CommandItem(id: "snippetLibrary", kind: .action, title: "Snippet Library", subtitle: "Snippets", keywords: "text expansion",
                        icon: .symbol("text.badge.plus")) { _ in context.snippets.openLibrary() },
            CommandItem(id: "scratchpad", kind: .toggle, title: "Scratchpad", subtitle: "Tools · floating notes", keywords: "notes notepad markdown jot",
                        icon: .symbol("note.text"), isActive: context.scratchpad.isOpen) { _ in context.scratchpad.toggle() },
            CommandItem(id: "cameraPreview", kind: .toggle, title: "Camera Preview", subtitle: "Tools · mirror before a call", keywords: "webcam mirror facetime video",
                        icon: .symbol("web.camera"), isActive: context.camera.isOpen) { _ in context.camera.toggle() },
        ]
        if let capture = context.screenTools.screenshot {
            let permission = ScreenshotHardware.permitted ? "Screenshot" : "Requires Screen Recording access"
            for (id, title, mode) in [("captureArea", "Capture Area or Window", CaptureMode.screenshot), ("captureScroll", "Capture Scrolling Region", CaptureMode.scrolling)] {
                items.append(CommandItem(id: id, kind: .action, title: title, subtitle: permission, keywords: "screenshot capture", icon: .symbol("viewfinder")) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { capture.start(mode) }
                })
            }
            items.append(CommandItem(id: "captureDisplay", kind: .action, title: "Capture Full Display", subtitle: permission, icon: .symbol("display")) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { capture.start(displayOnly: true) }
            })
            items.append(CommandItem(id: "captureHistory", kind: .action, title: "Recent Captures", subtitle: "Screenshot history", icon: .symbol("photo.stack")) { _ in capture.showHistory() })
            items.append(CommandItem(id: "captureLatest", kind: .action, title: "Edit Latest Screenshot", subtitle: "Open in editor", icon: .symbol("pencil")) { _ in capture.editLatest() })
        }
        items += keepAwakeMinutes.map { minutes in
            CommandItem(id: "keepAwake.\(minutes)", kind: .action, title: "Keep Awake for \(minutes >= 60 ? "\(minutes / 60) hours" : "\(minutes) minutes")",
                        subtitle: "Keep Awake", keywords: "caffeinate timer", icon: .symbol("timer")) { _ in context.keepAwake.start(.minutes(minutes)) }
        }
        if context.brightness.settings.isEnabled, let main = NSScreen.main?.displayID {
            items.append(CommandItem(id: "brightness", kind: .action, title: "Set Brightness", subtitle: "Type a number, like brightness 40",
                                     keywords: "display screen dim", icon: .symbol("sun.max.fill"), numberRange: 0...100) { number in
                context.brightness.setLevel(Double(number ?? 50) / 100, for: main)
            })
        }
        if context.shelf.settings.isEnabled {
            items.append(CommandItem(id: "shelf", kind: .toggle, title: "Shelf", subtitle: "\(context.shelf.items.count) items", keywords: "drop stash files",
                                     icon: .symbol("tray.full.fill"), isActive: context.shelf.isOpen) { _ in context.shelf.toggle() })
        }
        return items
    }

    static func apps() -> [CommandItem] {
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
                                 uniquingKeysWith: { first, _ in first })
        return installedApps().map { entry in
            let app = entry.bundleID.flatMap { running[$0] }
            return CommandItem(id: "app.\(entry.bundleID ?? entry.url.path)", kind: .app, title: entry.name, subtitle: app == nil ? "Application" : "Running",
                               keywords: entry.url.deletingPathExtension().lastPathComponent, icon: .file(entry.url.path), isActive: app != nil,
                               revealURL: entry.url) { _ in
                if let app {
                    app.activate()
                } else {
                    NSWorkspace.shared.openApplication(at: entry.url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    static func installedApps() -> [(name: String, url: URL, bundleID: String?)] {
        if let cachedApps, Date().timeIntervalSince(cachedApps.date) < appCacheLife { return cachedApps.apps }
        let manager = FileManager.default
        let folders = appFolders.map { URL(fileURLWithPath: $0) } + [manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [String: (name: String, url: URL, bundleID: String?)] = [:]
        for folder in folders {
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let candidates = url.pathExtension == "app" ? [url] : ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "app" }
                for app in candidates where found[app.path] == nil {
                    found[app.path] = (manager.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), app, Bundle(url: app)?.bundleIdentifier)
                }
            }
        }
        let apps = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedApps = (Date(), apps)
        return apps
    }

    nonisolated static func windows() -> [CommandItem] {
        var items: [CommandItem] = []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        for app in apps where items.count < windowLimit {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows: [AXUIElement] = AXWindow.value(element, kAXWindowsAttribute) else { continue }
            for window in windows {
                guard let title: String = AXWindow.value(window, kAXTitleAttribute), !title.isEmpty else { continue }
                let name = app.localizedName ?? "App"
                items.append(CommandItem(id: "window.\(app.processIdentifier).\(title)", kind: .window, title: title, subtitle: "Window · \(name)",
                                         keywords: name, icon: .file(app.bundleURL?.path ?? "/")) { _ in
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    app.activate()
                })
            }
        }
        return items
    }

    nonisolated static func menus(of app: NSRunningApplication) -> [CommandItem] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = AXWindow.value(element, kAXMenuBarAttribute),
              let menus: [AXUIElement] = AXWindow.value(bar, kAXChildrenAttribute) else { return [] }
        var items: [CommandItem] = []
        for menu in menus.dropFirst() {
            guard let title: String = AXWindow.value(menu, kAXTitleAttribute), !skippedMenus.contains(title) else { continue }
            collect(menu, path: [title], depth: 1, app: app, into: &items)
            if items.count >= menuLimit { break }
        }
        return items
    }

    nonisolated private static func collect(_ element: AXUIElement, path: [String], depth: Int, app: NSRunningApplication, into items: inout [CommandItem]) {
        guard depth <= menuDepth, items.count < menuLimit, let children: [AXUIElement] = AXWindow.value(element, kAXChildrenAttribute) else { return }
        for child in children {
            if AXWindow.role(child) == kAXMenuRole {
                collect(child, path: path, depth: depth, app: app, into: &items)
                continue
            }
            guard let title: String = AXWindow.value(child, kAXTitleAttribute), !title.isEmpty else { continue }
            let enabled: Bool = AXWindow.value(child, kAXEnabledAttribute) ?? true
            if AXWindow.value(child, kAXChildrenAttribute).map({ (list: [AXUIElement]) in !list.isEmpty }) == true {
                collect(child, path: path + [title], depth: depth + 1, app: app, into: &items)
            } else if enabled {
                items.append(CommandItem(id: "menu.\((path + [title]).joined(separator: ">"))", kind: .menu, title: title,
                                         subtitle: (path).joined(separator: " › ") + " · \(app.localizedName ?? "")", keywords: path.joined(separator: " "),
                                         icon: .symbol("filemenu.and.selection"), shortcut: shortcut(of: child)) { _ in
                    AXUIElementPerformAction(child, kAXPressAction as CFString)
                })
            }
            if items.count >= menuLimit { return }
        }
    }

    nonisolated private static func shortcut(of item: AXUIElement) -> String? {
        guard let key: String = AXWindow.value(item, kAXMenuItemCmdCharAttribute), !key.isEmpty else { return nil }
        let modifiers: Int = AXWindow.value(item, kAXMenuItemCmdModifiersAttribute) ?? 0
        var text = ""
        if modifiers & 4 != 0 { text += "⌃" }
        if modifiers & 2 != 0 { text += "⌥" }
        if modifiers & 1 != 0 { text += "⇧" }
        if modifiers & 8 == 0 { text += "⌘" }
        return text + key
    }

    static func macSettings() -> [CommandItem] {
        MacSettingsPane.all.map { pane in
            CommandItem(id: "settings.\(pane.id)", kind: .macSetting, title: pane.title, subtitle: "System Settings", keywords: pane.keywords,
                        icon: .symbol("gearshape")) { _ in
                if let url = URL(string: "x-apple.systempreferences:\(pane.id)") { NSWorkspace.shared.open(url) }
            }
        }
    }

    static func folders() -> [CommandItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places: [(String, URL)] = [("Home", home), ("Desktop", home.appendingPathComponent("Desktop")), ("Documents", home.appendingPathComponent("Documents")),
                                       ("Downloads", home.appendingPathComponent("Downloads")), ("Pictures", home.appendingPathComponent("Pictures")),
                                       ("Movies", home.appendingPathComponent("Movies")), ("Music", home.appendingPathComponent("Music")),
                                       ("Applications", URL(fileURLWithPath: "/Applications")), ("Library", home.appendingPathComponent("Library")),
                                       ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))]
        return places.filter { FileManager.default.fileExists(atPath: $0.1.path) }.map { name, url in
            CommandItem(id: "folder.\(name)", kind: .folder, title: name, subtitle: url.path.replacingOccurrences(of: home.path, with: "~"),
                        icon: .file(url.path), revealURL: url) { _ in NSWorkspace.shared.open(url) }
        }
    }

    static func emoji(_ clipboard: ClipboardViewModel) -> [CommandItem] {
        EmojiCatalog.entries.map { entry in
            CommandItem(id: "emoji.\(entry.glyph)", kind: .emoji, title: entry.name.capitalized, subtitle: "Emoji · Return types it", keywords: entry.glyph,
                        icon: .text(entry.glyph)) { _ in TextInsertion.type(entry.glyph, clipboard: clipboard) }
        }
    }

    static func file(_ path: String) -> CommandItem {
        let url = URL(fileURLWithPath: path)
        return CommandItem(id: "file.\(path)", kind: .file, title: url.lastPathComponent,
                           subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, icon: .file(path), revealURL: url) { _ in
            NSWorkspace.shared.open(url)
        }
    }

    static func selection(_ text: String, context: CommandContext, useAsQuery: @escaping @MainActor (String) -> Void) -> [CommandItem] {
        let preview = text.count > CommandBarController.previewLength ? String(text.prefix(CommandBarController.previewLength)) + "…" : text
        var items = [
            CommandItem(id: "selection.copy", kind: .action, title: "Copy “\(preview)”", subtitle: "Selected text", icon: .symbol("doc.on.doc")) { _ in
                ScreenTools.copy(text)
            },
            CommandItem(id: "selection.search", kind: .action, title: "Search for “\(preview)”", subtitle: "Selected text · use it as the query",
                        icon: .symbol("magnifyingglass"), keepsBarOpen: true) { _ in useAsQuery(text) },
        ]
        if let cleaned = URLCleaner.clean(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            items.append(CommandItem(id: "selection.cleanLink", kind: .action, title: "Copy Clean Link", subtitle: cleaned.url, icon: .symbol("link")) { _ in
                ScreenTools.copy(cleaned.url)
            })
        }
        items += TextTransform.allCases.map { transform in
            CommandItem(id: "selection.\(transform.rawValue)", kind: .action, title: transform.title, subtitle: "Replace the selected text",
                        icon: .symbol("textformat")) { _ in TextInsertion.type(transform.apply(text), clipboard: context.clipboard) }
        }
        if context.shelf.settings.isEnabled {
            items.append(CommandItem(id: "selection.shelf", kind: .action, title: "Send to Shelf", subtitle: "Selected text", icon: .symbol("tray.and.arrow.down")) { _ in
                context.shelf.add([ShelfItem(kind: .text, text: text)])
            })
        }
        let counts = TextCounts(text).summary
        items.append(CommandItem(id: "selection.counts", kind: .fact, title: counts, subtitle: "Selected text · Return copies", icon: .symbol("number")) { _ in
            ScreenTools.copy(counts)
        })
        return items
    }

    static func snippets(_ context: CommandContext) -> [CommandItem] {
        context.snippets.snippets.filter(\.isEnabled).map { snippet in
            CommandItem(id: "snippet.\(snippet.id)", kind: .snippet, title: snippet.title, subtitle: "Snippet · \(snippet.trigger)",
                        keywords: "\(snippet.trigger) \(snippet.folder)", icon: .symbol("text.quote")) { _ in context.snippets.insert(snippet) }
        }
    }

    static func clipboard(_ context: CommandContext) -> [CommandItem] {
        context.clipboard.items.prefix(50).map { item in
            CommandItem(id: "clip.\(item.id)", kind: .clipboard, title: item.preview, subtitle: "Clipboard · \(item.createdAt.formatted(.relative(presentation: .named)))",
                        icon: .symbol("doc.on.clipboard")) { _ in
                guard context.clipboard.copy(item) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { PasteService.pasteToFrontmostApp() }
            }
        }
    }

    static func quitRows(_ query: String) -> [CommandItem] {
        let words = query.lowercased().split(separator: " ")
        guard words.contains(where: { quitWords.contains(String($0)) }) else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.map { app in
            CommandItem(id: "quit.\(app.bundleIdentifier ?? "\(app.processIdentifier)")", kind: .quit, title: "Quit \(app.localizedName ?? "App")",
                        subtitle: "Running app", keywords: "quit close", icon: .file(app.bundleURL?.path ?? "/")) { _ in app.terminate() }
        }
    }

    static func facts(_ query: String) -> [CommandItem] {
        guard let first = query.lowercased().split(separator: " ").first, first.count >= 3 else { return [] }
        let word = String(first)
        var facts: [CommandItem] = []
        if "battery".hasPrefix(word), let battery = batteryText() {
            facts.append(fact("battery", "Battery \(battery)", "battery.100", battery))
        }
        if "memory".hasPrefix(word) {
            let total = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
            facts.append(fact("memory", "\(total) of memory", "memorychip", total))
        }
        if "storage".hasPrefix(word), let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage {
            let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            facts.append(fact("storage", "\(text) free on the startup disk", "internaldrive", text))
        }
        if "date".hasPrefix(word) {
            let text = Date().formatted(date: .complete, time: .omitted)
            facts.append(fact("date", text, "calendar", text))
        }
        if "time".hasPrefix(word) && !query.lowercased().hasPrefix("time in ") {
            let text = Date().formatted(date: .omitted, time: .standard)
            facts.append(fact("time", text, "clock", text))
        }
        return facts
    }

    private static func fact(_ id: String, _ title: String, _ symbol: String, _ copy: String) -> CommandItem {
        CommandItem(id: "fact.\(id)", kind: .fact, title: title, subtitle: "Return copies", icon: .symbol(symbol)) { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        }
    }

    private static func batteryText() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = details[kIOPSCurrentCapacityKey] as? Int, let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = details[kIOPSIsChargingKey] as? Bool == true ? ", charging" : ""
            return "\(current * 100 / maximum)%\(charging)"
        }
        return nil
    }
}

struct MacSettingsPane {
    let id: String
    let title: String
    let keywords: String

    static let all: [MacSettingsPane] = [
        MacSettingsPane(id: "com.apple.wifi-settings-extension", title: "Wi-Fi", keywords: "wireless network internet"),
        MacSettingsPane(id: "com.apple.BluetoothSettings", title: "Bluetooth", keywords: "airpods devices"),
        MacSettingsPane(id: "com.apple.Network-Settings.extension", title: "Network", keywords: "ethernet vpn dns"),
        MacSettingsPane(id: "com.apple.Notifications-Settings.extension", title: "Notifications", keywords: "alerts banners"),
        MacSettingsPane(id: "com.apple.Sound-Settings.extension", title: "Sound", keywords: "volume output input"),
        MacSettingsPane(id: "com.apple.Focus-Settings.extension", title: "Focus", keywords: "do not disturb"),
        MacSettingsPane(id: "com.apple.Screen-Time-Settings.extension", title: "Screen Time", keywords: "limits usage"),
        MacSettingsPane(id: "com.apple.SystemProfiler.AboutExtension", title: "About This Mac", keywords: "general version serial"),
        MacSettingsPane(id: "com.apple.Software-Update-Settings.extension", title: "Software Update", keywords: "upgrade macos"),
        MacSettingsPane(id: "com.apple.settings.Storage", title: "Storage", keywords: "disk space"),
        MacSettingsPane(id: "com.apple.Appearance-Settings.extension", title: "Appearance", keywords: "dark light accent"),
        MacSettingsPane(id: "com.apple.Accessibility-Settings.extension", title: "Accessibility", keywords: "zoom voiceover"),
        MacSettingsPane(id: "com.apple.ControlCenter-Settings.extension", title: "Control Center", keywords: "menu bar"),
        MacSettingsPane(id: "com.apple.Siri-Settings.extension", title: "Siri", keywords: "apple intelligence assistant"),
        MacSettingsPane(id: "com.apple.settings.PrivacySecurity.extension", title: "Privacy & Security", keywords: "permissions accessibility screen recording"),
        MacSettingsPane(id: "com.apple.Desktop-Settings.extension", title: "Desktop & Dock", keywords: "dock stage manager hot corners"),
        MacSettingsPane(id: "com.apple.Displays-Settings.extension", title: "Displays", keywords: "monitor resolution night shift"),
        MacSettingsPane(id: "com.apple.Wallpaper-Settings.extension", title: "Wallpaper", keywords: "background"),
        MacSettingsPane(id: "com.apple.ScreenSaver-Settings.extension", title: "Screen Saver", keywords: "screensaver"),
        MacSettingsPane(id: "com.apple.Battery-Settings.extension", title: "Battery", keywords: "energy power"),
        MacSettingsPane(id: "com.apple.Lock-Screen-Settings.extension", title: "Lock Screen", keywords: "password sleep"),
        MacSettingsPane(id: "com.apple.Touch-ID-Settings.extension", title: "Touch ID & Password", keywords: "fingerprint login"),
        MacSettingsPane(id: "com.apple.Users-Groups-Settings.extension", title: "Users & Groups", keywords: "accounts"),
        MacSettingsPane(id: "com.apple.Passwords-Settings.extension", title: "Passwords", keywords: "keychain"),
        MacSettingsPane(id: "com.apple.Internet-Accounts-Settings.extension", title: "Internet Accounts", keywords: "mail icloud google"),
        MacSettingsPane(id: "com.apple.Keyboard-Settings.extension", title: "Keyboard", keywords: "shortcuts input sources"),
        MacSettingsPane(id: "com.apple.Trackpad-Settings.extension", title: "Trackpad", keywords: "gestures"),
        MacSettingsPane(id: "com.apple.Mouse-Settings.extension", title: "Mouse", keywords: "scroll"),
        MacSettingsPane(id: "com.apple.Print-Scan-Settings.extension", title: "Printers & Scanners", keywords: "printer"),
        MacSettingsPane(id: "com.apple.Date-Time-Settings.extension", title: "Date & Time", keywords: "clock time zone"),
        MacSettingsPane(id: "com.apple.Sharing-Settings.extension", title: "Sharing", keywords: "airdrop screen sharing remote"),
        MacSettingsPane(id: "com.apple.Time-Machine-Settings.extension", title: "Time Machine", keywords: "backup"),
        MacSettingsPane(id: "com.apple.LoginItems-Settings.extension", title: "Login Items", keywords: "startup open at login"),
        MacSettingsPane(id: "com.apple.Startup-Disk-Settings.extension", title: "Startup Disk", keywords: "boot"),
    ]
}
