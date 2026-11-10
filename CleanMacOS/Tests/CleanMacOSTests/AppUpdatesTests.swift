import Foundation
import Testing
@testable import CleanMacOS

struct AppUpdatesTests {
    private let appcast = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>4.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:version>400</sparkle:version>
          <sparkle:shortVersionString>4.0b1</sparkle:shortVersionString>
          <enclosure url="https://example.com/4.0b1.zip" length="1"/>
        </item>
        <item>
          <title>3.5 for a future macOS</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/3.5.zip" sparkle:version="350" sparkle:shortVersionString="3.5" length="1"/>
        </item>
        <item>
          <title>3.2</title>
          <description><![CDATA[<ul><li>Faster</li></ul>]]></description>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/3.2.zip" sparkle:version="320" sparkle:shortVersionString="3.2" length="1"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/3.2-delta.zip" sparkle:version="900" sparkle:deltaFrom="310" length="1"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>Windows build</title>
          <enclosure url="https://example.com/win.exe" sparkle:os="windows" sparkle:version="999" length="1"/>
        </item>
        <item>
          <title>3.1</title>
          <sparkle:version>310</sparkle:version>
          <sparkle:shortVersionString>3.1</sparkle:shortVersionString>
          <enclosure url="https://example.com/3.1.zip" length="1"/>
        </item>
      </channel>
    </rss>
    """.utf8)

    private func app(_ bundleID: String, _ path: String, version: String = "1.0", build: String? = nil, feed: String? = nil,
                     isAppStore: Bool = false, electron: String? = nil) -> AppBundle {
        AppBundle(path: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, bundleID: bundleID, version: version,
                  build: build ?? version, feed: feed, isAppStore: isAppStore, electronConfig: electron)
    }

    private func cask(_ token: String, apps: [String], version: String = "1.0", homepage: String? = nil) -> BrewPackage {
        var cask = BrewPackage(kind: .cask, name: token)
        cask.apps = apps
        cask.latestVersion = version
        cask.homepage = homepage.flatMap(URL.init(string:))
        return cask
    }

    private func update(_ name: String, _ latest: String, action: AppUpdateAction = .openApp) -> AppUpdate {
        AppUpdate(app: app("com.example.\(name.lowercased())", "/Applications/\(name).app"), installed: "1.0", latest: latest, source: .sparkle,
                  action: action)
    }

    @Test func comparesVersionsTheWayPeopleReadThem() {
        #expect(AppVersion.compare("1.10", "1.9") == .orderedDescending)
        #expect(AppVersion.compare("1.0", "1.0.0") == .orderedSame)
        #expect(AppVersion.compare("1.0.1", "1.0") == .orderedDescending)
        #expect(AppVersion.compare("2.0b1", "2.0") == .orderedAscending)
        #expect(AppVersion.compare("2.0rc1", "2.0b3") == .orderedDescending)
        #expect(AppVersion.compare("v1.2.3", "1.2.3") == .orderedSame)
        #expect(AppVersion.compare("9.0.2_1", "9.0.2") == .orderedDescending)
        #expect(AppVersion.compare("1.2.3 (456)", "1.2.4") == .orderedAscending)
        #expect(AppVersion.compare("12345678901234567890", "12345678901234567891") == .orderedAscending)
        #expect(AppVersion.compare("010", "9") == .orderedDescending)
        #expect(AppVersion.isNewer("2026.11", than: "2026.9.30"))
        #expect(!AppVersion.isNewer("1.0", than: "1.0"))
        #expect(AppVersion.caskVersion("3.39.13,msmi2kd3cjc,a") == "3.39.13")
        #expect(AppVersion.caskVersion("latest") == "latest")
        #expect(AppVersion.label("3.2", build: "319", against: "3.2") == "3.2 (319)")
        #expect(AppVersion.label("3.3", build: "330", against: "3.2") == "3.3")
        #expect(AppVersion.installed("16.89", build: "16.89.24091630", matching: "16.89.24091630") == "16.89.24091630")
        #expect(AppVersion.installed("2.1", build: "1234", matching: "2.1.5") == "2.1")
        #expect(AppVersion.installed("2.1", build: "2.1.0.7", matching: "2.2") == "2.1")
    }

    @Test func readsAppBundlesFromApplicationFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-updates-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, in folder: URL, info: [String: Any], receipt: Bool = false, electron: String? = nil) throws {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            if receipt {
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
                try Data("r".utf8).write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
            }
            if let electron { try electron.write(to: contents.appendingPathComponent("Resources/app-update.yml"), atomically: true, encoding: .utf8) }
        }
        try make("Sparkly", in: root, info: ["CFBundleIdentifier": "com.example.sparkly", "CFBundleShortVersionString": "2.1", "CFBundleVersion": "210",
                                              "SUFeedURL": "https://example.com/appcast.xml"])
        try make("Store", in: root.appendingPathComponent("Utilities"), info: ["CFBundleIdentifier": "com.example.store", "CFBundleVersion": 7], receipt: true)
        try make("Broken", in: root, info: ["CFBundleName": "Broken"])
        try make("Rocket", in: root, info: ["CFBundleIdentifier": "com.example.rocket", "CFBundleShortVersionString": " 4.1.9 "],
                 electron: "provider: generic\nurl: https://updates.example.com/rocket\n")
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let apps = AppScanner.bundles(in: root).compactMap(AppBundle.read(at:)).sorted { $0.name < $1.name }
        #expect(apps.map(\.name) == ["Rocket", "Sparkly", "Store"])
        #expect(apps[0].version == "4.1.9" && apps[0].build == "4.1.9")
        #expect(apps[0].electronConfig?.hasPrefix("provider: generic") == true)
        #expect(apps[1].version == "2.1" && apps[1].build == "210" && apps[1].feed == "https://example.com/appcast.xml" && !apps[1].isAppStore)
        #expect(apps[2].version == "7" && apps[2].isAppStore && apps[2].fileName == "Store.app")
    }

    @Test func keepsSpotlightAppsOutsideLibraryBundlesAndHiddenFolders() {
        let home = "/Users/me"
        #expect(AppScanner.isSpotlightCandidate("/Users/me/Downloads/Tool.app", home: home))
        #expect(AppScanner.isSpotlightCandidate("/Users/me/Applications/Games/Chess.app", home: home))
        #expect(!AppScanner.isSpotlightCandidate("/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Debug/X.app", home: home))
        #expect(!AppScanner.isSpotlightCandidate("/Users/me/Downloads/Big.app/Contents/Helpers/Helper.app", home: home))
        #expect(!AppScanner.isSpotlightCandidate("/Users/me/.Trash/Old.app", home: home))
        #expect(!AppScanner.isSpotlightCandidate("/Applications/Safari.app", home: home))
        #expect(!AppScanner.isSpotlightCandidate("/Users/me/Downloads/readme.txt", home: home))
    }

    @Test func dropsDuplicatesAppleAppsAndMacKitItself() {
        let apps = [app("com.example.a", "/Applications/A.app"), app("com.example.A", "/Users/me/Downloads/A.app"),
                    app("com.apple.Safari", "/Applications/Safari.app"), app("com.apple.iWork.Pages", "/Applications/Pages.app", isAppStore: true),
                    app("click.ngoctruong.CleanMacOS", "/Applications/MacKit.app")]
        #expect(AppScanner.unique(apps, ownBundleID: "click.ngoctruong.CleanMacOS").map(\.path) == ["/Applications/A.app", "/Applications/Pages.app"])
    }

    @Test func picksTheNewestStableReleaseThisMacCanRun() throws {
        #expect(Appcast.releases(in: appcast).map(\.build) == ["350", "320", "310"])
        let latest = try #require(Appcast.latest(in: appcast, systemVersion: "26.4.0"))
        #expect(latest == FeedRelease(version: "3.2", build: "320", minimumSystemVersion: "13.0"))
        #expect(Appcast.latest(in: appcast, systemVersion: "12.7.1")?.build == "310")
        #expect(Appcast.latest(in: Data("not xml".utf8), systemVersion: "26.4.0") == nil)
    }

    @Test func findsElectronFeedsAndReadsLatestMac() {
        #expect(ElectronFeed.feedURL(fromConfig: "provider: generic\nurl: https://updates.example.com/app\nupdaterCacheDirName: app-updater\n")
                == URL(string: "https://updates.example.com/app/latest-mac.yml"))
        #expect(ElectronFeed.feedURL(fromConfig: "provider: generic\nurl: 'https://updates.example.com/app/'\n")
                == URL(string: "https://updates.example.com/app/latest-mac.yml"))
        #expect(ElectronFeed.feedURL(fromConfig: "owner: acme\nrepo: rocket\nprovider: github\n")
                == URL(string: "https://github.com/acme/rocket/releases/latest/download/latest-mac.yml"))
        #expect(ElectronFeed.feedURL(fromConfig: "provider: github\nowner: acme\nrepo: secret\nprivate: true\n") == nil)
        #expect(ElectronFeed.feedURL(fromConfig: "provider: s3\nbucket: rocket\n") == nil)
        let latest = "version: 4.2.0\nfiles:\n  - url: Rocket-4.2.0-arm64-mac.zip\n    sha512: abc\n    size: 1\npath: Rocket-4.2.0-arm64-mac.zip\n"
            + "releaseDate: '2026-10-01T10:00:00.000Z'\n"
        #expect(ElectronFeed.latest(latest) == FeedRelease(version: "4.2.0", build: "4.2.0"))
        #expect(ElectronFeed.latest("version: \"5.0.1\"\nminimumSystemVersion: '15.0'\n") == FeedRelease(version: "5.0.1", build: "5.0.1", minimumSystemVersion: "15.0"))
        #expect(ElectronFeed.latest("files: []\n") == nil)
    }

    @Test func batchesStoreLookupsAndReadsListings() throws {
        #expect(AppStoreLookup.batches((1...45).map { "com.example.app\($0)" }).map(\.count) == [20, 20, 5])
        let url = try #require(AppStoreLookup.url(for: ["com.a.one", "com.b.two"], country: "VN"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.scheme == "https" && url.host == "itunes.apple.com" && url.path == "/lookup")
        #expect(items.first { $0.name == "bundleId" }?.value == "com.a.one,com.b.two")
        #expect(items.first { $0.name == "country" }?.value == "vn")
        #expect(items.first { $0.name == "entity" }?.value == "macSoftware")
        let json = """
        {"resultCount":2,"results":[{"bundleId":"com.A.One","version":"5.1","trackViewUrl":"https://apps.apple.com/vn/app/one/id123?mt=12",
         "minimumOsVersion":"12.0","kind":"mac-software"},{"bundleId":"com.b.two"}]}
        """
        let listings = try #require(AppStoreLookup.listings(from: Data(json.utf8)))
        #expect(listings == ["com.a.one": StoreListing(version: "5.1", page: URL(string: "macappstore://apps.apple.com/vn/app/one/id123?mt=12"),
                                                       minimumSystemVersion: "12.0")])
        #expect(AppStoreLookup.listings(from: Data("nope".utf8)) == nil)
    }

    @Test func plansRequestsAndTurnsAnswersIntoEvidence() throws {
        let feed = try #require(URL(string: "https://example.com/appcast.xml"))
        let stores = (1...21).map { RoutedApp(app: app("com.example.S\($0)", "/Applications/S\($0).app", isAppStore: true), route: .appStore) }
        let routed = stores + [RoutedApp(app: app("com.example.f", "/Applications/F.app"), route: .sparkle(feed)),
                               RoutedApp(app: app("com.example.c", "/Applications/C.app"), route: .catalog)]
        let plan = UpdateFetchPlan(routed, country: "US")
        #expect(plan.storeBatches.map(\.count) == [20, 1])
        #expect(Set(plan.requests.keys) == ["store.0", "store.1", "/Applications/F.app"])
        #expect(plan.requests["/Applications/F.app"] == feed)
        let answer = #"{"resultCount":1,"results":[{"bundleId":"com.example.S1","version":"2.0"}]}"#
        let evidence = plan.evidence(from: ["store.0": .data(Data(answer.utf8)), "store.1": .failed("offline"),
                                            "/Applications/F.app": .failed("The server answered 404")], systemVersion: "26.4.0")
        #expect(evidence.store.keys.sorted() == ["com.example.s1"])
        #expect(evidence.storeFailures == ["com.example.s21"])
        #expect(evidence.feeds["/Applications/F.app"] == .failed("The server answered 404"))
        #expect(evidence.systemVersion == "26.4.0")
        #expect(UpdateFetchPlan([], country: "US").requests.isEmpty)
    }

    @Test func matchesCatalogCasksByAppNameOrBundleID() throws {
        let catalog = """
        [{"token":"firefox","name":["Mozilla Firefox"],"desc":"Web browser","homepage":"https://www.mozilla.org/firefox/","version":"145.0",
          "artifacts":[{"app":["Firefox.app"]},{"zap":[{"trash":["~/Library/Preferences/org.mozilla.firefox.plist"]}]}]},
         {"token":"firefox@esr","name":["Mozilla Firefox ESR"],"homepage":"https://www.mozilla.org/firefox/enterprise/","version":"140.5.0esr",
          "artifacts":[{"app":["Firefox.app"]}]},
         {"token":"tool","name":["Tool"],"homepage":"https://tool.example.com","version":"2.0,99",
          "artifacts":[{"app":["Tool Installer.app",{"target":"Tool.app"}]}]},
         {"token":"helper","name":["Helper"],"homepage":"https://helper.example.com","version":"1.5",
          "artifacts":[{"uninstall":[{"quit":["com.example.Helper","com.example.HelperAgent"]}]}]}]
        """
        let index = CaskIndex(try #require(BrewJSON.catalog(from: Data(catalog.utf8))))
        #expect(index.match(app("org.mozilla.firefox", "/Applications/Firefox.app"))?.name == "firefox")
        #expect(index.match(app("org.mozilla.unknown", "/Applications/Firefox.app"))?.name == "firefox")
        #expect(index.match(app("com.tool", "/Applications/Tool.app"))?.name == "tool")
        #expect(index.match(app("com.EXAMPLE.helper", "/Applications/Helper Pro.app"))?.name == "helper")
        #expect(index.match(app("com.nobody", "/Applications/Nothing.app")) == nil)
    }

    @Test func routesEachAppToOneSource() throws {
        let obsFeed = try #require(URL(string: "https://obs.example.com/appcast.xml"))
        let rocketFeed = try #require(URL(string: "https://updates.example.com/latest-mac.yml"))
        var settings = AppUpdateSettings()
        let casks = CaskIndex([cask("obs", apps: ["OBS.app"])])
        let store = app("com.example.store", "/Applications/Store.app", isAppStore: true)
        let obs = app("com.obsproject.obs-studio", "/Applications/OBS.app", feed: "https://obs.example.com/appcast.xml")
        let insecure = app("com.example.old", "/Applications/Old.app", feed: "http://example.com/appcast.xml")
        let rocket = app("com.example.rocket", "/Applications/Rocket.app", electron: "provider: generic\nurl: https://updates.example.com\n")
        #expect(AppUpdatePlanner.route(store, settings: settings, installedCasks: casks) == nil)
        #expect(AppUpdatePlanner.route(insecure, settings: settings, installedCasks: nil) == nil)
        settings.checksAppStore = true
        settings.usesCatalog = true
        #expect(AppUpdatePlanner.route(store, settings: settings, installedCasks: casks) == .appStore)
        #expect(AppUpdatePlanner.route(obs, settings: settings, installedCasks: casks) == .homebrew("obs"))
        #expect(AppUpdatePlanner.route(obs, settings: settings, installedCasks: nil) == .sparkle(obsFeed))
        #expect(AppUpdatePlanner.route(rocket, settings: settings, installedCasks: casks) == .electron(rocketFeed))
        #expect(AppUpdatePlanner.route(insecure, settings: settings, installedCasks: casks) == .catalog)
    }

    @Test func theBundleVersionWinsOverHomebrewsRecord() {
        let obs = app("com.obsproject.obs-studio", "/Applications/OBS.app", version: "33.0.1")
        let drawio = app("com.jgraph.drawio.desktop", "/Applications/draw.io.app", version: "32.5.5")
        var evidence = UpdateEvidence(systemVersion: "26.4.0")
        evidence.outdatedCasks = [
            "obs": BrewOutdated(kind: .cask, name: "obs", installedVersions: ["33.0.0"], currentVersion: "33.0.1", isPinned: false),
            "drawio": BrewOutdated(kind: .cask, name: "drawio", installedVersions: ["32.5.5"], currentVersion: "32.6.10,abc", isPinned: false),
        ]
        #expect(AppUpdatePlanner.evaluate(obs, route: .homebrew("obs"), evidence: evidence) == .current)
        #expect(AppUpdatePlanner.evaluate(drawio, route: .homebrew("drawio"), evidence: evidence)
                == .update(AppUpdate(app: drawio, installed: "32.5.5", latest: "32.6.10", source: .homebrew, action: .brew("drawio"))))
        #expect(AppUpdatePlanner.evaluate(drawio, route: .homebrew("other"), evidence: evidence) == .current)
    }

    @Test func comparesFeedBuildsAndReportsFeedProblems() throws {
        let feed = try #require(URL(string: "https://example.com/appcast.xml"))
        let sparkly = app("com.example.sparkly", "/Applications/Sparkly.app", version: "3.1", build: "310")
        var evidence = UpdateEvidence(systemVersion: "26.4.0")
        evidence.feeds = [sparkly.path: .data(appcast)]
        #expect(AppUpdatePlanner.evaluate(sparkly, route: .sparkle(feed), evidence: evidence)
                == .update(AppUpdate(app: sparkly, installed: "3.1", latest: "3.2", source: .sparkle, action: .openApp)))
        let rebuilt = app("com.example.sparkly", "/Applications/Sparkly.app", version: "3.2", build: "319")
        evidence.feeds = [rebuilt.path: .data(appcast)]
        #expect(AppUpdatePlanner.evaluate(rebuilt, route: .sparkle(feed), evidence: evidence)
                == .update(AppUpdate(app: rebuilt, installed: "3.2 (319)", latest: "3.2 (320)", source: .sparkle, action: .openApp)))
        let current = app("com.example.sparkly", "/Applications/Sparkly.app", version: "3.2", build: "320")
        #expect(AppUpdatePlanner.evaluate(current, route: .sparkle(feed), evidence: evidence) == .current)
        evidence.feeds = [sparkly.path: .failed("The server answered 404")]
        #expect(AppUpdatePlanner.evaluate(sparkly, route: .sparkle(feed), evidence: evidence) == .failed("The server answered 404"))
        evidence.feeds = [:]
        #expect(AppUpdatePlanner.evaluate(sparkly, route: .sparkle(feed), evidence: evidence) == .failed(AppUpdatePlanner.timedOut))
        evidence.feeds = [sparkly.path: .data(Data("<rss/>".utf8))]
        #expect(AppUpdatePlanner.evaluate(sparkly, route: .sparkle(feed), evidence: evidence) == .failed("The update feed lists no release for this Mac"))
        let rocket = app("com.example.rocket", "/Applications/Rocket.app", version: "4.1.9")
        evidence.feeds = [rocket.path: .data(Data("version: 4.2.0\n".utf8))]
        #expect(AppUpdatePlanner.evaluate(rocket, route: .electron(feed), evidence: evidence)
                == .update(AppUpdate(app: rocket, installed: "4.1.9", latest: "4.2.0", source: .electron, action: .openApp)))
        evidence.feeds = [rocket.path: .data(Data("version: 4.2.0\nminimumSystemVersion: 99.0\n".utf8))]
        #expect(AppUpdatePlanner.evaluate(rocket, route: .electron(feed), evidence: evidence) == .current)
    }

    @Test func checksAppStoreAndCatalogListings() throws {
        let store = app("com.example.Store", "/Applications/Store.app", version: "5.0", isAppStore: true)
        let page = try #require(URL(string: "macappstore://apps.apple.com/app/id1"))
        var evidence = UpdateEvidence(systemVersion: "26.4.0")
        evidence.store = ["com.example.store": StoreListing(version: "5.1", page: page, minimumSystemVersion: "12.0")]
        #expect(AppUpdatePlanner.evaluate(store, route: .appStore, evidence: evidence)
                == .update(AppUpdate(app: store, installed: "5.0", latest: "5.1", source: .appStore, action: .store(page))))
        evidence.store = ["com.example.store": StoreListing(version: "6.0", page: page, minimumSystemVersion: "99")]
        #expect(AppUpdatePlanner.evaluate(store, route: .appStore, evidence: evidence) == .current)
        evidence.store = [:]
        #expect(AppUpdatePlanner.evaluate(store, route: .appStore, evidence: evidence) == .failed("Not found in the App Store for this region"))
        evidence.storeFailures = ["com.example.store"]
        #expect(AppUpdatePlanner.evaluate(store, route: .appStore, evidence: evidence) == .failed("The App Store did not answer"))

        let firefox = app("org.mozilla.firefox", "/Applications/Firefox.app", version: "144.0.2")
        let homepage = try #require(URL(string: "https://www.mozilla.org/firefox/"))
        evidence.catalog = CaskIndex([cask("firefox", apps: ["Firefox.app"], version: "145.0", homepage: homepage.absoluteString),
                                      cask("chromium", apps: ["Chromium.app"], version: "latest", homepage: "https://chromium.org")])
        #expect(AppUpdatePlanner.evaluate(firefox, route: .catalog, evidence: evidence)
                == .update(AppUpdate(app: firefox, installed: "144.0.2", latest: "145.0", source: .catalog, action: .homepage(homepage))))
        #expect(AppUpdatePlanner.evaluate(app("org.chromium.Chromium", "/Applications/Chromium.app"), route: .catalog, evidence: evidence) == .current)

        let word = app("com.microsoft.Word", "/Applications/Microsoft Word.app", version: "16.89", build: "16.89.24091630")
        evidence.catalog = CaskIndex([cask("microsoft-word", apps: ["Microsoft Word.app"], version: "16.89.24091630", homepage: "https://www.microsoft.com")])
        #expect(AppUpdatePlanner.evaluate(word, route: .catalog, evidence: evidence) == .current)
        evidence.catalog = CaskIndex([cask("microsoft-word", apps: ["Microsoft Word.app"], version: "16.90.24101330", homepage: "https://www.microsoft.com")])
        #expect(AppUpdatePlanner.evaluate(word, route: .catalog, evidence: evidence)
                == .update(AppUpdate(app: word, installed: "16.89", latest: "16.90.24101330", source: .catalog,
                                     action: .homepage(URL(string: "https://www.microsoft.com")!))))
    }

    @Test func reportsMissingSourcesOnceAndSortsResults() throws {
        let feed = try #require(URL(string: "https://example.com/appcast.xml"))
        let routed = [RoutedApp(app: app("com.example.a", "/Applications/Alpha.app"), route: .homebrew("alpha")),
                      RoutedApp(app: app("com.example.b", "/Applications/Bravo.app"), route: .catalog),
                      RoutedApp(app: app("com.example.c", "/Applications/Charlie.app"), route: .sparkle(feed)),
                      RoutedApp(app: app("com.example.d", "/Applications/Delta.app"), route: .catalog)]
        let report = AppUpdatePlanner.report(routed, evidence: UpdateEvidence(systemVersion: "26.4.0"))
        #expect(report.checked == 4)
        #expect(report.updates.isEmpty)
        #expect(report.failures.map(\.name) == ["Charlie", "Homebrew", "Online catalog"])
        #expect(report.failures.first?.bundleID == "com.example.c")
    }

    @Test func rulesHideSkippedVersionsAndExcludedApps() {
        let update = update("Alpha", "1.1")
        var rules = AppUpdateRules()
        #expect(rules.allows(update))
        rules.skippedVersions["com.example.alpha"] = "1.1"
        #expect(!rules.allows(update))
        rules.skippedVersions["com.example.alpha"] = "1.0.9"
        #expect(rules.allows(update))
        rules.excludedBundleIDs = ["COM.EXAMPLE.ALPHA"]
        #expect(!rules.allows(update) && rules.isExcluded("com.example.alpha"))
    }

    @Test func schedulesTheNextCheckNoSoonerThanAllowed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = now.addingTimeInterval(180)
        #expect(AppUpdateSchedule.off.nextCheck(after: nil, notBefore: soon) == nil)
        #expect(AppUpdateSchedule.daily.nextCheck(after: nil, notBefore: soon) == soon)
        #expect(AppUpdateSchedule.daily.nextCheck(after: now.addingTimeInterval(-90_000), notBefore: soon) == soon)
        #expect(AppUpdateSchedule.daily.nextCheck(after: now.addingTimeInterval(-3_600), notBefore: soon) == now.addingTimeInterval(82_800))
        #expect(AppUpdateSchedule.weekly.nextCheck(after: now, notBefore: now) == now.addingTimeInterval(604_800))
    }

    @Test func everySettingStartsOffAndSurvivesEncoding() throws {
        let settings = AppUpdateSettings()
        #expect(settings.schedule == .off && !settings.notifies)
        #expect(!settings.checksHomebrew && !settings.checksAppStore && !settings.usesCatalog)
        #expect(settings.rules == AppUpdateRules() && settings.lastCheck == nil && settings.notifiedKeys.isEmpty)
        var changed = settings
        changed.schedule = .weekly
        changed.rules.skippedVersions["com.example.a"] = "2.0"
        changed.lastCheck = Date(timeIntervalSince1970: 100)
        let decoded = try JSONDecoder().decode(AppUpdateSettings.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }

    @Test func plansEachKindOfUpdate() throws {
        let page = try #require(URL(string: "macappstore://apps.apple.com/app/id1"))
        let site = try #require(URL(string: "https://echo.example.com"))
        let plan = AppUpdatePlan([update("Alpha", "2", action: .brew("alpha")), update("Bravo", "2", action: .brew("bravo")),
                                  update("Charlie", "2", action: .store(page)), update("Delta", "2"), update("Echo", "2", action: .homepage(site))])
        #expect(plan.brewTokens == ["alpha", "bravo"])
        #expect(plan.storeLinks == [page])
        #expect(plan.appPaths == ["/Applications/Delta.app"])
        #expect(plan.homepages == [site])
        #expect(plan.summary == "Homebrew runs: brew upgrade --cask --greedy alpha bravo\nOpens the app's App Store page.\n"
                + "Opens 1 app so it can update itself.\nOpens 1 download page.")
        let stores = AppUpdatePlan([update("Charlie", "2", action: .store(page)), update("Foxtrot", "2", action: .store(page))])
        #expect(stores.storeLinks == [AppStoreLookup.updatesPage])
    }

    @Test func notifiesOncePerUpdate() {
        let alpha = update("Alpha", "2.0")
        let bravo = update("Bravo", "3.1")
        let notified = UpdateNotice.remembering([alpha], in: [])
        #expect(UpdateNotice.fresh([alpha, bravo], notified: notified) == [bravo])
        #expect(UpdateNotice.fresh([update("Alpha", "2.1")], notified: notified).count == 1)
        #expect(UpdateNotice.body([alpha, bravo]) == "Alpha 2.0, Bravo 3.1")
        let many = (1...5).map { update("App\($0)", "1.\($0)") }
        #expect(UpdateNotice.body(many) == "App1 1.1, App2 1.2, App3 1.3 and 2 more")
        let remembered = UpdateNotice.remembering(many, in: Array(repeating: "old", count: UpdateNotice.memory))
        #expect(remembered.count == UpdateNotice.memory && remembered.last == many.last?.noticeKey)
    }

    @Test func allowsOnlyHTTPSFeeds() {
        #expect(FeedPolicy.isAllowed(URL(string: "https://example.com/appcast.xml")!))
        #expect(!FeedPolicy.isAllowed(URL(string: "http://example.com/appcast.xml")!))
        #expect(!FeedPolicy.isAllowed(URL(string: "file:///etc/hosts")!))
        #expect(FeedPolicy.maxBytes == 2_097_152 && FeedPolicy.concurrency == 4 && FeedPolicy.budget == 60)
    }

    @Test func fetcherRefusesPlainHTTPWithoutWaitingForTheBudget() async {
        let started = Date()
        let requests = Dictionary(uniqueKeysWithValues: (1...6).map { number in
            ("feed\(number)", URL(string: number.isMultiple(of: 2) ? "http://example.com/\(number).xml" : "ftp://example.com/\(number)")!)
        })
        let results = await FeedFetcher().fetchAll(requests)
        let empty = await FeedFetcher().fetchAll([:])
        #expect(results.count == 6)
        #expect(results.values.allSatisfy { $0 == .failed("The update feed is not HTTPS") })
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(empty.isEmpty)
    }
}
