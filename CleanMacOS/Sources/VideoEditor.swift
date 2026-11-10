import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VideoEditors: ObservableObject {
    private var windows: [UUID: VideoEditorWindow] = [:]
    let studio: RecordingStudio

    init(studio: RecordingStudio) { self.studio = studio }

    func chooseMovie() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let folder = try VideoTakeFiles.create(in: RecordingStudio.root)
                let master = folder.appendingPathComponent("master.\(url.pathExtension)")
                try FileManager.default.copyItem(at: url, to: master)
                await open(master, tracks: VideoTracks())
            } catch { studio.notify(error.localizedDescription) }
        }
    }

    func open(_ master: URL, tracks: VideoTracks) async {
        do {
            let model = try await VideoEditorModel(master: master, tracks: tracks, settings: studio.settings, folder: studio.saveFolder)
            model.saved = { [weak self] url in self?.studio.saved?(url) }
            let id = UUID()
            let window = VideoEditorWindow(model: model)
            window.closed = { [weak self] in self?.windows[id] = nil }
            windows[id] = window
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
        } catch { studio.notify("Could not open video: \(error.localizedDescription)") }
    }
}

@MainActor
final class VideoEditorModel: ObservableObject {
    let master: URL
    let tracks: VideoTracks
    let total: Double
    let player = AVPlayer()
    let folder: URL
    @Published private(set) var document: VideoEditDocument
    @Published private(set) var history = VideoEditHistory()
    @Published var playhead = 0.0
    @Published var selection: UUID?
    @Published var selectedCut: VideoSpan?
    @Published var thumbnails: [NSImage] = []
    @Published var waveforms: [[Float]] = []
    @Published var progress: Double?
    @Published var error: String?
    @Published var savedURL: URL?
    @Published var previewSize = CGSize(width: 16, height: 9)
    @Published var presets: [VideoPreset] = []
    var requestClose: (() -> Void)?
    var saved: ((URL) -> Void)?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var observer: Any?
    private var gestureBase: VideoEditDocument?
    private var closing = false
    private let hud = InputHUD()

