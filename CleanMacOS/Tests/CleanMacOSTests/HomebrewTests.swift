import Foundation
import Testing
@testable import CleanMacOS

struct HomebrewTests {
    private let info = """
    {"formulae":[
      {"name":"ffmpeg","full_name":"ffmpeg","tap":"homebrew/core","desc":"Play, record, convert, and stream audio and video",
       "homepage":"https://ffmpeg.org/","versions":{"stable":"9.0.2","head":"HEAD","bottle":true},"pinned":false,"outdated":true,
       "dependencies":["dav1d","lame","openssl@4","x265"],
       "installed":[{"version":"8.1.1","installed_on_request":true,"runtime_dependencies":[
         {"full_name":"dav1d","version":"1.5.3","declared_directly":true},
         {"full_name":"lame","version":"3.100","declared_directly":true},
         {"full_name":"ca-certificates","version":"2026-05-14","declared_directly":false},
         {"full_name":"openssl@3","version":"3.6.2","declared_directly":true},
         {"full_name":"x265","version":"4.2","declared_directly":true},
         {"full_name":"sdl2","version":"2.32.10","declared_directly":true},
         {"full_name":"json-c","version":"0.18","declared_directly":false}]}]},
      {"name":"dav1d","full_name":"dav1d","desc":"AV1 decoder","versions":{"stable":"1.5.4"},
       "installed":[{"version":"1.5.3","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"lame","full_name":"lame","desc":"MP3 encoder","versions":{"stable":"4.0"},"pinned":true,
       "installed":[{"version":"3.100","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"openssl@3","full_name":"openssl@3","desc":"TLS toolkit","versions":{"stable":"3.6.2"},
       "installed":[{"version":"3.6.2","installed_on_request":false,"runtime_dependencies":[{"full_name":"ca-certificates","declared_directly":true}]}]},
      {"name":"ca-certificates","full_name":"ca-certificates","desc":"Certificates","versions":{"stable":"2026-05-14"},
       "installed":[{"version":"2026-05-14","installed_on_request":false}]},
      {"name":"x265","full_name":"x265","desc":"H.265 encoder","versions":{"stable":"4.3"},
       "installed":[{"version":"4.2","installed_on_request":true,"runtime_dependencies":[{"full_name":"libvmaf","declared_directly":true}]}]},
      {"name":"libvmaf","full_name":"libvmaf","desc":"Video quality","versions":{"stable":"3.2.1"},
       "installed":[{"version":"3.1.0","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"sdl2-compat","full_name":"sdl2-compat","desc":"SDL2 on SDL3","aliases":["sdl2"],"oldnames":[],"versions":{"stable":"2.32.74"},
       "installed":[{"version":"2.32.10","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"json-c","full_name":"json-c","desc":"JSON parser","versions":{"stable":"0.18"},
       "installed":[{"version":"0.18","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"python@3.14","full_name":"python@3.14","desc":"Python","versions":{"stable":"3.14.1"},
       "installed":[{"version":"3.14.1","installed_on_request":false,"runtime_dependencies":[]}]},
      {"name":"libfoo","full_name":"someone/tools/libfoo","desc":"Orphan","versions":{"stable":"1.0"},
       "installed":[{"version":"1.0","installed_on_request":false,"runtime_dependencies":[{"full_name":"libbar","declared_directly":true}]}]},
      {"name":"libbar","full_name":"libbar","desc":"Orphan dependency","versions":{"stable":"2.0"},
       "installed":[{"version":"2.0","installed_on_request":false}]}],
     "casks":[
      {"token":"obs","full_token":"obs","name":["OBS"],"desc":"Open-source software for live streaming","homepage":"https://obsproject.com/",
       "version":"33.0.1","installed":"33.0.0","depends_on":{"macos":{">=":["13"]}},
       "artifacts":[{"uninstall":[{"quit":"com.obsproject.obs-studio","delete":"/Library/CoreMediaIO/Plug-Ins/DAL/obs-mac-virtualcam.plugin"}]},
                    {"app":["OBS.app"],"target":"/Applications/OBS.app"},
                    {"zap":[{"trash":["~/Library/Preferences/com.obsproject.obs-studio.plist","~/Library/Application Support/obs-studio"]}]}]},
      {"token":"gcloud-cli","name":["Google Cloud CLI"],"desc":null,"homepage":"https://cloud.google.com/cli/","version":"592.0.0",
       "installed":"592.0.0","depends_on":{"formula":["python@3.14"]},
       "artifacts":[{"binary":["google-cloud-sdk/bin/gcloud"],"target":"/opt/homebrew/bin/gcloud"},
                    {"installer":[{"script":{"executable":"install.sh","args":["--quiet"]}}]}]},
      {"token":"chromium","name":["Chromium"],"desc":"Web browser","version":"latest","installed":"latest",
       "artifacts":[{"app":["chrome-mac/Chromium.app",{"target":"Chromium Browser.app"}]},
                    {"zap":[{"trash":"~/Library/Saved Application State/org.chromium.Chromium.savedState"}]}]}]}
    """

