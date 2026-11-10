import AppKit
import Testing
@testable import CleanMacOS

struct URLCleanerTests {
    @Test func stripsTrackingParametersAndKeepsTheRest() {
        let result = URLCleaner.clean("https://example.com/page?utm_source=x&id=7&fbclid=abc#top")
        #expect(result == URLCleanResult(url: "https://example.com/page?id=7#top", removed: ["utm_source", "fbclid"]))
    }

    @Test func appliesSiteRulesToTheSiteAndItsSubdomains() {
        #expect(URLCleaner.clean("https://www.youtube.com/watch?v=abc&si=XYZ")?.url == "https://www.youtube.com/watch?v=abc")
        #expect(URLCleaner.clean("https://youtu.be/abc?si=1")?.url == "https://youtu.be/abc")
        #expect(URLCleaner.clean("https://example.com/?si=1")?.removed == [])
        #expect(URLCleaner.clean("https://notyoutube.com/?si=1")?.removed == [])
    }

    @Test func matchesNamesIgnoringCaseAndEscapes() {
        #expect(URLCleaner.clean("https://a.com/?UTM_Medium=1&%66bclid=2&q=%20x")?.url == "https://a.com/?q=%20x")
        #expect(URLCleaner.clean("https://a.com/?gclid&x=1")?.url == "https://a.com/?x=1")
        #expect(URLCleaner.clean("  https://a.com/p?utm_source=1\n")?.url == "https://a.com/p")
    }

    @Test func onlyCleansSingleWebLinks() {
        #expect(URLCleaner.clean("hello") == nil)
        #expect(URLCleaner.clean("ftp://a.com/?utm_source=1") == nil)
        #expect(URLCleaner.clean("https://a.com/?utm_source=1 and more") == nil)
    }

    @Test func followsCustomRules() {
        let rules = URLCleanRules(extraNames: ["ref"], keptNames: ["utm_source"])
        #expect(URLCleaner.clean("https://a.com/?ref=hn&utm_source=x&utm_medium=y", rules: rules)?.url == "https://a.com/?utm_source=x")
    }
}

