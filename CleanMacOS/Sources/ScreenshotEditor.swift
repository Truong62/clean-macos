import AppKit
import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers
import Vision
import ImageIO

@MainActor
final class ScreenshotEditorController: ObservableObject {
    static let settingsKey = "screenshotEditor.settings"
    @Published var settings: ScreenshotEditorSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applyShortcuts()
        }
    }
    private var windows: [UUID: ScreenshotEditorWindow] = [:]
    private var oldPolicy: NSApplication.ActivationPolicy?
    private var pins: [NSWindow] = []
    weak var shelf: ShelfController?
    var linkService: (any EditorLinkService)?
    private let hud = InputHUD()

    init(shelf: ShelfController) {
        self.shelf = shelf
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ScreenshotEditorSettings.self, from: $0) } ?? ScreenshotEditorSettings()
        KeyboardShortcuts.onKeyUp(for: .editImageFile) { [weak self] in MainActor.assumeIsolated { self?.pickImage() } }
        KeyboardShortcuts.onKeyUp(for: .editClipboardImage) { [weak self] in MainActor.assumeIsolated { self?.openClipboard() } }
        applyShortcuts()
    }
    private func applyShortcuts() {
        if settings.fileShortcut { KeyboardShortcuts.enable(.editImageFile) } else { KeyboardShortcuts.disable(.editImageFile) }
        if settings.clipboardShortcut { KeyboardShortcuts.enable(.editClipboardImage) } else { KeyboardShortcuts.disable(.editClipboardImage) }
    }
    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }
    func open(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let image = ScreenshotRenderer.decode(data) else { NSSound.beep(); return }
        let ext = url.pathExtension.lowercased()
        show(image, format: ["jpg", "jpeg"].contains(ext) ? .jpeg : ext == "heic" ? .heic : .png, title: url.lastPathComponent, scale: ScreenshotRenderer.captureScale(data))
    }
    static func clipboardImage() -> CGImage? {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if let data = try? Data(contentsOf: url), let image = ScreenshotRenderer.decode(data) { return image }
            }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let data = board.data(forType: type), let image = ScreenshotRenderer.decode(data) { return image }
        }
        return nil
    }
    func openClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { url in
               guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
               return CGImageSourceGetCount(source) > 0
           }) { open(url); return }
        guard let image = Self.clipboardImage() else { NSSound.beep(); return }
        show(image, format: .png, title: "Clipboard image")
    }
    func show(_ original: CGImage, format: EditorFormat, title: String, scale: CGFloat = 1) {
        var image = original
        if max(image.width, image.height) > 6000 {
            let alert = NSAlert()
            alert.messageText = "Downscale this image to 6,000 pixels?"
            alert.informativeText = "Smaller images use less memory while editing."
            alert.addButton(withTitle: "Downscale")
            alert.addButton(withTitle: "Keep Original")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            if response == .alertFirstButtonReturn {
                guard let resized = ScreenshotRenderer.resized(image, size: EditorGeometry.downscaled(CGSize(width: image.width, height: image.height))) else { NSSound.beep(); return }
                image = resized
            }
        }
        let size = CGSize(width: image.width, height: image.height)
        guard EditorGeometry.valid(size), let data = ScreenshotRenderer.encode(image) else { NSSound.beep(); return }
        let session = ScreenshotEditorSession(document: ScreenshotDocument(base: data, size: size, scale: scale, sourceFormat: format), owner: self)
        let controller = ScreenshotEditorWindow(session: session, title: title)
        windows[session.id] = controller
        if oldPolicy == nil { oldPolicy = NSApp.activationPolicy() }
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closed(_ id: UUID) {
        windows.removeValue(forKey: id)
        if windows.isEmpty, let oldPolicy {
            NSApp.setActivationPolicy(oldPolicy)
            self.oldPolicy = nil
        }
    }
    func message(_ text: String) { hud.show(text) }
    func retainPin(_ window: NSWindow) {
        pins.removeAll { !$0.isVisible }
        pins.append(window)
    }
}

