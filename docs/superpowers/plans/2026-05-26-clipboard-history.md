# Clipboard History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a text clipboard history to Clean macOS — a "Clipboard" tab in the main window (Name / Date / Copy+Delete actions) plus a global hotkey (⌘⇧V) that opens a floating picker and auto-pastes the chosen item into the frontmost app.

**Architecture:** A background `ClipboardMonitor` polls `NSPasteboard.changeCount` every ~0.5s and feeds new text into a `ClipboardViewModel` (`@MainActor ObservableObject`, injected app-wide via `environmentObject`). Pure list logic lives in a testable `ClipboardHistory` struct; JSON persistence lives in a testable `ClipboardStore`. The same view model backs both the in-window tab and an AppKit `NSPanel` opened by a global hotkey. Auto-paste re-activates the previous frontmost app and synthesizes ⌘V via `CGEvent` (requires Accessibility; degrades to copy-only).

**Tech Stack:** Swift 5.9, SwiftUI + AppKit, macOS 14, Swift Package Manager (`swift build` / `swift test`), XcodeGen (`xcodegen generate`), `KeyboardShortcuts` SPM package (Sindre Sorhus).

**Conventions to follow:** ViewModels are `@MainActor final class … : ObservableObject`. Settings sections are `GroupBox` blocks in `SettingsView`. Global helper `formatBytes` exists. New source files go in `CleanMacOS/Sources/`. After adding source files, run `xcodegen generate` so the Xcode project picks them up (`swift build`/`swift test` scan `Sources/` automatically).

**Working directory for all commands:** `CleanMacOS/` (i.e. `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS`).

---

## File Structure

**New source files (`CleanMacOS/Sources/`):**

| File | Responsibility |
|---|---|
| `ClipboardItem.swift` | `ClipboardItem` model (Codable) + pure `ClipboardHistory` struct (dedup/cap logic). |
| `ClipboardSettings.swift` | UserDefaults keys + typed accessors (persist / maxItems / skipConcealed). |
| `ClipboardStore.swift` | JSON load/save/delete of `[ClipboardItem]`; injectable file URL. |
| `ClipboardMonitor.swift` | Timer poll of `NSPasteboard.changeCount`; reports new text on main. |
| `ClipboardViewModel.swift` | `@MainActor ObservableObject`; owns history+store+monitor; copy/delete/clear/persist. |
| `ClipboardHistoryView.swift` | The Clipboard tab UI (Name/Date/Actions table + search + Clear All + empty state). |
| `PasteService.swift` | Accessibility check + synthesize ⌘V + open settings. |
| `GlobalShortcuts.swift` | `KeyboardShortcuts.Name.showClipboardHistory`. |
| `ClipboardPanelView.swift` | SwiftUI content of the floating picker (search + keyboard nav). |
| `ClipboardPanelController.swift` | Owns the `NSPanel`; show/close/toggle; select → copy → paste. |

**New test files (`CleanMacOS/Tests/CleanMacOSTests/`):**

| File | Responsibility |
|---|---|
| `ClipboardHistoryTests.swift` | Dedup, cap, remove, clear, `preview`. |
| `ClipboardStoreTests.swift` | Save→load round-trip; missing file; delete. |
| `ClipboardMonitorTests.swift` | `isCapturable` rules. |
| `ClipboardViewModelTests.swift` | add/copy/delete/clear + persistence toggle. |

**Modified files:**

- `Package.swift` — add `KeyboardShortcuts` dependency + product; add `.testTarget`.
- `project.yml` — add `KeyboardShortcuts` package + dependency.
- `Sources/SidebarView.swift` — add `case clipboard` + sidebar item.
- `Sources/ContentView.swift` — route `.clipboard` → `ClipboardHistoryView`.
- `Sources/CleanMacOSApp.swift` — create + inject `ClipboardViewModel`; start monitor; register hotkey + panel.
- `Sources/SettingsView.swift` — add the Clipboard settings `GroupBox`.
- `README.md` — document the feature, Accessibility requirement, "while app runs".

---

## Task 1: Add the KeyboardShortcuts dependency

**Files:**
- Modify: `CleanMacOS/Package.swift`
- Modify: `CleanMacOS/project.yml`

- [ ] **Step 1: Add the package + product to `Package.swift`**