    private func packages() throws -> [BrewPackage] {
        try #require(BrewJSON.packages(from: Data(info.utf8)))
    }

    @Test func parsesFormulaeFromInfoJSON() throws {
        let packages = try packages()
        let ffmpeg = try #require(packages.first { $0.name == "ffmpeg" })
        #expect(ffmpeg.kind == .formula)
        #expect(ffmpeg.installedVersion == "8.1.1")
        #expect(ffmpeg.latestVersion == "9.0.2")
        #expect(ffmpeg.isRequested)
        #expect(ffmpeg.dependencies == ["dav1d", "lame", "ca-certificates", "openssl@3", "x265", "sdl2", "json-c"])
        #expect(packages.first { $0.name == "sdl2-compat" }?.aliases == ["sdl2"])
        #expect(ffmpeg.homepage == URL(string: "https://ffmpeg.org/"))
        #expect(packages.first { $0.name == "lame" }?.isPinned == true)
        #expect(packages.first { $0.name == "dav1d" }?.isRequested == false)
        #expect(packages.first { $0.name == "ca-certificates" }?.dependencies == [])
        #expect(packages.first { $0.name == "libfoo" }?.fullName == "someone/tools/libfoo")
        #expect(packages.first { $0.name == "libfoo" }?.id == "formula:someone/tools/libfoo")
    }

    @Test func parsesCaskAppsBundleIDsAndFormulaDependencies() throws {
        let packages = try packages()
        let obs = try #require(packages.first { $0.name == "obs" })
        #expect(obs.kind == .cask)
        #expect(obs.installedVersion == "33.0.0" && obs.latestVersion == "33.0.1")
        #expect(obs.apps == ["OBS.app"])
        #expect(Set(obs.bundleIDs) == ["com.obsproject.obs-studio"])
        let gcloud = try #require(packages.first { $0.name == "gcloud-cli" })
        #expect(gcloud.summary == "Google Cloud CLI")
        #expect(gcloud.dependencies == ["python@3.14"])
        #expect(gcloud.apps.isEmpty && gcloud.bundleIDs.isEmpty)
        let chromium = try #require(packages.first { $0.name == "chromium" })
        #expect(chromium.apps == ["Chromium Browser.app"])
        #expect(chromium.bundleIDs == ["org.chromium.Chromium"])
        #expect(BrewJSON.packages(from: Data("Error: no JSON here".utf8)) == nil)
    }

    @Test func readsBundleIDsOnlyFromPathsThatLookLikeOne() {
        #expect(BrewJSON.bundleID(fromPath: "~/Library/Preferences/com.jgraph.drawio.desktop.plist") == "com.jgraph.drawio.desktop")
        #expect(BrewJSON.bundleID(fromPath: "~/Library/Containers/com.example.App") == "com.example.App")
        #expect(BrewJSON.bundleID(fromPath: "~/Library/Preferences/ByHost/com.example.App.ShipIt.*.plist") == nil)
        #expect(BrewJSON.bundleID(fromPath: "~/Library/Application Support/draw.io") == nil)
        #expect(BrewJSON.bundleID(fromPath: "~/Library/Application Support/Some App.v2.data") == nil)
    }

    @Test func groupsDependenciesUnderThePackagesThatNeedThem() throws {
        let tree = BrewTree(try packages())
        let groups = Dictionary(uniqueKeysWithValues: tree.groups.map { ($0.package.name, $0.dependencies.map(\.name)) })
        #expect(groups["ffmpeg"] == ["ca-certificates", "dav1d", "json-c", "lame", "libvmaf", "openssl@3", "sdl2-compat"])
        #expect(groups["x265"] == ["libvmaf"])
        #expect(groups["gcloud-cli"] == ["python@3.14"])
        #expect(groups["obs"] == [])
        #expect(groups["dav1d"] == nil)
        #expect(tree.leftovers.map(\.name) == ["libfoo", "libbar"])
    }

