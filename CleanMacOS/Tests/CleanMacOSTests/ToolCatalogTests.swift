import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .ram, .displays, .portsJobs, .powerRecovery,
                               .clipboard, .screenRecord, .typing, .music, .devTools])
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
    }
}
