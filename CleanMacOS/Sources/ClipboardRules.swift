import AppKit

struct URLCleanRules: Codable, Equatable {
    var extraNames: [String] = []
    var keptNames: [String] = []
}

struct URLCleanResult: Equatable {
    let url: String
    let removed: [String]
}

enum URLCleaner {
    static let trackingPrefixes = ["utm_"]
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid", "igshid", "twclid", "ttclid",
        "li_fat_id", "mkt_tok", "_hsenc", "_hsmi", "__twitter_impression", "fb_action_ids", "fb_action_types", "fb_source", "mibextid",
    ]
    static let siteNames: [String: Set<String>] = {
        let youtube: Set<String> = ["si", "pp", "feature", "kw"]
        let twitter: Set<String> = ["s", "t", "cn", "src", "refsrc", "ref_src", "ref_url"]
        return [
            "youtube.com": youtube,
            "youtu.be": youtube,
            "twitter.com": twitter,
            "x.com": twitter,
            "instagram.com": ["igsh"],
            "spotify.com": ["si"],
            "reddit.com": ["correlation_id", "ref_campaign", "ref_source", "rdt", "share_id", "_branch_match_id", "$deep_link", "$3p", "$original_url"],
            "tiktok.com": ["u_code", "preview_pb", "_d", "_t", "_r", "timestamp", "user_id", "share_app_name", "share_iid"],
            "bilibili.com": [
                "spm_id_from", "from_spmid", "from_source", "share_source", "share_from", "share_medium", "share_plat", "share_tag",
                "share_session_id", "msource", "refer_from", "seid", "unique_k", "vd_source", "plat_id", "buvid", "bbid", "up_id",
                "is_story_h5", "timestamp", "ts", "visit_id", "session_id", "broadcast_type", "is_room_feed",
            ],
            "xiaohongshu.com": [
                "xhsshare", "author_share", "xsec_source", "share_from_user_hidden", "shareredid", "share_id", "exsource",
                "app_version", "app_platform", "apptime", "appuid",
            ],
        ]
    }()

    static func clean(_ text: String, rules: URLCleanRules = URLCleanRules()) -> URLCleanResult? {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.contains(where: \.isWhitespace), let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let (beforeFragment, fragment) = split(link, at: "#")
        let (base, query) = split(beforeFragment, at: "?")
        guard let query else { return URLCleanResult(url: link, removed: []) }
        let unwanted = names(for: host, rules: rules)
        let kept = Set(rules.keptNames.map { $0.lowercased() })
        var removed: [String] = []
        let remaining = query.split(separator: "&", omittingEmptySubsequences: false).filter { part in
            let raw = String(part.prefix { $0 != "=" })
            let name = (raw.removingPercentEncoding ?? raw).lowercased()
            guard !kept.contains(name), unwanted.contains(name) || trackingPrefixes.contains(where: { name.hasPrefix($0) }) else { return true }
            removed.append(name)
            return false
        }
        guard !removed.isEmpty else { return URLCleanResult(url: link, removed: []) }
        let cleaned = base + (remaining.isEmpty ? "" : "?" + remaining.joined(separator: "&")) + (fragment.map { "#" + $0 } ?? "")
        return URLCleanResult(url: cleaned, removed: removed)
    }

    private static func names(for host: String, rules: URLCleanRules) -> Set<String> {
        var names = trackingNames.union(rules.extraNames.map { $0.lowercased() })
        for (site, siteNames) in siteNames where host == site || host.hasSuffix("." + site) {
            names.formUnion(siteNames)
        }
        return names
    }

    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }
}

enum SensitiveText {
    static let tokenLength = 20...160
    static let namedSecret = #"(?i)\b(pass(word|wd)?|pwd|secret|token|api[ _-]?key|private[ _-]?key|authorization)\b["']?\s*[:=]\s*\S+"#
    static let passwordFlag = #"(?i)(^|\s)--?password[= ]\S+"#
    static let email = #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#

    static func looksSensitive(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: namedSecret, options: .regularExpression) != nil { return true }
        if value.range(of: passwordFlag, options: .regularExpression) != nil { return true }
        return looksLikeToken(value)
    }

    private static func looksLikeToken(_ text: String) -> Bool {
        guard tokenLength.contains(text.count), !text.contains(where: \.isWhitespace), !isExempt(text) else { return false }
        return text.contains(where: \.isLetter) && text.contains(where: \.isNumber) && text.contains { !$0.isLetter && !$0.isNumber }
    }

    private static func isExempt(_ text: String) -> Bool {
        if UUID(uuidString: text) != nil { return true }
        if let url = URL(string: text), url.scheme != nil, url.host != nil { return true }
        return text.range(of: email, options: .regularExpression) != nil
    }
}