    @Test func readsOutdatedPackagesEvenWithNoiseAroundTheJSON() throws {
        let output = """
        Warning: {not json} Treating ffmpeg as a formula.
        ==> Auto-updated Homebrew!
        {"formulae":[{"name":"ffmpeg","installed_versions":["8.1.1"],"current_version":"9.0.2_1","pinned":false,"pinned_version":null},
                     {"name":"we{ird}","installed_versions":["3.100"],"current_version":"4.0","pinned":true,"pinned_version":"3.100"}],
         "casks":[{"name":"codex","installed_versions":["0.166.0"],"current_version":"0.167.0","pinned":false,"pinned_version":null}]}
        Error: something else happened {"a": "}"}
        """
        let outdated = try #require(BrewJSON.outdated(from: output))
        #expect(outdated.map(\.key) == ["formula:ffmpeg", "formula:we{ird}", "cask:codex"])
        #expect(outdated[0].installedVersions == ["8.1.1"])
        #expect(outdated[0].currentVersion == "9.0.2_1")
        #expect(outdated[1].isPinned && !outdated[2].isPinned)
        #expect(BrewJSON.outdated(from: "Error: brew is not happy {}") == nil)
        #expect(BrewJSON.outdated(from: #"{"formulae":[],"casks":[]}"#)?.isEmpty == true)
    }

    @Test func keysOutdatedCasksByTheirShortToken() {
        let items = [BrewOutdated(kind: .cask, name: "someone/apps/widget", installedVersions: ["1"], currentVersion: "2", isPinned: false),
                     BrewOutdated(kind: .cask, name: "codex", installedVersions: ["0.1"], currentVersion: "0.2", isPinned: false)]
        #expect(BrewOutdated.byToken(items).keys.sorted() == ["codex", "widget"])
    }

    @Test func parsesSearchOutputAndRanksIt() {
        let output = "==> Formulae\nffmpeg\nffmpeg@6 ✔\u{FE0E}\nhashicorp/tap/terraform\n\nIf you meant \"ffmpeg\" specifically:\nError:\nIt was migrated.\n"
        #expect(BrewJSON.searchResults(output) == ["ffmpeg", "ffmpeg@6", "hashicorp/tap/terraform"])
        let hits = [BrewSearchHit(kind: .formula, name: "ffmpeg@6"), BrewSearchHit(kind: .cask, name: "ffmpeg-gui"), BrewSearchHit(kind: .formula, name: "ffmpeg")]
        let ranked = BrewSearchHit.ranked(hits, query: "FFmpeg", popularity: ["formula:ffmpeg@6": 10, "cask:ffmpeg-gui": 500])
        #expect(ranked.map(\.name) == ["ffmpeg", "ffmpeg-gui", "ffmpeg@6"])
    }

    @Test func sumsThirtyDayInstallAnalytics() throws {
        let formulae = """
        {"category":"install","total_items":3,"items":[{"number":1,"formula":"openssl@3","count":"1,234,567","percent":"5.1"},
         {"number":2,"formula":"node --HEAD","count":"12","percent":"0"},{"number":3,"formula":"node","count":"3,000","percent":"1"}]}
        """
        #expect(try #require(BrewJSON.popularity(from: Data(formulae.utf8))) == ["openssl@3": 1_234_567, "node": 3_012])
        let casks = #"{"category":"cask_install","items":[{"number":1,"cask":"google-chrome","count":42,"percent":"4.5"}]}"#
        #expect(BrewJSON.popularity(from: Data(casks.utf8)) == ["google-chrome": 42])
        #expect(BrewJSON.popularity(from: Data("<html>".utf8)) == nil)
    }