Replace the entire contents of `CleanMacOS/Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CleanMacOS",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CleanMacOS",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources",
            resources: [
                .process("Assets.xcassets")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "CleanMacOSTests",
            dependencies: ["CleanMacOS"],
            path: "Tests/CleanMacOSTests"
        )
    ]
)
```

- [ ] **Step 2: Add the package to `project.yml`**

In `CleanMacOS/project.yml`, under `packages:` add the KeyboardShortcuts entry so the block reads:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: "2.0.0"
```

And under `targets: CleanMacOS: dependencies:` add the package dependency so the block reads:

```yaml
    dependencies:
      - package: Sparkle
      - package: KeyboardShortcuts
```

- [ ] **Step 3: Create an empty test directory placeholder**

The `.testTarget` references `Tests/CleanMacOSTests`, which must exist for resolution. Create the directory:

Run: `mkdir -p Tests/CleanMacOSTests`

- [ ] **Step 4: Resolve & build to verify the dependency loads**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift package resolve && swift build`
Expected: Resolves `KeyboardShortcuts`, build succeeds (the empty test dir is fine — `swift build` builds only the executable). If `swift build` complains the test target has no sources, that is expected to be silent for `swift build`; it only matters for `swift test` (added next task).

- [ ] **Step 5: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Package.swift CleanMacOS/project.yml
git commit -m "build: add KeyboardShortcuts dependency and test target"
```

---

## Task 2: ClipboardItem model + ClipboardHistory logic (TDD)

**Files:**
- Create: `CleanMacOS/Sources/ClipboardItem.swift`
- Test: `CleanMacOS/Tests/CleanMacOSTests/ClipboardHistoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CleanMacOS/Tests/CleanMacOSTests/ClipboardHistoryTests.swift`:

```swift
import XCTest
@testable import CleanMacOS

final class ClipboardHistoryTests: XCTestCase {
    func testAddInsertsAtTop() {
        var h = ClipboardHistory()
        h.add("first", maxItems: 10)
        h.add("second", maxItems: 10)
        XCTAssertEqual(h.items.map(\.text), ["second", "first"])
    }

    func testAddDuplicateMovesToTopWithoutDuplicating() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.add("b", maxItems: 10)
        h.add("a", maxItems: 10) // duplicate of the bottom item
        XCTAssertEqual(h.items.map(\.text), ["a", "b"])
        XCTAssertEqual(h.items.count, 2)
    }

    func testAddTrimsToMaxItems() {
        var h = ClipboardHistory()
        for i in 1...5 { h.add("item\(i)", maxItems: 3) }
        XCTAssertEqual(h.items.map(\.text), ["item5", "item4", "item3"])
    }

    func testRemoveById() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.add("b", maxItems: 10)
        let idToRemove = h.items[0].id
        h.remove(id: idToRemove)
        XCTAssertEqual(h.items.map(\.text), ["a"])
    }

    func testClear() {
        var h = ClipboardHistory()
        h.add("a", maxItems: 10)
        h.clear()
        XCTAssertTrue(h.items.isEmpty)
    }

    func testPreviewCollapsesWhitespaceAndTruncates() {
        let item = ClipboardItem(text: "line1\nline2\tend")
        XCTAssertEqual(item.preview, "line1 line2 end")
        let long = ClipboardItem(text: String(repeating: "x", count: 200))
        XCTAssertTrue(long.preview.hasSuffix("…"))
        XCTAssertEqual(long.preview.count, 121) // 120 chars + ellipsis
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test`
Expected: Compile failure — `cannot find 'ClipboardHistory'` / `'ClipboardItem' in scope`.

> If `swift test` fails to **link** the executable target itself (not just the missing types), stop and report it: testing an `executableTarget` is supported on Swift 5.9/macOS, but if the toolchain rejects it the fallback is to split the testable types into a small library target. Do not silently skip tests.

- [ ] **Step 3: Implement the model + history**

Create `CleanMacOS/Sources/ClipboardItem.swift`:

```swift
import Foundation

/// A single captured clipboard entry. Text-only for now.
struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    /// Single-line, length-capped preview for the table's Name column.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 120
        guard collapsed.count > maxLen else { return collapsed }
        return String(collapsed.prefix(maxLen)) + "…"
    }
}

