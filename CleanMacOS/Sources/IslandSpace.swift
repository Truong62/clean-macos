import AppKit

@MainActor
final class IslandSpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias Destroy = @convention(c) (Int32, UInt64) -> Void
    private typealias Show = @convention(c) (Int32, CFArray) -> Void
    private typealias Windows = @convention(c) (Int32, CFArray, CFArray) -> Void
    private var library: UnsafeMutableRawPointer?
    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var window: Int?

    init() { library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) }

    static var supportsAbsoluteLevel: Bool {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return false }
        defer { dlclose(library) }
        let names: [String] = ["CGSMainConnectionID", "CGSSpaceCreate", "CGSSpaceSetAbsoluteLevel", "CGSShowSpaces", "CGSAddWindowsToSpaces", "CGSSpaceDestroy", "CGSRemoveWindowsFromSpaces"]
        return names.allSatisfy { dlsym(library, $0) != nil }
    }

    @discardableResult func attach(_ panel: NSPanel, absoluteLevel: Int32? = nil) -> Bool {
        guard space == 0, let connectionFunction: Connection = symbol("CGSMainConnectionID"),
              let create: Create = symbol("CGSSpaceCreate"), let show: Show = symbol("CGSShowSpaces"),
              let add: Windows = symbol("CGSAddWindowsToSpaces"),
              symbol("CGSSpaceDestroy", as: Destroy.self) != nil, symbol("CGSRemoveWindowsFromSpaces", as: Windows.self) != nil else { return space != 0 }
        connection = connectionFunction()
        space = create(connection, 4, nil)
        guard space != 0 else { return false }
        if let absoluteLevel {
            typealias Level = @convention(c) (Int32, UInt64, Int32) -> Void
            guard let level: Level = symbol("CGSSpaceSetAbsoluteLevel") else { detach(); return false }
            level(connection, space, absoluteLevel)
        }
        window = panel.windowNumber
        let spaces = [NSNumber(value: space)] as CFArray
        show(connection, spaces)
        add(connection, [NSNumber(value: panel.windowNumber)] as CFArray, spaces)
        return true
    }

    func detach() {
        guard space != 0 else { return }
        if let window, let remove: Windows = symbol("CGSRemoveWindowsFromSpaces") {
            remove(connection, [NSNumber(value: window)] as CFArray, [NSNumber(value: space)] as CFArray)
        }
        if let destroy: Destroy = symbol("CGSSpaceDestroy") { destroy(connection, space) }
        space = 0
        window = nil
    }

    func isFullScreen(displayID: UInt32) -> Bool? {
        typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let connectionFunction: Connection = symbol("CGSMainConnectionID"), let copy: Copy = symbol("CGSCopyManagedDisplaySpaces"),
              let rows = copy(connectionFunction())?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        guard let row = rows.first(where: { ($0["Display Identifier"] as? String) == identifier }),
              let current = row["Current Space"] as? [String: Any], let type = current["type"] as? Int else { return nil }
        return type == 4
    }

    private func symbol<T>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
