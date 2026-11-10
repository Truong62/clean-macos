import AppKit
import ScreenCaptureKit
import SwiftUI
import UserNotifications
import Vision

enum IslandWatchRule: String, CaseIterable { case changes, settles, contains, reaches }

struct IslandWatchLogic {
    var rule = IslandWatchRule.changes
    var query = ""
    var target = 100.0
    private(set) var baseline: String?
    private var changedAt: Double?
    private var stableAt: Double?
    private var previous: String?
    private var firstNumber: Double?
    private(set) var finished = false

    init(rule: IslandWatchRule = .changes, query: String = "", target: Double = 100) {
        self.rule = rule
        self.query = query
        self.target = target
    }

    mutating func pause() {
        changedAt = nil
        stableAt = nil
    }

    mutating func read(_ text: String, now: Double, locale: Locale = .current) -> Bool {
        guard !finished, now.isFinite else { return false }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return false }
        defer { previous = normalized }
        guard let baseline else {
            baseline = normalized
            firstNumber = Self.number(normalized, locale: locale)
            stableAt = now
            if rule == .contains { finished = !query.isEmpty && normalized.localizedCaseInsensitiveContains(query) }
            if rule == .reaches { finished = firstNumber == target }
            return finished
        }
        if normalized != previous || stableAt == nil { stableAt = now }
        switch rule {
        case .changes:
            if normalized == baseline { changedAt = nil }
            else if changedAt == nil { changedAt = now }
            finished = changedAt.map { now - $0 >= 3 } ?? false
        case .settles:
            if normalized != baseline && changedAt == nil { changedAt = now }
            finished = changedAt != nil && stableAt.map { now - $0 >= 30 } == true
        case .contains:
            finished = !query.isEmpty && normalized.localizedCaseInsensitiveContains(query)
        case .reaches:
            if let firstNumber, let number = Self.number(normalized, locale: locale), target.isFinite {
                finished = firstNumber <= target ? number >= target : number <= target
            }
        }
        return finished
    }

    static func number(_ text: String, locale: Locale) -> Double? {
        let expression = try? NSRegularExpression(pattern: #"[-+]?\d+(?:[.,\u00a0\u202f ]\d+)*(?:\s*%)?"#)
        let matches = expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        let values = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        guard let value = values.first(where: { $0.contains("%") }) ?? values.first else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let clean = value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let number = formatter.number(from: clean)?.doubleValue, number.isFinite else { return nil }
        return number
    }

    static func unchanged(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == 256, second.count == 256 else { return false }
        var changes = 0
        for (a, b) in zip(first, second) {
            let delta = abs(Int(a) - Int(b))
            if delta > 15 { return false }
            if delta > 0 { changes += 1 }
        }
        return changes <= 3
    }

    static func headline(_ text: String, line: Int) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "Watching…" }
        let selected = lines[min(max(0, line), lines.count - 1)]
        let expression = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?\s*%"#)
        if let match = expression?.firstMatch(in: selected, range: NSRange(selected.startIndex..., in: selected)), let range = Range(match.range, in: selected) { return String(selected[range]) }
        return String(selected.prefix(22))
    }
}

struct IslandWatchTarget {
    var display: UInt32
    var rect: CGRect
    var window: UInt32?
    var windowRect: CGRect?
    var app: String
}

enum IslandWatchPixels {
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return bytes
    }

    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

@MainActor
final class IslandWatchController: ObservableObject {
    @Published var rule = IslandWatchRule.changes
    @Published var query = ""
    @Published var targetNumber = 100.0
    @Published var line = 0
    @Published private(set) var active = false
    @Published private(set) var text = ""
    @Published private(set) var status = "Pick an area to watch"
    @Published private(set) var thumbnail: NSImage?
    private(set) var target: IslandWatchTarget?
    private var logic = IslandWatchLogic()
    private var fingerprint: [UInt8] = []
    private var lastOCR = Date.distantPast
    private var nextRead = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = 0
    var onFinish: ((String) -> Void)?
    var headline: String { IslandWatchLogic.headline(text, line: line) }

    func start(_ target: IslandWatchTarget) {
        stop()
        self.target = target
        logic = IslandWatchLogic(rule: rule, query: query, target: targetNumber)
        fingerprint = []
        text = ""
        lastOCR = .distantPast
        nextRead = .distantPast
        active = true
        status = "Watching \(target.app)"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func again() { if let target { start(target) } }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        active = false
        thumbnail = nil
    }

    func pause() {
        logic.pause()
        generation += 1
        task?.cancel()
        task = nil
        nextRead = .distantPast
        status = "Paused"
    }

    func tick(pageOpen: Bool) {
        guard active, task == nil, Date() >= nextRead, let target else { return }
        nextRead = Date().addingTimeInterval(pageOpen ? 1 : 2)
        let token = generation
        task = Task {
            defer { if token == generation { task = nil } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled, token == generation else { return }
                let filter: SCContentFilter
                let rect: CGRect
                if let id = target.window {
                    guard let window = content.windows.first(where: { $0.windowID == id }) else { finish("Window closed"); return }
                    if !window.isOnScreen {
                        logic.pause()
                        status = "Paused · window is minimized or on another Space"
                        return
                    }
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    rect = target.windowRect ?? CGRect(origin: .zero, size: window.frame.size)
                } else {
                    guard let display = content.displays.first(where: { $0.displayID == target.display }) else { status = "Paused · display disconnected"; return }
                    let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
                    filter = SCContentFilter(display: display, excludingWindows: own)
                    rect = target.rect
                }
                let configuration = SCStreamConfiguration()
                let scale = min(1, 900 / max(rect.width, rect.height))
                configuration.sourceRect = rect
                configuration.width = max(1, Int(rect.width * scale))
                configuration.height = max(1, Int(rect.height * scale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard !Task.isCancelled, token == generation else { return }
                thumbnail = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                let next = IslandWatchPixels.fingerprint(image)
                if !IslandWatchLogic.unchanged(fingerprint, next) || Date().timeIntervalSince(lastOCR) >= 10 {
                    let recognized = try await IslandWatchPixels.recognize(image)
                    guard !Task.isCancelled, token == generation else { return }
                    text = recognized
                    fingerprint = next
                    lastOCR = Date()
                }
                status = "Watching \(target.app)"
                if logic.read(text, now: ProcessInfo.processInfo.systemUptime) { finish("Watch complete") }
            } catch {
                if !Task.isCancelled && token == generation { status = "Capture unavailable · retrying" }
            }
        }
    }

    private func finish(_ outcome: String) {
        active = false
        status = "\(outcome) · \(target?.app ?? "Screen")"
        onFinish?(status)
    }
}

struct IslandWatchView: View {
    @ObservedObject var watch: IslandWatchController
    var pick: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(watch.status).font(.headline)
            if watch.active {
                Text(watch.headline).font(.title2)
                if let thumbnail = watch.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 90) }
                Stepper("Headline line \(watch.line + 1)", value: $watch.line, in: 0...max(0, watch.text.components(separatedBy: .newlines).count - 1))
                Button("Stop") { watch.stop() }
            } else {
                Picker("Rule", selection: $watch.rule) { ForEach(IslandWatchRule.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                if watch.rule == .contains { TextField("Text to find", text: $watch.query) }
                if watch.rule == .reaches { TextField("Target", value: $watch.targetNumber, format: .number) }
                HStack {
                    Button("Pick Area…", action: pick)
                    if watch.target != nil { Button("Watch Again") { watch.again() } }
                }
                Text("Screen Recording access is needed when you pick an area. Notifications are requested when a watch starts.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
