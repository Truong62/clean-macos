import AppKit
import CryptoKit
import Foundation

enum CommandKind: String, Codable, CaseIterable {
    case answer, action, toggle, app, window, menu, quit, setting, macSetting, folder, snippet, clipboard, link, fact, emoji, file

    var cap: Int? {
        switch self {
        case .emoji: 6
        case .app, .menu, .toggle: 5
        case .window, .setting, .macSetting, .clipboard, .snippet, .folder, .file: 4
        case .quit: 3
        default: nil
        }
    }

    var bias: Int {
        switch self {
        case .app: 80
        case .menu: -80
        case .setting, .folder, .file: -40
        default: 0
        }
    }
}

enum CommandRanking {
    static let totalLimit = 12

    static func capped(_ kinds: [CommandKind]) -> [Int] {
        var counts: [CommandKind: Int] = [:]
        var kept: [Int] = []
        for (index, kind) in kinds.enumerated() {
            guard kept.count < totalLimit else { break }
            if let cap = kind.cap, counts[kind, default: 0] >= cap { continue }
            counts[kind, default: 0] += 1
            kept.append(index)
        }
        return kept
    }
}

struct CommandUsage: Codable, Equatable {
    var count: Int
    var lastUsed: Date
}

struct CommandMemory: Codable, Equatable {
    static let maxPins = 30
    static let maxUsage = 200
    static let maxPrefix = 24
    static let maxPrefixes = 320
    static let rowsPerPrefix = 4
    static let countCap = 40
    static let priorityCap = 720
    static let countWeight = 5
    static let lengthWeight = 6
    static let digestBytes = 12

    var salt: String
    var usage: [String: CommandUsage] = [:]
    var pins: [String] = []
    var learned: [String: [String: Int]] = [:]

    init(salt: String = UUID().uuidString) {
        self.salt = salt
    }

    func usageBoost(for id: String, now: Date) -> Int {
        guard let entry = usage[id] else { return 0 }
        let age = now.timeIntervalSince(entry.lastUsed)
        let weight = age < 2 * 3600 ? 12 : age < 48 * 3600 ? 8 : age < 14 * 86_400 ? 5 : 2
        return min(entry.count, Self.countCap) * weight
    }

    func priority(for id: String, query: String) -> Int {
        let folded = CommandText.fold(query)
        guard !folded.isEmpty else { return 0 }
        var best = 0
        for length in 1...min(folded.count, Self.maxPrefix) {
            if let count = learned[digest(String(folded.prefix(length)))]?[id] {
                best = max(best, count * Self.countWeight + length * Self.lengthWeight)
            }
        }
        return min(best, Self.priorityCap)
    }

    mutating func recordRun(_ id: String, query: String, at date: Date) {
        var entry = usage[id] ?? CommandUsage(count: 0, lastUsed: date)
        entry.count += 1
        entry.lastUsed = date
        usage[id] = entry
        if usage.count > Self.maxUsage, let oldest = usage.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { usage[oldest] = nil }
        let folded = CommandText.fold(query)
        guard !folded.isEmpty else { return }
        for length in 1...min(folded.count, Self.maxPrefix) {
            let key = digest(String(folded.prefix(length)))
            var rows = learned[key] ?? [:]
            rows[id, default: 0] += 1
            if rows.count > Self.rowsPerPrefix, let weakest = rows.filter({ $0.key != id }).min(by: { $0.value < $1.value })?.key { rows[weakest] = nil }
            learned[key] = rows
        }
        while learned.count > Self.maxPrefixes, let weakest = learned.min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key {
            learned[weakest] = nil
        }
    }

    mutating func togglePin(_ id: String) {
        if let index = pins.firstIndex(of: id) {
            pins.remove(at: index)
        } else if pins.count < Self.maxPins {
            pins.append(id)
        }
    }

    mutating func forget(_ id: String) {
        usage[id] = nil
        for key in learned.keys { learned[key]?[id] = nil }
    }

