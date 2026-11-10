import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .windows, .input, .ram, .displays, .portsJobs, .powerRecovery, .keepAwake, .controls,
                               .clipboard, .screenshot, .screenRecord, .typing, .commandBar, .snippets, .tools, .files, .sound, .music, .devTools])
        let productivity = ToolGroup.productivity.tools.map(\.page)
        #expect(productivity.firstIndex(of: .screenshot)! + 1 == productivity.firstIndex(of: .screenRecord)!)
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
    }
}
