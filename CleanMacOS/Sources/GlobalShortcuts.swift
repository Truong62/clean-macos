import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
    static let toggleKeepAwake = Self("toggleKeepAwake", default: .init(.k, modifiers: [.control, .option, .command]))
    static let toggleVietnamese = Self("toggleVietnamese", default: .init(.space, modifiers: [.control]))
}
