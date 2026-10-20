import Foundation

struct ScheduledJobsService: Sendable {
    static let launchctl = "/bin/launchctl"
    static let directories: [(String, ScheduledJobSource)] = [
        (NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
        ("/Library/LaunchAgents", .globalAgent),
        ("/Library/LaunchDaemons", .globalDaemon),
    ]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let maxCalendarEntries = 3
    private static let logTailBytes = 16_384

    func list() async -> [ScheduledJob] {
        await Task.detached(priority: .utility) {
            let statuses = Self.parseLaunchctlList(CommandRunner.run(Self.launchctl, ["list"]).output)
            let agents = Self.directories.flatMap { Self.readPlists(in: $0.0, source: $0.1, statuses: statuses) }
            let cron = Self.parseCrontab(CommandRunner.run("/usr/bin/crontab", ["-l"]).output)
            return agents + cron
        }.value
    }

    func runNow(_ job: ScheduledJob) async throws {
        try await launchctl(["kickstart", "\(Self.domain)/\(job.label)"])
    }

    func turnOff(_ job: ScheduledJob) async throws {
        guard let plist = job.plistPath else { return }
        try await launchctl(["disable", "\(Self.domain)/\(job.label)"])
        try await launchctl(["bootout", Self.domain, plist])
    }

    func turnOn(_ job: ScheduledJob) async throws {
        guard let plist = job.plistPath else { return }
        try await launchctl(["enable", "\(Self.domain)/\(job.label)"])
        try await launchctl(["bootstrap", Self.domain, plist])
    }

    func stop(_ job: ScheduledJob) async throws {
        try await launchctl(["kill", "SIGTERM", "\(Self.domain)/\(job.label)"])
    }

    func delete(_ job: ScheduledJob) async throws {
        if let line = job.cronLine {
            let current = CommandRunner.run("/usr/bin/crontab", ["-l"]).output
            let result = CommandRunner.run("/usr/bin/crontab", ["-"], input: Self.removingLine(line, from: current))
            guard result.status == 0 else { throw PortsJobsError.commandFailed("crontab update failed: \(result.error)") }
            return
        }
        guard let plist = job.plistPath, job.source.isManageable else { return }
        if job.isLoaded { try await launchctl(["bootout", Self.domain, plist]) }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: plist), resultingItemURL: nil)
    }

    static func removingLine(_ line: String, from crontab: String) -> String {
        var lines = crontab.components(separatedBy: "\n")
        if let index = lines.firstIndex(of: line) { lines.remove(at: index) }
        return lines.joined(separator: "\n")
    }

    static func logTail(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return size > UInt64(logTailBytes) ? text.drop { $0 != "\n" }.dropFirst().description : text
    }

    private static var domain: String { "gui/\(getuid())" }

    private func launchctl(_ args: [String]) async throws {
        let result = await Task.detached { CommandRunner.run(Self.launchctl, args) }.value
        guard result.status == 0 else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PortsJobsError.commandFailed("launchctl \(args[0]) failed: \(detail.isEmpty ? "exit \(result.status)" : detail)")
        }
    }

    static func readPlists(in directory: String, source: ScheduledJobSource,
                           statuses: [String: LaunchctlStatus]) -> [ScheduledJob] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".plist") }.sorted().compactMap { file in
            let path = directory + "/" + file
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
            let label = plist["Label"] as? String ?? String(file.dropLast(".plist".count))
            let status = statuses[label]
            return ScheduledJob(label: label, source: source, command: command(of: plist),
                                schedule: describeSchedule(plist), plistPath: path,
                                logPaths: Array(NSOrderedSet(array: [plist["StandardOutPath"], plist["StandardErrorPath"]].compactMap { $0 as? String })) as? [String] ?? [],
                                isLoaded: status != nil, pid: status?.pid, lastExitStatus: status?.lastExitStatus,
                                startsAtLogin: startsAtLogin(plist))
        }
    }

    static func startsAtLogin(_ plist: [String: Any]) -> Bool {
        if plist["RunAtLoad"] as? Bool == true { return true }
        guard let keepAlive = plist["KeepAlive"] else { return false }
        return (keepAlive as? Bool) != false
    }

    static func agentPlist(label: String, arguments: [String], keepsRunning: Bool = true, logPath: String? = nil) -> [String: Any] {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": keepsRunning]
        if let logPath {
            plist["StandardOutPath"] = logPath
            plist["StandardErrorPath"] = logPath
        }
        return plist
    }

    func addAgent(label: String, arguments: [String], keepsRunning: Bool = true, logPath: String? = nil) async throws {
        let path = Self.directories[0].0 + "/\(label).plist"
        guard !FileManager.default.fileExists(atPath: path) else {
            throw PortsJobsError.commandFailed("A job named \(label) already exists.")
        }
        let plist = Self.agentPlist(label: label, arguments: arguments, keepsRunning: keepsRunning, logPath: logPath)
        guard (plist as NSDictionary).write(toFile: path, atomically: true) else {
            throw PortsJobsError.commandFailed("Could not write \(path)")
        }
        try await launchctl(["bootstrap", Self.domain, path])
    }

    static func command(of plist: [String: Any]) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty { return args.joined(separator: " ") }
        return plist["Program"] as? String ?? ""
    }

    static func describeSchedule(_ plist: [String: Any]) -> String {
        if let interval = plist["StartInterval"] as? Int { return "Every \(describeInterval(interval))" }
        if let entry = plist["StartCalendarInterval"] as? [String: Int] { return describeCalendar(entry) }
        if let entries = plist["StartCalendarInterval"] as? [[String: Int]] {
            let shown = entries.prefix(maxCalendarEntries).map(describeCalendar).joined(separator: ", ")
            return entries.count > maxCalendarEntries ? "\(shown) +\(entries.count - maxCalendarEntries) more" : shown
        }
        if let keepAlive = plist["KeepAlive"], (keepAlive as? Bool) != false { return "Always running" }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { return "On file change" }
        if plist["RunAtLoad"] as? Bool == true { return "At login" }
        return "On demand"
    }

    static func describeInterval(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "\(seconds / 86_400) day\(seconds == 86_400 ? "" : "s")" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    static func describeCalendar(_ entry: [String: Int]) -> String {
        let time = entry["Hour"].map { String(format: "%02d:%02d", $0, entry["Minute"] ?? 0) }
        if let weekday = entry["Weekday"], weekdays.indices.contains(weekday) {
            return "\(weekdays[weekday]) \(time ?? "hourly")"
        }
        if let day = entry["Day"] { return "Day \(day) \(time ?? "hourly")" }
        if let time { return "Daily \(time)" }
        if let minute = entry["Minute"] { return String(format: "Hourly at :%02d", minute) }
        return "Every minute"
    }

    static func parseLaunchctlList(_ output: String) -> [String: LaunchctlStatus] {
        output.split(whereSeparator: \.isNewline).dropFirst().reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return }
            result[String(fields[2])] = LaunchctlStatus(pid: pid_t(fields[0]), lastExitStatus: Int(fields[1]))
        }
    }

    static func parseCrontab(_ output: String) -> [ScheduledJob] {
        output.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) == nil else { return nil }
            let fieldCount = line.hasPrefix("@") ? 1 : 5
            let fields = line.split(maxSplits: fieldCount, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == fieldCount + 1 else { return nil }
            let command = String(fields[fieldCount])
            return ScheduledJob(label: command, source: .cron, command: command,
                                schedule: fields.prefix(fieldCount).joined(separator: " "),
                                plistPath: nil, logPaths: [], isLoaded: true, pid: nil, lastExitStatus: nil, cronLine: raw)
        }
    }
}
