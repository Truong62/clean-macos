import Foundation

enum DevToolKind: String, CaseIterable, Identifiable, Sendable {
    case runtime = "Runtimes"
    case homebrew = "Homebrew"
    case package = "Global Packages"

    var id: String { rawValue }
}

enum DevToolRemoval: Hashable, Sendable {
    case trash(String)
    case command(path: String, arguments: [String])
    case unavailable(String)
}

struct DevTool: Identifiable, Hashable, Sendable {
    let name: String
    let version: String
    let source: String
    let path: String
    let kind: DevToolKind
    var summary = ""
    var homepage: URL?
    var note: String?
    var isDependency = false
    var isActive = false
    let removal: DevToolRemoval

    var id: String { "\(kind.rawValue)|\(source)|\(name)|\(path)" }
    var canRemove: Bool {
        if case .unavailable = removal { return false }
        return true
    }
}

enum DevToolVersion {
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    static func sortedByNameThenNewest(_ tools: [DevTool]) -> [DevTool] {
        tools.sorted { lhs, rhs in
            lhs.name == rhs.name ? isOrderedBefore(rhs.version, lhs.version) : lhs.name.lowercased() < rhs.name.lowercased()
        }
    }
}
