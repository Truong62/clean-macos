import SwiftUI
import AppKit

// MARK: - Wallpaper scaling

/// How a wallpaper image is fitted onto a screen — mirrors the macOS
/// "Fill Screen / Fit to Screen / Stretch / Center" options.
enum WallpaperScaling: String, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        case .center: "Center"
        }
    }

    var systemImage: String {
        switch self {
        case .fill: "rectangle.fill"
        case .fit: "rectangle.center.inset.filled"
        case .stretch: "arrow.up.left.and.arrow.down.right"
        case .center: "rectangle.compress.vertical"
        }
    }

    /// NSWorkspace desktop-image options for this scaling (fill color is added by the caller).
    var workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        switch self {
        case .fill:
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true]
        case .fit:
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: false]
        case .stretch:
            return [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                    .allowClipping: true]
        case .center:
            return [.imageScaling: NSImageScaling.scaleNone.rawValue,
                    .allowClipping: false]
        }
    }

    /// Read the scaling back from a live set of NSWorkspace options.
    init(options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        let raw = (options[.imageScaling] as? NSNumber)?.intValue
        let clips = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch NSImageScaling(rawValue: UInt(raw ?? 3)) {
        case .scaleAxesIndependently: self = .stretch
        case .scaleNone: self = .center
        case .scaleProportionallyUpOrDown, .scaleProportionallyDown:
            self = clips ? .fill : .fit
        default:
            self = .fill
        }
    }
}

// MARK: - Display info

/// A snapshot of one active display: its geometry, role, and current wallpaper.
/// `frame` is in the global CoreGraphics coordinate space (top-left origin, y-down),
/// where the main display sits at (0, 0) — the same space `CGConfigureDisplayOrigin` expects.
struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isMain: Bool
    let scale: CGFloat
    var wallpaperURL: URL?
    var scaling: WallpaperScaling
    var fillColor: Color

    var resolutionLabel: String {
        "\(Int(frame.width)) × \(Int(frame.height))"
    }
}
