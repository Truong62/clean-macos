import CMacKitCore
import Foundation

enum RustCore {
    struct FoundFile: Decodable, Equatable {
        let path: String
        let bytes: Int64
        let modified: Int64
    }

    static func dirSize(path: String, timeout: TimeInterval, maxDepth: Int) -> (size: Int64, didTimeout: Bool) {
        var bytes: UInt64 = 0
        let didTimeout = mk_dir_size(path, milliseconds(timeout), UInt32(clamping: maxDepth), &bytes)
        return (Int64(clamping: bytes), didTimeout)
    }

    static func largeFiles(root: String, minBytes: Int64, olderThan: Date?, limit: Int, timeout: TimeInterval,
                           excludedFolder: String?) -> [FoundFile] {
        let cutoff = Int64(olderThan?.timeIntervalSince1970 ?? 0)
        guard let raw = mk_large_files_json(root, UInt64(clamping: max(0, minBytes)), cutoff, UInt32(clamping: limit),
                                            milliseconds(timeout), excludedFolder) else { return [] }
        defer { mk_string_free(raw) }
        return (try? JSONDecoder().decode([FoundFile].self, from: Data(bytes: raw, count: strlen(raw)))) ?? []
    }

    static func aiUsage(_ request: Data) -> Data {
        guard let text = String(data: request, encoding: .utf8), let raw = mk_ai_usage(text) else { return Data() }
        defer { mk_string_free(raw) }
        return Data(bytes: raw, count: strlen(raw))
    }

    private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1000)
    }
}

struct RankRow: Equatable {
    var title: String
    var keywords = ""
    var bias = 0
    var priority = 0
}

struct RankedRow: Equatable {
    let index: Int
    let score: Int
    let tier: Int
}

struct UnitConversion: Equatable {
    let value: Double
    let from: String
    let to: String
    let result: Double
}

extension RustCore {
    static func calculate(_ text: String) -> (value: Double, closed: Int)? {
        var value = 0.0
        var closed: UInt32 = 0
        guard mk_calc(text, &value, &closed) else { return nil }
        return (value, Int(closed))
    }

    static func convert(_ text: String) -> UnitConversion? {
        guard let raw = mk_convert(text) else { return nil }
        defer { mk_string_free(raw) }
        let fields = String(cString: raw).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, let value = Double(fields[0]), let result = Double(fields[3]) else { return nil }
        return UnitConversion(value: value, from: fields[1], to: fields[2], result: result)
    }

    static func rank(_ query: String, _ rows: [RankRow]) -> [RankedRow] {
        let folded = CommandText.fold(query)
        guard !folded.isEmpty else { return [] }
        let payload = rows.map { "\(CommandText.fold($0.title))\t\(CommandText.fold($0.keywords))\t\($0.bias)\t\($0.priority)" }.joined(separator: "\n")
        guard let raw = mk_rank(folded, payload) else { return [] }
        defer { mk_string_free(raw) }
        return String(cString: raw).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let index = Int(fields[0]), let score = Int(fields[1]), let tier = Int(fields[2]) else { return nil }
            return RankedRow(index: index, score: score, tier: tier)
        }
    }
}

enum CommandText {
    static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}")

    static func fold(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        let folded = plain.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let visible = String(String.UnicodeScalarView(folded.unicodeScalars.filter { !invisible.contains($0) }))
        return visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum CalculatorFormat {
    static let significantDigits = 12
    static let maximumFraction = 8
    static let scientificDigits = 8
    static let largeLimit = 1e12
    static let smallLimit = 1e-6

    static func text(_ value: Double, locale: Locale = .current) -> String {
        let rounded = round(value, digits: significantDigits)
        let magnitude = abs(rounded)
        if magnitude >= largeLimit || (magnitude > 0 && magnitude < smallLimit) { return scientific(rounded) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maximumFraction
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }

    static func round(_ value: Double, digits: Int) -> Double {
        guard value != 0, value.isFinite else { return value }
        let scale = pow(10, Double(digits) - ceil(log10(abs(value))))
        return (value * scale).rounded() / scale
    }

    private static func scientific(_ value: Double) -> String {
        let exponent = Int(floor(log10(abs(value))))
        let mantissa = round(value / pow(10, Double(exponent)), digits: scientificDigits)
        var text = String(format: "%.\(scientificDigits - 1)f", mantissa)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)e\(exponent)"
    }
}

enum UnitFormat {
    static let inchesPerFoot = 12.0

    static func text(_ conversion: UnitConversion, locale: Locale = .current) -> String {
        if conversion.to == "ft", conversion.result >= 1 {
            var feet = conversion.result.rounded(.down)
            var inches = ((conversion.result - feet) * inchesPerFoot * 10).rounded() / 10
            if inches >= inchesPerFoot {
                feet += 1
                inches = 0
            }
            return "\(number(feet, decimals: 0, locale: locale)) ft \(number(inches, decimals: 1, locale: locale)) in"
        }
        let magnitude = abs(conversion.result)
        let decimals = magnitude < 1 ? 4 : magnitude < 100 ? 2 : 1
        return "\(number(conversion.result, decimals: decimals, locale: locale)) \(conversion.to)"
    }

    private static func number(_ value: Double, decimals: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
