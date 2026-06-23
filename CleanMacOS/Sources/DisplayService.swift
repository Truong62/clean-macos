import AppKit
import SwiftUI

enum DisplayError: LocalizedError {
    case screenNotFound
    case noWallpaper
    case configFailed

    var errorDescription: String? {
        switch self {
        case .screenNotFound: "Could not find that display."
        case .noWallpaper: "That display has no wallpaper set yet."
        case .configFailed: "macOS rejected the display arrangement change."
        }
    }
}

/// System adapter for reading/writing display geometry and per-display wallpaper.
/// Pure system I/O — no business decisions live here.
struct DisplayService {

    // MARK: - Read

    /// Active displays with their current wallpaper + scaling, ordered left → right.
    func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.displayID else { return nil }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let fill = (options[.fillColor] as? NSColor).map(Color.init) ?? .black
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                frame: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0,
                scale: screen.backingScaleFactor,
                wallpaperURL: NSWorkspace.shared.desktopImageURL(for: screen),
                scaling: WallpaperScaling(options: options),
                fillColor: fill
            )
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - Wallpaper

    /// Set a new wallpaper image (with scaling + fill color) for one display.
    func setWallpaper(url: URL, scaling: WallpaperScaling, fillColor: NSColor, displayID: CGDirectDisplayID) throws {
        guard let screen = screen(for: displayID) else { throw DisplayError.screenNotFound }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options(scaling, fillColor))
    }

    /// Re-apply scaling / fill color to a display's existing wallpaper.
    func setAppearance(scaling: WallpaperScaling, fillColor: NSColor, displayID: CGDirectDisplayID) throws {
        guard let screen = screen(for: displayID) else { throw DisplayError.screenNotFound }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { throw DisplayError.noWallpaper }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options(scaling, fillColor))
    }

    // MARK: - Arrangement

    /// Commit new top-left origins for displays. The display ending at (0, 0) becomes the main display.
    func applyArrangement(origins: [CGDirectDisplayID: CGPoint]) throws {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            throw DisplayError.configFailed
        }
        for (id, origin) in origins {
            let status = CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
            guard status == .success else {
                CGCancelDisplayConfiguration(config)
                throw DisplayError.configFailed
            }
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            throw DisplayError.configFailed
        }
    }

    // MARK: - Helpers

    private func options(_ scaling: WallpaperScaling, _ fillColor: NSColor) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var opts = scaling.workspaceOptions
        opts[.fillColor] = fillColor
        return opts
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
