import AppKit
import SwiftUI

struct TransferProgressState: Equatable {
    var totalItems = 0
    var finishedItems = 0
    var totalBytes: Int64 = 0
    var finishedBytes: Int64 = 0
    var containsFolders = false
    var currentName = ""

    func fraction(currentBytes: Int64) -> Double? {
        guard !containsFolders, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(finishedBytes + max(0, currentBytes)) / Double(totalBytes)))
    }

    static func crossesVolumes(sources: [String?], destination: String?) -> Bool {
        guard let destination else { return false }
        return sources.contains { $0.map { $0 != destination } ?? false }
    }
}

@MainActor
final class FinderTransferProgress: ObservableObject {
    @Published var state = TransferProgressState()
    @Published var currentBytes: Int64 = 0
    @Published var result: String?
    private var panel: NSPanel?
    private var destination: URL?
    private var timer: Timer?
    private var generation = UUID()

    func begin(items: Int, bytes: Int64, folders: Bool) {
        generation = UUID()
        state = TransferProgressState(totalItems: items, totalBytes: bytes, containsFolders: folders)
        result = nil
        let frame = NSScreen.main?.visibleFrame ?? .zero
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - 143, y: frame.maxY - 110, width: 286, height: 94),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FinderTransferProgressView(progress: self))
        self.panel = panel
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let destination = self.destination else { return }
                self.currentBytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
    }

    func started(_ source: URL, destination: URL) {
        self.destination = destination
        currentBytes = 0
        state.currentName = source.lastPathComponent
    }

    func finished(bytes: Int64) {
        state.finishedItems += 1
        state.finishedBytes += max(0, bytes)
        currentBytes = 0
        destination = nil
    }

    func end(message: String) {
        guard panel != nil else { return }
        result = message
        timer?.invalidate()
        timer = nil
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
        }
    }
}

private struct FinderTransferProgressView: View {
    @ObservedObject var progress: FinderTransferProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = progress.result {
                Text(result).font(.callout)
            } else {
                Text("Moving \(min(progress.state.totalItems, progress.state.finishedItems + 1)) of \(progress.state.totalItems)").font(.callout.bold())
                Text(progress.state.currentName).lineLimit(1).font(.caption)
                if let value = progress.state.fraction(currentBytes: progress.currentBytes) { ProgressView(value: value) }
                else { ProgressView().controlSize(.small) }
            }
        }.padding(14).frame(width: 286, height: 94).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
