import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let editImageFile = Self("editImageFile")
    static let editClipboardImage = Self("editClipboardImage")
    static func radialWheel(_ id: UUID) -> Self {
        id == RadialWheel.originalID ? .radialMenu : Self("radial.wheel.\(id.uuidString)")
    }

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
    static let radialMenu = Self("radialMenu", default: .init(.space, modifiers: [.control, .option, .command]))
    static let pickColor = Self("pickColor", default: .init(.c, modifiers: [.control, .option, .command]))
    static let grabText = Self("grabText", default: .init(.t, modifiers: [.control, .option, .command]))
    static let island = Self("island", default: .init(.i, modifiers: [.control, .option, .command]))
    static let quickPanel = Self("quickPanel", default: .init(.v, modifiers: [.control, .command]))
    static let cycleOutput = Self("cycleOutput", default: .init(.s, modifiers: [.control, .option, .command]))
    static let toggleMicMute = Self("toggleMicMute", default: .init(.m, modifiers: [.control, .option, .command]))
    static let scratchpad = Self("scratchpad", default: .init(.n, modifiers: [.control, .option, .command]))
    static let cameraPreview = Self("cameraPreview", default: .init(.w, modifiers: [.control, .option, .command]))
    static let quitApps = Self("quitApps", default: .init(.q, modifiers: [.control, .option, .command]))
}
