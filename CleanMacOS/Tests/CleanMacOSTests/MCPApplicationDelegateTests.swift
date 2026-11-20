import Testing
@testable import CleanMacOS

struct MCPApplicationDelegateTests {
    @Test func launchesWhenOnlyMCPProcessesExist() {
        #expect(MCPReopenDecision.shouldLaunchMain(processArguments: [
            ["/Applications/Clean macOS.app/Contents/MacOS/CleanMacOS", "--mcp"],
            ["CleanMacOS", "--mcp"],
        ]))
        #expect(MCPReopenDecision.shouldLaunchMain(processArguments: []))
    }

    @Test @MainActor func reopensExistingMainRegardlessOfProcessOrder() {
        let main = ["CleanMacOS", "-psn_0_1234"]
        let mcp = ["CleanMacOS", "--mcp"]
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [main, mcp]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [mcp, main]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [["CleanMacOS"]]))
        let launchedMain = ["CleanMacOS", MCPApplicationDelegate.showMainWindowArgument]
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [launchedMain, mcp]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [mcp, launchedMain]))
    }

    @Test func unreadableArgumentsNeverRiskLaunchingADuplicate() {
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [[]]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [["CleanMacOS", "--mcp"], []]))
    }

    @Test func requiresAnExactMCPArgument() {
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [["CleanMacOS", "--mcp-other"]]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [["/tmp/--mcp/CleanMacOS"]]))
    }
}
