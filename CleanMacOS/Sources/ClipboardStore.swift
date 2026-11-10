import Foundation

struct ClipboardStore {
    static let imagesFolder = "ClipboardImages"
    static let filePermissions = 0o600
    static let folderPermissions = 0o700

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

    var imagesURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.imagesFolder, isDirectory: true)
    }

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    func save(_ items: [ClipboardItem]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("ClipboardStore.save failed for \(fileURL.path): \(error.localizedDescription)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func imageURL(named name: String) -> URL {
        imagesURL.appendingPathComponent(name)
    }

    func saveImage(_ data: Data, named name: String) -> Bool {
        let url = imageURL(named: name)
        do {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Self.folderPermissions])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("ClipboardStore.saveImage failed for \(name): \(error.localizedDescription)")
            return false
        }
    }

    func removeImages(except names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesURL.path)) ?? []
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: imageURL(named: file))
        }
    }
}