    init(master: URL, tracks: VideoTracks, settings: RecorderSettings, folder: URL) async throws {
        self.master = master
        self.tracks = tracks
        self.folder = folder
        let asset = AVURLAsset(url: master)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.2 else { throw RecordingError.failed("The movie must contain at least 0.2 seconds of video.") }
        total = duration
        let url = master.deletingLastPathComponent().appendingPathComponent("edit.json")
        var document = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(VideoEditDocument.self, from: $0) }
            ?? VideoEditDocument(trim: VideoSpan(start: 0, end: duration))
        document.trim.start = min(max(0, document.trim.start), duration - 0.2)
        document.trim.end = min(duration, max(document.trim.start + 0.2, document.trim.end))
        if document.duration < 0.19999 { document.cuts = [] }
        if !FileManager.default.fileExists(atPath: url.path) {
            document.quality = settings.quality
            document.gifFPS = Double(settings.gifFPS)
            document.pointer = settings.pointer
            if settings.automaticZooms { document.zooms = VideoTimeline.automatic(clicks: tracks.clicks, typing: tracks.typing, duration: duration, holdsTyping: false) }
            document.volumes = Array(repeating: 1, count: try await asset.loadTracks(withMediaType: .audio).count)
        }
        self.document = document
        presets = UserDefaults.standard.data(forKey: "video.presets").flatMap { try? JSONDecoder().decode([VideoPreset].self, from: $0) } ?? []
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playhead = VideoTimeline.sourceTime(time.seconds, pieces: self.document.pieces)
            }
        }
        persist()
        rebuild()
        Task { [weak self] in
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            for track in audio {
                let peaks = (try? await VideoWaveform.read(track, asset: asset, duration: duration)) ?? []
                self?.waveforms.append(peaks)
            }
        }
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            for index in 0..<14 {
                guard let self else { return }
                if let image = try? await generator.image(at: CMTime(seconds: duration * Double(index) / 14, preferredTimescale: 600)).image {
                    self.thumbnails.append(NSImage(cgImage: image, size: .zero))
                }
            }
        }
    }

    func edit(_ change: (inout VideoEditDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document, next.trim.duration >= 0.19999, next.duration >= 0.19999 else { return }
        if gestureBase == nil { history.record(document) }
        document = next
        persist()
        rebuild()
    }

    func beginGesture() { if gestureBase == nil { gestureBase = document } }
    func endGesture() {
        if let gestureBase, gestureBase != document { history.record(gestureBase) }
        gestureBase = nil
    }
    func updateBlock(_ id: UUID, span: VideoSpan) {
        edit { edit in
            if let index = edit.zooms.firstIndex(where: { $0.id == id }) { edit.zooms[index].span = span }
            if let index = edit.overlays.firstIndex(where: { $0.id == id }) { edit.overlays[index].span = span }
        }
    }

    func undo() {
        guard let next = history.undo(document) else { return }
        document = next; persist(); rebuild()
    }
    func redo() {
        guard let next = history.redo(document) else { return }
        document = next; persist(); rebuild()
    }
    func regenerate() {
        edit { $0.zooms = VideoTimeline.automatic(clicks: tracks.clicks, typing: tracks.typing, duration: total, holdsTyping: $0.typingHold) }
    }
    func add(_ kind: VideoOverlayKind) {
        let span = VideoSpan(start: min(playhead, document.trim.end - 0.4), end: min(document.trim.end, playhead + 2))
        guard span.duration >= 0.4 else { return }
        var overlay = VideoOverlay(kind: kind, span: span)
        if kind == .image {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            overlay.image = "\(UUID().uuidString).\(url.pathExtension)"
            overlay.size = 0.25
            do { try FileManager.default.copyItem(at: url, to: master.deletingLastPathComponent().appendingPathComponent(overlay.image)) }
            catch { self.error = error.localizedDescription; return }
        }
        edit { $0.overlays.append(overlay) }
        selection = overlay.id
    }
    func trash() {
        let alert = NSAlert()
        alert.messageText = "Delete this take and its edits?"
        alert.informativeText = "Files already exported are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Take")
        if alert.runModal() == .alertSecondButtonReturn { requestClose?() }
    }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        let url: URL?
        if document.background == .wallpaper, let screen = NSScreen.main { url = NSWorkspace.shared.desktopImageURL(for: screen) }
        else { url = panel.runModal() == .OK ? panel.url : nil }
        guard let url else { return }
        let name = "\(UUID().uuidString).\(url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: master.deletingLastPathComponent().appendingPathComponent(name))
            edit { $0.backgroundImage = name }
        } catch { self.error = error.localizedDescription }
    }

    func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save preset"
        let field = NSTextField(string: "")
        field.placeholderString = "Preset name"
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var pictures: [String: Data] = [:]
        let files = document.overlays.filter { $0.kind == .image }.map(\.image) + [document.backgroundImage]
        for file in files where !file.isEmpty && !file.contains("/") {
            pictures[file] = try? Data(contentsOf: master.deletingLastPathComponent().appendingPathComponent(file))
        }
        presets = VideoPreset.saving(VideoPreset(name: name, document: document, pictures: pictures), into: presets)
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "video.presets")
    }

    func applyPreset(_ preset: VideoPreset) {
        do {
            for (name, data) in preset.pictures where !name.contains("/") && !name.isEmpty {
                try data.write(to: master.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
            }
            edit { $0 = preset.applying(to: $0) }
        } catch { self.error = error.localizedDescription }
    }

    func deleteSelection() {
        if let cut = selectedCut { edit { _ = $0.cut(cut) }; selectedCut = nil; return }
        guard let selection else { trash(); return }
        edit { $0.overlays.removeAll { $0.id == selection }; $0.zooms.removeAll { $0.id == selection } }
        self.selection = nil
    }
    func togglePlayback() { if player.rate == 0 { player.play() } else { player.pause() } }
    func seek(_ source: Double) {
        var offset = 0.0
        for piece in document.pieces {
            if source < piece.end { offset += max(0, source - piece.start); break }
            offset += piece.duration
        }
        playhead = source
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func persist() {
        do { try JSONEncoder().encode(document).write(to: master.deletingLastPathComponent().appendingPathComponent("edit.json"), options: .atomic) }
        catch { self.error = "Could not save edits: \(error.localizedDescription)" }
    }
    private func rebuild() {
        previewTask?.cancel()
        let document = document
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let result = try await VideoCompositionBuilder.build(master: master, document: document, tracks: tracks, exporting: false)
                try Task.checkCancellation()
                previewSize = result.size
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.video
                item.audioMix = result.audio
                let playing = player.rate > 0
                player.replaceCurrentItem(with: item)
                seek(playhead)
                if playing { player.play() }
            } catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }

    func export(saveAs: Bool = false, copy: Bool = false) {
        guard progress == nil else { return }
        let name = (ScreenRecording.fileName(at: Date()) as NSString).deletingPathExtension + ".\(document.format.rawValue)"
        var destination = VideoTakeFiles.unique(folder.appendingPathComponent(name))
        if saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [document.format == .gif ? .gif : .mpeg4Movie]
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        if copy {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacKit/VideoClipboard")
            VideoTakeFiles.purgeCopies(cache, now: Date())
            do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { self.error = error.localizedDescription; return }
            destination = cache.appendingPathComponent("\(UUID().uuidString).\(document.format.rawValue)")
        }
        let document = document
        progress = 0
        error = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { progress = nil; exportTask = nil; if closing { try? FileManager.default.removeItem(at: master.deletingLastPathComponent()) } }
            do {
                try await VideoExport.run(master: master, document: document, tracks: tracks, destination: destination) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([destination as NSURL])
                    if document.format == .gif, let bytes = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 64 * 1024 * 1024,
                       let data = try? Data(contentsOf: destination) { NSPasteboard.general.setData(data, forType: .init(UTType.gif.identifier)) }
                }
                savedURL = destination
                saved?(destination)
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
                NSSound.beep()
                hud.show("Video export failed: \(error.localizedDescription)", for: 2)
            }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func close() {
        closing = true
        previewTask?.cancel(); exportTask?.cancel(); player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
        if exportTask == nil { try? FileManager.default.removeItem(at: master.deletingLastPathComponent()) }
    }
}

