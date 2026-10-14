import Foundation

struct TokenFileStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS", isDirectory: true)
            .appendingPathComponent("jira-token")
    }

    func save(_ value: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        delete()
        guard manager.createFile(atPath: fileURL.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
