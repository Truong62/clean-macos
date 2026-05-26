import XCTest
@testable import CleanMacOS

final class ClipboardMonitorTests: XCTestCase {
    func testIsCapturableRejectsEmptyAndWhitespace() {
        XCTAssertFalse(ClipboardMonitor.isCapturable(""))
        XCTAssertFalse(ClipboardMonitor.isCapturable("   "))
        XCTAssertFalse(ClipboardMonitor.isCapturable("\n\t "))
    }

    func testIsCapturableAcceptsRealText() {
        XCTAssertTrue(ClipboardMonitor.isCapturable("hello"))
        XCTAssertTrue(ClipboardMonitor.isCapturable("  trimmed but real  "))
    }
}
