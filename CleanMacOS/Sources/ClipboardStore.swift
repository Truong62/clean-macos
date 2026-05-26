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
