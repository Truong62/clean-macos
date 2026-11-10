import AppKit
import ApplicationServices

struct IslandMenuRoom: Equatable {
    var known: Bool
    var left: Double
    var right: Double
    var overlaps: Bool
    static let unknown = IslandMenuRoom(known: false, left: 0, right: 0, overlaps: false)

    static func measure(camera: CGRect, screen: CGRect, items: [CGRect], known: Bool) -> IslandMenuRoom {
        let relevant = items.filter { $0.height > 0 && $0.width > 0 && $0.intersects(screen) && $0.maxY > camera.minY }
        let overlaps = relevant.contains { $0.intersects(camera) }
        let leftEdge = relevant.filter { $0.maxX <= camera.minX }.map(\.maxX).max() ?? screen.minX
        let rightEdge = relevant.filter { $0.minX >= camera.maxX }.map(\.minX).min() ?? screen.maxX
        return IslandMenuRoom(known: known && !overlaps, left: max(0, camera.minX - leftEdge - 8),
                              right: max(0, rightEdge - camera.maxX - 8), overlaps: overlaps)
    }
}

@MainActor
final class IslandMenuReader {
    private var reading = false
    private var generation = 0
    private let queue = DispatchQueue(label: "mackit.island.menu-room", qos: .utility)

    func cancel() { generation += 1 }

    func read(display: IslandDisplay, camera: CGRect, completion: @escaping (IslandMenuRoom) -> Void) {
        guard !reading else { return }
        reading = true
        let token = generation
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let top = NSScreen.screens.first?.frame.maxY ?? display.frame.maxY
        queue.async {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            var frames: [CGRect] = []
            var known = false
            if AXIsProcessTrusted(), let pid {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.15)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success, let value,
                   CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let bar = unsafeBitCast(value, to: AXUIElement.self)
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
                       let items = children as? [AXUIElement], items.count <= 64 {
                        known = true
                        for item in items {
                            guard ProcessInfo.processInfo.systemUptime < deadline else { known = false; break }
                            AXUIElementSetMessagingTimeout(item, Float(max(0.001, min(0.15, deadline - ProcessInfo.processInfo.systemUptime))))
                            var position: CFTypeRef?
                            var size: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { known = false; break }
                            var point = CGPoint.zero
                            var dimensions = CGSize.zero
                            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { known = false; break }
                            frames.append(CGRect(x: point.x, y: top - point.y - dimensions.height, width: dimensions.width, height: dimensions.height))
                        }
                    }
                }
            }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                      let level = window[kCGWindowLayer as String] as? Int, level >= Int(CGWindowLevelForKey(.statusWindow)),
                      let bounds = window[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.height <= 64 else { continue }
                frames.append(CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
            }
            let room = IslandMenuRoom.measure(camera: camera, screen: display.frame, items: frames, known: known)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                if token == self.generation { completion(room) }
            }
        }
    }
}
