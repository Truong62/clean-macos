import AppKit
import ApplicationServices

struct DockPreviewTarget: Equatable {
    let pid: Int32
    let frame: CGRect
}

enum DockPreviewAccess {
    private static let assignments = InstanceRegistry()

    private final class InstanceRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: DockInstanceAssignments] = [:]

        func resolve(path: String, tiles: [String], processes: [Int32], selected: String) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            var state = byPath[path] ?? DockInstanceAssignments()
            let result = state.resolve(tiles: tiles, processes: processes)
            byPath[path] = state
            return result[selected]
        }
    }

    static func preferences() -> DockGeometry? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first != nil else { return nil }
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
        let orientation = value("orientation") as? String ?? "bottom"
        guard let edge = DockEdge(rawValue: orientation) else { return nil }
        return DockGeometry(edge: edge, autoHide: value("autohide") as? Bool ?? false,
                            tileSize: min(256, max(16, value("tilesize") as? Double ?? 64)),
                            magnifiedSize: min(256, max(16, value("largesize") as? Double ?? 128)),
                            magnification: value("magnification") as? Bool ?? false)
    }

    static func target(at point: CGPoint, geometry: DockGeometry, screens: [CGRect], apps: [NSRunningApplication]) -> DockPreviewTarget? {
        guard screens.contains(where: { geometry.inBand(point, screen: $0) }),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var owner: pid_t = 0
        AXUIElementGetPid(hit, &owner)
        guard owner == dock.processIdentifier else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.25)
        var tile: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &tile) == .success else { return nil }
        for _ in 0..<8 {
            guard let current = tile else { return nil }
            AXUIElementSetMessagingTimeout(current, 0.25)
            if (AXWindow.value(current, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" {
                guard let frame = AXWindow.frame(current), frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
                let url: URL? = AXWindow.value(current, kAXURLAttribute)
                let title: String = AXWindow.value(current, kAXTitleAttribute) ?? AXWindow.value(current, kAXDescriptionAttribute) ?? ""
                let matching = apps.filter { app in
                    if let url { return app.bundleURL?.standardizedFileURL == url.standardizedFileURL }
                    return !title.isEmpty && app.localizedName == title
                }.sorted { a, b in
                    if a.launchDate != b.launchDate { return (a.launchDate ?? .distantPast) < (b.launchDate ?? .distantPast) }
                    return a.processIdentifier < b.processIdentifier
                }
                guard !matching.isEmpty else { return nil }
                let selected = String(CFHash(current))
                let parent: AXUIElement? = AXWindow.value(current, kAXParentAttribute)
                let children: [AXUIElement] = parent.flatMap { AXWindow.value($0, kAXChildrenAttribute) } ?? [current]
                let tiles = children.filter { child in
                    guard (AXWindow.value(child, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" else { return false }
                    if let url { return (AXWindow.value(child, kAXURLAttribute) as URL?)?.standardizedFileURL == url.standardizedFileURL }
                    return (AXWindow.value(child, kAXTitleAttribute) as String?) == title
                }.map { String(CFHash($0)) }
                let pid = assignments.resolve(path: url?.path ?? title, tiles: tiles.isEmpty ? [selected] : tiles,
                                              processes: matching.map(\.processIdentifier), selected: selected)
                guard let pid else { return nil }
                return DockPreviewTarget(pid: pid, frame: frame)
            }
            tile = AXWindow.value(current, kAXParentAttribute)
        }
        return nil
    }
}
