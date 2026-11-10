import AppKit

protocol CommandRunning: Sendable {
    func run(_ path: String, _ arguments: [String]) -> CommandResult
}

struct SystemCommandRunner: CommandRunning {
    func run(_ path: String, _ arguments: [String]) -> CommandResult {
        CommandRunner.run(path, arguments)
    }
}

struct RunningAppInfo: Equatable, Identifiable {
    let bundleID: String
    let name: String
    let isRegular: Bool

    var id: String { bundleID }
}

enum FinderFlag: String, CaseIterable, Identifiable {
    case hiddenFiles = "AppleShowAllFiles"
    case desktopIcons = "CreateDesktop"

    var id: String { rawValue }
    var defaultValue: Bool { self == .desktopIcons }
}

struct QuickControls: Sendable {
    static let finderDomain = "com.apple.finder"
    static let defaultsTool = "/usr/bin/defaults"
    static let screenSaver = "/System/Library/CoreServices/ScreenSaverEngine.app"

    let runner: CommandRunning

    init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    func isOn(_ flag: FinderFlag) -> Bool {
        let result = runner.run(Self.defaultsTool, ["read", Self.finderDomain, flag.rawValue])
        guard result.status == 0 else { return flag.defaultValue }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    func set(_ flag: FinderFlag, _ isOn: Bool) {
        _ = runner.run(Self.defaultsTool, ["write", Self.finderDomain, flag.rawValue, "-bool", isOn ? "true" : "false"])
        _ = runner.run("/usr/bin/killall", ["Finder"])
    }

    var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func setDarkMode(_ isOn: Bool) {
        osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(isOn)")
    }

    func sleepDisplay() {
        _ = runner.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func startScreenSaver() {
        _ = runner.run("/usr/bin/open", ["-a", Self.screenSaver])
    }

    func emptyTrash() {
        osascript("tell application \"Finder\" to empty trash")
    }

    func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let symbol = dlsym(library, "SACLockScreenImmediate") {
            unsafeBitCast(symbol, to: Lock.self)()
        } else {
            sleepDisplay()
        }
    }

    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || values?.volumeIsInternal == false
        }.filter { $0.path != "/" }
    }

    static func ejectAll() -> [String] {
        ejectableVolumes().compactMap { url in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return url.lastPathComponent
            }
        }
    }

    static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID, isRegular: app.activationPolicy == .regular)
        }
    }

    static func appsToQuit(_ running: [RunningAppInfo], keep: Set<String>, own: String?) -> [RunningAppInfo] {
        running.filter { $0.isRegular && $0.bundleID != "com.apple.finder" && $0.bundleID != own && !keep.contains($0.bundleID) }
    }

    static func quit(_ apps: [RunningAppInfo]) {
        let ids = Set(apps.map(\.bundleID))
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(ids.contains) ?? false }.forEach { $0.terminate() }
    }

    private func osascript(_ script: String) {
        _ = runner.run("/usr/bin/osascript", ["-e", script])
    }
}

@MainActor
final class KeyboardBacklight {
    private typealias Getter = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Setter = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private static let keyboard: UInt64 = 1

    private let client: AnyObject?

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }

    var isAvailable: Bool { brightness != nil }

    var brightness: Float? {
        guard let client, let method = class_getInstanceMethod(type(of: client), NSSelectorFromString("brightnessForKeyboard:")) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(client, NSSelectorFromString("brightnessForKeyboard:"), Self.keyboard)
    }

    func set(_ value: Float) {
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, let method = class_getInstanceMethod(type(of: client), selector) else { return }
        _ = unsafeBitCast(method_getImplementation(method), to: Setter.self)(client, selector, min(max(value, 0), 1), Self.keyboard)
    }
}
