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
    ])
    func sparkleSeesGentleReminderCallbacks(selector: String) {
        #expect(UpdaterViewModel.instancesRespond(to: NSSelectorFromString(selector)))
    }
}