struct PasteboardFacts {
    static let concealed = "org.nspasteboard.ConcealedType"
    static let transient = "org.nspasteboard.TransientType"
    static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    static let source = "org.nspasteboard.source"
    static let remote = "com.apple.is-remote-clipboard"
    static let richTypes: Set<String> = [
        "public.html", "public.rtf", "public.rtfd", "com.apple.flat-rtfd", "com.apple.webarchive", "public.tiff", "public.png",
        "public.jpeg", "public.file-url", "com.adobe.pdf", "Apple HTML pasteboard type", "NeXT Rich Text Format v1.0 pasteboard type",
        "NeXT RTFD pasteboard type", "Apple Web Archive pasteboard type", "NeXT TIFF v4.0 pasteboard type", "Apple PDF pasteboard type",
        "Apple PNG pasteboard type", "NSFilenamesPboardType",
    ]

    var types: Set<String> = []
    var declaredSource: String?
    var activeApps: Set<String> = []

    var isConcealed: Bool { types.contains(Self.concealed) }
    var isTransient: Bool { types.contains(Self.transient) || types.contains(Self.autoGenerated) }
    var isRemote: Bool { types.contains(Self.remote) }

    var holdsOnlyText: Bool {
        !isConcealed && types.isDisjoint(with: Self.richTypes)
    }
}

enum ClipboardFilter {
    static func shouldSkip(_ facts: PasteboardFacts, options: ClipboardOptions, skipsConcealed: Bool) -> Bool {
        if facts.isTransient || (skipsConcealed && facts.isConcealed) { return true }
        let skipped = Set(options.skippedApps)
        if let source = facts.declaredSource, skipped.contains(source) { return true }
        return !skipped.isDisjoint(with: facts.activeApps)
    }

    static func sourceApp(_ facts: PasteboardFacts) -> String? {
        guard !facts.isRemote else { return nil }
        if let source = facts.declaredSource { return source }
        return facts.activeApps.count == 1 ? facts.activeApps.first : nil
    }
}

struct ClipboardColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum ColorText {
    static let maxLength = 80
    static let swiftUIKeys: Set<String> = ["red", "green", "blue", "opacity"]

    static func parse(_ text: String) -> ClipboardColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= maxLength else { return nil }
        let lower = value.lowercased()
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        if lower.hasPrefix("rgb") { return rgb(lower) }
        if lower.hasPrefix("hsl") { return hsl(lower) }
        if value.hasPrefix("Color(") { return swiftUI(value) }
        return nil
    }

    private static func hex(_ digits: String) -> ClipboardColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), let number = UInt64(digits, radix: 16) else { return nil }
        let isShort = digits.count <= 4
        let count = isShort ? digits.count : digits.count / 2
        let bits = isShort ? 4 : 8
        let mask = UInt64((1 << bits) - 1)
        var channels: [Double] = []
        for index in 0..<count {
            let shift = UInt64(count - 1 - index) * UInt64(bits)
            channels.append(Double((number >> shift) & mask) / Double(mask))
        }
        if channels.count == 3 { channels.append(1) }
        return ClipboardColor(red: channels[0], green: channels[1], blue: channels[2], alpha: channels[3])
    }

    private static func rgb(_ text: String) -> ClipboardColor? {
        guard let parts = arguments(text, names: ["rgb", "rgba"]), parts.count == 3 || parts.count == 4,
              let red = component(parts[0], scale: 255), let green = component(parts[1], scale: 255), let blue = component(parts[2], scale: 255),
              let alpha = parts.count == 4 ? component(parts[3], scale: 1) : 1 else { return nil }
        return ClipboardColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hsl(_ text: String) -> ClipboardColor? {
        guard let parts = arguments(text, names: ["hsl", "hsla"]), parts.count == 3 || parts.count == 4,
              let hue = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
              let saturation = component(parts[1], scale: 100), let lightness = component(parts[2], scale: 100),
              let alpha = parts.count == 4 ? component(parts[3], scale: 1) : 1 else { return nil }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let offset = lightness - chroma / 2
        return ClipboardColor(red: red + offset, green: green + offset, blue: blue + offset, alpha: alpha)
    }

    private static func swiftUI(_ text: String) -> ClipboardColor? {
        guard text.hasSuffix(")") else { return nil }
        var values: [String: Double] = [:]
        for part in text.dropFirst("Color(".count).dropLast().split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 1, pair[0].hasPrefix(".") { continue }
            guard pair.count == 2, swiftUIKeys.contains(pair[0]), let number = Double(pair[1]), (0...1).contains(number) else { return nil }
            values[pair[0]] = number
        }
        guard let red = values["red"], let green = values["green"], let blue = values["blue"] else { return nil }
        return ClipboardColor(red: red, green: green, blue: blue, alpha: values["opacity"] ?? 1)
    }

    private static func arguments(_ text: String, names: Set<String>) -> [String]? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")"),
              names.contains(text[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)].replacingOccurrences(of: "/", with: " ")
        return inner.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    private static func component(_ text: String, scale: Double) -> Double? {
        let isPercent = text.hasSuffix("%")
        guard let number = Double(isPercent ? String(text.dropLast()) : text) else { return nil }
        let value = isPercent ? number / 100 : number / scale
        return (0...1).contains(value) ? value : nil
    }
}

