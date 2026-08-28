import XCTest
@testable import CleanMacOS

final class ProcessServiceTests: XCTestCase {
    func testParsePreservesFieldsAndPathsContainingSpaces() {
        let output = """
            42     1   12.5  2048 alice /Applications/Example App.app/Contents/MacOS/Example App
             1     0    0.1  8192 root  /sbin/launchd
            """

        let processes = ProcessService.parse(
            output,
            currentUser: "alice",
            applicationKinds: [42: .app]
        )

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, 42)
        XCTAssertEqual(processes[0].ppid, 1)
        XCTAssertEqual(processes[0].cpuPercent, 12.5)
        XCTAssertEqual(processes[0].rssKilobytes, 2_048)
        XCTAssertEqual(processes[0].memoryBytes, 2_048 * 1_024)
        XCTAssertEqual(processes[0].user, "alice")
        XCTAssertEqual(processes[0].path, "/Applications/Example App.app/Contents/MacOS/Example App")
        XCTAssertEqual(processes[0].kind, .app)
        XCTAssertFalse(processes[0].isSystem)
        XCTAssertTrue(processes[1].isSystem)
    }

    func testProtectedPIDIsRefused() throws {
        let output = "1 0 0.0 8192 root /sbin/launchd"
        let process = try XCTUnwrap(ProcessService.parse(output, currentUser: "alice").first)

        XCTAssertThrowsError(try ProcessService.validateTermination(process)) { error in
            guard case ProcessServiceError.protectedProcess = error else {
                return XCTFail("Expected protected process error, got \(error)")
            }
        }
    }
}
