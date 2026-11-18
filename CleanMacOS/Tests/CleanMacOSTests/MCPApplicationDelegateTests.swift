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

    @Test func reopensExistingMainRegardlessOfProcessOrder() {
        let main = ["CleanMacOS", "-psn_0_1234"]
        let mcp = ["CleanMacOS", "--mcp"]
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [main, mcp]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [mcp, main]))
        #expect(!MCPReopenDecision.shouldLaunchMain(processArguments: [["CleanMacOS"]]))
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
