import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IslandFilePolicy {
    static func media(_ urls: [URL]) -> MediaTab? {
        guard !urls.isEmpty else { return nil }
        if urls.allSatisfy(MediaTab.images.accepts) { return .images }
        if urls.count == 1 && MediaTab.video.accepts(urls[0]) { return .video }
        return nil
    }

    static func archiveDestination(input: URL, folder: URL, exists: (URL) -> Bool) throws -> URL {
        let source = input.resolvingSymlinksInPath().standardizedFileURL
        let directory = folder.resolvingSymlinksInPath().standardizedFileURL
        guard directory.path != source.path, !directory.path.hasPrefix(source.path + "/") else {
            throw MediaToolError.message("Choose a folder outside the input item.")
        }
        let output = directory.appendingPathComponent(input.lastPathComponent + ".zip")
        guard !exists(output) else { throw MediaToolError.message("\(output.lastPathComponent) already exists.") }
        return output
    }
}

@MainActor
final class IslandFileTools: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private let shelf: ShelfController

    init(shelf: ShelfController) { self.shelf = shelf }

    func cancel() { task?.cancel() }

    func optimize(_ urls: [URL]) {
        guard !busy else { return }
        guard let tab = IslandFilePolicy.media(urls) else { status = "Drop images or one video to optimize."; return }
        let settings = UserDefaults.standard.data(forKey: MediaToolsController.settingsKey).flatMap { try? JSONDecoder().decode(MediaToolSettings.self, from: $0) } ?? MediaToolSettings()
        busy = true
        status = "Optimizing…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await MediaJobs.run(tab, files: urls, settings: settings, trim: ClipTrim()) { [weak self] _, message in
                    Task { @MainActor in self?.status = message }
                }
                try Task.checkCancellation()
                shelf.add(result.outputs.map { ShelfItem(kind: .file, path: $0.path) })
                status = result.failures.isEmpty ? "Added \(result.outputs.count) optimized files" : result.failures.joined(separator: "\n")
            } catch { status = Task.isCancelled ? "Cancelled" : error.localizedDescription }
        }
    }

    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !providers.isEmpty else { return false }
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard supported.count == providers.count else { status = "Drop local media files to optimize."; return false }
        busy = true
        status = "Reading files…"
        task = Task {
            var urls: [URL] = []
            for provider in supported {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            busy = false
            guard !Task.isCancelled, urls.count == supported.count else { status = "Could not read the dropped files."; return }
            optimize(urls)
        }
        return true
    }

    func archive(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Save Archives Here"
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        busy = true
        status = "Creating archives…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                var outputs: [URL] = []
                for input in urls {
                    try Task.checkCancellation()
                    let destination = try IslandFilePolicy.archiveDestination(input: input, folder: folder) { FileManager.default.fileExists(atPath: $0.path) }
                    let scratch = try MediaFiles.scratchFile(near: folder, ext: "zip")
                    defer { MediaFiles.discard(scratch) }
                    let result = try await CommandRunner.stream("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, scratch.path], terminationGrace: 0.5) { _ in }
                    guard result.status == 0 else { throw MediaToolError.message("Could not archive \(input.lastPathComponent).") }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: scratch, to: destination)
                    outputs.append(destination)
                    shelf.add([ShelfItem(kind: .file, path: destination.path)])
                }
                status = "Created \(outputs.count) archives"
            } catch { status = Task.isCancelled ? "Cancelled" : error.localizedDescription }
        }
    }
}

struct IslandShareButton: NSViewRepresentable {
    var items: [ShelfItem]
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.isEnabled = !items.isEmpty
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var items: [ShelfItem] = []
        @objc func share(_ sender: NSButton) {
            let objects: [Any] = items.map { item in
                if let url = item.fileURL ?? item.link.flatMap(URL.init(string:)) { return url }
                return item.text ?? ""
            }
            NSSharingServicePicker(items: objects).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct IslandFilesView: View {
    @ObservedObject var shelf: ShelfController
    @ObservedObject var tools: IslandFileTools
    @State private var confirmsClear = false
    var selected: [ShelfItem] { shelf.items.filter { shelf.selection.ids.contains($0.id) } }
    var targets: [ShelfItem] { selected.isEmpty ? shelf.items : selected }

    var body: some View {
        VStack {
            if !shelf.settings.isEnabled { Button("Enable Files Shelf") { shelf.settings.isEnabled = true } }
            else {
                HStack {
                    IslandShareButton(items: targets).frame(width: 80)
                    Button("ZIP…") { tools.archive(targets.compactMap(\.fileURL)) }.disabled(tools.busy || targets.compactMap(\.fileURL).isEmpty)
                    Button("Remove") { shelf.remove(shelf.selection.ids) }.disabled(selected.isEmpty)
                    Button("Clear…") { confirmsClear = true }.disabled(shelf.items.isEmpty)
                }
                if shelf.items.isEmpty { Text("Drop files, images, links or text here").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))]) {
                        ForEach(shelf.items) { ShelfTile(item: $0, controller: shelf) }
                    }
                }
                HStack {
                    Text(tools.status).font(.caption).lineLimit(2)
                    if tools.busy { Button("Cancel") { tools.cancel() } }
                }
            }
        }.confirmationDialog("Clear the shelf? Pinned items stay.", isPresented: $confirmsClear) {
            Button("Clear Shelf", role: .destructive) { shelf.selection.clear(); shelf.removeSelectedOrAll() }
        }
    }
}
