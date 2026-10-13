import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

enum CommandRunner {
    static func run(_ tool: String, _ args: [String]) -> CommandResult {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
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
