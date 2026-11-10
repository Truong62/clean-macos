import AppKit

struct ScratchTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var edited: Date
}

enum ScratchRetention: String, Codable, CaseIterable, Identifiable {
    case never, day, week, month

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .never: nil
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }

    var title: String {
        switch self {
        case .never: "Never"
        case .day: "After a day"
        case .week: "After a week"
        case .month: "After a month"
        }
    }
}

struct ScratchpadState: Codable, Equatable {
    static let maxTabs = 12
    static let namePrefix = "Scratchpad"

    var tabs: [ScratchTab]
    var selected: UUID?

    init(now: Date) {
        let first = ScratchTab(name: "\(Self.namePrefix) 1", text: "", edited: now)
        tabs = [first]
        selected = first.id
    }

    @discardableResult
    mutating func addTab(now: Date) -> Bool {
        guard tabs.count < Self.maxTabs else { return false }
        let used = Set(tabs.map(\.name))
        let number = (1...Self.maxTabs).first { !used.contains("\(Self.namePrefix) \($0)") } ?? tabs.count + 1
        let tab = ScratchTab(name: "\(Self.namePrefix) \(number)", text: "", edited: now)
        tabs.append(tab)
        selected = tab.id
        return true
    }

    @discardableResult
    mutating func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: index)
        if selected == id { selected = tabs[min(index, tabs.count - 1)].id }
        return true
    }

    mutating func prune(_ retention: ScratchRetention, now: Date) {
        guard let limit = retention.seconds else { return }
        tabs.removeAll { now.timeIntervalSince($0.edited) > limit }
        if tabs.isEmpty { tabs = [ScratchTab(name: "\(Self.namePrefix) 1", text: "", edited: now)] }
        if !tabs.contains(where: { $0.id == selected }) { selected = tabs.first?.id }
    }

    static func exportName(for tab: ScratchTab, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(tab.name) \(formatter.string(from: date)).txt"
    }
}

struct ScratchpadStore {
    static let filePermissions = 0o600

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS", isDirectory: true).appendingPathComponent("Scratchpad.json")
    }

    func load() -> ScratchpadState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ScratchpadState.self, from: data)
    }

    func save(_ state: ScratchpadState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("ScratchpadStore.save failed for \(fileURL.path): \(error.localizedDescription)")
        }
    }
}

enum ScratchCommand: Equatable {
    case newTab, closeTab, preview, find, findNext, findPrevious, blocked
}

enum ScratchpadKeys {
    static let tKey: UInt16 = 17
    static let fKey: UInt16 = 3
    static let gKey: UInt16 = 5

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ScratchCommand? {
        let modifiers = modifiers.intersection(PanelKeys.relevantModifiers)
        switch (keyCode, modifiers) {
        case (tKey, .command): return .newTab
        case (PanelKeys.closeKey, .command): return .closeTab
        case (PanelKeys.returnKey, .command), (PanelKeys.enterKey, .command): return .preview
        case (fKey, .command): return .find
        case (gKey, .command): return .findNext
        case (gKey, [.command, .shift]): return .findPrevious
        default: return PanelKeys.isAppCommand(keyCode: keyCode, modifiers: modifiers) ? .blocked : nil
        }
    }
}

enum PreviewLine: Equatable {
    case heading(level: Int, text: String)
    case task(indent: Int, isDone: Bool, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: String, text: String)
    case quote(String)
    case fence
    case code(String)
    case plain(String)
}

enum MarkdownPreview {
    static let fence = "```"
    static let maxHeading = 6
    static let spacesPerIndent = 2