/// Pure, UI-free history transformations — easy to unit test.
struct ClipboardHistory: Equatable {
    private(set) var items: [ClipboardItem]

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    /// Insert `text` at the top. If an item with identical text already exists,
    /// move it to the top instead of duplicating. Trim oldest beyond `maxItems`.
    mutating func add(_ text: String, maxItems: Int) {
        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text), at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    mutating func remove(id: ClipboardItem.ID) {
        items.removeAll { $0.id == id }
    }

    mutating func clear() {
        items.removeAll()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test`
Expected: All 6 tests in `ClipboardHistoryTests` PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/ClipboardItem.swift CleanMacOS/Tests/CleanMacOSTests/ClipboardHistoryTests.swift
git commit -m "feat: add ClipboardItem model and ClipboardHistory logic"
```

---

## Task 3: ClipboardStore persistence (TDD)

**Files:**
- Create: `CleanMacOS/Sources/ClipboardStore.swift`
- Test: `CleanMacOS/Tests/CleanMacOSTests/ClipboardStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CleanMacOS/Tests/CleanMacOSTests/ClipboardStoreTests.swift`:

```swift
import XCTest
@testable import CleanMacOS

final class ClipboardStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    func testSaveThenLoadRoundTrips() {
        let store = ClipboardStore(fileURL: tempURL())
        let items = [ClipboardItem(text: "one"), ClipboardItem(text: "two")]
        store.save(items)
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.text), ["one", "two"])
        XCTAssertEqual(loaded.map(\.id), items.map(\.id))
    }

    func testLoadMissingFileReturnsEmpty() {
        let store = ClipboardStore(fileURL: tempURL())
        XCTAssertTrue(store.load().isEmpty)
    }

    func testDeleteRemovesFile() {
        let url = tempURL()
        let store = ClipboardStore(fileURL: url)
        store.save([ClipboardItem(text: "x")])
        XCTAssertFalse(store.load().isEmpty)
        store.delete()
        XCTAssertTrue(store.load().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardStoreTests`
Expected: Compile failure — `cannot find 'ClipboardStore' in scope`.

- [ ] **Step 3: Implement the store**

Create `CleanMacOS/Sources/ClipboardStore.swift`:

```swift
import Foundation

/// Loads and saves clipboard history as JSON. The file URL is injectable for tests;
/// the default lives in Application Support.
struct ClipboardStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CleanMacOS", isDirectory: true)
            self.fileURL = base.appendingPathComponent("clipboard-history.json")
        }
    }

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    func save(_ items: [ClipboardItem]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ClipboardStore save failed: \(error.localizedDescription)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardStoreTests`
Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/ClipboardStore.swift CleanMacOS/Tests/CleanMacOSTests/ClipboardStoreTests.swift
git commit -m "feat: add ClipboardStore JSON persistence"
```

---

## Task 4: ClipboardSettings + ClipboardMonitor (TDD for the capture filter)

**Files:**
- Create: `CleanMacOS/Sources/ClipboardSettings.swift`
- Create: `CleanMacOS/Sources/ClipboardMonitor.swift`
- Test: `CleanMacOS/Tests/CleanMacOSTests/ClipboardMonitorTests.swift`

- [ ] **Step 1: Create the settings accessors**

Create `CleanMacOS/Sources/ClipboardSettings.swift`:

```swift
import Foundation

/// Central UserDefaults keys + typed accessors for clipboard settings.
/// `SettingsView` writes these via @AppStorage using the same string keys.
enum ClipboardSettings {
    static let persistKey = "clipboardPersist"
    static let maxItemsKey = "clipboardMaxItems"
    static let skipConcealedKey = "clipboardSkipConcealed"

    static let defaultMaxItems = 200

    /// Default true (history survives quit) when the key was never set.
    static var persist: Bool {
        UserDefaults.standard.object(forKey: persistKey) as? Bool ?? true
    }

    static var maxItems: Int {
        let v = UserDefaults.standard.integer(forKey: maxItemsKey)
        return v > 0 ? v : defaultMaxItems
    }

    /// Default false (store everything) when the key was never set.
    static var skipConcealed: Bool {
        UserDefaults.standard.bool(forKey: skipConcealedKey)
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `CleanMacOS/Tests/CleanMacOSTests/ClipboardMonitorTests.swift`:

```swift
import XCTest
@testable import CleanMacOS

final class ClipboardMonitorTests: XCTestCase {
    func testIsCapturableRejectsEmptyAndWhitespace() {
        XCTAssertFalse(ClipboardMonitor.isCapturable(""))
        XCTAssertFalse(ClipboardMonitor.isCapturable("   "))
        XCTAssertFalse(ClipboardMonitor.isCapturable("\n\t "))
    }

    func testIsCapturableAcceptsRealText() {
        XCTAssertTrue(ClipboardMonitor.isCapturable("hello"))
        XCTAssertTrue(ClipboardMonitor.isCapturable("  trimmed but real  "))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardMonitorTests`
Expected: Compile failure — `cannot find 'ClipboardMonitor' in scope`.

- [ ] **Step 4: Implement the monitor**

Create `CleanMacOS/Sources/ClipboardMonitor.swift`:

```swift
import AppKit

/// Polls the general pasteboard for new string content and reports it on the main thread.
final class ClipboardMonitor {
    /// Called on the main thread when a new, non-empty string is copied.
    var onNewText: ((String) -> Void)?

    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval

    init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit { timer?.cancel() }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Pure capture rule: ignore empty / whitespace-only strings.
    static func isCapturable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if ClipboardSettings.skipConcealed, isConcealed() { return }
        guard let text = pasteboard.string(forType: .string), Self.isCapturable(text) else { return }
        onNewText?(text)
    }

    /// True when a password manager / transient producer marked the pasteboard.
    private func isConcealed() -> Bool {
        let types = pasteboard.types ?? []
        let flags = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ].map { NSPasteboard.PasteboardType($0) }
        return flags.contains { types.contains($0) }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardMonitorTests`
Expected: Both tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/ClipboardSettings.swift CleanMacOS/Sources/ClipboardMonitor.swift CleanMacOS/Tests/CleanMacOSTests/ClipboardMonitorTests.swift
git commit -m "feat: add ClipboardSettings and ClipboardMonitor"
```

---

## Task 5: ClipboardViewModel (TDD)

**Files:**
- Create: `CleanMacOS/Sources/ClipboardViewModel.swift`
- Test: `CleanMacOS/Tests/CleanMacOSTests/ClipboardViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CleanMacOS/Tests/CleanMacOSTests/ClipboardViewModelTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardViewModelTests`
Expected: Compile failure — `cannot find 'ClipboardViewModel' in scope`.

- [ ] **Step 3: Implement the view model**

Create `CleanMacOS/Sources/ClipboardViewModel.swift`:

```swift
import AppKit
import SwiftUI

/// App-wide clipboard history store. Owns the monitor (background capture),
/// the pure history, and persistence. Injected via `.environmentObject`.
@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private var history: ClipboardHistory
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor

    init(store: ClipboardStore = ClipboardStore(),
         monitor: ClipboardMonitor = ClipboardMonitor()) {
        self.store = store
        self.monitor = monitor
        let loaded = ClipboardSettings.persist ? store.load() : []
        self.history = ClipboardHistory(items: loaded)
        self.items = history.items
        self.monitor.onNewText = { [weak self] text in
            // The monitor's timer runs on the main queue, so we are on main here.
            MainActor.assumeIsolated { self?.add(text) }
        }
    }

    /// Begin background capture. Call once at app launch.
    func startMonitoring() {
        monitor.start()
    }

    /// Insert newly-copied text (called by the monitor; safe to call directly in tests).
    func add(_ text: String) {
        history.add(text, maxItems: ClipboardSettings.maxItems)
        items = history.items
        persistIfEnabled()
    }

    /// Put an item back on the system pasteboard. The next poll dedups it to the top.
    func copy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
    }

    func delete(_ item: ClipboardItem) {
        history.remove(id: item.id)
        items = history.items
        persistIfEnabled()
    }

    func clearAll() {
        history.clear()
        items = history.items
        persistIfEnabled()
    }

    /// Re-apply persistence when the Settings toggle changes.
    func persistenceSettingChanged() {
        if ClipboardSettings.persist {
            store.save(items)
        } else {
            store.delete()
        }
    }

    private func persistIfEnabled() {
        guard ClipboardSettings.persist else { return }
        store.save(items)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test --filter ClipboardViewModelTests`
Expected: All 5 tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test`
Expected: All tests across all 4 test files PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/ClipboardViewModel.swift CleanMacOS/Tests/CleanMacOSTests/ClipboardViewModelTests.swift
git commit -m "feat: add ClipboardViewModel with persistence"
```

---

## Task 6: Clipboard tab UI + wiring (capture works end-to-end in the window)

**Files:**
- Create: `CleanMacOS/Sources/ClipboardHistoryView.swift`
- Modify: `CleanMacOS/Sources/SidebarView.swift`
- Modify: `CleanMacOS/Sources/ContentView.swift`
- Modify: `CleanMacOS/Sources/CleanMacOSApp.swift`

- [ ] **Step 1: Create the tab view**

Create `CleanMacOS/Sources/ClipboardHistoryView.swift`:

```swift
import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    @State private var search = ""
    @State private var showClearConfirm = false

    private var filtered: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if clipboard.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear clipboard history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { clipboard.clearAll() }
        } message: {
            Text("This removes all \(clipboard.items.count) items and cannot be undone.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard History").font(.title2).fontWeight(.bold)
                    Text("\(clipboard.items.count) items — text only (images & files coming soon)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(clipboard.items.isEmpty)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.caption)
                TextField("Search clipboard...", text: $search)
                    .textFieldStyle(.plain).font(.callout)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        }
        .padding(16)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.clipboard").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No clipboard history yet").font(.headline)
            Text("Copy some text and it will show up here.\nImages and files are coming soon.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                HStack {
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("DATE").frame(width: 140, alignment: .leading)
                    Text("ACTIONS").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 24).padding(.vertical, 6)

                ForEach(filtered) { item in
                    ClipboardRow(item: item,
                                 onCopy: { clipboard.copy(item) },
                                 onDelete: { clipboard.delete(item) })
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack {
            Text(item.preview)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 10) {
                Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Delete")
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.gray.opacity(0.1) : .clear))
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
    }
}
```

- [ ] **Step 2: Add the sidebar page**

In `CleanMacOS/Sources/SidebarView.swift`, add a case to the `SidebarPage` enum so it reads:

```swift
enum SidebarPage: Hashable {
    case home
    case largeFiles
    case uninstall
    case clipboard
    case settings
    case about
}
```

Then in `SidebarView.body`, add a sidebar item after the "Uninstall Apps" item (before "Settings"):

```swift
                SidebarItem(icon: "doc.on.clipboard.fill", label: "Clipboard", color: .indigo, isSelected: currentPage == .clipboard) {
                    currentPage = .clipboard
                }
```

- [ ] **Step 3: Route the page**

In `CleanMacOS/Sources/ContentView.swift`, add a case in the `switch currentPage` block (after the `.uninstall` case):

```swift
            case .clipboard:
                ClipboardHistoryView()
```

- [ ] **Step 4: Create, inject, and start the view model in the App**

In `CleanMacOS/Sources/CleanMacOSApp.swift`, add the state object below the existing `@StateObject` lines:

```swift
    @StateObject private var clipboard = ClipboardViewModel()
```

Add `.environmentObject(clipboard)` to the `ContentView()` modifier chain (next to the existing `.environmentObject` calls), and add `clipboard.startMonitoring()` inside the existing `.onAppear { … }` block (after `menuBar.setup(...)`):

```swift
                .environmentObject(clipboard)
```

```swift
                    clipboard.startMonitoring()
```

- [ ] **Step 5: Regenerate the Xcode project and build**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && xcodegen generate && swift build`
Expected: Build succeeds.

- [ ] **Step 6: Manual verification**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift run`
Then:
1. Click the **Clipboard** item in the sidebar — the tab shows the empty state.
2. In another app, copy a few text snippets (⌘C). Within ~1s each appears at the top of the list, newest first.
3. Copy a snippet that's already in the list — it jumps to the top, no duplicate row.
4. Type in the search box — the list filters.
5. Click the **Copy** icon on a row, then ⌘V in another app — that text pastes.
6. Click the **Delete** (trash) icon — the row disappears.
7. Click **Clear All** → confirm → list empties.

Expected: all behaviors as described. Quit the app (⌘Q) when done.

- [ ] **Step 7: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/ClipboardHistoryView.swift CleanMacOS/Sources/SidebarView.swift CleanMacOS/Sources/ContentView.swift CleanMacOS/Sources/CleanMacOSApp.swift CleanMacOS/CleanMacOS.xcodeproj/project.pbxproj
git commit -m "feat: add Clipboard tab with background capture"
```

---

## Task 7: PasteService (Accessibility + synthesize ⌘V)

**Files:**
- Create: `CleanMacOS/Sources/PasteService.swift`

- [ ] **Step 1: Implement the paste service**

Create `CleanMacOS/Sources/PasteService.swift`:

```swift
import AppKit
import ApplicationServices

/// Auto-paste support: checks Accessibility trust and synthesizes ⌘V into the
/// frontmost app. Degrades gracefully — `pasteToFrontmostApp()` returns false
/// (a no-op) when the app is not trusted, leaving the content on the clipboard.
enum PasteService {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Show the system prompt that lets the user add this app to Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Synthesize ⌘V into whatever app is frontmost. Returns false if not trusted.
    @discardableResult
    static func pasteToFrontmostApp() -> Bool {
        guard isAccessibilityTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/PasteService.swift
git commit -m "feat: add PasteService for auto-paste"
```

---

## Task 8: Global hotkey + floating panel (hotkey → pick → auto-paste)

**Files:**
- Create: `CleanMacOS/Sources/GlobalShortcuts.swift`
- Create: `CleanMacOS/Sources/ClipboardPanelView.swift`
- Create: `CleanMacOS/Sources/ClipboardPanelController.swift`
- Modify: `CleanMacOS/Sources/CleanMacOSApp.swift`

- [ ] **Step 1: Define the shortcut name**

Create `CleanMacOS/Sources/GlobalShortcuts.swift`:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default ⌘⇧V; user-customizable in Settings.
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        default: .init(.v, modifiers: [.command, .shift])
    )
}
```

- [ ] **Step 2: Create the panel content view**

Create `CleanMacOS/Sources/ClipboardPanelView.swift`:

```swift
import SwiftUI

