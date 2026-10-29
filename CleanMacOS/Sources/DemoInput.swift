import AppKit
import ApplicationServices

struct FoundElement: Equatable {
    let role: String
    let label: String
    let frame: CGRect
}

enum ElementMatch {
    static func score(_ query: String, labels: [String]) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        return labels.map { label in
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text == needle { return 3 }
            if text.hasPrefix(needle) { return 2 }
            return text.contains(needle) ? 1 : 0
        }.max() ?? 0
    }

    static func rolePriority(_ role: String) -> Int {
        role == "AXImage" ? 0 : 1
    }

    static func roleMatches(_ role: String, filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return role.lowercased().contains(filter.lowercased())
    }
}

enum AccessibilityFinder {
    static let maxNodes = 8000
    static let labelAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute,
                                  kAXHelpAttribute, kAXPlaceholderValueAttribute] as [String]

    static func find(_ query: String, pid: pid_t, role: String? = nil) -> [FoundElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var queue = [app]
        var head = 0
        var matches: [(score: Int, priority: Int, order: Int, element: FoundElement)] = []
        while head < queue.count, head < maxNodes {
            let element = queue[head]
            head += 1
            queue += children(of: element)
            let labels = labelAttributes.compactMap { string(element, $0) }
            let score = ElementMatch.score(query, labels: labels)
            let elementRole = string(element, kAXRoleAttribute) ?? ""
            guard score > 0, ElementMatch.roleMatches(elementRole, filter: role), let frame = frame(of: element),
                  frame.width > 0, frame.height > 0 else { continue }
            let label = labels.first { ElementMatch.score(query, labels: [$0]) == score } ?? labels.first ?? ""
            matches.append((score, ElementMatch.rolePriority(elementRole), head, FoundElement(role: elementRole, label: label, frame: frame)))
        }
        return matches.sorted { ($0.score, $0.priority, -$0.order) > ($1.score, $1.priority, -$1.order) }.map(\.element)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

struct KeyCombo: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "option": .maskAlternate,
        "alt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
    ]

    static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let keyCode = keys[key] else { return nil }
        var flags = CGEventFlags()
        for part in parts.dropLast() {
            guard let flag = modifiers[part] else { return nil }
            flags.insert(flag)
        }
        return KeyCombo(keyCode: keyCode, flags: flags)
    }
}

enum DemoInput {
    static let glideSteps = 24

    static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else {
            throw MCPToolError.message("Accessibility is off for the app running Claude Code. Turn it on in System Settings › Privacy & Security › Accessibility, then try again.")
        }
    }

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func glide(to point: CGPoint, duration: TimeInterval) async {
        let start = cursor
        for step in 1...glideSteps {
            let t = Double(step) / Double(glideSteps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let position = CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .seconds(duration / Double(glideSteps)))
        }
    }

    static func click(at point: CGPoint, count: Int) async {
        for index in 1...max(count, 1) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
            up?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    static func type(_ text: String, interval: TimeInterval) async {
        for character in text {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    static func press(_ combo: KeyCombo) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: isDown)
            event?.flags = combo.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(by amount: CGVector, steps: Int) async {
        let count = max(steps, 1)
        for _ in 0..<count {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(-amount.dy / CGFloat(count)), wheel2: Int32(-amount.dx / CGFloat(count)), wheel3: 0)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}