@MainActor
final class VideoEditorWindow: NSWindowController, NSWindowDelegate {
    let model: VideoEditorModel
    var closed: (() -> Void)?
    init(model: VideoEditorModel) {
        self.model = model
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: max(1060, frame.width * 0.7), height: max(600, frame.height * 0.68))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Video Editor"
        window.minSize = CGSize(width: 1060, height: 600)
        window.sharingType = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.requestClose = { [weak self] in self?.window?.close() }
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.progress != nil { model.cancelExport(); return false }
        if model.savedURL != nil { return true }
        let alert = NSAlert()
        alert.messageText = "Delete this unsaved take?"
        alert.informativeText = "Closing deletes the master and edits. Export a file to keep the video."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Delete Take")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) { model.close(); closed?() }
}

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    @State private var tab = "Look"
    @State private var cutStart: Double?
    @State private var dragging: (UUID, VideoSpan)?
    @State private var aiming = false
    @State private var drawing = false

    private func binding<T>(_ key: WritableKeyPath<VideoEditDocument, T>) -> Binding<T> {
        Binding(get: { model.document[keyPath: key] }, set: { value in model.edit { $0[keyPath: key] = value } })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(12)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    VideoPlayer(player: model.player)
                        .aspectRatio(model.previewSize.width / max(1, model.previewSize.height), contentMode: .fit)
                        .overlay {
                            if aiming || drawing {
                                GeometryReader { stage in
                                    Color.clear.contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                                            guard let id = model.selection else { return }
                                            let point = CGPoint(x: min(1, max(0, value.location.x / stage.size.width)), y: min(1, max(0, value.location.y / stage.size.height)))
                                            if aiming { model.edit { edit in if let index = edit.zooms.firstIndex(where: { $0.id == id }) { edit.zooms[index].focus = point } }; aiming = false }
                                            if drawing {
                                                let start = CGPoint(x: min(1, max(0, value.startLocation.x / stage.size.width)), y: min(1, max(0, value.startLocation.y / stage.size.height)))
                                                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                                                if rect.width > 0.01, rect.height > 0.01 { model.edit { edit in if let index = edit.overlays.firstIndex(where: { $0.id == id }) { edit.overlays[index].rect = rect } } }
                                                drawing = false
                                            }
                                        })
                                }
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                Divider()
                inspector.frame(width: 248).padding(12)
            }
            Divider()
            transport.padding(10)
            timeline.padding(.horizontal, 12).padding(.bottom, 12)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        .onExitCommand {
            if model.progress != nil { model.cancelExport() }
            else if aiming { aiming = false }
            else if drawing { drawing = false }
            else { model.selection = nil; model.selectedCut = nil }
        }
        .onDeleteCommand { model.deleteSelection() }
    }

    private var toolbar: some View {
        HStack {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.history.undo.isEmpty).keyboardShortcut("z").help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.history.redo.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
            Menu("Presets") {
                ForEach(model.presets) { preset in Button(preset.name) { model.applyPreset(preset) } }
                Divider()
                Button("Save Preset…", action: model.savePreset)
            }
            Button(action: model.trash) { Image(systemName: "trash") }.help("Delete take")
            Button("Copy") { model.export(copy: true) }.keyboardShortcut("c")
            Button("Copy File") { model.export(copy: true) }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Save As…") { model.export(saveAs: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Spacer()
            if let url = model.savedURL { Text(url.lastPathComponent).lineLimit(1).font(.caption).onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } }
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: 100)
                Button("Cancel", action: model.cancelExport)
            }
            Picker("Format", selection: binding(\.format)) { ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }.frame(width: 120)
            Button("Save") { model.export() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(model.progress != nil)
        }
    }

    private var transport: some View {
        HStack {
            Button(action: model.togglePlayback) { Image(systemName: "playpause.fill") }.keyboardShortcut(.space, modifiers: [])
            Text("\(ScreenRecording.elapsed(model.playhead)) / \(ScreenRecording.elapsed(model.total))").font(.caption.monospacedDigit())
            Button("Text") { model.add(.text) }
            Button("Image") { model.add(.image) }
            Button("Blur") { model.add(.blur) }
            Button("Zoom") { model.edit { _ = $0.addZoom(at: model.playhead) } }
            Spacer()
            Text("Export speed")
            Slider(value: binding(\.speed), in: 0.25...4, step: 0.01).frame(width: 100)
            Text(String(format: "%.2f×", model.document.speed)).monospacedDigit().frame(width: 48)
        }.font(.caption)
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            lane("Zoom", blocks: model.document.zooms.map { ($0.id, $0.span, "Zoom") }, color: .blue)
            ForEach([VideoOverlayKind.text, .image, .blur], id: \.self) { kind in
                lane(kind.rawValue.capitalized, blocks: model.document.overlays.filter { $0.kind == kind }.map { ($0.id, $0.span, $0.kind == .text ? $0.text : $0.kind.rawValue) }, color: .purple)
            }
            ForEach(model.document.volumes.indices, id: \.self) { index in
                HStack {
                    Text("Audio \(index + 1)").frame(width: 60, alignment: .leading)
                    if model.waveforms.indices.contains(index) {
                        Canvas { context, size in
                            let peaks = model.waveforms[index]
                            var path = Path()
                            for (bin, peak) in peaks.enumerated() {
                                let x = Double(bin) / Double(max(1, peaks.count)) * size.width
                                let height = Double(peak) * size.height / 2
                                path.move(to: CGPoint(x: x, y: size.height / 2 - height))
                                path.addLine(to: CGPoint(x: x, y: size.height / 2 + height))
                            }
                            context.stroke(path, with: .color(.green.opacity(0.6)), lineWidth: 1)
                        }.frame(height: 20)
                    }
                    Slider(value: Binding(get: { Double(model.document.volumes[index]) }, set: { value in model.edit { $0.volumes[index] = Float(value) } }), in: 0...1).frame(width: 120)
                    Text("\(Int(model.document.volumes[index] * 100))%").monospacedDigit().frame(width: 32)
                    Button(model.document.volumes[index] == 0 ? "Restore" : "Remove") { model.edit { $0.volumes[index] = $0.volumes[index] == 0 ? 1 : 0 } }
                }.font(.caption)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) { ForEach(model.thumbnails.indices, id: \.self) { Image(nsImage: model.thumbnails[$0]).resizable().scaledToFill().frame(width: geometry.size.width / 14, height: 40).clipped() } }
                    ForEach(Array(model.document.cuts.enumerated()), id: \.offset) { _, cut in
                        Rectangle().fill(.black.opacity(0.8)).frame(width: geometry.size.width * cut.duration / model.total).offset(x: geometry.size.width * cut.start / model.total)
                            .highPriorityGesture(TapGesture().onEnded { model.edit { $0.cuts.removeAll { $0 == cut } } })
                    }
                    if let cut = model.selectedCut { Rectangle().fill(.red.opacity(0.5)).frame(width: geometry.size.width * cut.duration / model.total).offset(x: geometry.size.width * cut.start / model.total) }
                    Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width * model.playhead / model.total)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let time = min(model.total, max(0, value.location.x / geometry.size.width * model.total))
                    if NSEvent.modifierFlags.contains(.shift) {
                        let start = cutStart ?? min(model.total, max(0, value.startLocation.x / geometry.size.width * model.total))
                        cutStart = start
                        model.selectedCut = VideoSpan(start: min(start, time), end: max(start, time))
                    } else { model.seek(time) }
                }.onEnded { _ in cutStart = nil })
            }.frame(height: 40)
            HStack {
                Text("Trim in")
                Slider(value: Binding(get: { model.document.trim.start }, set: { value in model.edit { $0.trim.start = min(value, $0.trim.end - 0.2) } }), in: 0...model.total)
                Text("Trim out")
                Slider(value: Binding(get: { model.document.trim.end }, set: { value in model.edit { $0.trim.end = max(value, $0.trim.start + 0.2) } }), in: 0...model.total)
                Text("Shift-drag to cut · Delete to remove").foregroundStyle(.secondary)
            }.font(.caption)
        }
    }

    private func lane(_ title: String, blocks: [(UUID, VideoSpan, String)], color: Color) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.05))
                        .onTapGesture(coordinateSpace: .local) { point in
                            model.seek(min(model.total, max(0, point.x / geometry.size.width * model.total)))
                            if title == "Zoom" { model.edit { _ = $0.addZoom(at: model.playhead) } }
                            else if let kind = VideoOverlayKind(rawValue: title.lowercased()) { model.add(kind) }
                        }
                    if title == "Zoom" {
                        ForEach(Array(model.tracks.clicks.enumerated()), id: \.offset) { _, time in
                            Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: 6).offset(x: geometry.size.width * time / model.total)
                        }
                    }
                    ForEach(blocks, id: \.0) { id, span, label in
                        Text(label).lineLimit(1).font(.caption2).padding(.horizontal, 4)
                            .frame(width: max(8, geometry.size.width * span.duration / model.total), height: 20)
                            .background(color.opacity(model.selection == id ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 3))
                            .overlay {
                                if model.selection == id {
                                    HStack { Capsule().fill(.white).frame(width: 2, height: 12); Spacer(); Capsule().fill(.white).frame(width: 2, height: 12) }.padding(.horizontal, 3)
                                }
                            }
                            .offset(x: geometry.size.width * span.start / model.total)
                            .onTapGesture { model.selection = id; if title == "Zoom" { tab = "Zoom" } }
                            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                if dragging?.0 != id { dragging = (id, span); model.beginGesture() }
                                guard let original = dragging?.1 else { return }
                                model.selection = id
                                let delta = value.translation.width / geometry.size.width * model.total
                                let anchors = model.tracks.clicks + [model.playhead] + blocks.flatMap { [$0.1.start, $0.1.end] }
                                let neighbours = title == "Zoom" ? blocks.filter { $0.0 != id }.map { $0.1 } : []
                                let width = geometry.size.width * original.duration / model.total
                                let next: VideoSpan
                                if value.startLocation.x < 7 {
                                    let lower = max(model.document.trim.start, neighbours.filter { $0.end <= original.start }.map(\.end).max() ?? model.document.trim.start)
                                    next = VideoSpan(start: min(original.end - 0.4, max(lower, VideoTimeline.snap(original.start + delta, to: anchors))), end: original.end)
                                } else if value.startLocation.x > width - 7 {
                                    let upper = min(model.document.trim.end, neighbours.filter { $0.start >= original.end }.map(\.start).min() ?? model.document.trim.end)
                                    next = VideoSpan(start: original.start, end: max(original.start + 0.4, min(upper, VideoTimeline.snap(original.end + delta, to: anchors))))
                                } else {
                                    next = VideoTimeline.moved(original, by: delta, bounds: model.document.trim, neighbours: neighbours, anchors: anchors)
                                }
                                model.updateBlock(id, span: next)
                            }.onEnded { _ in dragging = nil; model.endGesture() })
                    }
                }
            }.frame(height: 22)
        }.font(.caption)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Inspector", selection: $tab) { ForEach(["Look", "Pointer", "Zoom"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                if let id = model.selection, let index = model.document.overlays.firstIndex(where: { $0.id == id }) {
                    Text("Selected \(model.document.overlays[index].kind.rawValue)").font(.headline)
                    if model.document.overlays[index].kind == .text {
                        TextField("Text", text: Binding(get: { model.document.overlays[index].text }, set: { value in model.edit { $0.overlays[index].text = String(value.prefix(200)).components(separatedBy: "\n").prefix(3).joined(separator: "\n") } }), axis: .vertical)
                    }
                    if model.document.overlays[index].kind == .blur {
                        Button(drawing ? "Draw on the frame" : "Draw Blur Rectangle") { model.player.pause(); drawing = true }
                        Slider(value: Binding(get: { model.document.overlays[index].strength }, set: { value in model.edit { $0.overlays[index].strength = value } }), in: 1...5)
                    }
                    if model.document.overlays[index].kind == .text {
                        Picker("Color", selection: Binding(get: { model.document.overlays[index].color }, set: { value in model.edit { $0.overlays[index].color = value } })) {
                            ForEach(["white", "black", "red", "blue", "yellow", "green"], id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    Text("Opacity")
                    Slider(value: Binding(get: { model.document.overlays[index].opacity }, set: { value in model.edit { $0.overlays[index].opacity = value } }), in: 0.05...1)
                    Text("Size")
                    Slider(value: Binding(get: { model.document.overlays[index].size }, set: { value in model.edit { $0.overlays[index].size = value } }), in: model.document.overlays[index].kind == .text ? 0.03...0.16 : 0.04...0.6)
                    Picker("Position", selection: Binding(get: { model.document.overlays[index].position }, set: { value in model.edit { $0.overlays[index].position = value } })) {
                        ForEach(0..<9) { Text(["Top left", "Top", "Top right", "Left", "Center", "Right", "Bottom left", "Bottom", "Bottom right"][$0]).tag($0) }
                    }
                    Button("Delete", action: model.deleteSelection)
                } else if tab == "Look" {
                    Picker("Look", selection: Binding(get: { model.document.look }, set: { value in model.edit {
                        $0.look = value
                        $0.margin = value == .studio ? 0.45 : value == .smooth ? 0.24 : 0
                        $0.corners = value == .studio ? 0.35 : value == .smooth ? 0.15 : 0
                        $0.background = value == .original ? .none : .gradient
                    } })) { ForEach(VideoLook.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Background", selection: binding(\.background)) { ForEach(VideoBackground.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    if model.document.background == .image || model.document.background == .wallpaper { Button("Choose Background…", action: model.chooseBackground) }
                    if model.document.background == .color {
                        Picker("Color", selection: binding(\.backgroundColor)) { ForEach(["graphite", "white", "black", "blue", "green", "purple"], id: \.self) { Text($0.capitalized).tag($0) } }
                    }
                    Text("Margin")
                    Slider(value: binding(\.margin), in: 0...0.45)
                    Text("Corners")
                    Slider(value: binding(\.corners), in: 0...1)
                    Text("Background blur")
                    Slider(value: binding(\.backgroundBlur), in: 0...1)
                    Picker("Canvas", selection: binding(\.shape)) { ForEach(VideoShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Quality", selection: binding(\.quality)) { ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    if model.document.format == .gif {
                        Text("GIF size")
                        Slider(value: binding(\.gifScale), in: 0.01...1, step: 0.01)
                        Text("GIF fps: \(Int(model.document.gifFPS))")
                        Slider(value: binding(\.gifFPS), in: 1...50, step: 1)
                    }
                } else if tab == "Pointer" {
                    Toggle("Render pointer", isOn: binding(\.pointer)).disabled(model.tracks.pointer.isEmpty)
                    Toggle("Click rings", isOn: binding(\.clickRings))
                    Picker("Smoothing", selection: binding(\.smoothing)) { ForEach(VideoPointerSmoothing.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Text("Pointer size")
                    Slider(value: binding(\.pointerSize), in: 0.5...2)
                    if model.tracks.pointer.isEmpty { Text("This movie has no pointer track.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Toggle("Hold zoom while typing", isOn: Binding(get: { model.document.typingHold }, set: { value in model.edit { $0.typingHold = value }; model.regenerate() }))
                    Button("Regenerate Zooms", action: model.regenerate)
                    if let id = model.selection, let index = model.document.zooms.firstIndex(where: { $0.id == id }) {
                        Text("Strength")
                        Slider(value: Binding(get: { model.document.zooms[index].strength }, set: { value in model.edit { $0.zooms[index].strength = value } }), in: 1.2...3)
                        Button(aiming ? "Click a focus point" : "Set Focus Point") { model.player.pause(); aiming = true }
                        Button("Follow Pointer") { model.edit { $0.zooms[index].focus = nil } }
                        Button("Delete Zoom", action: model.deleteSelection)
                    }
                }
            }
        }
    }
}

struct VideoToolView: View {
    @EnvironmentObject var editors: VideoEditors
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "film", title: "Video Editor", subtitle: "Trim, cut, zoom and export movies on your Mac.", colors: [.purple, .blue])
                CardSection(title: "Open a movie", icon: "film") {
                    Text("The editor works on a private copy. Export an MP4 or GIF to keep your edits; closing deletes the working take.")
                    Button("Open Movie…", action: editors.chooseMovie).buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }
    }
}
