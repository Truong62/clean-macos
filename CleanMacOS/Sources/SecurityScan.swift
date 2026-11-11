import Foundation
import Security

enum SecurityProblem: String, CaseIterable, Sendable {
    case invalidSignature = "Invalid signature"
    case sharedFolder = "Runs from a temporary or shared folder"
    case hiddenFile = "Hidden file"
    case unsigned = "Not signed"
    case unidentified = "Not from an identified developer"
    case missing = "File is missing"
}

struct SecurityFinding: Identifiable, Hashable, Sendable {
    let name: String
    let kind: String
    let path: String
    let problems: [SecurityProblem]

    var id: String { "\(kind):\(name):\(path)" }
}

struct SecurityProtection: Identifiable, Equatable, Sendable {
    let name: String
    let isOn: Bool?
    let fix: String

    var id: String { name }
    var stateLabel: String { isOn.map { $0 ? "On" : "Off" } ?? "Unknown" }
}

struct SecurityReport: Equatable, Sendable {
    let protections: [SecurityProtection]
    let findings: [SecurityFinding]

    var issueCount: Int { findings.count + protections.filter { $0.isOn == false }.count }
}

struct ProtectionCheck: Sendable {
    let name: String
    let tool: String
    let arguments: [String]
    let onMarkers: [String]
    let fix: String

    func state(_ output: String) -> Bool? {
        output.isEmpty ? nil : onMarkers.contains { output.contains($0) }
    }
}

enum SecurityScan {
    typealias ScanTarget = (name: String, kind: String, arguments: [String])

    static let checks = [
        ProtectionCheck(name: "System Integrity Protection", tool: "/usr/bin/csrutil", arguments: ["status"],
                        onMarkers: ["status: enabled."], fix: "Start up in macOS Recovery and run csrutil enable in Terminal."),
        ProtectionCheck(name: "Gatekeeper", tool: "/usr/sbin/spctl", arguments: ["--status"],
                        onMarkers: ["assessments enabled"], fix: "Run sudo spctl --global-enable in Terminal."),
        ProtectionCheck(name: "FileVault", tool: "/usr/bin/fdesetup", arguments: ["status"],
                        onMarkers: ["FileVault is On"],
                        fix: "System Settings › Privacy & Security › FileVault. Leave it off if you use Power Recovery, which has to log in on its own."),
        ProtectionCheck(name: "Firewall", tool: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"],
                        onMarkers: ["State = 1", "State = 2"], fix: "System Settings › Network › Firewall."),
    ]
    static let securityUpdatesFix = "System Settings › General › Software Update › Automatic Updates › Install Security Responses and system files."
    private static let softwareUpdatePreferences = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    private static let sharedFolderPattern = #"(^|[\s'"=:;|&(])(/private)?/(tmp|var/tmp|var/folders|Users/Shared)/"#
    private static let identifiedDeveloper = "anchor apple generic"

    static func run(jobs: [ScheduledJob], loginItems: [LoginItem], ports: [ListeningPort]) async -> SecurityReport {
        await Task.detached(priority: .utility) {
            SecurityReport(protections: protections(),
                           findings: findings(jobs: jobs, loginItems: loginItems, ports: ports, ownPath: Bundle.main.bundlePath,
                                              executablePath: executablePath, signature: signatureProblem))
        }.value
    }

    static func protections() -> [SecurityProtection] {
        let updates = NSDictionary(contentsOfFile: softwareUpdatePreferences) as? [String: Any] ?? [:]
        return checks.map { SecurityProtection(name: $0.name, isOn: $0.state(CommandRunner.run($0.tool, $0.arguments).output), fix: $0.fix) }
            + [SecurityProtection(name: "Automatic security updates", isOn: installsSecurityUpdates(updates), fix: securityUpdatesFix)]
    }

    static func installsSecurityUpdates(_ preferences: [String: Any]) -> Bool {
        ["ConfigDataInstall", "CriticalUpdateInstall"].allSatisfy { preferences[$0] as? Bool ?? true }
    }

    static func findings(jobs: [ScheduledJob], loginItems: [LoginItem], ports: [ListeningPort], ownPath: String,
                         executablePath: (pid_t) -> String?, signature: (String) -> SecurityProblem?) -> [SecurityFinding] {
        let jobTargets: [ScanTarget] = jobs.map { ($0.label, $0.source.label, $0.arguments) }
        let itemTargets: [ScanTarget] = loginItems.filter(\.isEnabled).compactMap { item in
            item.path.map { (item.name, "Login Item", [$0]) }
        }
        let portTargets: [ScanTarget] = Dictionary(grouping: ports.filter { !$0.isLocalOnly }, by: \.pid).compactMap { pid, held in
            executablePath(pid).map { (held[0].command, portsLabel(held), [$0]) }
        }
        return (jobTargets + itemTargets + portTargets).compactMap { target in
            guard let path = target.arguments.first, path != ownPath, !path.hasPrefix(ownPath + "/") else { return nil }
            let problems = problems(path: path, arguments: target.arguments, signature: signature)
            return problems.isEmpty ? nil : SecurityFinding(name: target.name, kind: target.kind, path: path, problems: problems)
        }
        .sorted { (rank($0), $0.name.lowercased(), $0.id) < (rank($1), $1.name.lowercased(), $1.id) }
    }

    static func usesSharedFolder(_ text: String) -> Bool {
        text.range(of: sharedFolderPattern, options: .regularExpression) != nil
    }

    static func signatureProblem(_ path: String) -> SecurityProblem? {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(identifiedDeveloper as CFString, [], &requirement) == errSecSuccess else { return nil }
        switch SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) {
        case errSecSuccess: return nil
        case errSecCSReqFailed: return .unidentified
        case errSecCSUnsigned: return isScript(path) ? nil : .unsigned
        default: return .invalidSignature
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    private static func problems(path: String, arguments: [String], signature: (String) -> SecurityProblem?) -> [SecurityProblem] {
        let found: [SecurityProblem?] = [
            signature(path),
            URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") ? .hiddenFile : nil,
            arguments.contains(where: usesSharedFolder) ? .sharedFolder : nil,
        ]
        return SecurityProblem.allCases.filter { found.contains($0) }
    }

    private static func isScript(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 2) == Data("#!".utf8)
    }

    private static func portsLabel(_ ports: [ListeningPort]) -> String {
        let numbers = ports.map(\.port).sorted()
        return (numbers.count == 1 ? "Port " : "Ports ") + numbers.map(String.init).joined(separator: ", ")
    }

    private static func rank(_ finding: SecurityFinding) -> Int {
        finding.problems.first.flatMap { SecurityProblem.allCases.firstIndex(of: $0) } ?? 0
    }
}
