import XCTest
@testable import CleanMacOS

@MainActor
final class ClipboardViewModelTests: XCTestCase {
    private func tempStore() -> ClipboardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
        return ClipboardStore(fileURL: url)
    }

    override func setUp() {
        super.setUp()
        // Ensure deterministic settings: persist on, default cap.
        UserDefaults.standard.removeObject(forKey: ClipboardSettings.persistKey)
        UserDefaults.standard.removeObject(forKey: ClipboardSettings.maxItemsKey)
        UserDefaults.standard.removeObject(forKey: ClipboardSettings.skipConcealedKey)
    }

    func testAddUpdatesPublishedItems() {
        let vm = ClipboardViewModel(store: tempStore())
        vm.add("hello")
        XCTAssertEqual(vm.items.map(\.text), ["hello"])
    }

    func testDeleteRemovesItem() {
        let vm = ClipboardViewModel(store: tempStore())
        vm.add("a")
        vm.add("b")
        vm.delete(vm.items[0]) // removes "b"
        XCTAssertEqual(vm.items.map(\.text), ["a"])
    }

    func testClearAllEmpties() {
        let vm = ClipboardViewModel(store: tempStore())
        vm.add("a")
        vm.clearAll()
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testPersistenceSurvivesNewViewModel() {
        let store = tempStore()
        let vm1 = ClipboardViewModel(store: store)
        vm1.add("persisted")
        let vm2 = ClipboardViewModel(store: store)
        XCTAssertEqual(vm2.items.map(\.text), ["persisted"])
    }

    func testPersistOffDeletesFileAndStillHoldsInMemory() {
        let store = tempStore()
        let vm = ClipboardViewModel(store: store)
        vm.add("a")
        UserDefaults.standard.set(false, forKey: ClipboardSettings.persistKey)
        vm.persistenceSettingChanged()
        XCTAssertEqual(vm.items.map(\.text), ["a"])      // still in memory
        XCTAssertTrue(store.load().isEmpty)              // file gone
    }
}
