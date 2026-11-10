import AppKit
import SwiftUI

struct PinnedPreviewSelection {
    var index = 0
    private(set) var ids: [String] = []
    var selected: String? { ids.indices.contains(index) ? ids[index] : nil }

    mutating func update(_ ids: [String]) {
        let previous = selected
        self.ids = ids
        index = previous.flatMap { ids.firstIndex(of: $0) } ?? min(index, max(0, ids.count - 1))
    }

    mutating func step(_ delta: Int) {
        guard !ids.isEmpty else { index = 0; return }
        index = ((index + delta) % ids.count + ids.count) % ids.count
    }
}

enum PreviewDragGeometry {
    static func placed(window: CGRect, pointer: CGPoint, visible: CGRect) -> CGRect {
        CGRect(x: min(max(pointer.x, visible.minX), max(visible.minX, visible.maxX - window.width)),
               y: min(max(pointer.y, visible.minY), max(visible.minY, visible.maxY - window.height)), width: window.width, height: window.height)
    }
}

@MainActor
final class SwitcherPinnedPreview: ObservableObject, Identifiable {
    let id = UUID()
    let pid: Int32
    @Published private(set) var windows: [SwitcherWindow] = []
    @Published var selection = PinnedPreviewSelection()
    private weak var controller: SwitcherController?
    private var panel: SwitcherPanel?
    private var refresh: Task<Void, Never>?

    init(window: SwitcherWindow, controller: SwitcherController) {
        pid = window.pid
        self.controller = controller
        windows = [window]
        selection.update([window.id])
    }

    var selected: SwitcherWindow? { windows.first { $0.id == selection.selected } }

    func show(at point: CGPoint) {
        guard let controller else { return }
        let panel = SwitcherPanel(contentRect: CGRect(x: point.x, y: point.y, width: 250, height: 239), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXUnknown"))
        panel.contentView = NSHostingView(rootView: PinnedPreviewView(preview: self, thumbnails: controller.thumbnails))
        self.panel = panel
        panel.orderFrontRegardless()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let controller = self.controller else { return }
                let windows = await controller.refreshPinned(pid: self.pid)
                guard !Task.isCancelled else { return }
                guard !windows.isEmpty else { self.close(); return }
                self.windows = windows
                self.selection.update(windows.map(\.id))
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func open() { if let selected { controller?.activatePinned(selected) } }
    func closeWindow() { if let selected { controller?.close(selected) } }
    func moveHeader(_ event: NSEvent) { panel?.performDrag(with: event) }

    func close() {
        refresh?.cancel()
        refresh = nil
        panel?.orderOut(nil)
        panel = nil
        controller?.removePin(id)
    }
}

private struct PinnedPreviewView: View {
    @ObservedObject var preview: SwitcherPinnedPreview
    @ObservedObject var thumbnails: SwitcherThumbnails

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if let window = preview.selected, let icon = AppIconCache.image(for: window.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(preview.selected?.appName ?? "Preview").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button { preview.selection.step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous window")
                Text("\(preview.selection.index + 1)/\(preview.windows.count)").font(.caption2.monospacedDigit())
                Button { preview.selection.step(1) } label: { Image(systemName: "chevron.right") }.help("Next window")
                Button { preview.close() } label: { Image(systemName: "pin.slash") }.help("Unpin preview")
                Button { preview.closeWindow() } label: { Image(systemName: "xmark") }.help("Close window")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(PinnedPreviewDragHeader(preview: preview))
            if let window = preview.selected {
                VStack(spacing: 7) {
                    Group {
                        if let image = thumbnails.images[window.id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                        else if let icon = AppIconCache.image(for: window.bundleID) { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(30) }
                        else { Image(systemName: "macwindow").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.frame(width: 220, height: 150)
                    Text(window.displayTitle).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { preview.open() }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
    }
}

private struct PinnedPreviewDragHeader: NSViewRepresentable {
    let preview: SwitcherPinnedPreview
    func makeNSView(context: Context) -> Header { Header(preview: preview) }
    func updateNSView(_ nsView: Header, context: Context) {}

    final class Header: NSView {
        let preview: SwitcherPinnedPreview
        init(preview: SwitcherPinnedPreview) { self.preview = preview; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func mouseDown(with event: NSEvent) { preview.moveHeader(event) }
    }
}
