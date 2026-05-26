import XCTest
@testable import CleanMacOS

final class ClipboardStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    func testSaveThenLoadRoundTrips() {
        let store = ClipboardStore(fileURL: tempURL())
        let items = [ClipboardItem(text: "one"), ClipboardItem(text: "two")]
        store.save(items)
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.text), ["one", "two"])
        XCTAssertEqual(loaded.map(\.id), items.map(\.id))
    }

    func testLoadMissingFileReturnsEmpty() {
        let store = ClipboardStore(fileURL: tempURL())
        XCTAssertTrue(store.load().isEmpty)
    }

    func testDeleteRemovesFile() {
        let url = tempURL()
        let store = ClipboardStore(fileURL: url)
        store.save([ClipboardItem(text: "x")])
        XCTAssertFalse(store.load().isEmpty)
        store.delete()
        XCTAssertTrue(store.load().isEmpty)
    }
}