/// Searchable, keyboard-navigable list shown in the floating hotkey panel.
struct ClipboardPanelView: View {
    @ObservedObject var clipboard: ClipboardViewModel
    let onSelect: (ClipboardItem) -> Void
    let onCancel: () -> Void

    @State private var search = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { commit() }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                VStack { Spacer(); Text("No items").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Text(item.preview).lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(index == selection ? Color.accentColor.opacity(0.25) : .clear))
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture { selection = index; commit() }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { _, new in
                        withAnimation { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 480, height: 420)
        .onAppear { searchFocused = true; selection = 0 }
        .onChange(of: search) { _, _ in selection = 0 }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = max(0, min(filtered.count - 1, selection + delta))
    }

    private func commit() {
        guard filtered.indices.contains(selection) else { return }
        onSelect(filtered[selection])
    }
}
```

- [ ] **Step 3: Create the panel controller**

Create `CleanMacOS/Sources/ClipboardPanelController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the floating NSPanel for the global hotkey. On select it copies the
/// item, restores the previously-frontmost app, then synthesizes ⌘V.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?
    private let clipboard: ClipboardViewModel

    init(clipboard: ClipboardViewModel) {
        self.clipboard = clipboard
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

        let content = ClipboardPanelView(
            clipboard: clipboard,
            onSelect: { [weak self] item in self?.select(item) },
            onCancel: { [weak self] in self?.close() }
        )

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: content)
        p.delegate = self
        p.center()
        panel = p

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func select(_ item: ClipboardItem) {
        clipboard.copy(item)   // writes to NSPasteboard
        close()
        guard let app = previousApp else { return }
        app.activate()
        // Let the target app become frontmost before pasting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteService.pasteToFrontmostApp() // no-op (copy-only) if not trusted
        }
    }

    // Clear our reference when the user closes the panel via its close button.
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
```

- [ ] **Step 4: Register the hotkey + panel in the App**

In `CleanMacOS/Sources/CleanMacOSApp.swift`, add `import KeyboardShortcuts` at the top (below `import SwiftUI`). Add a panel-controller state property below the `clipboard` state object:

```swift
    @State private var panelController: ClipboardPanelController?
