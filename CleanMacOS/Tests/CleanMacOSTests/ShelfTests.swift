import Foundation
import Testing
@testable import CleanMacOS

struct ShakeDetectorTests {
    private func feed(_ detector: inout ShakeDetector, _ points: [(CGFloat, TimeInterval)]) -> Bool {
        points.reduce(false) { fired, point in detector.add(x: point.0, at: point.1) || fired }
    }

    @Test func spotsAQuickShakeWhileDragging() {
        var detector = ShakeDetector()
        let zigzag: [(CGFloat, TimeInterval)] = [(0, 0), (80, 0.05), (0, 0.1), (80, 0.15), (0, 0.2)]
        #expect(feed(&detector, zigzag))
    }

    @Test func ignoresSlowMovesStraightDragsAndJitter() {
        var slow = ShakeDetector()
        #expect(!feed(&slow, [(0, 0), (80, 0.3), (0, 0.6), (80, 0.9), (0, 1.2)]))
        var straight = ShakeDetector()
        #expect(!feed(&straight, [(0, 0), (100, 0.05), (98, 0.06), (200, 0.1), (198, 0.11), (300, 0.15), (299, 0.16)]))
        var small = ShakeDetector()
        #expect(!feed(&small, [(0, 0), (30, 0.05), (0, 0.1), (30, 0.15), (0, 0.2)]))
    }

    @Test func waitsBeforeFiringAgain() {
        var detector = ShakeDetector()
        #expect(feed(&detector, [(0, 0), (80, 0.05), (0, 0.1), (80, 0.15), (0, 0.2)]))
        #expect(!feed(&detector, [(80, 0.25), (0, 0.3), (80, 0.35), (0, 0.4), (80, 0.45)]))
        #expect(feed(&detector, [(0, 1.5), (80, 1.55), (0, 1.6), (80, 1.65), (0, 1.7)]))
    }
}

struct ShelfCollectionTests {
    @Test func titlesItemsByWhatTheyHold() {
        #expect(ShelfItem(kind: .file, path: "/Users/me/Report.pdf").title == "Report.pdf")
        #expect(ShelfItem(kind: .link, link: "https://www.apple.com/mac/").title == "www.apple.com")
        #expect(ShelfItem(kind: .text, text: "\n  First line here\nsecond").title == "First line here")
    }

    @Test func addsWithoutDuplicatesAndKeepsTheLimit() {
        var shelf = ShelfCollection()
        let added = shelf.add([ShelfItem(kind: .file, path: "/a"), ShelfItem(kind: .file, path: "/a"), ShelfItem(kind: .text, text: "hi")])
        #expect(added.count == 2)
        #expect(shelf.add([ShelfItem(kind: .file, path: "/a")]).isEmpty)
        var pinned = ShelfItem(kind: .text, text: "keep")
        pinned.isPinned = true
        var full = ShelfCollection()
        _ = full.add([pinned] + (0..<ShelfCollection.limit).map { ShelfItem(kind: .text, text: "item \($0)") })
        #expect(full.items.isEmpty)
    }

    @Test func keepsPinnedItemsWhenClearingOrDraggingOut() {
        var shelf = ShelfCollection()
        var pinned = ShelfItem(kind: .text, text: "pinned")
        pinned.isPinned = true
        let loose = ShelfItem(kind: .text, text: "loose")
        _ = shelf.add([pinned, loose])
        shelf.removeAfterDragOut([pinned.id, loose.id])
        #expect(shelf.items.map(\.text) == ["pinned"])
        _ = shelf.add([ShelfItem(kind: .text, text: "again")])
        shelf.clear()
        #expect(shelf.items.map(\.text) == ["pinned"])
        shelf.togglePin(pinned.id)
        shelf.clear()
        #expect(shelf.items.isEmpty)
    }

    @Test func selectsByClickRangeAndAll() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = ShelfSelection()
        selection.click(ids[1], extend: false, order: ids)
        selection.click(ids[3], extend: true, order: ids)
        #expect(selection.ids == Set(ids[1...3]))
        selection.click(ids[2], extend: false, order: ids)
        #expect(selection.ids == [ids[1], ids[3]])
        selection.selectAll(ids)
        #expect(selection.ids.count == 5)
        selection.clear()
        #expect(selection.ids.isEmpty)
    }

    @Test func savesAndRestoresTheShelf() throws {
        let suite = "mackit.tests.shelf.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShelfStore(defaults: defaults, payloadFolder: folder)
        let image = try #require(store.savePayload(Data([1, 2, 3]), named: "Image.png"))
        store.save([ShelfItem(kind: .image, path: image.path), ShelfItem(kind: .link, link: "https://example.com")])
        #expect(store.load()?.map(\.kind) == [.image, .link])
        _ = store.savePayload(Data([4]), named: "Unused.png")
        store.removePayloads(except: [image.path])
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Unused.png").path))
        defaults.set(Data("junk".utf8), forKey: ShelfStore.key)
        #expect(store.load() == nil)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}
