import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
    static let toggleVietnamese = Self("toggleVietnamese", default: .init(.space, modifiers: [.control]))
}
