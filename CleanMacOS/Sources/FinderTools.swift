import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct RenameKey: Codable, Equatable {
    static let f2 = RenameKey(keyCode: kVK_F2, modifiers: 0)
    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    static let names: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter",
        kVK_Space: "Space", kVK_Tab: "Tab",
    ]

    var keyCode: Int
    var modifiers: UInt64

    func matches(keyCode: Int, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevant).rawValue == modifiers
    }

    var title: String {
        let flags = CGEventFlags(rawValue: modifiers)
        let symbols: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + (Self.names[keyCode] ?? "Key \(keyCode)")
    }
}

struct FinderSettings: Codable, Equatable {
    var cutsAndPastes = false
    var showsHUD = true
    var renames = false
    var renameKey = RenameKey.f2
    var pastesImages = false
    var showsTransferProgress = false
}

enum FinderAction: Equatable {
    case cut, moveCut, cancelCut, pasteImage, rename
}

enum FinderKeys {
    static func action(keyCode: Int, flags: CGEventFlags, settings: FinderSettings, hasCut: Bool, hasImage: @autoclosure () -> Bool) -> FinderAction? {
        if settings.renames && settings.renameKey.matches(keyCode: keyCode, flags: flags) { return .rename }
        guard flags.intersection(RenameKey.relevant) == .maskCommand else { return nil }
        switch keyCode {
        case kVK_ANSI_X where settings.cutsAndPastes: return .cut
        case kVK_ANSI_C where settings.cutsAndPastes && hasCut: return .cancelCut
        case kVK_ANSI_V where settings.cutsAndPastes && hasCut: return .moveCut
        case kVK_ANSI_V where settings.pastesImages && hasImage(): return .pasteImage
        default: return nil
        }
    }
}

enum FileMove {
    static func destination(for source: URL, in folder: URL, exists: (URL) -> Bool) -> URL? {
        guard source.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path else { return nil }
        let name = source.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

enum FileMover {
    struct Result: Equatable {
        var moved = 0
        var unchanged = 0
        var denied: [URL] = []
        var failed: [URL] = []
    }

    static let deniedCodes: Set<CocoaError.Code> = [.fileWriteNoPermission, .fileReadNoPermission]

    static func move(_ items: [URL], into folder: URL, fileManager: FileManager = .default,
                     started: (URL, URL) -> Void = { _, _ in }, finished: (URL) -> Void = { _ in }) -> Result {
        var result = Result()
        for item in items {
            guard let target = FileMove.destination(for: item, in: folder, exists: { fileManager.fileExists(atPath: $0.path) }) else {
                result.unchanged += 1
                continue
            }
            started(item, target)
            defer { finished(item) }
            do {
                try fileManager.moveItem(at: item, to: target)
                result.moved += 1
            } catch let error as CocoaError where deniedCodes.contains(error.code) {
                result.denied.append(item)
            } catch {
                result.failed.append(item)
            }
        }
        return result
    }
}

enum PastedImage {
    static let maxBytes = 64 * 1_048_576

    static func fileName(at date: Date, prefix: String = "Pasted_Image", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: date)).png"
    }

    static func isOffered(by pasteboard: NSPasteboard) -> Bool {
        !(pasteboard.types ?? []).contains(.fileURL) && NSImage.canInit(with: pasteboard)
    }

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png.count <= maxBytes ? png : nil }
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation, tiff.count <= maxBytes else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

enum FinderScript {
    static let selection = """
    with timeout of 10 seconds
        tell application "Finder"
            set chosen to ""
            repeat with anItem in (get selection)
                set chosen to chosen & POSIX path of (anItem as alias) & linefeed
            end repeat
            return chosen
        end tell
    end timeout
    """
    static let insertionLocation = """
    with timeout of 10 seconds
        tell application "Finder" to return POSIX path of (insertion location as alias)
    end timeout
    """

