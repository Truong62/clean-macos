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
