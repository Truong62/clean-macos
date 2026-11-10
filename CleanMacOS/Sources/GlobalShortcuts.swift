import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
    static let toggleKeepAwake = Self("toggleKeepAwake", default: .init(.k, modifiers: [.control, .option, .command]))
    static let toggleVietnamese = Self("toggleVietnamese", default: .init(.space, modifiers: [.control]))
    static let pastePlainText = Self("pastePlainText", default: .init(.v, modifiers: [.command, .option, .shift]))
    static let snippetLibrary = Self("snippetLibrary", default: .init(.l, modifiers: [.control, .option, .command]))
}
