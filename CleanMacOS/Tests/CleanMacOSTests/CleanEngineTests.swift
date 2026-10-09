#if canImport(XCTest)
import XCTest
import Darwin
@testable import CleanMacOS

final class CleanEngineTests: XCTestCase {
    func testRemovingDescendantsKeepsOnlySelectedAncestor() {
        let parent = artifact("/tmp/clean-engine/parent")
        let child = artifact("/tmp/clean-engine/parent/child")
        let sibling = artifact("/tmp/clean-engine/sibling")

        let filtered = AppViewModel.removingDescendants(from: [child, sibling, parent])

        XCTAssertEqual(Set(filtered.map(\.path)), Set([parent.path, sibling.path]))
    }

    func testPermissionFailureClassification() {
        let accessDenied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let operationNotPermitted = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let cocoaDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))

        XCTAssertTrue(CleanerService.isRetryablePermissionError(accessDenied))
        XCTAssertTrue(CleanerService.isRetryablePermissionError(operationNotPermitted))
        XCTAssertTrue(CleanerService.isRetryablePermissionError(cocoaDenied))
        XCTAssertFalse(CleanerService.isRetryablePermissionError(missing))
    }

    func testProtectedPathsRemainUnsafeToDelete() {
        for path in ScannerService.protectedPaths {
            XCTAssertFalse(ScannerService.isSafeToDelete(path: path), path)
        }
        XCTAssertFalse(ScannerService.isSafeToDelete(path: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testDirectoryWithUndeletableChildReportsPartialSuccess() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean-engine-partial-\(UUID().uuidString)")
        let deletable = root.appendingPathComponent("deletable.bin")
        let nested = root.appendingPathComponent("nested")
        let locked = root.appendingPathComponent("locked.bin")

        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: deletable)
        try Data(count: 200_000).write(to: nested.appendingPathComponent("inner.bin"))
        try Data(count: 200_000).write(to: locked)
        XCTAssertEqual(chflags(locked.path, UInt32(UF_IMMUTABLE)), 0)
        defer {
            chflags(locked.path, 0)
            try? fm.removeItem(at: root)
        }

        let result = CleanerService().reclaim([artifact(root.path)])
        let item = try XCTUnwrap(result.deleted.first)

        XCTAssertFalse(item.success)
        XCTAssertGreaterThan(item.freedBytes, 0)
        XCTAssertEqual(result.totalFreed, item.freedBytes)
        XCTAssertEqual(item.failures.map(\.path), [locked.path])
        XCTAssertTrue(item.retryableAsAdmin)
        XCTAssertEqual(result.retryArtifacts.map(\.path), [locked.path])
        XCTAssertFalse(fm.fileExists(atPath: deletable.path))
        XCTAssertFalse(fm.fileExists(atPath: nested.path))
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
    }

    private func artifact(_ path: String) -> Artifact {
        Artifact(
            path: path,
            name: (path as NSString).lastPathComponent,
            size: 1,
            category: .caches,
            description: "Test",
            needsSudo: false
        )
    }
}
#endif