    private func digest(_ prefix: String) -> String {
        SHA256.hash(data: Data((salt + "\u{1F}" + prefix).utf8)).prefix(Self.digestBytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct CommandArgument: Equatable {
    let text: String
    let number: Int

    static func split(_ query: String) -> CommandArgument? {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, var last = words.last else { return nil }
        if last.hasSuffix("%") { last.removeLast() }
        guard let number = Int(last) else { return nil }
        words.removeLast()
        return CommandArgument(text: words.joined(separator: " "), number: number)
    }
}

struct CommandLink: Codable, Equatable, Identifiable {
    static let valueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return allowed
    }()

    var id = UUID()
    var name: String
    var keyword: String
    var template: String

    func url(query: String, clipboard: String?, selection: String?, date: Date, timeZone: TimeZone = .current) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let values = ["{query}": query, "{clipboard}": clipboard ?? "", "{selection}": selection ?? "", "{date}": formatter.string(from: date)]
        var text = template
        for (token, value) in values {
            text = text.replacingOccurrences(of: token, with: value.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed) ?? value)
        }
        return URL(string: text)
    }

    static func match(_ query: String, links: [CommandLink]) -> (link: CommandLink, query: String)? {
        let parts = query.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first?.lowercased(), let link = links.first(where: { $0.keyword.lowercased() == first }) else { return nil }
        return (link, parts.count > 1 ? parts[1] : "")
    }
}

struct CommandAnswer: Equatable {
    enum Kind: Equatable {
        case calculation, conversion, color, link, date, time, script
    }

    let kind: Kind
    let title: String
    let detail: String
    let copyText: String
}

enum CommandAnswers {
    static let dateUnits: [String: Calendar.Component] = [
        "day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear, "month": .month, "months": .month, "year": .year, "years": .year,
    ]
    static let commonDomains: Set<String> = ["com", "org", "net", "io", "dev", "app", "ai", "co", "vn", "uk", "de", "jp", "fr", "edu", "gov", "me", "info", "xyz"]

    static func answers(for query: String, locale: Locale = .current, now: Date = Date(), timeZone: TimeZone = .current) -> [CommandAnswer] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [calculation(text, locale), conversion(text, locale), color(text), link(text), relativeDate(text, now, timeZone, locale),
                worldTime(text, now, locale)].compactMap { $0 }
    }

    private static func calculation(_ text: String, _ locale: Locale) -> CommandAnswer? {
        guard let result = RustCore.calculate(text) else { return nil }
        let value = CalculatorFormat.text(result.value, locale: locale)
        let detail = result.closed > 0
            ? "\(text + String(repeating: ")", count: result.closed)) · added \(result.closed) closing bracket\(result.closed == 1 ? "" : "s")"
            : text
        return CommandAnswer(kind: .calculation, title: value, detail: detail, copyText: value)
    }

    private static func conversion(_ text: String, _ locale: Locale) -> CommandAnswer? {
        guard let result = RustCore.convert(text) else { return nil }
        let title = UnitFormat.text(result, locale: locale)
        let source = UnitConversion(value: 0, from: "", to: result.from, result: result.value)
        return CommandAnswer(kind: .conversion, title: title, detail: UnitFormat.text(source, locale: locale), copyText: title)
    }

    private static func color(_ text: String) -> CommandAnswer? {
        guard let color = ColorText.parse(text) else { return nil }
        let hex = ColorFormats.hex(color)
        return CommandAnswer(kind: .color, title: hex, detail: "\(ColorFormats.rgb(color)) · \(ColorFormats.hsl(color))", copyText: hex)
    }

    private static func link(_ text: String) -> CommandAnswer? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let candidate = text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") ? text : "https://" + text
        guard let url = URL(string: candidate), let host = url.host, let ending = host.split(separator: ".").last, host.contains("."),
              ending.allSatisfy(\.isLetter), ending.count >= 2,
              text.lowercased().hasPrefix("http") || text.hasPrefix("www.") || text.contains("/") || commonDomains.contains(ending.lowercased()) else { return nil }
        return CommandAnswer(kind: .link, title: "Open \(text)", detail: url.absoluteString, copyText: url.absoluteString)
    }

    private static func relativeDate(_ text: String, _ now: Date, _ timeZone: TimeZone, _ locale: Locale) -> CommandAnswer? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        let parsed: (amount: Int, unit: String)? = if words.count == 3, words[0] == "in", let amount = Int(words[1]) {
            (amount, words[2])
        } else if words.count == 3, words[2] == "ago", let amount = Int(words[0]) {
            (-amount, words[1])
        } else {
            nil
        }
        guard let parsed, let component = dateUnits[parsed.unit] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(byAdding: component, value: parsed.amount, to: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        let title = formatter.string(from: date)
        return CommandAnswer(kind: .date, title: title, detail: text, copyText: title)
    }

    private static func worldTime(_ text: String, _ now: Date, _ locale: Locale) -> CommandAnswer? {
        let lower = text.lowercased()
        guard lower.hasPrefix("time in ") else { return nil }
        let city = lower.dropFirst("time in ".count).trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty, let identifier = TimeZone.knownTimeZoneIdentifiers.first(where: {
            ($0.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " ").lowercased() == city
        }), let zone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let title = formatter.string(from: now)
        formatter.dateFormat = "EEEE"
        let name = (identifier.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " ")
        return CommandAnswer(kind: .time, title: title, detail: "\(name) · \(formatter.string(from: now))", copyText: title)
    }
}

