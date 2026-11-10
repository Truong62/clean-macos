import CoreGraphics
import Foundation
import Testing
@testable import CleanMacOS

struct FinderToolsTests {
    @Test func picksAFreeNameNextToExistingFiles() {
        let folder = URL(fileURLWithPath: "/tmp/dest")
        let taken: Set<String> = ["/tmp/dest/report.pdf", "/tmp/dest/report 2.pdf", "/tmp/dest/Docs"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        #expect(FileMove.destination(for: URL(fileURLWithPath: "/tmp/src/report.pdf"), in: folder, exists: exists)?.path == "/tmp/dest/report 3.pdf")
        #expect(FileMove.destination(for: URL(fileURLWithPath: "/tmp/src/Docs"), in: folder, exists: exists)?.path == "/tmp/dest/Docs 2")
        #expect(FileMove.destination(for: URL(fileURLWithPath: "/tmp/src/new.txt"), in: folder, exists: exists)?.path == "/tmp/dest/new.txt")
        #expect(FileMove.destination(for: URL(fileURLWithPath: "/tmp/dest/same.txt"), in: folder, exists: exists) == nil)
    }

    @Test func movesFilesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("from")
        let target = root.appendingPathComponent("to")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: source.appendingPathComponent("b.txt"))
        try Data("old".utf8).write(to: target.appendingPathComponent("a.txt"))
        let result = FileMover.move([source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")], into: target)
        #expect(result.moved == 2 && result.denied.isEmpty && result.failed.isEmpty)
        #expect(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: target.appendingPathComponent("a 2.txt"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("b.txt").path))
        #expect(FileMover.move([target.appendingPathComponent("b.txt")], into: target).unchanged == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func namesPastedImagesByTime() {
        let date = Date(timeIntervalSince1970: 1_794_301_500)
        #expect(PastedImage.fileName(at: date, timeZone: TimeZone(identifier: "UTC")!) == "Pasted_Image_20261110_090500.png")
    }

    @Test func readsFinderPaths() {
        #expect(FinderScript.urls(from: "/Users/me/a.txt\n/Users/me/Folder/\n\n") == [URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/Users/me/Folder/")])
        #expect(FinderScript.quoted(#"/tmp/a "b"\c"#) == #""/tmp/a \"b\"\\c""#)
    }

    @Test func routesFinderKeys() {
        var settings = FinderSettings()
        #expect(FinderKeys.action(keyCode: 7, flags: .maskCommand, settings: settings, hasCut: false, hasImage: false) == nil)
        settings.cutsAndPastes = true
        settings.renames = true
        settings.pastesImages = true
        #expect(FinderKeys.action(keyCode: 7, flags: .maskCommand, settings: settings, hasCut: false, hasImage: false) == .cut)
        #expect(FinderKeys.action(keyCode: 9, flags: .maskCommand, settings: settings, hasCut: true, hasImage: true) == .moveCut)
        #expect(FinderKeys.action(keyCode: 9, flags: .maskCommand, settings: settings, hasCut: false, hasImage: true) == .pasteImage)
        #expect(FinderKeys.action(keyCode: 9, flags: [.maskCommand, .maskShift], settings: settings, hasCut: false, hasImage: true) == nil)
        #expect(FinderKeys.action(keyCode: 9, flags: .maskCommand, settings: settings, hasCut: false, hasImage: false) == nil)
        #expect(FinderKeys.action(keyCode: 8, flags: .maskCommand, settings: settings, hasCut: true, hasImage: false) == .cancelCut)
        #expect(FinderKeys.action(keyCode: 120, flags: [.maskSecondaryFn], settings: settings, hasCut: false, hasImage: false) == .rename)
        #expect(FinderKeys.action(keyCode: 120, flags: .maskCommand, settings: settings, hasCut: false, hasImage: false) == nil)
    }

    @Test func describesTheRenameKey() {
        #expect(RenameKey.f2.title == "F2")
        #expect(RenameKey(keyCode: 36, modifiers: CGEventFlags.maskShift.rawValue).title == "⇧Return")
    }
}
