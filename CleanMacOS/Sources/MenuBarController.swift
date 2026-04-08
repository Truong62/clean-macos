import AppKit
import SwiftUI

final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let monitor = SystemMonitor()
    private var labelTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "menubar.label", qos: .utility)

    override private init() { super.init() }

    func setup(showMenuBar: Bool) {
        if showMenuBar { show() } else { hide() }
    }

    func show() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Clean macOS")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 300, height: 400)
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = NSHostingController(rootView: MenuBarView(monitor: monitor))
        popover = pop

        // Start background sampling — chỉ đọc CPU nhẹ, không update UI
        monitor.startSampling(interval: 3)
        startLabelUpdate()
    }

    func hide() {
        stopLabelUpdate()
        monitor.stopSampling()
        popover?.close()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
    }

    // MARK: - Label update (chỉ set text, không trigger SwiftUI)

    private func startLabelUpdate() {
        stopLabelUpdate()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cpu = String(format: " %.0f%%", self.monitor.latestCPU)
            DispatchQueue.main.async {
                self.statusItem?.button?.title = cpu
            }
        }
        t.resume()
        labelTimer = t
    }

    private func stopLabelUpdate() {
        labelTimer?.cancel()
        labelTimer = nil
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.popoverDidOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        monitor.popoverDidClose()
    }
}
