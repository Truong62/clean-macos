import XCTest
@testable import CleanMacOS

final class ClipboardHistoryTests: XCTestCase {
    func testAddInsertsAtTop() {
        var h = ClipboardHistory()
        h.add("first", maxItems: 10)
        h.add("second", maxItems: 10)
        XCTAssertEqual(h.items.map(\.text), ["second", "first"])
    }

    func testAddDuplicateMovesToTopWithoutDuplicating() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.add("b", maxItems: 10)
        h.add("a", maxItems: 10) // duplicate of the bottom item
        XCTAssertEqual(h.items.map(\.text), ["a", "b"])
        XCTAssertEqual(h.items.count, 2)
    }

    func testAddTrimsToMaxItems() {
        var h = ClipboardHistory()
        for i in 1...5 { h.add("item\(i)", maxItems: 3) }
        XCTAssertEqual(h.items.map(\.text), ["item5", "item4", "item3"])
    }

    func testRemoveById() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.add("b", maxItems: 10)
        let idToRemove = h.items[0].id
        h.remove(id: idToRemove)
        XCTAssertEqual(h.items.map(\.text), ["a"])
    }

    func testClear() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.clear()
        XCTAssertTrue(h.items.isEmpty)
    }

    func testPreviewCollapsesWhitespaceAndTruncates() {
        let item = ClipboardItem(text: "line1\nline2\tend")
        XCTAssertEqual(item.preview, "line1 line2 end")
        let long = ClipboardItem(text: String(repeating: "x", count: 200))
        XCTAssertTrue(long.preview.hasSuffix("…"))
        XCTAssertEqual(long.preview.count, 121) // 120 chars + ellipsis
    }
}
