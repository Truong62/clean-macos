import AppKit
import Testing
@testable import CleanMacOS

@MainActor struct MainWindowTests {
    @Test func showingFromOutsideMovesWindowHereInsteadOfPinningItToEverySpace() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        MainWindowController.bringToActiveSpace(window)
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
