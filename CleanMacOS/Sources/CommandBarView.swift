import KeyboardShortcuts
import SwiftUI

struct CommandBarView: View {
    static let iconSize: CGFloat = 30

    @ObservedObject var bar: CommandBarController
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Search apps, actions, settings or type a sum", text: $bar.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CommandCategory.allCases) { category in
                        Button(category.title) { bar.category = category }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(bar.category == category ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)
            Divider()
            list
            Divider()
            Text("↩ open · ⌘↩ show in Finder · ⌘K actions · ⌘1–9 · tab completes · ⌘P pins · : emoji · esc")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .frame(width: CommandBarController.size.width, height: CommandBarController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .bottomTrailing) { if !bar.rowActions.isEmpty { rowActionsMenu } }
        .onAppear { DispatchQueue.main.async { isFocused = true } }
    }

    private var rowActionsMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(bar.rowActions.enumerated()), id: \.element.id) { index, action in
                Label(action.title, systemImage: action.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(index == bar.actionSelection ? Color.accentColor.opacity(0.25) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { bar.runRowAction(action) }
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .padding(.trailing, 14)
        .padding(.bottom, 34)
    }

    private var list: some View {
        Group {
            if bar.rows.isEmpty {
                Text(bar.query.isEmpty ? "Nothing here yet" : "No matches · Return clears").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(bar.rows.enumerated()), id: \.element.id) { index, row in
                                CommandRowView(row: row, index: index, isSelected: index == bar.selection, isConfirming: isConfirming(row),
                                               isPinned: bar.isPinned(row))
                                    .id(row.id)
                                    .onTapGesture { bar.run(index) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: bar.selection) { _, selection in
                        guard bar.rows.indices.contains(selection) else { return }
                        proxy.scrollTo(bar.rows[selection].id)
                    }
                }
            }
        }
    }

    private func isConfirming(_ row: CommandRow) -> Bool {
        if case .item(let item, _) = row { return bar.confirming == item.id }
        return false
    }
}

private struct CommandRowView: View {
    let row: CommandRow
    let index: Int
    let isSelected: Bool
    let isConfirming: Bool
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: CommandBarView.iconSize, height: CommandBarView.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).lineLimit(1)
                    if isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    if isActive { Circle().fill(Color.green).frame(width: 6, height: 6) }
                }
                Text(isConfirming ? "Press Return again to do this" : subtitle)
                    .font(.caption)
                    .foregroundStyle(isConfirming ? Color.orange : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let trailing { Text(trailing).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if index < PanelKeys.digitKeys.count { Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            if isSelected { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private var title: String {
        switch row {
        case .answer(let answer): answer.title
        case .link(let link, let text): text.isEmpty ? "Open \(link.name)" : "Search \(link.name) for “\(text)”"
        case .item(let item, let argument): argument.map { "\(item.title) to \($0)%" } ?? item.title
        }
    }

    private var subtitle: String {
        switch row {
        case .answer(let answer): answer.detail
        case .link(let link, _): link.template
        case .item(let item, _): item.subtitle
        }
    }

    private var trailing: String? {
        switch row {
        case .answer: "Return copies"
        case .link: nil
        case .item(let item, _): item.shortcut
        }
    }

    private var isActive: Bool {
        if case .item(let item, _) = row { return item.isActive }
        return false
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .answer(let answer):
            Image(systemName: answer.kind == .link ? "safari" : answer.kind == .color ? "paintpalette" : "equal.circle")
                .font(.system(size: 18)).foregroundStyle(Color.accentColor)
        case .link:
            Image(systemName: "link").font(.system(size: 18)).foregroundStyle(Color.accentColor)
        case .item(let item, _):
            switch item.icon {
            case .symbol(let name): Image(systemName: name).font(.system(size: 17)).foregroundStyle(.secondary)
            case .file(let path): Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
            case .text(let glyph): Text(glyph).font(.system(size: 20))
            }
        }
    }
}

struct CommandBarSettingsView: View {
    @EnvironmentObject var bar: CommandBarController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "command", title: "Command Bar", subtitle: "Open apps, run actions, find settings, calculate and convert. Also a radial menu and a quick panel.",
                           colors: [.indigo, .purple])
                SecureInputStatusCard()
                CardSection(title: "Opening", icon: "keyboard") {
                    Toggle("Open the Command Bar with a shortcut", isOn: $bar.settings.isEnabled)
                    if bar.settings.isEnabled {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .commandBar)
                        }
                    }
                    HStack {
                        Text("Try it now")
                        Spacer()
                        Button("Open Command Bar") { bar.open() }
                    }
                }
                CardSection(title: "What it searches", icon: "magnifyingglass") {
                    Text("Apps, MacKit's actions and pages, System Settings panes and common folders are always searched.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Open windows", isOn: $bar.settings.searchesWindows)
                    Toggle("Menu commands of the app in front", isOn: $bar.settings.searchesMenus)
                    Toggle("Snippets", isOn: $bar.settings.searchesSnippets)
                    Toggle("Clipboard history", isOn: $bar.settings.searchesClipboard)
                    Text("Try “2(3+4)^2”, “15% of 80”, “100 km to mi”, “#ff8800”, “time in tokyo”, “in 3 weeks” or “volume 40”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Links", icon: "link") {
                    Text("Type the keyword, a space and your text. Use {query}, {clipboard}, {selection} and {date} in the address.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($bar.settings.links) { $link in
                        HStack {
                            TextField("Name", text: $link.name).frame(width: 110)
                            TextField("Keyword", text: $link.keyword).frame(width: 70)
                            TextField("https://example.com/search?q={query}", text: $link.template)
                            Button { bar.settings.links.removeAll { $0.id == link.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    Button { bar.settings.links.append(CommandLink(name: "Google", keyword: "g", template: "https://www.google.com/search?q={query}")) } label: {
                        Label("Add Link", systemImage: "plus")
                    }
                }
                CardSection(title: "Files", icon: "doc.text.magnifyingglass") {
                    Text("Find files by name with Spotlight, only inside the folders you add here. Hidden files, app bundles and build folders are skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(bar.settings.fileFolders, id: \.self) { folder in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder)).resizable().frame(width: 18, height: 18)
                            Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { bar.settings.fileFolders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button { addFileFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                }
                LauncherSettingsCards()
                CardSection(title: "Ranking", icon: "chart.bar") {
                    HStack {
                        Text("Results you pick often move up, and what you type is remembered only as hashed prefixes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Ranking") { bar.resetRanking() }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func addFileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !bar.settings.fileFolders.contains($0) }
        bar.settings.fileFolders += added
    }
}
