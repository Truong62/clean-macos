import AppKit

struct EmojiEntry: Equatable {
    let glyph: String
    let name: String
}

enum EmojiCatalog {
    static let prefix = ":"
    static let ranges: [ClosedRange<UInt32>] = [0x00A9...0x00AE, 0x203C...0x3299, 0x1F000...0x1FAFF]
    static let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
    static let presentationSelector = "\u{FE0F}"

    static let entries: [EmojiEntry] = ranges.flatMap { range in
        range.compactMap { value -> EmojiEntry? in
            guard !regionalIndicators.contains(value), let scalar = Unicode.Scalar(value), scalar.properties.isEmoji,
                  !scalar.properties.isEmojiModifier, let name = scalar.properties.name else { return nil }
            let glyph = scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + presentationSelector
            return EmojiEntry(glyph: glyph, name: name.lowercased())
        }
    }

    static func query(_ text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return text.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

enum FileSearch {
    static let minimumLength = 2
    static let pause: TimeInterval = 0.12
    static let fetchLimit = 1000
    static let keepLimit = 200
    static let tool = "/usr/bin/mdfind"
    static let ignoredFolders: Set<String> = ["node_modules", ".git", "DerivedData", "Pods", ".build", "vendor"]
    static let packageExtensions: Set<String> = ["app", "appex", "bundle", "framework", "plugin", "kext", "xcodeproj", "xcworkspace", "photoslibrary",
                                                 "musiclibrary", "rtfd", "playground", "pkg"]

    static func spotlightQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.joined(separator: " ").count >= minimumLength else { return nil }
        return words.map { word in
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "\\*")
            return "kMDItemFSName == \"*\(escaped)*\"cd"
        }.joined(separator: " && ")
    }

    static func keeps(_ path: String, under root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return false }
        let parts = path.dropFirst(base.count).split(separator: "/")
        guard let last = parts.last, !last.hasPrefix(".") else { return false }
        return parts.dropLast().allSatisfy { part in
            !part.hasPrefix(".") && !ignoredFolders.contains(String(part)) && !packageExtensions.contains((part as NSString).pathExtension.lowercased())
        }
    }

    static func search(_ text: String, in folders: [String]) -> [String] {
        guard let query = spotlightQuery(text) else { return [] }
        var kept: [String] = []
        for folder in folders where kept.count < keepLimit {
            let lines = CommandRunner.run(tool, ["-onlyin", folder, query]).output.split(separator: "\n").prefix(fetchLimit)
            kept += lines.map(String.init).filter { keeps($0, under: folder) }
        }
        return Array(kept.prefix(keepLimit))
    }
}

enum TextTransform: String, CaseIterable, Identifiable {
    case upper, lower, title, sentence

    static let maxLength = 5000

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: "UPPERCASE"
        case .lower: "lowercase"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.lowercased().capitalized
        case .sentence:
            var result = ""
            var startsSentence = true
            for character in text.lowercased() {
                if startsSentence, character.isLetter {
                    result += character.uppercased()
                    startsSentence = false
                } else {
                    result.append(character)
                }
                if ".!?\n".contains(character) { startsSentence = true }
            }
            return result
        }
    }
}

struct TextCounts: Equatable {
    let characters: Int
    let words: Int
    let lines: Int

    init(_ text: String) {
        characters = text.count
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var summary: String { "\(characters) characters · \(words) words · \(lines) lines" }
}

enum CommandRowActionKind: String, Identifiable {
    case run, reveal, copyPath, copyTitle, quit, pin, unpin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Open"
        case .reveal: "Show in Finder"
        case .copyPath: "Copy Path"
        case .copyTitle: "Copy Name"
        case .quit: "Quit"
        case .pin: "Pin"
        case .unpin: "Unpin"
        }
    }

    var symbol: String {
        switch self {
        case .run: "return"
        case .reveal: "folder"
        case .copyPath: "doc.on.doc"
        case .copyTitle: "textformat"
        case .quit: "xmark.circle"
        case .pin: "pin"
        case .unpin: "pin.slash"
        }
    }
}

enum CommandRowActions {
    static func kinds(for row: CommandRow, isPinned: Bool, isRunning: Bool) -> [CommandRowActionKind] {
        guard case .item(let item, _) = row else { return [.run] }
        var kinds: [CommandRowActionKind] = [.run]
        kinds += item.revealURL == nil ? [.copyTitle] : [.reveal, .copyPath]
        if item.kind == .app && isRunning { kinds.append(.quit) }
        kinds.append(isPinned ? .unpin : .pin)
        return kinds
    }

    static func runningApp(at url: URL?) -> NSRunningApplication? {
        guard let url else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }
}

@MainActor
enum TextInsertion {
    static let pasteThreshold = 200
    static let hud = InputHUD()
    static let messageTime: TimeInterval = 1.4

    static func type(_ text: String, clipboard: ClipboardViewModel) {
        guard AXIsProcessTrusted() else {
            ScreenTools.copy(text)
            hud.show("Copied \(text.prefix(40))", for: messageTime)
            return
        }
        if text.count > pasteThreshold || text.contains(where: \.isNewline) {
            clipboard.pasteTemporarily(text)
        } else {
            SyntheticTyping.send(TypingEdit(backspaces: 0, text: text), style: InjectionStyle.style(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
        }
    }

    nonisolated static func selectedText(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = AXWindow.value(element, kAXFocusedUIElementAttribute),
              let text: String = AXWindow.value(focused, kAXSelectedTextAttribute), !text.isEmpty, text.count <= TextTransform.maxLength else { return nil }
        return text
    }
}
