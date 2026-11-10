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
    static let toggleShelf = Self("toggleShelf", default: .init(.d, modifiers: [.control, .option, .command]))
    static let displayBrightnessUp = Self("displayBrightnessUp", default: .init(.equal, modifiers: [.command, .shift]))
    static let displayBrightnessDown = Self("displayBrightnessDown", default: .init(.minus, modifiers: [.command, .shift]))
    static let keyboardLightUp = Self("keyboardLightUp", default: .init(.equal, modifiers: [.command, .option]))
    static let keyboardLightDown = Self("keyboardLightDown", default: .init(.minus, modifiers: [.command, .option]))
    static let commandBar = Self("commandBar", default: .init(.space, modifiers: [.option]))
    static let cycleOutput = Self("cycleOutput", default: .init(.s, modifiers: [.control, .option, .command]))
    static let toggleMicMute = Self("toggleMicMute", default: .init(.m, modifiers: [.control, .option, .command]))
}