struct ClipboardPrivacyTests {
    @Test func spotsSecretsButNotOrdinaryText() {
        let secrets = ["password: hunter2", "API_KEY=sk-123abc", "Authorization: Bearer abc.def", "mysql -u root --password s3cret",
                       "Xk9#mP2$vL7@qR4!tN8&", "ghp_16C7e42F292c6912E7710c838347Ae178B4a"]
        for secret in secrets { #expect(SensitiveText.looksSensitive(secret), "\(secret)") }
        let ordinary = ["hello world", "https://example.com/a?b=1&c=2", "550e8400-e29b-41d4-a716-446655440000", "short1!",
                        "the password is in the safe", "someone2024@example.com"]
        for text in ordinary { #expect(!SensitiveText.looksSensitive(text), "\(text)") }
    }

    @Test func skipsChosenAppsAndPrivateCopies() {
        var options = ClipboardOptions()
        options.skippedApps = ["com.example.vault"]
        let text: Set<String> = ["public.utf8-plain-text"]
        #expect(!ClipboardFilter.shouldSkip(PasteboardFacts(types: text, activeApps: ["com.apple.Safari"]), options: options, skipsConcealed: false))
        #expect(ClipboardFilter.shouldSkip(PasteboardFacts(types: text, activeApps: ["com.apple.Safari", "com.example.vault"]), options: options, skipsConcealed: false))
        #expect(ClipboardFilter.shouldSkip(PasteboardFacts(types: text, declaredSource: "com.example.vault"), options: options, skipsConcealed: false))
        #expect(ClipboardFilter.shouldSkip(PasteboardFacts(types: ["org.nspasteboard.TransientType"]), options: options, skipsConcealed: false))
        #expect(!ClipboardFilter.shouldSkip(PasteboardFacts(types: ["org.nspasteboard.ConcealedType"]), options: options, skipsConcealed: false))
        #expect(ClipboardFilter.shouldSkip(PasteboardFacts(types: ["org.nspasteboard.ConcealedType"]), options: options, skipsConcealed: true))
    }

    @Test func namesTheAppACopyCameFrom() {
        #expect(ClipboardFilter.sourceApp(PasteboardFacts(declaredSource: "com.a", activeApps: ["com.b"])) == "com.a")
        #expect(ClipboardFilter.sourceApp(PasteboardFacts(activeApps: ["com.b"])) == "com.b")
        #expect(ClipboardFilter.sourceApp(PasteboardFacts(activeApps: ["com.b", "com.c"])) == nil)
        #expect(ClipboardFilter.sourceApp(PasteboardFacts(types: ["com.apple.is-remote-clipboard"], declaredSource: "com.a", activeApps: ["com.b"])) == nil)
    }
}

struct ColorTextTests {
    @Test func readsHexColors() {
        #expect(ColorText.parse("#ff0000") == ClipboardColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorText.parse(" #F00 ") == ClipboardColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorText.parse("#00ff0080")?.alpha == 128.0 / 255)
        #expect(ColorText.parse("#0f08")?.alpha == 136.0 / 255)
        #expect(ColorText.parse("#ggg") == nil)
        #expect(ColorText.parse("ff0000") == nil)
    }

    @Test func readsCSSAndSwiftUIColors() {
        #expect(ColorText.parse("rgb(255, 0, 0)") == ClipboardColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorText.parse("rgba(0,0,255,0.5)") == ClipboardColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        #expect(ColorText.parse("rgb(100% 0% 0% / 50%)") == ClipboardColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(ColorText.parse("hsl(120, 100%, 50%)") == ClipboardColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(ColorText.parse("hsla(240, 100%, 50%, 0.25)") == ClipboardColor(red: 0, green: 0, blue: 1, alpha: 0.25))
        #expect(ColorText.parse("Color(red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)") == ClipboardColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8))
        #expect(ColorText.parse("rgb(300, 0, 0)") == nil)
        #expect(ColorText.parse("hello") == nil)
    }
}

struct ClipboardSearchTests {
    private func items(_ texts: [String], pinned: Set<String> = []) -> [ClipboardItem] {
        texts.map { ClipboardItem(text: $0, isPinned: pinned.contains($0)) }
    }

    @Test func needsEveryWordIgnoringCaseAndAccents() {
        let list = items(["Hello World", "world peace", "say hello", "Tiếng Việt"])
        #expect(ClipboardSearch.rank(list, query: "hello world").map(\.text) == ["Hello World"])
        #expect(ClipboardSearch.rank(list, query: "tieng viet").map(\.text) == ["Tiếng Việt"])
        #expect(ClipboardSearch.rank(list, query: " ").map(\.text) == list.map(\.text))
    }

    @Test func ranksExactThenPrefixThenWholeWords() {
        let list = items(["concat", "a cat", "category", "cat"])
        #expect(ClipboardSearch.rank(list, query: "cat").map(\.text) == ["cat", "category", "a cat", "concat"])
    }

    @Test func pinnedItemsWinTies() {
        let list = items(["cat food", "cat toy"], pinned: ["cat toy"])
        #expect(ClipboardSearch.rank(list, query: "cat").map(\.text) == ["cat toy", "cat food"])
    }
}

struct ClipboardHistoryUpgradeTests {
    @Test func recopyingKeepsTheItemAndItsPin() {
        var history = ClipboardHistory()
        history.add("a", maxItems: 10)
        history.add("b", maxItems: 10)
        let first = history.items[1]
        history.togglePin(id: first.id, at: Date())
        history.insert(ClipboardItem(text: "  a \n", sourceApp: "com.x"), maxItems: 10)
        #expect(history.items.count == 2)
        #expect(history.items[0].id == first.id)
        #expect(history.items[0].isPinned)
        #expect(history.items[0].sourceApp == "com.x")
    }

    @Test func pinnedItemsIgnoreTheLimit() {
        var history = ClipboardHistory()
        history.add("keep", maxItems: 2)
        history.togglePin(id: history.items[0].id, at: Date())
        for text in ["x", "y", "z"] { history.add(text, maxItems: 2) }
        #expect(history.items.map(\.text) == ["z", "y", "keep"])
    }

    @Test func expiryAndClearingSparePinnedItems() {
        var history = ClipboardHistory()
        let old = Date(timeIntervalSinceNow: -10 * 86_400)
        history.insert(ClipboardItem(text: "pinned", createdAt: old, isPinned: true), maxItems: 10)
        history.insert(ClipboardItem(text: "stale", createdAt: old), maxItems: 10)
        history.insert(ClipboardItem(text: "fresh"), maxItems: 10)
        history.prune(before: Date(timeIntervalSinceNow: -7 * 86_400))
        #expect(history.items.map(\.text) == ["fresh", "pinned"])
        history.clear()
        #expect(history.items.map(\.text) == ["pinned"])
    }

    @Test func unpinningMovesTheItemBackToTheTop() {
        var history = ClipboardHistory()
        history.add("a", maxItems: 10)
        history.togglePin(id: history.items[0].id, at: Date(timeIntervalSince1970: 0))
        history.add("b", maxItems: 10)
        let now = Date()
        history.togglePin(id: history.items[1].id, at: now)
        #expect(history.items.map(\.text) == ["a", "b"])
        #expect(history.items[0].createdAt == now)
        #expect(!history.items[0].isPinned)
    }

    @Test func dedupesImagesByHashAndFilesByPath() {
        var history = ClipboardHistory()
        let first = ClipboardItem.ImageInfo(fileName: "1.png", hash: "abc", width: 10, height: 20)
        let second = ClipboardItem.ImageInfo(fileName: "2.png", hash: "abc", width: 10, height: 20)
        history.insert(ClipboardItem(text: "", kind: .image, image: first), maxItems: 10)
        history.insert(ClipboardItem(text: "", kind: .image, image: second), maxItems: 10)
        history.insert(ClipboardItem(text: "", kind: .files, files: ["/a", "/b"]), maxItems: 10)
        history.insert(ClipboardItem(text: "", kind: .files, files: ["/b", "/a"]), maxItems: 10)
        #expect(history.items.count == 3)
        #expect(history.items.last?.image?.fileName == "1.png")
    }

    @Test func editsText() {
        var history = ClipboardHistory()
        history.add("tpyo", maxItems: 10)
        history.update(id: history.items[0].id, text: "typo")
        #expect(history.items.map(\.text) == ["typo"])
    }

    @Test func describesImagesAndFiles() {
        let image = ClipboardItem.ImageInfo(fileName: "1.png", hash: "h", width: 640, height: 480)
        #expect(ClipboardItem(text: "", kind: .image, image: image).preview == "Image · 640×480")
        #expect(ClipboardItem(text: "", kind: .files, files: ["/Users/me/Report.pdf"]).preview == "Report.pdf")
        #expect(ClipboardItem(text: "", kind: .files, files: ["/a", "/b"]).preview == "2 files")
    }

    @Test func readsHistorySavedByOlderVersions() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"hi","createdAt":700000000}]"#
        let items = try JSONDecoder().decode([ClipboardItem].self, from: Data(json.utf8))
        #expect(items.first?.kind == .text)
        #expect(items.first?.isPinned == false)
        let again = try JSONDecoder().decode([ClipboardItem].self, from: JSONEncoder().encode(items))
        #expect(again == items)
    }
}

