import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default ⌘⇧V; user-customizable in Settings.
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
}