enum ColorFormats {
    static func channel(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    static func hex(_ color: ClipboardColor) -> String {
        let base = String(format: "#%02X%02X%02X", channel(color.red), channel(color.green), channel(color.blue))
        return color.alpha < 1 ? base + String(format: "%02X", channel(color.alpha)) : base
    }

    static func rgb(_ color: ClipboardColor) -> String {
        let values = "\(channel(color.red)), \(channel(color.green)), \(channel(color.blue))"
        return color.alpha < 1 ? "rgba(\(values), \(String(format: "%.2g", color.alpha)))" : "rgb(\(values))"
    }

    static func hsl(_ color: ClipboardColor) -> String {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let lightness = (high + low) / 2
        let delta = high - low
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue = 0.0
        if delta > 0 {
            switch high {
            case color.red: hue = 60 * ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            case color.green: hue = 60 * ((color.blue - color.red) / delta + 2)
            default: hue = 60 * ((color.red - color.green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        return "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }
}

enum CommandBarCommand: Equatable {
    case move(Int), run, reveal, runNumber(Int), complete, pin, actions, escape, category(Int), blocked
}

enum CommandBarKeys {
    static let upKey: UInt16 = 126
    static let downKey: UInt16 = 125
    static let leftKey: UInt16 = 123
    static let rightKey: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let tabKey: UInt16 = 48
    static let escapeKey: UInt16 = 53
    static let pKey: UInt16 = 35
    static let nKey: UInt16 = 45
    static let kKey: UInt16 = 40
    static let blockedKeys: Set<UInt16> = [12, 13, 46, 4]
    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, queryIsEmpty: Bool) -> CommandBarCommand? {
        let modifiers = modifiers.intersection(relevant)
        switch (keyCode, modifiers) {
        case (upKey, []), (pKey, .control): return .move(-1)
        case (downKey, []), (nKey, .control): return .move(1)
        case (returnKey, []), (enterKey, []): return .run
        case (returnKey, .command), (enterKey, .command): return .reveal
        case (tabKey, []): return .complete
        case (pKey, .command): return .pin
        case (kKey, .command): return .actions
        case (escapeKey, _): return .escape
        case (leftKey, []) where queryIsEmpty: return .category(-1)
        case (rightKey, []) where queryIsEmpty: return .category(1)
        default:
            guard modifiers == .command else { return nil }
            if blockedKeys.contains(keyCode) { return .blocked }
            return PanelKeys.digitKeys[keyCode].map(CommandBarCommand.runNumber)
        }
    }
}
