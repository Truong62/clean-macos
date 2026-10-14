import CoreServices
import Foundation

struct LoginItemsService {
    static let disabledKey = "loginItems.disabled"

    private let defaults: UserDefaults
    private let ownPath: String

    init(defaults: UserDefaults = .standard, ownPath: String = Bundle.main.bundlePath) {
        self.defaults = defaults
        self.ownPath = ownPath
    }

    func list() -> [LoginItem] {
        let enabled = SharedLoginItems.snapshot().map { entry in
            LoginItem(name: entry.name, path: entry.path, isEnabled: true, isMissing: entry.path == nil)
        }
        return Self.merge(enabled: enabled, disabledPaths: disabledPaths, ownPath: ownPath,
                          fileExists: FileManager.default.fileExists(atPath:))
    }

    func turnOff(_ item: LoginItem) throws {
        try removeFromLoginList(item)
        if let path = item.path { setDisabled(path, true) }
    }

    func turnOn(_ item: LoginItem) throws {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            throw PortsJobsError.commandFailed("\(item.name) is no longer installed.")
        }
        try add(URL(fileURLWithPath: path))
    }

    func add(_ appURL: URL) throws {
        try SharedLoginItems.insert(appURL)
        setDisabled(appURL.path, false)
    }

    func forget(_ item: LoginItem) throws {
        if item.isEnabled { try removeFromLoginList(item) }
        if let path = item.path { setDisabled(path, false) }
    }

    static func merge(enabled: [LoginItem], disabledPaths: [String], ownPath: String,
                      fileExists: (String) -> Bool) -> [LoginItem] {
        let enabledPaths = Set(enabled.compactMap(\.path))
        let turnedOff = disabledPaths.filter { !enabledPaths.contains($0) }.map { path in
            LoginItem(name: displayName(path), path: path, isEnabled: false, isMissing: !fileExists(path))
        }
        return (enabled.filter { $0.path != ownPath } + turnedOff)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var disabledPaths: [String] {
        defaults.stringArray(forKey: Self.disabledKey) ?? []
    }

    private func setDisabled(_ path: String, _ isDisabled: Bool) {
        let others = disabledPaths.filter { $0 != path }
        defaults.set(isDisabled ? others + [path] : others, forKey: Self.disabledKey)
    }

    private func removeFromLoginList(_ item: LoginItem) throws {
        SharedLoginItems.remove { ($0.path ?? $0.name) == item.id }
        if SharedLoginItems.snapshot().contains(where: { ($0.path ?? $0.name) == item.id }) {
            throw PortsJobsError.commandFailed("\(item.name) keeps adding itself back. Turn off its own “Open at login” setting instead.")
        }
    }
}

private enum SharedLoginItems {
    struct Entry {
        let item: LSSharedFileListItem
        let name: String
        let path: String?
    }

    private static let resolveFlags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

    static func snapshot() -> [Entry] {
        guard let list = open() else { return [] }
        return items(in: list).map { item in
            let url = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?
            return Entry(item: item, name: LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String, path: url?.path)
        }
    }

    static func remove(where shouldRemove: (Entry) -> Bool) {
        guard let list = open() else { return }
        for entry in snapshot() where shouldRemove(entry) {
            LSSharedFileListItemRemove(list, entry.item)
        }
    }

    // kLSSharedFileListItemLast is a null symbol on macOS 26 and crashes when read, so insert after an existing item.
    static func insert(_ appURL: URL) throws {
        guard let list = open(), let anchor = items(in: list).last else {
            throw PortsJobsError.commandFailed("Add the first app in System Settings › General › Login Items.")
        }
        guard LSSharedFileListInsertItemURL(list, anchor, nil, nil, appURL as CFURL, nil, nil) != nil else {
            throw PortsJobsError.commandFailed("macOS refused to add \(appURL.lastPathComponent) to Login Items.")
        }
    }

    private static func open() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }

    private static func items(in list: LSSharedFileList) -> [LSSharedFileListItem] {
        var seed: UInt32 = 0
        return (LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
    }
}
