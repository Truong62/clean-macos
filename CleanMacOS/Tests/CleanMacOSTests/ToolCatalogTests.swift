import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .windows, .input, .ram, .displays, .portsJobs, .powerRecovery, .keepAwake, .controls,
                               .clipboard, .screenRecord, .typing, .commandBar, .snippets, .tools, .island, .files, .sound, .music, .devTools, .aiUsage])
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
        #expect(ToolGroup.productivity.tools.map(\.page) == [.clipboard, .screenRecord, .typing, .commandBar, .snippets, .tools, .island, .files])
        #expect(ToolGroup.developer.tools.map(\.page) == [.devTools, .aiUsage])
    }
}
