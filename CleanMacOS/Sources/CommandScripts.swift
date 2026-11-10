import Foundation
import Darwin

struct CommandScript: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var runOnBareName = false
    var directShortcut = false
    var shortcutEnabled = false
    var hidden = false

    var normalized: CommandScript? {
        var result = self
        result.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty { result.name = URL(fileURLWithPath: result.path).deletingPathExtension().lastPathComponent }
        return result.name.isEmpty || result.path.isEmpty ? nil : result
    }

    func argument(in query: String) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let names = name.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !names.isEmpty, words.count >= names.count,
              zip(words, names).allSatisfy({ Self.fold($0) == Self.fold($1) }) else { return nil }
        let argument = words.dropFirst(names.count).joined(separator: " ")
        return argument.isEmpty && !runOnBareName ? nil : argument
    }

    static func match(_ query: String, scripts: [CommandScript]) -> (script: CommandScript, argument: String)? {
        scripts.compactMap(\.normalized).filter { !$0.hidden }.sorted { $0.name.count > $1.name.count }.compactMap { script in
            script.argument(in: query).map { (script, $0) }
        }.first
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct ScriptRunKey: Hashable {
    let id: UUID
    let path: String
    let argument: String
}

struct ScriptRunState {
    private(set) var opening = 0
    private(set) var results: [ScriptRunKey: ScriptResult] = [:]
    private(set) var running: Set<ScriptRunKey> = []

    mutating func open() { opening += 1; results = [:] }
    mutating func begin(_ key: ScriptRunKey, direct: Bool = false) -> Bool {
        guard direct || results[key] == nil else { return false }
        return running.insert(key).inserted
    }
    mutating func finish(_ key: ScriptRunKey, result: ScriptResult, opening: Int?) {
        running.remove(key)
        if opening == self.opening { results[key] = result }
    }
}

struct ScriptResult: Equatable {
    let output: String
    let status: Int32
    let timedOut: Bool

    var failed: Bool { status != 0 || timedOut }
    var rowText: String? { output.isEmpty ? (failed ? (timedOut ? "Script timed out" : "Script failed (\(status))") : nil) : output }
}

struct ScriptOutputBuffer {
    static let limit = 64 * 1024
    private(set) var data = Data()

    mutating func append(_ chunk: Data) {
        data.append(chunk.prefix(max(0, Self.limit - data.count)))
    }

    var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum CommandScriptRunner {
    static func run(path: String, argument: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        process.arguments = [argument]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ScriptResult(output: error.localizedDescription, status: -1, timedOut: false) }
        try? pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var output = ScriptOutputBuffer()
        let start = ProcessInfo.processInfo.systemUptime
        var timedOut = false
        var killed = false
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 { output.append(Data(bytes.prefix(count))) }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if process.isRunning && elapsed >= 5 && !timedOut {
                timedOut = true
                process.terminate()
            }
            if process.isRunning && elapsed >= 5.5 && !killed {
                killed = true
                kill(process.processIdentifier, SIGKILL)
            }
            if !process.isRunning && count <= 0 { break }
            if elapsed >= 6 { break }
            if count <= 0 {
                var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&pollFD, 1, 10)
            }
        }
        try? pipe.fileHandleForReading.close()
        return ScriptResult(output: output.text, status: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut)
    }
}
