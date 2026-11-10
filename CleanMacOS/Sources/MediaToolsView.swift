import AVFoundation
import AppKit
import SwiftUI

enum MediaRun: Equatable {
    case running(progress: Double?, status: String)
    case finished(MediaResult)
    case failed(String)
}

@MainActor
final class MediaToolsController: ObservableObject {
    typealias Runner = @Sendable (MediaTab, [URL], MediaToolSettings, ClipTrim, @escaping MediaJobs.Report) async throws -> MediaResult

    static let settingsKey = "mediaTools.settings"

    @Published var settings: MediaToolSettings {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey) }
    }
    @Published var tab = MediaTab.video
    @Published var trims: [MediaTab: ClipTrim] = [:]
    @Published private(set) var files: [MediaTab: [URL]] = [:]
    @Published private(set) var inputBytes: [MediaTab: Int64] = [:]
    @Published private(set) var lengths: [MediaTab: Double] = [:]
    @Published private(set) var runs: [MediaTab: MediaRun] = [:]

    private let runner: Runner
    private var tasks: [MediaTab: Task<Void, Never>] = [:]
    private var tokens: [MediaTab: Int] = [:]

    init(runner: @escaping Runner = { try await MediaJobs.run($0, files: $1, settings: $2, trim: $3, report: $4) }) {
        self.runner = runner
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(MediaToolSettings.self, from: $0) }
            ?? MediaToolSettings()
    }

    func isRunning(_ tab: MediaTab) -> Bool {
        if case .running = runs[tab] { return true }
        return false
    }

    @discardableResult
    func choose(_ urls: [URL], for tab: MediaTab) -> Bool {
        let accepted = urls.filter(tab.accepts)
        guard let first = accepted.first, !isRunning(tab) else { return false }
        let chosen = tab.allowsMany ? accepted : [first]
        files[tab] = chosen
        inputBytes[tab] = chosen.reduce(0) { $0 + MediaFiles.size($1) }
        runs[tab] = nil
        trims[tab] = ClipTrim()
        lengths[tab] = nil
        if tab.takesVideo { loadLength(of: first, for: tab) }
        return true
    }

    func run(_ tab: MediaTab, endEditing: @MainActor () -> Void = { NSApp?.keyWindow?.makeFirstResponder(nil) }) {
        endEditing()
        guard let inputs = files[tab], !inputs.isEmpty, !isRunning(tab) else { return }
        let token = (tokens[tab] ?? 0) + 1
        tokens[tab] = token
        runs[tab] = .running(progress: nil, status: "Starting…")
        let progressFilter = MediaProgress()
        let report: MediaJobs.Report = { [weak self] progress, status in
            guard progressFilter.accepts(progress, status: status) else { return }
            Task { @MainActor in self?.update(tab, token: token, progress: progress, status: status) }
        }
        let runner = runner
        let settings = settings
        let trim = trims[tab] ?? ClipTrim()
        tasks[tab] = Task { [weak self] in
            let outcome: MediaRun?
            do {
                outcome = .finished(try await runner(tab, inputs, settings, trim, report))
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
            }
            self?.finish(tab, token: token, outcome: outcome)
        }
    }

    func cancel(_ tab: MediaTab) {
        tasks[tab]?.cancel()
    }

    private func update(_ tab: MediaTab, token: Int, progress: Double?, status: String) {
        guard tokens[tab] == token, isRunning(tab) else { return }
        runs[tab] = .running(progress: progress, status: status)
    }

    private func finish(_ tab: MediaTab, token: Int, outcome: MediaRun?) {
        guard tokens[tab] == token else { return }
        runs[tab] = outcome
        tasks[tab] = nil
    }

    private func loadLength(of url: URL, for tab: MediaTab) {
        Task { [weak self] in
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            guard let self, self.files[tab]?.first == url else { return }
            self.lengths[tab] = MediaDuration.finite(seconds)
        }
    }
}

