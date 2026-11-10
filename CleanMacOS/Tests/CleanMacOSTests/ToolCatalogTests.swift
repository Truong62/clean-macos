import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .windows, .input, .ram, .monitor, .displays, .portsJobs, .powerRecovery, .keepAwake, .controls,
                               .clipboard, .screenRecord, .typing, .commandBar, .snippets, .tools, .files, .sound, .music, .devTools])
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
    }

    @Test func monitorFollowsRAMInTheSystemGroup() {
        let pages = ToolGroup.system.tools.map(\.page)
        #expect(pages.firstIndex(of: .monitor) == pages.firstIndex(of: .ram).map { $0 + 1 })
    }
}
