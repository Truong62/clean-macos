import AppKit
import SwiftUI

struct IslandLockPolicy {
    static func visible(enabled: Bool, reasons: Set<String>, supported: Bool) -> Bool {
        enabled && supported && reasons == ["com.apple.screenIsLocked"]
    }
}

@MainActor
final class IslandLockScreen {
    private struct Scene {
        var panel: IslandPanel
        var space: IslandSpace
    }
    private var scenes: [Scene] = []
    private var displays: [UInt32] = []
    private var generation = 0
    private var played = false

    func update(_ controller: IslandController, visible: Bool) {
        guard visible else { hide(); return }
        played = played || controller.musicSample?.playing == true
        let screens = NSScreen.screens
        let identifiers = screens.compactMap(\.displayID)
        let wantsPlayer = played || controller.musicSample?.playing == true
        if identifiers != displays || scenes.isEmpty {
            let previousPlayed = played
            hide(immediate: true)
            played = previousPlayed
            displays = identifiers
            for (index, screen) in screens.enumerated() where index == 0 || screen.safeAreaInsets.top > 0 {
                let main = index == 0
                let size = CGSize(width: main ? 400 : 180, height: main ? 260 : 32)
                let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: main ? screen.frame.maxY - min(480, screen.frame.height * 0.6) : screen.frame.maxY - size.height)
                let panel = IslandPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.acceptsKeyboard = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.sharingType = .none
                panel.level = NSWindow.Level(rawValue: 400)
                panel.collectionBehavior = [.stationary, .ignoresCycle]
                panel.contentView = IslandLockHost(rootView: IslandLockView(controller: controller, main: main, played: wantsPlayer))
                let space = IslandSpace()
                guard space.attach(panel, absoluteLevel: 400) else { continue }
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.35; panel.animator().alphaValue = 1 }
                scenes.append(Scene(panel: panel, space: space))
            }
        } else {
            for (index, scene) in scenes.enumerated() {
                (scene.panel.contentView as? IslandLockHost)?.rootView = IslandLockView(controller: controller, main: index == 0, played: wantsPlayer)
            }
        }
    }

    func hide(immediate: Bool = false) {
        guard !scenes.isEmpty else { return }
        generation += 1
        let old = scenes
        scenes = []
        displays = []
        played = false
        for scene in old {
            if immediate { scene.panel.orderOut(nil); scene.space.detach() }
            else {
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; scene.panel.animator().alphaValue = 0 } completionHandler: {
                    MainActor.assumeIsolated { scene.panel.orderOut(nil); scene.space.detach() }
                }
            }
        }
    }
}

struct IslandLockView: View {
    @ObservedObject var controller: IslandController
    var main: Bool
    var played: Bool
    @State private var padlockClosed = false
    var body: some View {
        Group {
            if main {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        if controller.timer.active { Label(controller.timerText, systemImage: "timer") }
                        if let event = IslandCalendarLogic.countdown(controller.calendar.events, now: Date()) { Text(event.title).lineLimit(1) }
                        if controller.enabledTurns.contains(where: { $0.working(at: Date()) }) { Image(systemName: "sparkles") }
                        if controller.downloads.items.contains(where: { !$0.finished }) { Image(systemName: "arrow.down.circle") }
                    }.font(.caption).frame(height: 28)
                    if played, let sample = controller.musicSample {
                        VStack(spacing: 14) {
                            Image(systemName: "music.note").font(.largeTitle)
                            Text(sample.title).font(.headline).lineLimit(1)
                            Text(sample.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if sample.duration > 0 {
                                Slider(value: Binding(get: { sample.position(at: Date()) }, set: { controller.seekMusic($0) }), in: 0...sample.duration)
                            }
                            HStack(spacing: 40) {
                                Button { controller.skipMusic(next: false) } label: { Image(systemName: "backward.end.fill") }
                                Button { controller.toggleMusic() } label: { Image(systemName: sample.playing ? "pause.fill" : "play.fill") }
                                Button { controller.skipMusic(next: true) } label: { Image(systemName: "forward.end.fill") }
                            }.buttonStyle(.plain).font(.title2)
                        }.padding(20).frame(width: 400).frame(minHeight: 190).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    }
                }
            } else {
                HStack {
                    Image(systemName: padlockClosed ? "lock.fill" : "lock.open.fill")
                    if controller.musicSample?.playing == true { Image(systemName: "waveform") }
                }.padding(8).frame(width: 180, height: 32).background(.black, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { try? await Task.sleep(for: .seconds(0.35)); padlockClosed = true }
    }
}

final class IslandLockHost: NSHostingView<IslandLockView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
