import Foundation

struct JiraNavItem: Equatable {
    let id: String
    let label: String
    let count: Int?
}

struct JiraNav: Equatable {
    var list = ""
    var view = ""
    var lists: [JiraNavItem] = []
    var views: [JiraNavItem] = []

    init() {}

    init?(message: Any) {
        guard let body = message as? [String: Any] else { return nil }
        list = body["list"] as? String ?? ""
        view = body["view"] as? String ?? ""
        lists = Self.items(body["lists"])
        views = Self.items(body["views"])
    }

    private static func items(_ value: Any?) -> [JiraNavItem] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return JiraNavItem(id: id, label: item["label"] as? String ?? id, count: item["count"] as? Int)
        }
    }
}

struct JiraNavRequest: Equatable {
    let id: Int
    let list: String?
    let view: String?

    var script: String {
        let payload = ["list": list, "view": view].compactMapValues { $0 }
        let json = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "void window.jiraSetNav?.(\(json))"
    }
}