@MainActor
final class ScreenshotEditorSession: ObservableObject {
    let id = UUID()
    let owner: ScreenshotEditorController
    let linkController = EditorLinkController()
    @Published var history: EditorHistory
    @Published var draft: ScreenshotDocument?
    @Published var tool: AnnotationTool
    @Published var selection: UUID?
    @Published var crop: CGRect?
    @Published var zoom: CGFloat = 1
    @Published var effectiveZoom: CGFloat = 1
    @Published var fits = true
    @Published var pan = CGSize.zero
    @Published var words: [EditorWord]?
    @Published var codes: [String] = []
    @Published var selectedWords: Set<String> = []
    @Published var editingText: UUID?
    @Published var text = ""
    @Published var renderRevision = 0
    @Published var status = ""
    weak var window: NSWindow?
    var discard = false
    var lastPointer: TimeInterval = 0
    private var savedDocument: ScreenshotDocument
    private var savedAppearance: ScreenshotEditorSettings
    private var recognitionTask: Task<Void, Never>?
    private var temporaryFiles: [URL] = []
    var document: ScreenshotDocument { draft ?? history.document }
    var settings: ScreenshotEditorSettings { owner.settings }
    var unsaved: Bool {
        history.document != savedDocument || appearance(settings) != appearance(savedAppearance)
    }
    var selected: AnnotationMark? { document.marks.first { $0.id == selection } }
    init(document: ScreenshotDocument, owner: ScreenshotEditorController) {
        self.owner = owner
        history = EditorHistory(document)
        savedDocument = document
        savedAppearance = owner.settings
        tool = owner.settings.lastTool.openingTool
        if owner.settings.style.strength < 3 { owner.settings.style.strength = 3 }
        recognize()
    }
    private func appearance(_ value: ScreenshotEditorSettings) -> ScreenshotEditorSettings {
        var result = ScreenshotEditorSettings()
        result.background = value.background
        result.watermark = value.watermark
        result.shadows = value.shadows
        result.dim = value.dim
        return result
    }
    func commit(_ document: ScreenshotDocument) {
        let baseChanged = document.base != history.document.base
        history.commit(document)
        draft = nil
        renderRevision += 1
        if baseChanged { recognize() }
    }
    func choose(_ next: AnnotationTool) {
        commitText()
        crop = next == .crop ? document.bounds : nil
        draft = nil
        tool = next
        selectedWords.removeAll()
        owner.settings.lastTool = next
    }
    func undo(_ redo: Bool = false) {
        commitText()
        draft = nil
        if redo { history.redo() } else { history.undo() }
        selection = nil
        crop = tool == .crop ? document.bounds : nil
        recognize()
        renderRevision += 1
    }
    func delete() {
        guard let selection else { return }
        var next = history.document
        next.remove(selection)
        commit(next)
        self.selection = nil
    }
    func restyle(_ update: (inout AnnotationStyle) -> Void) {
        update(&owner.settings.style)
        if let selection, let index = document.marks.firstIndex(where: { $0.id == selection }) {
            var next = document
            update(&next.marks[index].style)
            if next.marks[index].tool == .text {
                let mark = next.marks[index]
                let size = (mark.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: mark.style.fontSize * next.scale, weight: .semibold)])
                next.marks[index].end = CGPoint(x: mark.start.x + max(1, size.width), y: mark.start.y + max(1, size.height))
            }
            if editingText != nil { draft = next } else { commit(next) }
        }
    }
    func reorder(_ offset: Int) {
        guard let selection else { return }
        var next = history.document
        next.reorder(selection, by: offset)
        commit(next)
    }
    func beginText(at point: CGPoint, existing: AnnotationMark? = nil) {
        commitText()
        if let existing {
            editingText = existing.id
            text = existing.text
            selection = existing.id
        } else {
            let mark = AnnotationMark(tool: .text, start: point, end: CGPoint(x: point.x + 180 * document.scale, y: point.y + 30 * document.scale), style: settings.style)
            var next = history.document
            next.marks.append(mark)
            draft = next
            editingText = mark.id
            selection = mark.id
            text = ""
        }
    }
    func commitText() {
        guard let id = editingText else { return }
        var next = document
        if text.isEmpty { next.remove(id) }
        else if let index = next.marks.firstIndex(where: { $0.id == id }) {
            next.marks[index].text = text.replacingOccurrences(of: "\n", with: " ")
            let mark = next.marks[index]
            let size = (mark.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: mark.style.fontSize * next.scale, weight: .semibold)])
            next.marks[index].end = CGPoint(x: mark.start.x + size.width, y: mark.start.y + size.height)
        }
        editingText = nil
        commit(next)
    }
    func applyCrop() {
        guard let crop, let rect = EditorGeometry.crop(crop, bounds: document.bounds),
              let image = ScreenshotRenderer.decode(document.base)?.cropping(to: rect), let data = ScreenshotRenderer.encode(image) else { return }
        var next = document
        next.replaceBase(data, size: rect.size, offset: CGSize(width: -rect.minX, height: -rect.minY))
        commit(next)
        self.crop = nil
        tool = .arrow
        fits = true
    }
    func expand(to rect: CGRect) {
        guard rect != document.bounds, EditorGeometry.valid(rect.size), let base = ScreenshotRenderer.decode(document.base),
              let image = ScreenshotRenderer.expanded(base, rect: rect, fill: settings.expandColor), let data = ScreenshotRenderer.encode(image) else { NSSound.beep(); return }
        var next = document
        next.replaceBase(data, size: rect.size, offset: CGSize(width: -rect.minX, height: -rect.minY))
        commit(next)
        fits = true
    }
    func paste() {
        guard let image = ScreenshotEditorController.clipboardImage() else { NSSound.beep(); return }
        insert(image)
    }
    func insert(_ image: CGImage) {
        guard EditorGeometry.valid(CGSize(width: image.width, height: image.height)), let data = ScreenshotRenderer.encode(image) else { NSSound.beep(); return }
        commitText()
        let factor = min(1, min(document.size.width / CGFloat(image.width), document.size.height / CGFloat(image.height)))
        let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        let origin = CGPoint(x: (document.size.width - size.width) / 2, y: (document.size.height - size.height) / 2)
        let mark = AnnotationMark(tool: .rectangle, start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height), image: data)
        var next = history.document
        next.marks.append(mark)
        commit(next)
        choose(.select)
        selection = mark.id
    }
    func escape() {
        if editingText != nil { commitText() }
        else if tool == .expand || tool == .crop { choose(.arrow) }
        else if !selectedWords.isEmpty { selectedWords.removeAll() }
        else if selection != nil { selection = nil }
        else { window?.performClose(nil) }
    }
    func output(background: Bool = true, native: Bool = false) -> CGImage? {
        commitText()
        var options = settings
        if native { options.export1x = false }
        return ScreenshotRenderer.render(history.document, settings: options, words: words, background: background)
    }
    func markSaved() {
        savedDocument = history.document
        savedAppearance = settings
    }
    func copy() {
        if !selectedWords.isEmpty {
            let selected = (words ?? []).filter { selectedWords.contains($0.id) }
            let text = EditorWord.joined(selected)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        guard let image = output(), let data = ScreenshotRenderer.encode(image, scale: settings.export1x ? 1 : document.scale) else { NSSound.beep(); return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(data, forType: .png) else { NSSound.beep(); return }
        let format = EditorExport.format(source: document.sourceFormat, transparent: ScreenshotRenderer.transparent(image))
        if format != .png, let native = ScreenshotRenderer.encode(image, format: format, scale: settings.export1x ? 1 : document.scale) {
            board.setData(native, forType: NSPasteboard.PasteboardType(format == .jpeg ? UTType.jpeg.identifier : UTType.heic.identifier))
        }
        board.setString(Bundle.main.bundleIdentifier ?? "click.ngoctruong.CleanMacOS", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        markSaved()
        owner.message("Image copied")
        window?.close()
    }
    func exportData(background: Bool = true, native: Bool = false) -> (Data, EditorFormat)? {
        guard let image = output(background: background, native: native) else { return nil }
        let format = EditorExport.format(source: document.sourceFormat, transparent: ScreenshotRenderer.transparent(image))
        guard let data = ScreenshotRenderer.encode(image, format: format, scale: settings.export1x && !native ? 1 : document.scale) else { return nil }
        return (data, format)
    }
    func save(as saveAs: Bool = false) {
        guard let (data, format) = exportData() else { NSSound.beep(); return }
        let folder = settings.exportFolder.isEmpty ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first! : URL(fileURLWithPath: settings.exportFolder)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = EditorExport.filename(prefix: settings.namePrefix, date: Date(), format: format, existing: existing)
        if saveAs || settings.exportFolder.isEmpty {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .png ? .png : format == .jpeg ? .jpeg : .heic]
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            guard let window else { return }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.write(data, to: url)
            }
        } else { write(data, to: folder.appendingPathComponent(name)) }
    }
    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .withoutOverwriting)
            markSaved()
            owner.message("Image saved")
            window?.close()
        } catch { status = "Could not save: \(error.localizedDescription)" }
    }
    func tempFile(background: Bool = true) -> URL? {
        guard let (data, format) = exportData(background: background, native: true) else { NSSound.beep(); return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacKit-\(UUID().uuidString).\(format.rawValue)")
        do { try data.write(to: url, options: .withoutOverwriting) } catch { status = error.localizedDescription; return nil }
        temporaryFiles.append(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { try? FileManager.default.removeItem(at: url) }
        markSaved()
        return url
    }
    func addToShelf() {
        guard let shelf = owner.shelf, shelf.settings.isEnabled, let image = output(), let data = ScreenshotRenderer.encode(image) else { return }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in completion(data, nil); return nil }
        if shelf.accept([provider]) { markSaved(); window?.close() }
    }
    func pin() {
        guard let image = output(background: false) else { NSSound.beep(); return }
        let factor = min(1, 600 / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        let panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Pinned image"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        owner.retainPin(panel)
        panel.center()
        panel.orderFront(nil)
        markSaved()
    }
    func share() {
        guard let url = tempFile(), let view = window?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: CGRect(x: view.bounds.maxX - 200, y: view.bounds.maxY - 38, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
    func recognize() {
        recognitionTask?.cancel()
        words = nil
        codes = []
        selectedWords.removeAll()
        let data = history.document.base
        recognitionTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { EditorRecognition.recognize(data) }.value
            guard !Task.isCancelled, let self, self.history.document.base == data else { return }
            self.words = result.0
            self.codes = result.1
            self.renderRevision += 1
        }
    }
}

enum EditorRecognition {
    static func recognize(_ data: Data) -> ([EditorWord], [String]) {
        guard let image = ScreenshotRenderer.decode(data) else { return ([], []) }
        var words: [EditorWord] = [], codes: [String] = []
        for band in EditorGeometry.bands(size: CGSize(width: image.width, height: image.height)) {
            guard !Task.isCancelled, let part = image.cropping(to: band) else { break }
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let qr = VNDetectBarcodesRequest()
            qr.symbologies = [.qr]
            try? VNImageRequestHandler(cgImage: part).perform([text, qr])
            for observation in text.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex, options: .byWords) { substring, range, _, _ in
                    guard let substring, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                    let rect = CGRect(x: box.minX * band.width, y: band.minY + (1 - box.maxY) * band.height, width: box.width * band.width, height: box.height * band.height)
                    if !words.contains(where: { $0.text == substring && $0.rect.intersection(rect).width * $0.rect.intersection(rect).height > rect.width * rect.height * 0.5 }) {
                        words.append(EditorWord(text: substring, rect: rect))
                    }
                }
            }
            for payload in qr.results?.compactMap(\.payloadStringValue) ?? [] where !codes.contains(payload) { codes.append(payload) }
        }
        return (words, codes)
    }
}

