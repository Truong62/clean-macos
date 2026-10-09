import Foundation
import Testing
@testable import CleanMacOS

struct UninstallTrashTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")

    @Test func nonWritableAppBundleFailsAsRetryableAsAdmin() throws {
        let app = folder.appendingPathComponent("Locked.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let result = CleanerService().moveToTrash([app.path])
        #expect(result.failCount == 1)
        #expect(result.deleted.first?.retryableAsAdmin == true)
    }

    @Test func trashDestinationAvoidsExistingNames() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Slack.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fresh = CleanerService.trashDestination(for: "/Applications/Telegram.app", in: folder.path)
        let taken = CleanerService.trashDestination(for: "/Applications/Slack.app", in: folder.path)
        #expect(fresh == folder.appendingPathComponent("Telegram.app").path)
        #expect(taken != folder.appendingPathComponent("Slack.app").path)
        #expect(taken.hasPrefix(folder.appendingPathComponent("Slack ").path) && taken.hasSuffix(".app"))
    }

    @Test func privilegedTrashCommandMovesThenReturnsOwnership() {
        let command = CleanerService.privilegedTrashCommand(path: "/Applications/It's.app",
                                                            destination: "/Users/me/.Trash/It's.app", owner: "me")
        #expect(command == #"/bin/mv -n '/Applications/It'\''s.app' '/Users/me/.Trash/It'\''s.app' && /usr/sbin/chown -R 'me' '/Users/me/.Trash/It'\''s.app'"#)
    }
}