```

Inside the existing `.onAppear { … }` block (after `clipboard.startMonitoring()`), register the hotkey once:

```swift
                    if panelController == nil {
                        let controller = ClipboardPanelController(clipboard: clipboard)
                        panelController = controller
                        KeyboardShortcuts.onKeyUp(for: .showClipboardHistory) {
                            controller.toggle()
                        }
                    }
```

- [ ] **Step 5: Regenerate the Xcode project and build**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && xcodegen generate && swift build`
Expected: Build succeeds.

- [ ] **Step 6: Manual verification**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift run`
Then:
1. Copy a few text snippets so history is non-empty.
2. Switch to another app (e.g. TextEdit) and click into a text field.
3. Press **⌘⇧V** — the floating panel appears centered, search focused.
4. Press **↓ / ↑** to move the highlight; type to filter.
5. **Without** Accessibility granted yet: press **Enter** — the panel closes and the item is on the clipboard; press ⌘V manually to confirm it's there.
6. Grant Accessibility: System Settings → Privacy & Security → Accessibility → enable the running app (for `swift run` this is the `CleanMacOS` binary / your terminal; for a real `.app` it's Clean macOS). Re-run if needed.
7. **With** Accessibility granted: press ⌘⇧V, pick an item, press **Enter** — it auto-pastes into the TextEdit field.
8. Press **Esc** — the panel closes without pasting.

Expected: all behaviors as described. Note in your report whether auto-paste worked under `swift run` (it may require the packaged `.app` to be the trusted process — that's fine, it's verified again in Task 10).

- [ ] **Step 7: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/GlobalShortcuts.swift CleanMacOS/Sources/ClipboardPanelView.swift CleanMacOS/Sources/ClipboardPanelController.swift CleanMacOS/Sources/CleanMacOSApp.swift CleanMacOS/CleanMacOS.xcodeproj/project.pbxproj
git commit -m "feat: add global hotkey and floating clipboard panel"
```

