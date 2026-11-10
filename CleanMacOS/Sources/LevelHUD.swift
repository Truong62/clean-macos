import AppKit
import SwiftUI

@MainActor
final class LevelHUDModel: ObservableObject {
    @Published var symbol = "sun.max.fill"
    @Published var level = 0.0
    @Published var showsPercent = false
}

@MainActor
final class LevelHUD {
    static let size = NSSize(width: 196, height: 154)
    static let visibleTime: TimeInterval = 1
    static let fadeIn: TimeInterval = 0.1
    static let fadeOut: TimeInterval = 0.2
    static let heightShare: CGFloat = 0.2

    private var panel: NSPanel?
    private let model = LevelHUDModel()
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, level: Double, showsPercent: Bool, on screen: NSScreen?) {
        model.symbol = symbol
        model.level = level
        model.showsPercent = showsPercent
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let frame = (screen ?? NSScreen.main)?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + frame.height * Self.heightShare))
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeIn
                panel.animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleTime, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: LevelHUDView(model: model))
        return panel
    }
}

struct LevelHUDView: View {
    static let segments = 16

    @ObservedObject var model: LevelHUDModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.symbol).font(.system(size: 44, weight: .medium)).foregroundStyle(.white)
            if model.showsPercent {
                Text("\(Int((model.level * 100).rounded()))%").font(.headline.monospacedDigit()).foregroundStyle(.white)
            }
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(index) < (model.level * Double(Self.segments)).rounded() ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .frame(width: LevelHUD.size.width, height: LevelHUD.size.height)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.72)))
    }
}
