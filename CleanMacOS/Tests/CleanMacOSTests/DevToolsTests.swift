import Foundation
import Testing
@testable import CleanMacOS

struct DevToolsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("devtools-\(UUID())", isDirectory: true)

    private func make(_ relative: String, contents: String? = nil) throws {
        let url = root.appendingPathComponent(relative)
        if let contents {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @Test func findsVersionManagerAndInstallerRuntimes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("home/.nvm/versions/node/v20.11.1/bin/node", contents: "")
        try make("home/.nvm/versions/node/v22.22.0/bin/node", contents: "")
        try make("home/.pyenv/versions/3.12.4/bin/python3", contents: "")
        try make("home/.pyenv/versions/broken")
        try make("usr/local/go/VERSION", contents: "go1.24.2\ntime 2025-03-26T19:09:39Z\n")
        try make("usr/local/go/bin/go", contents: "")
        try make("Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/release", contents: "IMPLEMENTOR=\"Eclipse\"\nJAVA_VERSION=\"21.0.4\"\n")
        try make("Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java", contents: "")

        let tools = RuntimeScanner(home: root.appendingPathComponent("home"), systemRoot: root).scan()
        #expect(tools.map { "\($0.name) \($0.version) \($0.source)" } == [
            "Go 1.24.2 Go installer", "Java 21.0.4 JDK", "Node.js 22.22.0 nvm", "Node.js 20.11.1 nvm", "Python 3.12.4 pyenv",
        ])
        #expect(tools.allSatisfy { $0.kind == .runtime })
        #expect(tools.first { $0.version == "22.22.0" }?.removal == .trash(root.appendingPathComponent("home/.nvm/versions/node/v22.22.0").path))
    }

    @Test func parsesHomebrewFormulaeCasksAndRuntimes() throws {
        let json = """
        {"formulae":[
          {"name":"node","desc":"JS runtime","homepage":"https://nodejs.org","versions":{"stable":"25.1.0"},
           "installed":[{"version":"25.0.0","installed_on_request":true}]},
          {"name":"python@3.13","desc":"Python","homepage":"https://python.org","versions":{"stable":"3.13.9"},
           "installed":[{"version":"3.13.9","installed_on_request":false}]},
          {"name":"fmt","desc":"Formatting","homepage":"https://fmt.dev","versions":{"stable":"12.2.0"},
           "installed":[{"version":"12.2.0","installed_on_request":false}]}],
         "casks":[{"token":"chromium","desc":"Browser","homepage":"https://chromium.org","installed":"latest","version":"latest"}]}
        """
        let brew = try HomebrewInventory.parse(Data(json.utf8), prefix: "/opt/homebrew")
        #expect(brew.map(\.name) == ["chromium", "fmt", "node", "python@3.13"])
        let node = try #require(brew.first { $0.name == "node" })
        #expect(node.path == "/opt/homebrew/Cellar/node/25.0.0")
        #expect(node.note == "Update available: 25.1.0")
        #expect(node.removal == .command(path: "/opt/homebrew/bin/brew", arguments: ["uninstall", "node"]))
        #expect(brew.first { $0.name == "fmt" }?.isDependency == true)
        #expect(brew.first { $0.name == "chromium" }?.removal == .command(path: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--cask", "chromium"]))

        #expect(node.updateCommand == ShellCommand(path: "/opt/homebrew/bin/brew", arguments: ["upgrade", "node"]))
        #expect(brew.first { $0.name == "fmt" }?.updateCommand == nil)

        let runtimes = HomebrewInventory.runtimes(from: brew)
        #expect(runtimes.first?.updateCommand == node.updateCommand)
        #expect(runtimes.map { "\($0.name) \($0.version)" } == ["Node.js 25.0.0", "Python 3.13.9"])
        #expect(runtimes.allSatisfy { $0.kind == .runtime && $0.source == "Homebrew" })
    }

    @Test func outdatedCaskGetsGreedyUpgrade() throws {
        let json = """
        {"formulae":[],"casks":[
          {"token":"ngrok","installed":"3.22.1,abc,a","version":"3.39.11,def,a"},
          {"token":"gcloud-cli","installed":"588.0.0","version":"588.0.0"},
          {"token":"chromium","installed":"latest","version":"latest"}]}
        """
        let casks = try HomebrewInventory.parse(Data(json.utf8), prefix: "/opt/homebrew")
        let ngrok = try #require(casks.first { $0.name == "ngrok" })
        #expect(ngrok.version == "3.22.1")
        #expect(ngrok.note == "Update available: 3.39.11")
        #expect(ngrok.updateCommand == ShellCommand(path: "/opt/homebrew/bin/brew", arguments: ["upgrade", "--cask", "--greedy", "ngrok"]))
        #expect(casks.filter { $0.name != "ngrok" }.allSatisfy { $0.updateCommand == nil && $0.note == nil })
    }

    @Test func appliesNpmOutdatedToGlobalPackages() {
        let base = "/home/.nvm/versions/node/v22.22.0"
        let json = """
        {"typescript":{"current":"5.6.2","latest":"5.9.0","location":"\(base)/lib/node_modules/typescript"},
         "npm":{"current":"10.9.4","latest":"11.21.0","location":"\(base)/lib/node_modules/npm"}}
        """
        let latest = GlobalPackageScanner.parseNpmOutdated(json)
        #expect(latest == ["\(base)/lib/node_modules/typescript": "5.9.0", "\(base)/lib/node_modules/npm": "11.21.0"])
        #expect(GlobalPackageScanner.npmBinDirectory(forPackageAt: "\(base)/lib/node_modules/@scope/cli") == "\(base)/bin")
        #expect(GlobalPackageScanner.npmBinDirectory(forPackageAt: "/home/.bun/install/global/node_modules/x") == nil)

        let tools = [
            DevTool(name: "typescript", version: "5.6.2", source: "npm", path: "\(base)/lib/node_modules/typescript", kind: .package, removal: .unavailable("")),
            DevTool(name: "npm", version: "10.9.4", source: "npm", path: "\(base)/lib/node_modules/npm", kind: .package, removal: .unavailable("")),
            DevTool(name: "eslint", version: "9.0.0", source: "npm", path: "\(base)/lib/node_modules/eslint", kind: .package, removal: .unavailable("")),
        ]
        let updated = GlobalPackageScanner.applyingNpmUpdates(tools, latestByLocation: latest)
        #expect(updated[0].note == "Update available: 5.9.0")
        #expect(updated[0].updateCommand == ShellCommand(path: "/usr/bin/env",
                                                         arguments: ["PATH=\(base)/bin:/usr/bin:/bin", "\(base)/bin/npm", "install", "-g", "typescript@latest"]))
        #expect(updated[1].updateCommand != nil)
        #expect(updated[2].updateCommand == nil && updated[2].note == nil)
    }

    @Test func listsGlobalNodePackagesIncludingScopedOnes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("lib/node_modules/typescript/package.json", contents: #"{"name":"typescript","version":"5.6.2"}"#)
        try make("lib/node_modules/@shopify/cli/package.json", contents: #"{"name":"@shopify/cli","version":"3.70.0"}"#)
        try make("lib/node_modules/npm/package.json", contents: #"{"name":"npm","version":"10.9.0"}"#)
        let packages = GlobalPackageScanner.nodePackages(in: root.appendingPathComponent("lib/node_modules"),
                                                         source: "npm · Node.js 22 (nvm)", binDirectory: "/x/bin")
        #expect(packages.map { "\($0.name)@\($0.version)" } == ["@shopify/cli@3.70.0", "npm@10.9.0", "typescript@5.6.2"])
        #expect(packages.first { $0.name == "typescript" }?.removal
                == .command(path: "/usr/bin/env", arguments: ["PATH=/x/bin:/usr/bin:/bin", "/x/bin/npm", "uninstall", "-g", "typescript"]))
        #expect(packages.first { $0.name == "npm" }?.removal == .unavailable("Bundled with Node.js"))
    }

    @Test func dropsRuntimeLinkedIntoAnotherInstall() {
        let jdk = DevTool(name: "Java", version: "17", source: "JDK", path: "/Library/Java/JavaVirtualMachines/openjdk-17.jdk",
                          kind: .runtime, removal: .unavailable(""))
        let brew = DevTool(name: "Java", version: "17", source: "Homebrew", path: "/opt/homebrew/Cellar/openjdk@17/17.0.15",
                           kind: .runtime, removal: .unavailable(""))
        let links = ["/Library/Java/JavaVirtualMachines/openjdk-17.jdk": "/opt/homebrew/Cellar/openjdk@17/17.0.15/libexec/openjdk.jdk"]
        let kept = RuntimeScanner.removingLinkedDuplicates([jdk, brew], resolve: { links[$0] ?? $0 })
        #expect(kept.map(\.source) == ["Homebrew"])
    }

    @Test func marksTheRuntimeTheLoginShellUses() {
        let output = "Last login: today\n@@node=/home/.nvm/versions/node/v22.22.0/bin/node\n@@python3=\n@@go=/usr/local/go/bin/go\n"
        let commands = RuntimeScanner.parseShellProbe(output)
        #expect(commands == ["node": "/home/.nvm/versions/node/v22.22.0/bin/node", "go": "/usr/local/go/bin/go"])
        let tools = [
            DevTool(name: "Node.js", version: "22.22.0", source: "nvm", path: "/home/.nvm/versions/node/v22.22.0", kind: .runtime, removal: .unavailable("")),
            DevTool(name: "Node.js", version: "20.0.0", source: "nvm", path: "/home/.nvm/versions/node/v20.0.0", kind: .runtime, removal: .unavailable("")),
        ]
        let marked = RuntimeScanner.markActive(tools, commandPaths: Array(commands.values), resolve: { $0 })
        #expect(marked.map(\.isActive) == [true, false])
    }
}