---

## Task 9: Clipboard settings section

**Files:**
- Modify: `CleanMacOS/Sources/SettingsView.swift`

- [ ] **Step 1: Add imports and the clipboard view model**

In `CleanMacOS/Sources/SettingsView.swift`, add `import KeyboardShortcuts` below `import SwiftUI`, and add the environment object + local state to `SettingsView`:

```swift
    @EnvironmentObject var clipboard: ClipboardViewModel
    @AppStorage(ClipboardSettings.persistKey) private var clipboardPersist = true
    @AppStorage(ClipboardSettings.maxItemsKey) private var clipboardMaxItems = ClipboardSettings.defaultMaxItems
    @AppStorage(ClipboardSettings.skipConcealedKey) private var clipboardSkipConcealed = false
    @State private var accessibilityTrusted = PasteService.isAccessibilityTrusted
```

- [ ] **Step 2: Add the Clipboard GroupBox**

In `SettingsView.body`, insert this `GroupBox` after the "Menu Bar settings" `GroupBox` and before the "Update settings" `GroupBox`:

```swift
                // Clipboard settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.indigo.gradient)
                                .font(.title3)
                            Text("Clipboard")
                                .font(.headline)
                        }

                        Divider()

                        Toggle(isOn: $clipboardPersist) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep history after quitting")
                                    .fontWeight(.medium)
                                Text("Save clipboard history to disk so it survives a restart")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: clipboardPersist) { _, _ in
                            clipboard.persistenceSettingChanged()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Maximum items")
                                    .fontWeight(.medium)
                                Text("Oldest items are dropped beyond this count")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $clipboardMaxItems) {
                                Text("50").tag(50)
                                Text("100").tag(100)
                                Text("200").tag(200)
                                Text("500").tag(500)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("History shortcut")
                                    .fontWeight(.medium)
                                Text("Global hotkey to open the clipboard picker")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .showClipboardHistory)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-paste")
                                    .fontWeight(.medium)
                                Text(accessibilityTrusted
                                     ? "Accessibility granted — picks paste automatically"
                                     : "Grant Accessibility to paste the picked item automatically")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if accessibilityTrusted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.callout)
                            } else {
                                Button("Open Accessibility…") {
                                    PasteService.requestAccessibility()
                                    PasteService.openAccessibilitySettings()
                                }
                            }
                        }

                        Toggle(isOn: $clipboardSkipConcealed) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skip passwords")
                                    .fontWeight(.medium)
                                Text("Don't capture clipboard marked private by password managers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }
```