struct MediaToolsView: View {
    @EnvironmentObject var media: MediaToolsController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "photo.on.rectangle.angled", title: "Media Tools",
                           subtitle: "Compress videos, make GIFs, convert images and pull text out of pictures. Results are saved next to the original.",
                           colors: [.orange, .purple])
                Picker("Tool", selection: $media.tab) {
                    ForEach(MediaTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                MediaDropZone(tab: media.tab)
                switch media.tab {
                case .video: VideoOptions()
                case .gif: GIFOptions()
                case .images: ImageOptions()
                case .text: EmptyView()
                }
                MediaRunSection(tab: media.tab)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension MediaTab {
    var symbol: String {
        switch self {
        case .video: "film"
        case .gif: "play.rectangle.on.rectangle"
        case .images: "photo.on.rectangle"
        case .text: "text.viewfinder"
        }
    }

    var prompt: String {
        switch self {
        case .video: "Drop a video here"
        case .gif: "Drop a video to turn into a GIF"
        case .images: "Drop images here"
        case .text: "Drop an image with text in it"
        }
    }

    var actionTitle: String {
        switch self {
        case .video: "Compress"
        case .gif: "Make GIF"
        case .images: "Convert"
        case .text: "Extract Text"
        }
    }
}

private extension CompressionLevel {
    var summary: String {
        switch self {
        case .low: "Best quality at full resolution, encoded in two passes."
        case .medium: "Good quality, scaled down to the max size."
        case .high: "Smallest file, with lower quality and resolution."
        }
    }
}

private struct MediaDropZone: View {
    @EnvironmentObject var media: MediaToolsController
    let tab: MediaTab
    @State private var isTargeted = false

    var body: some View {
        let files = media.files[tab] ?? []
        VStack(spacing: 8) {
            Image(systemName: tab.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if files.isEmpty {
                Text(tab.prompt).foregroundStyle(.secondary)
            } else {
                Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) images")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: media.inputBytes[tab] ?? 0, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(files.isEmpty ? "Choose…" : "Choose Another…", action: choose)
                .disabled(media.isRunning(tab))
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            media.choose(urls, for: tab)
        } isTargeted: { isTargeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = tab.acceptedTypes
        panel.allowsMultipleSelection = tab.allowsMany
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        media.choose(panel.urls, for: tab)
    }
}

private struct VideoOptions: View {
    @EnvironmentObject var media: MediaToolsController

    var body: some View {
        let video = $media.settings.video
        CardSection(title: "Compression", icon: "film") {
            Picker("Mode", selection: video.mode) {
                ForEach(VideoCompressMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            if video.wrappedValue.mode == .resolution {
                Picker("Compression", selection: video.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text(video.wrappedValue.level.summary).font(.caption).foregroundStyle(.secondary)
                if video.wrappedValue.level == .medium {
                    Picker("Max size", selection: video.maxSize) {
                        ForEach(VideoPresets.resolutions.map { $0.edge }, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .frame(maxWidth: 240)
                }
            } else {
                MegabytesField(title: "Target size", value: video.targetMB)
                Text("Re-encodes to H.264 and AAC at a size picked from the budget, with up to three tries to get under it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TrimFields(tab: .video)
        }
    }
}

private struct GIFOptions: View {
    @EnvironmentObject var media: MediaToolsController

    var body: some View {
        let gif = $media.settings.gif
        let fps = gif.wrappedValue.fps
        CardSection(title: "GIF", icon: "play.rectangle.on.rectangle") {
            Stepper("Frame rate: \(fps) fps", value: gif.fps, in: GIFPlanner.fpsRange)
                .frame(maxWidth: 320, alignment: .leading)
            HStack {
                Text("Width")
                Slider(value: Binding(get: { Double(gif.wrappedValue.width) }, set: { gif.wrappedValue.width = Int($0) }),
                       in: Double(GIFPlanner.widthRange.lowerBound)...Double(GIFPlanner.widthRange.upperBound), step: 20)
                Text("\(gif.wrappedValue.width) px").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 420)
            Toggle("Keep it under a size", isOn: gif.limitsSize)
            if gif.wrappedValue.limitsSize {
                MegabytesField(title: "Target size", value: gif.targetMB)
                Text("Lowers the frame rate first, then the width, over up to four tries.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Loops forever. A GIF holds up to \(GIFPlanner.maxFrames) frames, so up to \(GIFPlanner.maxSeconds(fps: fps)) seconds at \(fps) fps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TrimFields(tab: .gif)
        }
    }
}

private struct ImageOptions: View {
    @EnvironmentObject var media: MediaToolsController

    var body: some View {
        let images = $media.settings.images
        let current = images.wrappedValue
        CardSection(title: "Format", icon: "photo") {
            HStack(spacing: 8) {
                Text("Presets").foregroundStyle(.secondary)
                ForEach(ImagePreset.allCases) { preset in
                    Button(preset.title) { images.wrappedValue = preset.applied(to: images.wrappedValue) }
                        .help(preset.summary)
                }
            }
            Picker("Format", selection: images.format) {
                ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            if current.format.usesQuality {
                HStack {
                    Text("Quality")
                    Slider(value: images.quality, in: 0.1...1)
                    Text("\(Int((current.quality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: 420)
            }
            if !current.format.hasAlpha {
                ColorPicker("Background for transparent areas", selection: backgroundColor(images), supportsOpacity: false)
            }
        }
        CardSection(title: "Size", icon: "arrow.up.left.and.arrow.down.right") {
            Picker("Resize", selection: images.resize) {
                ForEach(ResizeMode.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 280)
            switch current.resize {
            case .original:
                EmptyView()
            case .longestSide, .width, .height:
                PixelField(title: current.resize.title, value: images.length)
            case .exact:
                HStack(spacing: 16) {
                    PixelField(title: "Width", value: images.exactWidth)
                    PixelField(title: "Height", value: images.exactHeight)
                }
                Picker("Fit", selection: images.fit) {
                    ForEach(ExactFit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }
            Text("Smaller images are never enlarged, except to an exact size. Each image can be up to 20,000 px a side and 64 megapixels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        CardSection(title: "Details", icon: "slider.horizontal.3") {
            Toggle("Strip metadata such as location and camera details", isOn: images.stripsMetadata)
            Toggle("Add a text watermark", isOn: images.addsWatermark)
            if current.addsWatermark {
                TextField("Watermark text", text: images.watermark)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            HStack {
                Text("File name")
                TextField(NameTemplate.standard, text: images.nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            Text("Use \(NameTemplate.tokens.joined(separator: " ")). A number is added when the name is taken.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Keep the original modification date", isOn: images.keepsModificationDate)
            Toggle("Put results in a \"\(ImageConverter.subfolder)\" folder", isOn: images.usesSubfolder)
        }
    }

    private func backgroundColor(_ images: Binding<ImageConvertSettings>) -> Binding<Color> {
        Binding(get: {
            let color = ColorText.parse(images.wrappedValue.background)
            return Color(red: color?.red ?? 1, green: color?.green ?? 1, blue: color?.blue ?? 1)
        }, set: { newValue in
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            images.wrappedValue.background = ColorFormats.hex(ClipboardColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1))
        })
    }
}

private struct TrimFields: View {
    @EnvironmentObject var media: MediaToolsController
    let tab: MediaTab

    var body: some View {
        let trim = Binding(get: { media.trims[tab] ?? ClipTrim() }, set: { media.trims[tab] = $0 })
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Trim", isOn: trim.isOn)
            if trim.wrappedValue.isOn {
                HStack(spacing: 8) {
                    TextField("Start", text: trim.start, prompt: Text("0:00"))
                        .frame(width: 80)
                    Text("to").foregroundStyle(.secondary)
                    TextField("End", text: trim.end, prompt: Text(media.lengths[tab].map(ScreenRecording.elapsed) ?? "end"))
                        .frame(width: 80)
                    if let length = media.lengths[tab] {
                        Text("of \(ScreenRecording.elapsed(length))").foregroundStyle(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Text("Times like 1:05 or 65.5. Leave the end empty to keep going to the end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MegabytesField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: clamped, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("MB").foregroundStyle(.secondary)
            Stepper(title, value: clamped, in: TargetSizePlanner.sizeRange, step: 1)
                .labelsHidden()
        }
        .frame(maxWidth: 320)
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max($0, TargetSizePlanner.sizeRange.lowerBound), TargetSizePlanner.sizeRange.upperBound) })
    }
}

private struct PixelField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            TextField(title, value: Binding(get: { value }, set: { value = min(max($0, 1), ImageLimits.maxSide) }), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

private struct MediaRunSection: View {
    @EnvironmentObject var media: MediaToolsController
    let tab: MediaTab

    var body: some View {
        switch media.runs[tab] {
        case .running(let progress, let status)?:
            CardSection(title: "Working", icon: "hourglass") {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { media.cancel(tab) }
                }
            }
        case .finished(let result)?:
            MediaResultCard(tab: tab, result: result)
        case .failed(let message)?:
            CardSection(title: "Couldn't finish", icon: "exclamationmark.triangle.fill") {
                Text(message).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Run Again") { media.run(tab) }
                }
            }
        case nil:
            HStack {
                Spacer()
                Button(tab.actionTitle) { media.run(tab) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled((media.files[tab] ?? []).isEmpty)
            }
        }
    }
}

private struct MediaResultCard: View {
    @EnvironmentObject var media: MediaToolsController
    let tab: MediaTab
    let result: MediaResult

    var body: some View {
        CardSection(title: result.outputs.isEmpty ? "Nothing was saved" : "Done", icon: result.outputs.isEmpty ? "xmark.circle" : "checkmark.circle.fill") {
            if let first = result.outputs.first {
                HStack(spacing: 8) {
                    Text(bytes(result.bytesBefore)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(bytes(result.bytesAfter)).fontWeight(.semibold)
                    if let change {
                        Text(change).font(.caption).foregroundStyle(result.isLarger ? .orange : .green)
                    }
                }
                .font(.title3.monospacedDigit())
                Text(result.outputs.count > 1 ? "\(result.outputs.count) files saved" : first.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if result.isLarger {
                    Label("The new file is larger than the original.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(Array(result.notes.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
            if !result.failures.isEmpty {
                Text("\(result.failures.count) couldn't be converted:").font(.caption.weight(.semibold))
                ForEach(Array(result.failures.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
            }
            if let text = result.text {
                ScrollView {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                if let text = result.text {
                    Button("Copy") { ScreenTools.copy(text) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
                    .disabled(result.outputs.isEmpty)
                Button("Run Again") { media.run(tab) }
                Spacer()
            }
        }
    }

    private var change: String? {
        guard result.bytesBefore > 0 else { return nil }
        let percent = Int((Double(result.bytesAfter - result.bytesBefore) / Double(result.bytesBefore) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
