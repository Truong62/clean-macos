import Testing
@testable import CleanMacOS

struct ToolCatalogTests {
    @Test func everyToolAppearsOnceInExactlyOneGroup() {
        let pages = ToolGroup.allTools.map(\.page)
        #expect(Set(pages).count == pages.count)
        #expect(Set(pages) == [.cleanDisk, .largeFiles, .uninstall, .appUpdates, .windows, .switcher, .input, .ram, .monitor, .displays, .portsJobs, .powerRecovery,
                               .keepAwake, .controls, .clipboard, .screenshot, .screenRecord, .typing, .commandBar, .snippets, .tools, .island, .files, .sound, .music, .mediaTools,
                               .devTools, .homebrew, .aiUsage])
        #expect(ToolGroup.media.tools.map(\.page) == [.sound, .music, .mediaTools])
        let productivity = ToolGroup.productivity.tools.map(\.page)
        #expect(productivity.firstIndex(of: .screenshot)! + 1 == productivity.firstIndex(of: .screenRecord)!)
        #expect(ToolGroup.allCases.allSatisfy { !$0.tools.isEmpty })
        #expect(Array(ToolGroup.system.tools.prefix(3).map(\.page)) == [.windows, .switcher, .input])
        #expect(ToolGroup.productivity.tools.map(\.page).firstIndex(of: .island) == ToolGroup.productivity.tools.map(\.page).firstIndex(of: .tools).map { $0 + 1 })
        #expect(ToolGroup.developer.tools.map(\.page) == [.devTools, .homebrew, .aiUsage])
    }

    @Test func monitorFollowsRAMInTheSystemGroup() {
        let pages = ToolGroup.system.tools.map(\.page)
        #expect(pages.firstIndex(of: .monitor) == pages.firstIndex(of: .ram).map { $0 + 1 })
    }

    @Test func homebrewAndAppUpdatesSitRightAfterTheirNeighbours() {
        #expect(ToolGroup.clean.tools.map(\.page) == [.cleanDisk, .largeFiles, .uninstall, .appUpdates])
        #expect(ToolGroup.developer.tools.map(\.page).prefix(2) == [.devTools, .homebrew])
        #expect(ToolGroup.allTools.first { $0.page == .homebrew }?.title == "Homebrew")
        #expect(ToolGroup.allTools.first { $0.page == .appUpdates }?.title == "App Updates")
    }
}