- [ ] **Step 3: Refresh Accessibility status when Settings appears**

Add `.onAppear` to the outer `ScrollView` in `SettingsView.body` (the one wrapping the `VStack`), so the status reflects the current grant:

```swift
        .onAppear { accessibilityTrusted = PasteService.isAccessibilityTrusted }
```

(Place it alongside the existing `.background(Color(nsColor: .windowBackgroundColor))` modifier on the `ScrollView`.)

- [ ] **Step 4: Build to verify it compiles**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift build`
Expected: Build succeeds.

- [ ] **Step 5: Manual verification**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift run`
Then open **Settings** → Clipboard section:
1. Toggle **Keep history after quitting** off, quit, reopen → Clipboard tab is empty. Toggle on, copy items, quit/reopen → items survive.
2. Change **Maximum items** to 50 → after copying >50 items, the oldest drop.
3. Click in the **History shortcut** recorder and set a new combo → it opens the panel; the old combo no longer does.
4. **Auto-paste** row shows "Granted" or an "Open Accessibility…" button correctly.
5. Toggle **Skip passwords** on → copy from a password manager → it is not captured (best-effort; depends on the manager marking the pasteboard).

Expected: all behaviors as described.

- [ ] **Step 6: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/SettingsView.swift
git commit -m "feat: add clipboard settings (persist, cap, hotkey, accessibility, skip passwords)"
```

---

## Task 10: Documentation + final full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the feature in the README**

In `README.md`, add a bullet to the **Features** list (after the "Menu bar + monitoring" bullet):

```markdown
- **Clipboard history** — keeps the text you copy so you can reuse earlier copies; browse them in the **Clipboard** tab or press **⌘⇧V** anywhere to pick one (auto-pastes when Accessibility is granted). History is captured **only while the app is running**; images and files are coming soon.
```

And add a short subsection after the "How cleaning works" section:

```markdown
## Clipboard history