struct ClipboardCaptureTests {
    @Test func prefersFilesThenImagesThenText() {
        #expect(ClipboardCapture.kind(hasFiles: true, hasImage: true, text: "Report.pdf") == .files)
        #expect(ClipboardCapture.kind(hasFiles: false, hasImage: true, text: nil) == .image)
        #expect(ClipboardCapture.kind(hasFiles: false, hasImage: true, text: "https://example.com/cat.png") == .image)
        #expect(ClipboardCapture.kind(hasFiles: false, hasImage: true, text: "Q1 revenue\t42") == .text)
        #expect(ClipboardCapture.kind(hasFiles: false, hasImage: false, text: "hi") == .text)
        #expect(ClipboardCapture.kind(hasFiles: false, hasImage: false, text: "  ") == nil)
    }

    @Test @MainActor func turnsRichTextIntoPlainText() throws {
        let styled = NSAttributedString(string: "Bold move", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(PlainText.extract(string: nil, rtf: rtf, html: nil) == "Bold move")
        #expect(PlainText.extract(string: nil, rtf: nil, html: Data("<p>Hi <b>there</b></p>".utf8)) == "Hi there")
        #expect(PlainText.extract(string: "plain", rtf: rtf, html: nil) == "plain")
        #expect(PlainText.extract(string: nil, rtf: nil, html: nil) == nil)
    }

    @Test func skipsHugeText() {
        #expect(!ClipboardMonitor.isCapturable(String(repeating: "a", count: ClipboardMonitor.maxTextLength + 1)))
        #expect(ClipboardMonitor.isCapturable("fits"))
    }

    @Test func autoClearWaitsForTheDelay() {
        let rule = ClipboardAutoClear(afterDelay: true, delaySeconds: 20)
        let changed = Date(timeIntervalSince1970: 1000)
        #expect(!rule.isDue(lastChange: changed, now: changed.addingTimeInterval(19)))
        #expect(rule.isDue(lastChange: changed, now: changed.addingTimeInterval(20)))
        #expect(!ClipboardAutoClear().isDue(lastChange: changed, now: changed.addingTimeInterval(9999)))
    }
}

struct ClipboardStorageTests {
    private func tempStore() -> ClipboardStore {
        ClipboardStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("clipboard-history.json"))
    }