enum ClipboardSearch {
    static let exactScore = 1000
    static let prefixScore = 500
    static let containsScore = 200
    static let wordsScore = 100
    static let wholeWordBonus = 50
    static let pinnedBonus = 10

    static func rank(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let needle = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        let scored: [(index: Int, item: ClipboardItem, score: Int)] = items.enumerated().compactMap { index, item in
            guard let value = score(item, needle: needle, words: words) else { return nil }
            return (index, item, value)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.item)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func score(_ item: ClipboardItem, needle: String, words: [String]) -> Int? {
        let haystack = normalize(item.searchText)
        guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
        let tokens = Set(haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let base = haystack == needle ? exactScore : haystack.hasPrefix(needle) ? prefixScore : haystack.contains(needle) ? containsScore : wordsScore
        return base + words.filter(tokens.contains).count * wholeWordBonus + (item.isPinned ? pinnedBonus : 0)
    }
}

enum ClipboardCapture {
    static func kind(hasFiles: Bool, hasImage: Bool, text: String?) -> ClipboardItem.Kind? {
        if hasFiles { return .files }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hasImage && (trimmed.isEmpty || isSingleLink(trimmed)) { return .image }
        return trimmed.isEmpty ? nil : .text
    }

    static func isSingleLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), url.scheme != nil else { return false }
        return url.host != nil || url.isFileURL
    }
}

enum PlainText {
    static func extract(string: String?, rtf: Data?, html: Data?) -> String? {
        if let string, !string.isEmpty { return string }
        if let rtf, let text = trimmed(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string) { return text }
        if let html, let text = trimmed(NSAttributedString(html: html, documentAttributes: nil)?.string) { return text }
        return nil
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct ClipboardAutoClear: Codable, Equatable {
    var afterDelay = false
    var delaySeconds = 20
    var onSleep = false
    var onDisplaySleep = false
    var onLock = false

    func isDue(lastChange: Date, now: Date) -> Bool {
        afterDelay && now.timeIntervalSince(lastChange) >= TimeInterval(delaySeconds)
    }
}

struct ClipboardOptions: Codable, Equatable {
    static let key = "clipboard.options"
    static let retentionChoices = [0, 1, 7, 30, 90, 365]

    var layout = ClipboardLayout.list
    var savesImagesAndFiles = true
    var retentionDays = 0
    var skipsSensitiveText = false
    var skippedApps: [String] = []
    var cleansURLs = false
    var urlRules = URLCleanRules()
    var autoClear = ClipboardAutoClear()
    var pastesPlainText = false
    var showsSourceIcons = false
    var showsLatestInMenuBar = false
    var latestLength = 20
    var showsInMenuPanel = true
}


enum ClipboardLayout: String, Codable, CaseIterable {
    case list, cards

    init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = value.flatMap(Self.init(rawValue:)) ?? .list
    }
}

extension ClipboardOptions {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        layout = try values.decodeIfPresent(ClipboardLayout.self, forKey: .layout) ?? defaults.layout
        savesImagesAndFiles = try values.decodeIfPresent(Bool.self, forKey: .savesImagesAndFiles) ?? defaults.savesImagesAndFiles
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays
        skipsSensitiveText = try values.decodeIfPresent(Bool.self, forKey: .skipsSensitiveText) ?? defaults.skipsSensitiveText
        skippedApps = try values.decodeIfPresent([String].self, forKey: .skippedApps) ?? defaults.skippedApps
        cleansURLs = try values.decodeIfPresent(Bool.self, forKey: .cleansURLs) ?? defaults.cleansURLs
        urlRules = try values.decodeIfPresent(URLCleanRules.self, forKey: .urlRules) ?? defaults.urlRules
        autoClear = try values.decodeIfPresent(ClipboardAutoClear.self, forKey: .autoClear) ?? defaults.autoClear
        pastesPlainText = try values.decodeIfPresent(Bool.self, forKey: .pastesPlainText) ?? defaults.pastesPlainText
        showsSourceIcons = try values.decodeIfPresent(Bool.self, forKey: .showsSourceIcons) ?? defaults.showsSourceIcons
        showsLatestInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showsLatestInMenuBar) ?? defaults.showsLatestInMenuBar
        latestLength = try values.decodeIfPresent(Int.self, forKey: .latestLength) ?? defaults.latestLength
        showsInMenuPanel = try values.decodeIfPresent(Bool.self, forKey: .showsInMenuPanel) ?? defaults.showsInMenuPanel
    }
}