@MainActor
final class ScreenshotEditorWindow: NSWindowController, NSWindowDelegate {
    let session: ScreenshotEditorSession
    private var monitor: Any?
    init(session: ScreenshotEditorSession, title: String) {
        self.session = session
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let minimum = CGSize(width: min(visible.width, max(760, min(980, visible.width * 0.76))), height: min(visible.height, max(560, min(680, visible.height * 0.72))))
        let size = CGSize(width: max(minimum.width, min(visible.width * 0.9, session.document.size.width / session.document.scale + 96)),
                          height: max(minimum.height, min(visible.height * 0.88, session.document.size.height / session.document.scale + 140)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentMinSize = minimum
        window.isReleasedWhenClosed = false
        super.init(window: window)
        session.window = window
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(session: session).environmentObject(session.owner))
        window.center()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.key(event) ? nil : event
        }
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        session.commitText()
        guard !session.discard, session.unsaved else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your annotations have not been copied or saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        session.owner.closed(session.id)
    }
    func key(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let recorder = window?.firstResponder as? EditorKeyRecorder.Recorder, recorder.recording { recorder.keyDown(with: event); return true }
        let textField = window?.firstResponder is NSTextView
        if event.keyCode == 53 { session.escape(); return true }
        if textField { return false }
        if event.isARepeat && ([36, 76].contains(event.keyCode) || command && ["c", "v"].contains(key)) { return true }
        if session.settings.toolKeys, !["escape", "return", "enter", "delete", "forwarddelete"].contains(EditorShortcutOwners.key(event)),
           let entry = session.settings.customKeys.first(where: { $0.value == EditorShortcutOwners.key(event) }), let tool = AnnotationTool(rawValue: entry.key) {
            session.choose(tool)
            return true
        }
        if command {
            switch key {
            case "z": session.undo(shift)
            case "c":
                let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
                if pid == 0 || pid == Int64(ProcessInfo.processInfo.processIdentifier) || ProcessInfo.processInfo.systemUptime - session.lastPointer >= 0.6 { session.copy() }
            case "v": session.paste()
            case "s": session.save(as: shift)
            case "p": session.pin()
            case "w": window?.performClose(nil)
            case "0": session.fits = true; session.pan = .zero
            case "1": session.fits = false; session.zoom = 1
            case "=", "+": session.fits = false; session.zoom = min(3, session.effectiveZoom * 1.25)
            case "-": session.fits = false; session.zoom = max(0.05, session.effectiveZoom * 0.8)
            default:
                if event.keyCode == 51 { session.discard = true; window?.close() } else { return false }
            }
            return true
        }
        if [36, 76].contains(event.keyCode) {
            if session.tool == .crop { session.applyCrop() } else { session.copy() }
            return true
        }
        if [51, 117].contains(event.keyCode) { session.delete(); return true }
        if session.settings.toolKeys {
            let typed = EditorShortcutOwners.key(event)
            if let slot = Int(typed), (1...9).contains(slot), session.settings.toolOrder.count >= slot { session.choose(session.settings.toolOrder[slot - 1]); return true }
            if let entry = session.settings.customKeys.first(where: { $0.value == typed }), let tool = AnnotationTool(rawValue: entry.key) { session.choose(tool); return true }
        }
        return false
    }
}