    @Test func keepsHistoryPrivateAndDropsUnusedImages() throws {
        let store = tempStore()
        store.save([ClipboardItem(text: "secret")])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(store.saveImage(Data([1, 2, 3]), named: "keep.png"))
        #expect(store.saveImage(Data([4, 5, 6]), named: "drop.png"))
        store.removeImages(except: ["keep.png"])
        #expect(FileManager.default.fileExists(atPath: store.imageURL(named: "keep.png").path))
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(named: "drop.png").path))
        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    @Test func rewritesOnlyPlainTextCopies() {
        #expect(PasteboardFacts(types: ["public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"]).holdsOnlyText)
        #expect(!PasteboardFacts(types: ["public.utf8-plain-text", "public.html"]).holdsOnlyText)
    }
}

@MainActor
struct ClipboardMonitorReadTests {
    @Test func readsTextImagesAndFilesAndSkipsTransientCopies() throws {
        let pasteboard = NSPasteboard(name: .init("mackit.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var snapshots: [ClipboardSnapshot] = []
        monitor.onChange = { snapshots.append($0) }
        monitor.shouldSkip = { ClipboardFilter.shouldSkip($0, options: ClipboardOptions(), skipsConcealed: false) }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        monitor.poll()
        #expect(snapshots.last?.text == "hello")

        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pasteboard.clearContents()
        pasteboard.setData(try #require(bitmap.tiffRepresentation), forType: .tiff)
        monitor.poll()
        let png = try #require(snapshots.last?.image)
        #expect(NSBitmapImageRep(data: png)?.pixelsWide == 4)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let folder = FileManager.default.temporaryDirectory
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        monitor.poll()
        #expect(snapshots.last?.files.map { URL(fileURLWithPath: $0).standardizedFileURL } == [folder.standardizedFileURL])

        let seen = snapshots.count
        pasteboard.clearContents()
        pasteboard.setString("one-time code", forType: .string)
        pasteboard.setData(Data(), forType: .init(PasteboardFacts.transient))
        monitor.poll()
        #expect(snapshots.count == seen)
    }
}