    static func lines(_ text: String) -> [PreviewLine] {
        var isInCode = false
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                isInCode.toggle()
                return .fence
            }
            return isInCode ? .code(line) : parse(line)
        }
    }

    static func togglingTask(in text: String, line index: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index), case .task(_, let isDone, _) = parse(lines[index]) else { return text }
        let line = lines[index]
        let start = line.index(line.startIndex, offsetBy: line.prefix { $0 == " " || $0 == "\t" }.count + 2)
        lines[index].replaceSubrange(start..<line.index(start, offsetBy: 3), with: isDone ? "[ ]" : "[x]")
        return lines.joined(separator: "\n")
    }

    static func parse(_ line: String) -> PreviewLine {
        let lead = line.prefix { $0 == " " || $0 == "\t" }
        let indent = (lead.filter { $0 == " " }.count / spacesPerIndent) + lead.filter { $0 == "\t" }.count
        let body = line.dropFirst(lead.count)
        let hashes = body.prefix { $0 == "#" }.count
        if (1...maxHeading).contains(hashes), body.dropFirst(hashes).hasPrefix(" ") {
            return .heading(level: hashes, text: String(body.dropFirst(hashes + 1)))
        }
        if let marker = ListContinuation.checkboxes.first(where: { body.hasPrefix($0) }) {
            return .task(indent: indent, isDone: !marker.contains("[ ]"), text: String(body.dropFirst(marker.count)))
        }
        if let marker = ListContinuation.bullets.first(where: { body.hasPrefix($0) }) {
            return .bullet(indent: indent, text: String(body.dropFirst(marker.count)))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") {
            return .numbered(indent: indent, number: String(digits), text: String(body.dropFirst(digits.count + 2)))
        }
        if body.hasPrefix(">") {
            return .quote(String(body.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return .plain(line)
    }
}

enum ListContinuation {
    static let checkboxes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "]
    static let bullets = ["- ", "* ", "+ "]

    static func prefix(after line: String) -> String? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)
        if let marker = checkboxes.first(where: { body.hasPrefix($0) }) {
            return body.count > marker.count ? indent + String(marker.prefix(2)) + "[ ] " : nil
        }
        if let marker = bullets.first(where: { body.hasPrefix($0) }) {
            return body.count > marker.count ? indent + marker : nil
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". "), let number = Int(digits) else { return nil }
        return body.count > digits.count + 2 ? indent + "\(number + 1). " : nil
    }
}

enum MarkdownStyle: String, CaseIterable, Identifiable {
    case bold, italic, strike, heading, bullet, numbered, quote, code, link

    static let placeholder = "text"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strike: "strikethrough"
        case .heading: "number"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        }
    }

    func wrap(_ selected: String) -> String {
        let text = selected.isEmpty ? Self.placeholder : selected
        let lines = text.components(separatedBy: "\n")
        switch self {
        case .bold: return "**\(text)**"
        case .italic: return "*\(text)*"
        case .strike: return "~~\(text)~~"
        case .code: return text.contains("\n") ? "```\n\(text)\n```" : "`\(text)`"
        case .link: return "[\(text)](https://)"
        case .heading: return lines.map { "# " + $0 }.joined(separator: "\n")
        case .bullet: return lines.map { "- " + $0 }.joined(separator: "\n")
        case .numbered: return lines.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n")
        case .quote: return lines.map { "> " + $0 }.joined(separator: "\n")
        }
    }
}

enum QuitList {
    static let finder = "com.apple.finder"
    static let alwaysKept: Set<String> = [finder, "com.apple.mobilephone"]

    static func ordered(_ apps: [RunningAppInfo], front: String?, own: String?) -> [RunningAppInfo] {
        apps.filter { $0.isRegular && $0.bundleID != own && $0.bundleID != finder }.sorted { lhs, rhs in
            if (lhs.bundleID == front) != (rhs.bundleID == front) { return lhs.bundleID == front }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func batch(_ apps: [RunningAppInfo], kept: Set<String>, exceptFront: String?) -> [RunningAppInfo] {
        apps.filter { !alwaysKept.contains($0.bundleID) && !kept.contains($0.bundleID) && $0.bundleID != exceptFront }
    }

    static func jump(to typed: String, in apps: [RunningAppInfo]) -> Int? {
        let typed = CommandText.fold(typed)
        guard !typed.isEmpty else { return nil }
        return apps.firstIndex { CommandText.fold($0.name).hasPrefix(typed) }
    }
}

enum QuitCommand: Equatable {
    case move(Int), quitSelected, quitAll, quitAllExceptFront, cancel
}

enum QuitKeys {
    static let tabKey: UInt16 = 48

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> QuitCommand? {
        switch (keyCode, modifiers.intersection(PanelKeys.relevantModifiers)) {
        case (PanelKeys.upKey, []), (tabKey, .shift): return .move(-1)
        case (PanelKeys.downKey, []), (tabKey, []): return .move(1)
        case (PanelKeys.deleteKey, .command): return .quitSelected
        case (PanelKeys.returnKey, .command), (PanelKeys.enterKey, .command): return .quitAll
        case (PanelKeys.returnKey, [.command, .option]), (PanelKeys.enterKey, [.command, .option]): return .quitAllExceptFront
        case (PanelKeys.escapeKey, _): return .cancel
        default: return nil
        }
    }
}

enum CameraChoice {
    static func pick(available: [String], preferred: String?, current: String?) -> String? {
        if let current, available.contains(current) { return current }
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }
}
