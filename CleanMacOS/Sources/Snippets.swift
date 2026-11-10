import CoreGraphics
import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case afterDelimiter, immediately

        var id: String { rawValue }

        var title: String {
            switch self {
            case .afterDelimiter: "After Space, Tab or Return"
            case .immediately: "Right away"
            }
        }
    }

    static let minTrigger = 2
    static let maxTrigger = 40

    var id = UUID()
    var name = ""
    var trigger = ""
    var text = ""
    var mode = Mode.afterDelimiter
    var isEnabled = true
    var ignoresCase = false
    var folder = ""
    var showsInLibrary = true
    var createdAt = Date()

    var title: String { name.isEmpty ? trigger : name }

    func cleaned() -> Snippet {
        var copy = self
        copy.trigger = Self.normalizedTrigger(trigger)
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    static func normalizedTrigger(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace }.prefix(maxTrigger))
    }
}

struct SnippetMatcher {
    static let limit = 64

    private(set) var buffer = ""

    mutating func type(_ text: String) {
        buffer += text
        if buffer.count > Self.limit { buffer = String(buffer.suffix(Self.limit)) }
    }

    mutating func backspace() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    mutating func reset() {
        buffer = ""
    }

    func match(in snippets: [Snippet], mode: Snippet.Mode, adding text: String = "") -> Snippet? {
        let typed = buffer + text
        return snippets
            .filter { $0.isEnabled && $0.mode == mode && $0.trigger.count >= Snippet.minTrigger && Self.ends(typed, with: $0) }
            .max { $0.trigger.count < $1.trigger.count }
    }

    private static func ends(_ typed: String, with snippet: Snippet) -> Bool {
        guard typed.count >= snippet.trigger.count else { return false }
        let tail = String(typed.suffix(snippet.trigger.count))
        return snippet.ignoresCase ? tail.caseInsensitiveCompare(snippet.trigger) == .orderedSame : tail == snippet.trigger
    }
}

enum SnippetKey: Equatable {
    case character(String)
    case backspace
    case delimiter
    case reset
}

enum SnippetKeys {
    static let backspaceKey = 51
    static let delimiterKeys: Set<Int> = [49, 48, 36, 76]
    static let navigationKeys: Set<Int> = [123, 124, 125, 126, 53, 115, 119, 116, 121, 117]

    static func classify(keyCode: Int, flags: CGEventFlags, characters: String) -> SnippetKey {
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty || navigationKeys.contains(keyCode) { return .reset }
        if keyCode == backspaceKey { return .backspace }
        if delimiterKeys.contains(keyCode) { return .delimiter }
        guard !characters.isEmpty, !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .reset }
        return .character(characters)
    }

    static func delimiterText(keyCode: Int) -> String {
        switch keyCode {
        case 48: "\t"
        case 36, 76: "\n"
        default: " "
        }
    }
}

enum SnippetTemplate {
    static let pattern = #"\{\{(date|time|datetime|clipboard)(?:-tz\(([^)]*)\))?(?::([^}]*))?\}\}"#
    static let tag = try? NSRegularExpression(pattern: pattern)

    static func render(_ text: String, now: Date, locale: Locale, timeZone: TimeZone, clipboard: () -> String?) -> String {
        guard let tag, text.contains("{{") else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        var clipboardText: String?
        for match in tag.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = source.substring(with: match.range(at: 1))
            let zone = match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2))
            let format = match.range(at: 3).location == NSNotFound ? nil : source.substring(with: match.range(at: 3))
            if name == "clipboard" {
                if zone == nil && format == nil {
                    if clipboardText == nil { clipboardText = clipboard() ?? "" }
                    output += clipboardText ?? ""
                } else {
                    output += source.substring(with: match.range)
                }
            } else {
                output += dateText(name, zone: zone, format: format, now: now, locale: locale, timeZone: timeZone) ?? source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }

    private static func dateText(_ name: String, zone: String?, format: String?, now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if let zone {
            guard let format, !format.isEmpty, let named = TimeZone(identifier: zone) else { return nil }
            formatter.timeZone = named
        }
        if let format {
            guard !format.isEmpty else { return nil }
            formatter.dateFormat = format
            return formatter.string(from: now)
        }
        func styled(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> String {
            formatter.dateStyle = date
            formatter.timeStyle = time
            return formatter.string(from: now)
        }
        switch name {
        case "date": return styled(.medium, .none)
        case "time": return styled(.none, .short)
        default: return styled(.medium, .none) + " " + styled(.none, .short)
        }
    }
}

enum SnippetLibrary {
    enum Problem: Equatable {
        case triggerTooShort, duplicateTrigger, emptyText

        var message: String {
            switch self {
            case .triggerTooShort: "The trigger needs at least \(Snippet.minTrigger) characters."
            case .duplicateTrigger: "Another snippet already uses this trigger."
            case .emptyText: "Add the text this snippet types."
            }
        }
    }

    static func problem(with snippet: Snippet, among snippets: [Snippet]) -> Problem? {
        let trigger = Snippet.normalizedTrigger(snippet.trigger)
        if trigger.count < Snippet.minTrigger { return .triggerTooShort }
        let clash = snippets.contains { other in
            guard other.id != snippet.id else { return false }
            let ignoresCase = other.ignoresCase || snippet.ignoresCase
            return ignoresCase ? other.trigger.caseInsensitiveCompare(trigger) == .orderedSame : other.trigger == trigger
        }
        if clash { return .duplicateTrigger }
        return snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyText : nil
    }

    static func sections(_ snippets: [Snippet], query: String) -> [(folder: String, snippets: [Snippet])] {
        let words = ClipboardSearch.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = snippets.filter { snippet in
            guard snippet.isEnabled && snippet.showsInLibrary else { return false }
            let haystack = ClipboardSearch.normalize([snippet.name, snippet.trigger, snippet.text, snippet.folder].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
        let folders = Dictionary(grouping: shown, by: \.folder)
        let names = folders.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { folder in
            let sorted = (folders[folder] ?? []).sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.createdAt < rhs.createdAt : order == .orderedAscending
            }
            return (folder, sorted)
        }
    }
}