    @Test func followsPhasesAndPercentsInLiveOutput() {
        var log = BrewLog()
        log.append("==> Fetching ffmpeg\n==> Downloading https://ghcr.io/ffmpeg\n###      12.5%")
        #expect(log.phase == "Downloading https://ghcr.io/ffmpeg")
        #expect(log.percent == 12.5)
        log.append("\r########################   64.0%\r#####")
        #expect(log.percent == 64)
        #expect(log.text.hasSuffix("==> Downloading https://ghcr.io/ffmpeg\n#####"))
        log.append("###### 100.0%\n==> Pouring ffmpeg--9.0.2.arm64_tahoe.bottle.tar.gz\n")
        #expect(log.phase == "Pouring ffmpeg--9.0.2.arm64_tahoe.bottle.tar.gz")
        #expect(log.percent == nil)
        #expect(log.lines == ["==> Fetching ffmpeg", "==> Downloading https://ghcr.io/ffmpeg", "########### 100.0%",
                             "==> Pouring ffmpeg--9.0.2.arm64_tahoe.bottle.tar.gz"])
    }

    @Test func overwritesCarriageReturnsStripsColorsAndCapsTheLog() {
        var log = BrewLog()
        log.append("abc\r")
        log.append("de\n")
        log.append("\u{1B}[1mbold\u{1B}[0m\n")
        #expect(log.lines == ["de", "bold"])
        for number in 0..<(BrewLog.lineLimit + 5) { log.append("line \(number)\n") }
        #expect(log.lines.count == BrewLog.lineLimit)
        #expect(log.lines.first == "line 5")
        #expect(BrewLog.percent(in: "Downloading 250% faster") == nil)
    }

    @Test func spotsUntrustedTapsAndPasswordPrompts() {
        let refusal = "Error: Refusing to load formula someone/tools/widget from untrusted tap someone/tools.\n"
            + "Run `brew trust --formula someone/tools/widget` or `brew trust someone/tools` to trust it."
        #expect(BrewSignals.untrustedTap(refusal) == "someone/tools")
        #expect(BrewSignals.untrustedTap("Warning: Skipping my.org/casks because it is not trusted. Run `brew trust my.org/casks` to trust it.")
                == "my.org/casks")
        #expect(BrewSignals.untrustedTap("==> Pouring x") == nil)
        #expect(BrewSignals.needsPassword("==> Running installer for zoom with sudo; the password may be necessary.\n"
                                          + "sudo: a terminal is required to read the password; either use the -S option"))
        #expect(!BrewSignals.needsPassword("==> Upgrading 1 outdated package"))
    }

    @Test func offersFollowUpsOnlyAfterAFailure() {
        var job = BrewJob(action: .install(.cask, "zoom"), commandLine: "/opt/homebrew/bin/brew install --cask zoom")
        job.log.append("Refusing to load cask a/b/zoom from untrusted tap a/b.\nsudo: a terminal is required to read the password\n")
        #expect(job.isRunning && !job.needsTerminal && job.untrustedTap == nil && job.statusText == "Running…")
        job.status = 1
        #expect(job.needsTerminal && job.untrustedTap == "a/b" && job.statusText == "Failed with exit code 1")
        job.isCancelling = true
        #expect(!job.needsTerminal && job.untrustedTap == nil && job.statusText == "Cancelled")
        var done = BrewJob(action: .update, commandLine: "brew update")
        done.status = 0
        #expect(done.succeeded && done.statusText == "Done" && !done.needsTerminal)
    }

    @Test func buildsEveryBrewCommand() {
        #expect(BrewAction.install(.cask, "visual-studio-code").arguments == ["install", "--cask", "visual-studio-code"])
        #expect(BrewAction.uninstall(.formula, "ffmpeg").arguments == ["uninstall", "--formula", "ffmpeg"])
        #expect(BrewAction.upgrade(.cask, "obs").arguments == ["upgrade", "--cask", "obs"])
        #expect(BrewAction.upgradeAll.arguments == ["upgrade"])
        #expect(BrewAction.update.arguments == ["update"])
        #expect(BrewAction.trustTap("someone/tools").arguments == ["trust", "--tap", "someone/tools"])
        #expect(BrewAction.upgradeApps(["obs", "drawio"]).arguments == ["upgrade", "--cask", "--greedy", "obs", "drawio"])
        #expect(BrewAction.upgradeApps(["obs", "drawio"]).title == "Upgrade 2 apps")
        #expect(BrewAction.upgradeApps(["obs"]).title == "Upgrade obs")
        #expect(BrewAction.install(.formula, "it's").commandLine(brew: "/opt/homebrew/bin/brew") == "/opt/homebrew/bin/brew install --formula 'it'\\''s'")
        #expect(BrewAction.uninstall(.formula, "x").isDestructive && !BrewAction.update.isDestructive)
    }

    @Test func prefersAppleSiliconHomebrewThenIntel() {
        #expect(BrewClient.locate { _ in true }?.path == "/opt/homebrew/bin/brew")
        #expect(BrewClient.locate { $0 == "/usr/local/bin/brew" }?.path == "/usr/local/bin/brew")
        #expect(BrewClient.locate { _ in false }?.path == nil)
    }

    @Test func installerScriptRunsTheOfficialCommandAndRemovesItself() {
        #expect(TerminalScript.contents(for: TerminalScript.homebrewInstaller)
                == "#!/bin/bash\nrm -f \"$0\"\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n")
    }

    @Test func filtersByKind() {
        #expect(BrewFilter.all.includes(.cask) && BrewFilter.all.includes(.formula))
        #expect(BrewFilter.casks.includes(.cask) && !BrewFilter.casks.includes(.formula))
        #expect(BrewFilter.formulae.includes(.formula) && !BrewFilter.formulae.includes(.cask))
    }

    @Test func cacheServesOnlyFreshFiles() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brew-cache-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DownloadCache(folder: folder)
        #expect(cache.cached("a.json", maxAge: 60) == nil)
        cache.store(Data("{}".utf8), as: "a.json")
        #expect(cache.cached("a.json", maxAge: 60) == Data("{}".utf8))
        #expect(cache.cached("a.json", maxAge: 60, now: Date().addingTimeInterval(120)) == nil)
    }
}