    static func urls(from output: String) -> [URL] {
        output.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0)) }
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func move(_ items: [URL], to folder: URL) -> String {
        let list = items.map { "POSIX file \(quoted($0.path)) as alias" }.joined(separator: ", ")
        return "with timeout of 600 seconds\ntell application \"Finder\" to move {\(list)} to (POSIX file \(quoted(folder.path)) as alias)\nend timeout"
    }

    static func run(_ script: String, runner: CommandRunning = SystemCommandRunner()) -> String? {
        let result = runner.run("/usr/bin/osascript", ["-e", script])
        return result.status == 0 ? result.output : nil
    }

    static func currentFolder() -> URL? {
        run(insertionLocation).flatMap { urls(from: $0).first }
    }
}

@MainActor
final class FinderTools: ObservableObject {
    static let settingsKey = "finder.settings"
    static let finderID = "com.apple.finder"
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    static let cutMessageTime: TimeInterval = 2.5
    static let resultMessageTime: TimeInterval = 1.8
    static let movingMessageTime: TimeInterval = 60

    @Published var settings: FinderSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applyTap()
        }
    }
    @Published private(set) var cutItems: [URL] = []

    private let transferProgress = FinderTransferProgress()
    private var cutChangeCount: Int?
    private var isMoving = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "mackit.finder", qos: .userInitiated)
    private let hud = InputHUD()

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(FinderSettings.self, from: $0) }
            ?? FinderSettings()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTap() }
        }
        applyTap()
    }

    var isListening: Bool { tap != nil }

    func cancelCut() {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == cutChangeCount { pasteboard.clearContents() }
        cutItems = []
        cutChangeCount = nil
    }

    private func applyTap() {
        let needsTap = (settings.cutsAndPastes || settings.renames || settings.pastesImages) && AXIsProcessTrusted()
        guard needsTap != (tap != nil) else { return }
        if needsTap { startTap() } else { stopTap() }
        objectWillChange.send()
    }

    private func startTap() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tools = Unmanaged<FinderTools>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { tools.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != SyntheticTyping.marker,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID else { return pass }
        let pasteboard = NSPasteboard.general
        let hasCut = !cutItems.isEmpty && cutChangeCount == pasteboard.changeCount
        guard let action = FinderKeys.action(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                                             settings: settings, hasCut: hasCut, hasImage: PastedImage.isOffered(by: pasteboard)),
              !Self.isEditingText() else { return pass }
        switch action {
        case .cut:
            cutSelection()
        case .moveCut:
            moveCutItems()
        case .cancelCut:
            cutItems = []
            cutChangeCount = nil
            return pass
        case .pasteImage:
            pasteImage()
        case .rename:
            SyntheticTyping.press(kVK_Return, flags: [])
        }
        return nil
    }

    static func isEditingText() -> Bool {
        guard let focused: AXUIElement = AXWindow.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        return textRoles.contains(AXWindow.role(focused) ?? "")
    }

    private func cutSelection() {
        queue.async {
            let urls = FinderScript.run(FinderScript.selection).map(FinderScript.urls) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishCut(urls) }
            }
        }
    }

    private func finishCut(_ urls: [URL]) {
        guard !urls.isEmpty else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutItems = urls
        cutChangeCount = pasteboard.changeCount
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        if settings.showsHUD { hud.show("Cut \(name) · press ⌘V in another folder to move", for: Self.cutMessageTime) }
    }

    private func moveCutItems() {
        guard !isMoving, let changeCount = cutChangeCount else { return }
        let items = cutItems
        isMoving = true
        if settings.showsHUD { hud.show("Moving \(items.count == 1 ? items[0].lastPathComponent : "\(items.count) items")…", for: Self.movingMessageTime) }
        let showsProgress = settings.showsTransferProgress
        queue.async {
            let folder = FinderScript.currentFolder()
            func volume(_ url: URL) -> String? {
                (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier).map { String(describing: $0) }
            }
            let progress = showsProgress && TransferProgressState.crossesVolumes(sources: items.map(volume), destination: folder.flatMap(volume))
            let metadata = items.map { try? $0.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) }
            if progress {
                let bytes = metadata.reduce(Int64(0)) { $0 + Int64($1?.fileSize ?? 0) }
                let folders = metadata.contains { $0?.isDirectory == true }
                DispatchQueue.main.async { self.transferProgress.begin(items: items.count, bytes: bytes, folders: folders) }
            }
            var result = folder.map { folder in
                FileMover.move(items, into: folder, started: { source, destination in
                    if progress { DispatchQueue.main.async { self.transferProgress.started(source, destination: destination) } }
                }, finished: { source in
                    if progress {
                        let bytes = items.firstIndex(of: source).map { Int64(metadata[$0]?.fileSize ?? 0) } ?? 0
                        DispatchQueue.main.async { self.transferProgress.finished(bytes: bytes) }
                    }
                })
            }
            if let folder, var moved = result, !moved.denied.isEmpty {
                _ = FinderScript.run(FinderScript.move(moved.denied, to: folder))
                let stillThere = moved.denied.filter { FileManager.default.fileExists(atPath: $0.path) }
                moved.moved += moved.denied.count - stillThere.count
                moved.denied = stillThere
                result = moved
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishMove(result, changeCount: changeCount) }
            }
        }
    }

    private func finishMove(_ result: FileMover.Result?, changeCount: Int) {
        isMoving = false
        transferProgress.end(message: result.map { "Moved \($0.moved + $0.unchanged) items" } ?? "Move failed")
        guard let result else {
            NSSound.beep()
            if settings.showsHUD { hud.show("Couldn't find the Finder folder", for: Self.resultMessageTime) }
            return
        }
        let remaining = result.denied + result.failed
        let pasteboard = NSPasteboard.general
        if remaining.isEmpty {
            if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
            cutItems = []
            cutChangeCount = nil
        } else {
            cutItems = remaining
            cutChangeCount = pasteboard.changeCount
        }
        let moved = result.moved + result.unchanged
        var message = "Moved \(moved) \(moved == 1 ? "item" : "items")"
        if !remaining.isEmpty { message += " · \(remaining.count) couldn't be moved" }
        if settings.showsHUD { hud.show(message, for: Self.resultMessageTime) }
    }

    private func pasteImage() {
        guard let png = PastedImage.pngData(from: NSPasteboard.general) else { return NSSound.beep() }
        let name = PastedImage.fileName(at: Date())
        queue.async {
            var saved: URL?
            if let folder = FinderScript.currentFolder(),
               let target = FileMove.destination(for: URL(fileURLWithPath: "/").appendingPathComponent(name), in: folder,
                                                 exists: { FileManager.default.fileExists(atPath: $0.path) }),
               (try? png.write(to: target, options: .withoutOverwriting)) != nil {
                saved = target
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let saved else { return NSSound.beep() }
                    if self.settings.showsHUD { self.hud.show("Saved \(saved.lastPathComponent)", for: Self.resultMessageTime) }
                }
            }
        }
    }
}

extension FinderSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        cutsAndPastes = try values.decodeIfPresent(Bool.self, forKey: .cutsAndPastes) ?? defaults.cutsAndPastes
        showsHUD = try values.decodeIfPresent(Bool.self, forKey: .showsHUD) ?? defaults.showsHUD
        renames = try values.decodeIfPresent(Bool.self, forKey: .renames) ?? defaults.renames
        renameKey = try values.decodeIfPresent(RenameKey.self, forKey: .renameKey) ?? defaults.renameKey
        pastesImages = try values.decodeIfPresent(Bool.self, forKey: .pastesImages) ?? defaults.pastesImages
        showsTransferProgress = try values.decodeIfPresent(Bool.self, forKey: .showsTransferProgress) ?? false
    }
}
