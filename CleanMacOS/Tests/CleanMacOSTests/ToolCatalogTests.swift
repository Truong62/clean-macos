import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .windows, .switcher, .input, .ram, .displays, .portsJobs, .powerRecovery, .keepAwake, .controls,
                               .clipboard, .screenRecord, .typing, .commandBar, .snippets, .tools, .files, .sound, .music, .devTools, .aiUsage])
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
        #expect(Array(ToolGroup.system.tools.prefix(3).map(\.page)) == [.windows, .switcher, .input])
        #expect(ToolGroup.developer.tools.map(\.page) == [.devTools, .aiUsage])
    }
}
