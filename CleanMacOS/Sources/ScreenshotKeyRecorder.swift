import AppKit
import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

@MainActor
enum EditorShortcutOwners {
    static func owner(of event: NSEvent) -> String? {
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("KeyboardShortcuts_") {
            let name = String(key.dropFirst("KeyboardShortcuts_".count))
            if KeyboardShortcuts.getShortcut(for: .init(name)) == shortcut { return name }
        }
        var unmanaged: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&unmanaged) == noErr, let values = unmanaged?.takeRetainedValue() as? [[String: Any]] {
            for value in values {
                if value[kHISymbolicHotKeyEnabled] as? Bool == true,
                   let code = value[kHISymbolicHotKeyCode] as? Int, let modifiers = value[kHISymbolicHotKeyModifiers] as? Int,
                   KeyboardShortcuts.Shortcut(carbonKeyCode: code, carbonModifiers: modifiers) == shortcut { return "System shortcut" }
            }
        }
        return nil
    }
    static func key(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 53: return "escape"
        case 36: return "return"
        case 76: return "enter"
        case 51: return "delete"
        case 117: return "forwarddelete"
        default: break
        }
        let flags = event.modifierFlags
        var prefix = ""
        if flags.contains(.command) { prefix += "⌘" }
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        return prefix + (event.characters?.lowercased() ?? "")
    }
}

struct EditorKeyRecorder: NSViewRepresentable {
    var label: String
    var record: (String, String?) -> Void
    func makeNSView(context: Context) -> Recorder { Recorder(label: label, record: record) }
    func updateNSView(_ view: Recorder, context: Context) {
        view.label = label
        view.record = record
        if !view.recording { view.title = label.isEmpty ? "Record" : label }
    }
    final class Recorder: NSButton {
        var label: String
        var record: (String, String?) -> Void
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init(label: String, record: @escaping (String, String?) -> Void) {
            self.label = label
            self.record = record
            super.init(frame: .zero)
            title = label.isEmpty ? "Record" : label
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
        }
        required init?(coder: NSCoder) { nil }
        @objc private func beginRecording() {
            recording = true
            title = "Type key"
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            record(EditorShortcutOwners.key(event), EditorShortcutOwners.owner(of: event))
            recording = false
            title = label.isEmpty ? "Record" : label
            window?.makeFirstResponder(nil)
        }
        override func resignFirstResponder() -> Bool { recording = false; title = label.isEmpty ? "Record" : label; return true }
    }
}
