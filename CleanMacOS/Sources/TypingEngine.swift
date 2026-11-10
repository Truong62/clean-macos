import CMacKitCore
import Foundation

enum TypingMethod: String, CaseIterable, Identifiable, Codable {
    case telex, vni

    var id: String { rawValue }
    var title: String { self == .telex ? "Telex" : "VNI" }
}

struct TypingOptions: Codable, Equatable {
    var method: TypingMethod = .telex
    var modernTone = true
    var autoRestore = true
    var wAsU = true
    var brackets = false
    var foreignConsonants = false
    var autoCapitalize = false

    func flags(vietnamese: Bool) -> UInt32 {
        [method == .vni, vietnamese, modernTone, autoRestore, wAsU, brackets, foreignConsonants, autoCapitalize]
            .enumerated()
            .reduce(UInt32(0)) { flags, option in option.element ? flags | (1 << UInt32(option.offset)) : flags }
    }
}

struct TypingEdit: Equatable {
    let backspaces: Int
    let text: String
}

final class TypingEngine {
    private let handle: OpaquePointer

    init() {
        handle = mk_typing_new()
    }

    deinit {
        mk_typing_free(handle)
    }

    func configure(_ options: TypingOptions, vietnamese: Bool = true) {
        mk_typing_configure(handle, options.flags(vietnamese: vietnamese))
    }

    func setMacros(_ macros: [String: String]) {
        let lines = macros
            .filter { !$0.key.contains("\t") && !$0.key.contains("\n") && !$0.value.contains("\n") }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n")
        mk_typing_set_macros(handle, lines)
    }

    func key(_ scalar: Unicode.Scalar) -> TypingEdit? {
        var backspaces: UInt32 = 0
        return edit(mk_typing_key(handle, scalar.value, &backspaces), backspaces)
    }

    func finish(separator: Unicode.Scalar?) -> TypingEdit? {
        var backspaces: UInt32 = 0
        return edit(mk_typing_finish(handle, separator?.value ?? 0, &backspaces), backspaces)
    }

    func restore() -> TypingEdit? {
        var backspaces: UInt32 = 0
        return edit(mk_typing_restore(handle, &backspaces), backspaces)
    }

    func backspace() {
        mk_typing_backspace(handle)
    }

    func reset() {
        mk_typing_reset(handle)
    }

    private func edit(_ raw: UnsafeMutablePointer<CChar>?, _ backspaces: UInt32) -> TypingEdit? {
        guard let raw else { return nil }
        defer { mk_string_free(raw) }
        return TypingEdit(backspaces: Int(backspaces), text: String(cString: raw))
    }
}
