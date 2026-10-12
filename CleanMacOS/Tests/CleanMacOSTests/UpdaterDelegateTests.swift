import Foundation
import Testing
@testable import CleanMacOS

struct UpdaterDelegateTests {
    @Test(arguments: [
        "supportsGentleScheduledUpdateReminders",
        "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
        "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
        "standardUserDriverDidReceiveUserAttentionForUpdate:",
        "standardUserDriverWillFinishUpdateSession",
        "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
    ])
    func sparkleSeesGentleReminderCallbacks(selector: String) {
        #expect(UpdaterViewModel.instancesRespond(to: NSSelectorFromString(selector)))
    }
}
