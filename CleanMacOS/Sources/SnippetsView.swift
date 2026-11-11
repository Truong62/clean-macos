import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject var expander: SnippetExpander
    @State private var editing: Snippet?
    @State private var search = ""

    private var filtered: [Snippet] {
        let words = ClipboardSearch.normalize(search).split(whereSeparator: \.isWhitespace).map(String.init)
        return expander.snippets
            .filter { snippet in
                let haystack = ClipboardSearch.normalize([snippet.name, snippet.trigger, snippet.text, snippet.folder].joined(separator: " "))
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "text.badge.plus", title: "Snippets", subtitle: "Type a short trigger and it turns into longer text.",
                           colors: [.orange, .pink])
                if !AXIsProcessTrusted() {
                    AccessibilityNotice(text: "Snippets need Accessibility access for \(AppIdentity.installedName).")
                }
                SecureInputStatusCard()
                CardSection(title: "Expansion", icon: "keyboard") {
                    Toggle("Expand snippets as you type", isOn: $expander.settings.expandsWhileTyping)
                    HStack {
                        Toggle("Play a sound", isOn: $expander.settings.playsSound)
                        Picker("", selection: $expander.settings.soundName) {
                            ForEach(SnippetExpander.sounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled(!expander.settings.playsSound)
                        .onChange(of: expander.settings.soundName) { _, name in NSSound(named: NSSound.Name(name))?.play() }
                    }
                    if IsSecureEventInputEnabled() {
                        Label("A password field has Secure Input on, so snippets wait until it closes.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Snippets set to expand after a delimiter fire when you press Space, Tab or Return, and that key is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Library", icon: "list.bullet.rectangle") {
                    Toggle("Open the snippet library with a shortcut", isOn: $expander.settings.libraryEnabled)
                    if expander.settings.libraryEnabled {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .snippetLibrary)
                        }
                    }
                    Text("Pick a snippet with ↑ ↓ and Return, or press ⌘1–⌘9.").font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Your snippets", icon: "text.quote") {
                    HStack {
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Spacer()
                        Button { editing = Snippet() } label: { Label("Add Snippet", systemImage: "plus") }
                    }
                    if expander.snippets.isEmpty {
                        Text("No snippets yet. Add one like ;;addr for your address, or ;;today with {{date}} for today's date.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { snippet in
                        SnippetRow(snippet: snippet,
                                   onToggle: { expander.setEnabled(snippet, $0) },
                                   onEdit: { editing = snippet },
                                   onDelete: { expander.delete(snippet) })
                        Divider()
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet, others: expander.snippets) { expander.save($0) }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: onToggle)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snippet.title).fontWeight(.medium)
                    TriggerBadge(trigger: snippet.trigger)
                    if !snippet.folder.isEmpty { Text(snippet.folder).font(.caption).foregroundStyle(.secondary) }
                }
                Text(snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(snippet.mode == .immediately ? "Right away" : "After a space").font(.caption).foregroundStyle(.tertiary)
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.red).help("Delete")
        }
        .opacity(snippet.isEnabled ? 1 : 0.55)
    }
}

struct TriggerBadge: View {
    let trigger: String

    var body: some View {
        Text(trigger)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

struct SnippetEditor: View {
    static let variables: [(title: String, tag: String)] = [
        ("Date", "{{date}}"),
        ("Time", "{{time}}"),
        ("Date and time", "{{datetime}}"),
        ("Date as 2026-11-10", "{{date:yyyy-MM-dd}}"),
        ("Time as 14:30", "{{time:HH:mm}}"),
        ("ISO 8601 timestamp", "{{datetime:yyyy-MM-dd'T'HH:mm:ssXXXXX}}"),
        ("Clipboard", "{{clipboard}}"),
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet
    let others: [Snippet]
    let onSave: (Snippet) -> Void

    init(snippet: Snippet, others: [Snippet], onSave: @escaping (Snippet) -> Void) {
        _snippet = State(initialValue: snippet)
        self.others = others
        self.onSave = onSave
    }

    private var problem: SnippetLibrary.Problem? { SnippetLibrary.problem(with: snippet, among: others) }
    private var isNew: Bool { !others.contains { $0.id == snippet.id } }
    private var preview: String {
        SnippetTemplate.render(snippet.text, now: Date(), locale: .current, timeZone: .current) { "‹clipboard›" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Name (optional)", text: $snippet.name).textFieldStyle(.roundedBorder)
            TextField("Trigger, like ;;addr", text: $snippet.trigger).textFieldStyle(.roundedBorder).font(.body.monospaced())
            HStack {
                Text("Text")
                Spacer()
                Menu("Insert") {
                    ForEach(Self.variables, id: \.tag) { variable in
                        Button(variable.title) { snippet.text += variable.tag }
                    }
                }
                .fixedSize()
            }
            TextEditor(text: $snippet.text)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Picker("Expands", selection: $snippet.mode) {
                ForEach(Snippet.Mode.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 360)
            Toggle("Match upper and lower case alike", isOn: $snippet.ignoresCase)
            TextField("Folder (optional)", text: $snippet.folder).textFieldStyle(.roundedBorder)
            Toggle("Show in the library", isOn: $snippet.showsInLibrary)
            GroupBox("Preview") {
                Text(preview.isEmpty ? " " : preview)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let problem {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(snippet)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct SnippetLibraryView: View {
    @ObservedObject var model: SnippetLibraryModel
    @ObservedObject var expander: SnippetExpander
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let sections = model.sections
        let visible = sections.flatMap(\.snippets)
        let indexes = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search snippets", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            Divider()
            if visible.isEmpty {
                Text(expander.snippets.isEmpty ? "No snippets yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.folder) { section in
                                if !section.folder.isEmpty {
                                    Text(section.folder.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
                                        .padding(.horizontal, 10).padding(.top, 6)
                                }
                                ForEach(section.snippets) { snippet in
                                    row(snippet, index: indexes[snippet.id] ?? 0)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) { _, selection in
                        guard visible.indices.contains(selection) else { return }
                        withAnimation { proxy.scrollTo(visible[selection].id, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack {
                Text("↩ inserts · esc closes").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Manage Snippets") {
                    model.onClose?()
                    MainWindowController.show()
                    NotificationCenter.default.post(name: .openSidebarPage, object: SidebarPage.snippets)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: SnippetLibraryController.size.width, height: SnippetLibraryController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { DispatchQueue.main.async { isSearchFocused = true } }
    }

    private func row(_ snippet: Snippet, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.title).fontWeight(.medium).lineLimit(1)
                    TriggerBadge(trigger: snippet.trigger)
                }
                Text(snippet.text.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if index < PanelKeys.digitKeys.count {
                Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(index == model.selection ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .id(snippet.id)
        .onHover { if $0 { model.selection = index } }
        .onTapGesture { model.onInsert?(snippet) }
    }
}
