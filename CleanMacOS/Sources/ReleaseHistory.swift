import SwiftUI

struct ReleaseNote: Identifiable, Equatable {
    let version: String
    let date: Date?
    let items: [String]

    var id: String { version }
}

enum ReleaseFeed {
    private static let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parse(_ data: Data) -> [ReleaseNote] {
        let collector = FeedCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return collector.items.compactMap { fields in
            guard let version = fields["sparkle:shortVersionString"], !version.isEmpty else { return nil }
            return ReleaseNote(version: version, date: fields["pubDate"].flatMap(dateFormatter.date(from:)),
                               items: bulletItems(fromHTML: fields["description"] ?? ""))
        }
    }

    static func bulletItems(fromHTML html: String) -> [String] {
        let listItems = html.matches(of: #/(?s)<li>(.*?)</li>/#).map { String($0.1) }
        return (listItems.isEmpty ? [html] : listItems).map(plainText).filter { !$0.isEmpty }
    }

    static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private static func plainText(_ html: String) -> String {
        let stripped = entities.reduce(html.replacing(#/<[^>]+>/#, with: " ")) {
            $0.replacingOccurrences(of: $1.key, with: $1.value)
        }
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private final class FeedCollector: NSObject, XMLParserDelegate {
        private static let itemFields: Set<String> = ["sparkle:shortVersionString", "pubDate", "description"]

        var items: [[String: String]] = []
        private var current: [String: String]?
        private var element = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            element = elementName
            if elementName == "item" { current = [:] }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "item", let current { items.append(current.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
            if elementName == "item" { current = nil }
            element = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func append(_ text: String) {
            guard current != nil, Self.itemFields.contains(element) else { return }
            current?[element, default: ""] += text
        }
    }
}

@MainActor
final class ReleaseHistoryViewModel: ObservableObject {
    @Published private(set) var notes: [ReleaseNote] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    let currentVersion: String
    private let feedURL: URL?

    init(feedURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)),
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.feedURL = feedURL
        self.currentVersion = currentVersion
    }

    func load() async {
        guard let feedURL else {
            error = "Release history is only available in the installed app"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
            let (data, _) = try await URLSession.shared.data(for: request)
            notes = ReleaseFeed.parse(data)
            error = notes.isEmpty ? "No releases found" : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReleaseHistoryButton: View {
    @StateObject private var history = ReleaseHistoryViewModel()
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                Text(history.currentVersion.isEmpty ? "Release history" : "Version \(history.currentVersion)")
                    .font(.caption).fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(isShowing ? 0.1 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Release history")
        .popover(isPresented: $isShowing, arrowEdge: .trailing) { ReleaseHistoryView(history: history) }
    }
}

struct ReleaseHistoryView: View {
    @ObservedObject var history: ReleaseHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Release history").font(.headline)
                Spacer()
                if history.isLoading, !history.notes.isEmpty { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { if history.notes.isEmpty { await history.load() } }
    }

    static let size = CGSize(width: 380, height: 520)

    @ViewBuilder
    private var content: some View {
        if !history.notes.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(history.notes) { note in ReleaseNoteRow(note: note, currentVersion: history.currentVersion) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
        } else if let error = history.error {
            VStack(spacing: 8) {
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await history.load() } }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Loading releases…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ReleaseNoteRow: View {
    let note: ReleaseNote
    let currentVersion: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(note.version).font(.system(size: 13, weight: .semibold, design: .rounded))
                if note.version == currentVersion { badge("Current", .orange) }
                if ReleaseFeed.isNewer(note.version, than: currentVersion), !currentVersion.isEmpty { badge("New", .green) }
                Spacer()
                if let date = note.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(note.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.orange)
                    Text(item).font(.callout).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
