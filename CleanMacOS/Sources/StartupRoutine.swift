import AppKit
import ServiceManagement

enum StartupSettings {
    static let lockKey = "startup.lockAfterLogin"
    static let lockDelayKey = "startup.lockDelay"
    static let lastBootKey = "startup.lastBoot"
    static let defaultLockDelay = 1
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
        runAsAdmin("/usr/bin/pmset -a autorestart \(isOn ? 1 : 0)")
    }

    static func turnOffAutoLogin() -> String? {
        runAsAdmin("/usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser; /bin/rm -f /etc/kcpassword")
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

    private static func runAsAdmin(_ shell: String) -> String? {
        let result = CommandRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(shell)\" with administrator privileges"])
        guard result.status != 0, !result.error.contains("-128") else { return nil }
        return result.error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum StartupJobs {
    static let keepAwakeLabel = "click.ngoctruong.CleanMacOS.caffeinate"
    static let keepAwakeArguments = ["/usr/bin/caffeinate", "-d"]

    static func atLogin(_ jobs: [ScheduledJob]) -> [ScheduledJob] {
        jobs.filter { $0.source == .userAgent && $0.startsAtLogin }
    }

    static func keepsAwake(_ job: ScheduledJob) -> Bool {
        job.command.contains("caffeinate")
    }

    static func locksScreen(_ job: ScheduledJob) -> Bool {
        job.command.localizedCaseInsensitiveContains("lockscreen")
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
enum StartupRoutine {
    nonisolated static let freshBootWindow: TimeInterval = 600

    nonisolated static func shouldRun(bootTime: Date, now: Date, lastBoot: Double) -> Bool {
        now.timeIntervalSince(bootTime) < freshBootWindow && bootTime.timeIntervalSince1970 != lastBoot
    }

    static func start(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: StartupSettings.lockKey),
              let boot = SystemPower.bootTime(),
              shouldRun(bootTime: boot, now: Date(), lastBoot: defaults.double(forKey: StartupSettings.lastBootKey)) else { return }
        defaults.set(boot.timeIntervalSince1970, forKey: StartupSettings.lastBootKey)
        let delay = defaults.object(forKey: StartupSettings.lockDelayKey) as? Int ?? StartupSettings.defaultLockDelay
        Task {
            let user = await Task.detached { SystemPower.autoLoginUser() }.value
            guard user != nil else { return }
            try? await Task.sleep(for: .seconds(delay))
            ScreenLock.lock()
        }
    }
}

enum StartupReadiness: Equatable, Sendable {
    case power, password

    static func missing(autoRestart: Bool?, fileVaultIsOn: Bool?, autoLoginUser: String?) -> [StartupReadiness] {
        [autoRestart == true ? nil : .power,
         fileVaultIsOn == true || autoLoginUser == nil ? .password : nil].compactMap { $0 }
    }
}
