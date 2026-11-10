import AppKit
import ApplicationServices

/// Auto-paste support: checks Accessibility trust and synthesizes ⌘V into the
/// frontmost app. Degrades gracefully — `pasteToFrontmostApp()` returns false
/// (a no-op) when the app is not trusted, leaving the content on the clipboard.
enum PasteService {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Show the system prompt that lets the user add this app to Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Synthesize ⌘V into whatever app is frontmost. Returns false if not trusted.
    @discardableResult
    static func pasteToFrontmostApp() -> Bool {
        guard isAccessibilityTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    static let heldModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    static let modifierPoll: TimeInterval = 0.02

    @MainActor
    static func whenModifiersReleased(timeout: TimeInterval, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            let isHeld = !CGEventSource.flagsState(.combinedSessionState).intersection(heldModifiers).isEmpty
            guard !isHeld || Date() >= deadline else {
                DispatchQueue.main.asyncAfter(deadline: .now() + modifierPoll) { attempt() }
                return
            }
            action()
        }
        attempt()
    }
}
