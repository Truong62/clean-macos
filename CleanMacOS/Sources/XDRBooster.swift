import AppKit
import CoreImage
import Metal
import QuartzCore

@MainActor
final class XDRBooster {
    static let tick: TimeInterval = 0.25
    static let supportThreshold: CGFloat = 2.05
    static let protectedRunningApps = ["com.apple.SecurityAgent"]
    static let protectedFrontApps: Set<String> = ["com.apple.AppStore"]
    static let drawableSize = CGSize(width: 2, height: 2)

    var level = 1.0 {
        didSet { current = targetFactor() ?? current }
    }

    private var window: NSWindow?
    private var layer: CAMetalLayer?
    private var timer: Timer?
    private var current = 1.0
    private var isPaused = false
    private var observers: [NSObjectProtocol] = []
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()

    static var screen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.displayID, CGDisplayIsBuiltin(id) != 0 else { return false }
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > supportThreshold || screen.localizedName.contains("XDR")
        }
    }

    static var isSupported: Bool { screen != nil }

    static var model: XDRModel {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let name = String(cString: brand)
        return name.contains("M1") || name.contains("M2") ? .firstGeneration : .laterGenerations
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil, device != nil, Self.isSupported else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPaused = true
                    self?.hideOverlay()
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPaused = false }
            },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        step()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        hideOverlay()
        current = 1
    }

    private var isProtectedScreenShowing: Bool {
        if Self.protectedFrontApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") { return true }
        return Self.protectedRunningApps.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    private func targetFactor() -> Double? {
        guard let screen = Self.screen else { return nil }
        return Self.model.factor(level: level, headroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                                 potential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
    }

    private func step() {
        guard !isPaused, let screen = Self.screen, !isProtectedScreenShowing, let target = targetFactor() else { return hideOverlay() }
        showOverlay(on: screen)
        current = XDRModel.smooth(current: current, target: target)
        present(current)
    }

    private func showOverlay(on screen: NSScreen) {
        if let window, window.frame == screen.frame { return }
        hideOverlay()
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.isOpaque = false
        layer.drawableSize = Self.drawableSize
        layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        self.layer = layer
    }

    private func hideOverlay() {
        window?.orderOut(nil)
        window = nil
        layer = nil
    }

    private func present(_ factor: Double) {
        guard let layer, let queue, let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: factor, green: factor, blue: factor, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
