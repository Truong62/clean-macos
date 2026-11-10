import AppKit

enum PanelCommand: Equatable {
    case move(Int)
    case paste
    case copyOnly
    case togglePile
    case pasteNumber(Int)
    case togglePin
    case delete
    case deletePile
    case togglePreview
    case selectAll
    case escape
}

enum PanelKeys {
    static let upKey: UInt16 = 126
    static let downKey: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let spaceKey: UInt16 = 49
    static let escapeKey: UInt16 = 53
    static let deleteKey: UInt16 = 51
    static let pKey: UInt16 = 35
    static let nKey: UInt16 = 45
    static let cKey: UInt16 = 8
    static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let appCommandKeys: Set<UInt16> = [12, 46, 4]
    static let closeKey: UInt16 = 13

    static func isAppCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection(relevantModifiers) == .command && (appCommandKeys.contains(keyCode) || keyCode == closeKey)
    }

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, usedArrows: Bool, hasPile: Bool, cards: Bool = false, emptySearch: Bool = false) -> PanelCommand? {
        let modifiers = modifiers.intersection(relevantModifiers)
        if cards && modifiers.isEmpty && [123, 124].contains(keyCode) { return .move(keyCode == 123 ? -1 : 1) }
        if keyCode == 0 && modifiers == .command && (hasPile || emptySearch) { return .selectAll }
        switch (keyCode, modifiers) {
        case (upKey, []), (pKey, .control): return .move(-1)
        case (downKey, []), (nKey, .control): return .move(1)
        case (returnKey, []), (enterKey, []): return .paste
        case (returnKey, .shift), (enterKey, .shift): return .copyOnly
        case (returnKey, .command), (enterKey, .command): return .togglePile
        case (pKey, .option): return .togglePin
        case (deleteKey, .option), (117, .option): return .delete
        case (deleteKey, .command): return hasPile ? .deletePile : nil
        case (cKey, .command): return hasPile ? .copyOnly : nil
        case (spaceKey, []): return usedArrows ? .togglePreview : nil
        case (escapeKey, _): return .escape
        default: return modifiers == .command ? (digitKeys[keyCode] ?? [83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9][keyCode]).map(PanelCommand.pasteNumber) : nil
        }
    }
}

struct ClipboardPanelState: Equatable {
    var selection = 0
    var pile: Set<ClipboardItem.ID> = []
    var usedArrows = false

    mutating func move(by delta: Int, count: Int) {
        guard count > 0 else {
            selection = 0
            return
        }
        selection = min(max(selection + delta, 0), count - 1)
    }

    mutating func togglePile(_ id: ClipboardItem.ID) {
        if pile.remove(id) == nil { pile.insert(id) }
    }

    mutating func extendPile(through index: Int, in items: [ClipboardItem]) {
        guard items.indices.contains(index) else { return }
        let start = min(selection, items.count - 1)
        pile.formUnion(items[min(start, index)...max(start, index)].map(\.id))
        selection = index
    }

    func pileItems(in items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { pile.contains($0.id) }
    }
}

enum ClipboardPile {
    static func text(_ items: [ClipboardItem]) -> String {
        items.map { $0.kind == .files ? $0.files.joined(separator: "\n") : $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func allFiles(_ items: [ClipboardItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .files }
    }
}

enum PrettyJSON {
    static func format(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
