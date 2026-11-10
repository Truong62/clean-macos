import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .appUpdates, .windows, .input, .ram, .displays, .portsJobs, .powerRecovery, .keepAwake,
                               .controls, .clipboard, .screenRecord, .typing, .commandBar, .snippets, .tools, .files, .sound, .music, .devTools, .homebrew])
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
    }

    @Test func homebrewAndAppUpdatesSitRightAfterTheirNeighbours() {
        #expect(ToolGroup.clean.tools.map(\.page) == [.cleanDisk, .largeFiles, .uninstall, .appUpdates])
        #expect(ToolGroup.developer.tools.map(\.page) == [.devTools, .homebrew])
        #expect(ToolGroup.allTools.first { $0.page == .homebrew }?.title == "Homebrew")
        #expect(ToolGroup.allTools.first { $0.page == .appUpdates }?.title == "App Updates")
    }
}
