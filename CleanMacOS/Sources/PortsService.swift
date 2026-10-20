import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

enum CommandRunner {
    static func run(_ tool: String, _ args: [String], input: String? = nil) -> CommandResult {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
        }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: output, as: UTF8.self),
                             error: String(decoding: errorOutput, as: UTF8.self))
    }
}

struct PortsService: Sendable {
    func list() async -> [ListeningPort] {
        await Task.detached(priority: .utility) {
            let result = CommandRunner.run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcLn"])
            return Self.parse(result.output)
        }.value
    }

    func details(pid: pid_t) async -> ProcessDetails? {
        await Task.detached(priority: .utility) {
            guard var details = Self.parseDetails(
                CommandRunner.run("/bin/ps", ["-o", "etime=,%cpu=,rss=,ppid=,args=", "-p", "\(pid)"]).output
            ) else { return nil }
            let parent = CommandRunner.run("/bin/ps", ["-o", "comm=", "-p", "\(details.parentPID)"]).output
            details.parentName = URL(fileURLWithPath: parent.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
            details.directory = Self.parseDirectory(
                CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]).output
            )
            return details
        }.value
    }

    static func parseDetails(_ output: String) -> ProcessDetails? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count == 5, let cpu = Double(fields[1]), let rss = UInt64(fields[2]),
              let parentPID = pid_t(fields[3]) else { return nil }
        return ProcessDetails(elapsed: String(fields[0]), arguments: String(fields[4]),
                              cpuPercent: cpu, rssKilobytes: rss, parentPID: parentPID)
    }

    static func parseDirectory(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
            .flatMap { $0 == "/" ? nil : $0 }
    }

    static func parse(_ output: String) -> [ListeningPort] {
        var ports: [String: ListeningPort] = [:]
        var pid: pid_t = 0
        var command = ""
        var user = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "L": user = value
            case "n":
                guard let (address, port) = splitAddress(value) else { continue }
                let key = "\(pid):\(port)"
                let addresses = (ports[key]?.addresses ?? []) + [address]
                ports[key] = ListeningPort(port: port, pid: pid, command: command, user: user,
                                           addresses: Array(Set(addresses)).sorted())
            default: continue
            }
        }
        return ports.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func splitAddress(_ name: String) -> (String, Int)? {
        guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { return nil }
        return (String(name[..<colon]), port)
    }
}
