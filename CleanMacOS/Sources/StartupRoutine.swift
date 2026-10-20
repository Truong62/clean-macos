import AppKit
import IOKit.pwr_mgt
import ServiceManagement

enum StartupAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepOpen, hide, quit

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepOpen: "Keep open"
        case .hide: "Hide after"
        case .quit: "Quit after"
        }
    }
}

struct StartupApp: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var action: StartupAction = .quit
    var delaySeconds = 5

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

enum StartupSettings {
    static let appsKey = "startup.apps"
    static let lockKey = "startup.lockAfterLogin"
    static let keepAwakeKey = "startup.keepAwake"
    static let lastBootKey = "startup.lastBoot"

    static func apps(in defaults: UserDefaults = .standard) -> [StartupApp] {
        defaults.data(forKey: appsKey).flatMap { try? JSONDecoder().decode([StartupApp].self, from: $0) } ?? []
    }

    static func save(_ apps: [StartupApp], in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(apps), forKey: appsKey)
    }
}

enum OpenAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ isOn: Bool) {
        do {
            try isOn ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            NSLog("OpenAtLogin.set(\(isOn)) failed: \(error.localizedDescription)")
        }
    }
}

enum SystemPower {
    static let usersSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!
    static let fileVaultSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")!

    static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }

    static func autoRestart() -> Bool? {
        parseAutoRestart(settings: CommandRunner.run("/usr/bin/pmset", ["-g"]).output,
                         capabilities: CommandRunner.run("/usr/bin/pmset", ["-g", "cap"]).output)
    }

    static func setAutoRestart(_ isOn: Bool) -> String? {
        let script = "do shell script \"/usr/bin/pmset -a autorestart \(isOn ? 1 : 0)\" with administrator privileges"
        let result = CommandRunner.run("/usr/bin/osascript", ["-e", script])
        guard result.status != 0, !result.error.contains("-128") else { return nil }
        return result.error.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fileVaultIsOn() -> Bool? {
        parseFileVault(CommandRunner.run("/usr/bin/fdesetup", ["status"]).output)
    }

    static func autoLoginUser() -> String? {
        parseAutoLoginUser(CommandRunner.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"]).output)
    }

    static func parseAutoRestart(settings: String, capabilities: String) -> Bool? {
        guard capabilities.split(whereSeparator: \.isWhitespace).contains("autorestart") else { return nil }
        let line = settings.split(whereSeparator: \.isNewline).first { $0.split(whereSeparator: \.isWhitespace).first == "autorestart" }
        return line?.split(whereSeparator: \.isWhitespace).last == "1"
    }

    static func parseFileVault(_ output: String) -> Bool? {
        if output.contains("FileVault is On") { return true }
        if output.contains("FileVault is Off") { return false }
        return nil
    }

    static func parseAutoLoginUser(_ output: String) -> String? {
        let user = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
    }
}

enum ScreenLock {
    private static let framework = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

    @discardableResult
    static func lock() -> Bool {
        guard let handle = dlopen(framework, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockScreen = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockScreen.self)()
        return true
    }
}

@MainActor
final class StartupRoutine {
    static let shared = StartupRoutine()
    nonisolated static let freshBootWindow: TimeInterval = 600

    private var displayAssertion: IOPMAssertionID?

    nonisolated static func shouldRun(bootTime: Date, now: Date, lastBoot: Double) -> Bool {
        now.timeIntervalSince(bootTime) < freshBootWindow && bootTime.timeIntervalSince1970 != lastBoot
    }

    func start(defaults: UserDefaults = .standard) {
        setKeepAwake(defaults.bool(forKey: StartupSettings.keepAwakeKey))
        guard let boot = SystemPower.bootTime(),
              Self.shouldRun(bootTime: boot, now: Date(), lastBoot: defaults.double(forKey: StartupSettings.lastBootKey)) else { return }
        defaults.set(boot.timeIntervalSince1970, forKey: StartupSettings.lastBootKey)
        let locks = defaults.bool(forKey: StartupSettings.lockKey)
        Task { await run(StartupSettings.apps(in: defaults), locksScreen: locks) }
    }

    func run(_ apps: [StartupApp], locksScreen: Bool) async {
        var launched: [(StartupApp, NSRunningApplication)] = []
        for app in apps {
            if let running = await open(app) { launched.append((app, running)) }
        }
        if locksScreen { ScreenLock.lock() }
        for (app, running) in launched where app.action != .keepOpen {
            Task {
                try? await Task.sleep(for: .seconds(app.delaySeconds))
                if app.action == .hide { running.hide() } else { running.terminate() }
            }
        }
    }

    func setKeepAwake(_ isOn: Bool) {
        if isOn, displayAssertion == nil {
            var id = IOPMAssertionID(0)
            let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                      IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                      "Clean macOS keeps the screen awake" as CFString, &id)
            if created == kIOReturnSuccess { displayAssertion = id }
        } else if !isOn, let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
    }

    private func open(_ app: StartupApp) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            return try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration)
        } catch {
            NSLog("StartupRoutine.open(\(app.path)) failed: \(error.localizedDescription)")
            return nil
        }
    }
}

enum StartupReadiness: Equatable, Sendable {
    case power, disk, login, app

    static func missing(autoRestart: Bool?, fileVaultIsOn: Bool?, autoLoginUser: String?, opensAtLogin: Bool) -> [StartupReadiness] {
        [autoRestart == true ? nil : .power,
         fileVaultIsOn == true ? .disk : nil,
         autoLoginUser == nil ? .login : nil,
         opensAtLogin ? nil : .app].compactMap { $0 }
    }
}