Clean macOS records the text you copy (while it's running) so a new copy no
longer discards the previous one.

- **Clipboard tab** — browse, search, re-copy, or delete past items; **Clear All** wipes the list.
- **Global shortcut** — press **⌘⇧V** (changeable in Settings) anywhere to open a picker; ↑/↓ + Enter selects.
- **Auto-paste** — grant **Accessibility** (System Settings → Privacy & Security → Accessibility) and the picked item is pasted into the frontmost app automatically. Without it, the item is copied and you press ⌘V yourself.
- **Persistence** — on by default; turn off "Keep history after quitting" in Settings to keep history in memory only.
- Only **text** is captured for now (images & files later). It is stored unencrypted at `~/Library/Application Support/CleanMacOS/clipboard-history.json`; enable "Skip passwords" in Settings to ignore clipboard marked private by password managers.
```

- [ ] **Step 2: Run the full test suite**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift test`
Expected: All tests PASS.

- [ ] **Step 3: Full manual checklist (from the spec)**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && swift build -c release && swift run -c release`
Walk the spec's manual checklist end-to-end:
1. Copy several snippets in another app → appear newest-first.
2. Copy a duplicate → moves to top, no second row.
3. Search filters; Clear All empties (after confirm).
4. Row **Copy** → ⌘V in another app pastes it.
5. ⌘⇧V anywhere → panel opens, ↑↓ + Enter selects.
6. With Accessibility granted → selection auto-pastes into the frontmost app.
7. Without Accessibility → selection copies only.
8. Persist off → quit/reopen → empty; on → survives.
9. Change the hotkey → new one works, old one doesn't.

Expected: every item passes. Record any deviations in your report.

- [ ] **Step 4: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add README.md
git commit -m "docs: document clipboard history feature"
```

---

## Notes for the executor

- **Do not bump the app version or touch the appcast** — releasing is a separate, manual process (see README). This plan ships the feature on a branch only.
- **`@AppStorage` ↔ `ClipboardSettings` contract:** both use the same string keys (`clipboardPersist`, `clipboardMaxItems`, `clipboardSkipConcealed`). `SettingsView` writes via `@AppStorage`; `ClipboardViewModel`/`ClipboardMonitor` read via `ClipboardSettings`. Keep the defaults consistent: persist=true, maxItems=200, skipConcealed=false.
- **Monitor threading:** `ClipboardMonitor`'s timer runs on the main queue, so its `onNewText` callback is on the main thread; that's why `ClipboardViewModel` uses `MainActor.assumeIsolated`. Don't move the timer to a background queue without revisiting this.
- **Auto-paste under `swift run`:** the trusted process is the binary that runs, which under `swift run` may be your terminal rather than "Clean macOS". Auto-paste is most reliably verified from the packaged `.app` (Task 10, or via `scripts/package.sh`). Copy-only fallback always works.
```
