import SwiftUI

@main
struct CleanMacOSApp: App {
    @StateObject private var vm = AppViewModel()
    @StateObject private var updater = UpdaterViewModel()
    @StateObject private var clipboard = ClipboardViewModel()
    private let menuBar = MenuBarController.shared

    var body: some Scene {
        Window("Clean macOS", id: "main") {
            ContentView()
                .environmentObject(vm)
                .environmentObject(updater)
                .environmentObject(clipboard)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setAppIcon()
                    menuBar.setup(showMenuBar: vm.showMenuBar)
                    clipboard.startMonitoring()
                }
                .onChange(of: vm.showMenuBar) {
                    menuBar.setup(showMenuBar: vm.showMenuBar)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Disable New Window (Cmd+N)
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: updater.automaticallyChecksForUpdates)
            }

            CommandGroup(after: .toolbar) {
                Button("Scan") {
                    Task { await vm.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func setAppIcon() {
        // Try loading from asset catalog
        if let image = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = image
            return
        }
        // Fallback: render icon programmatically — "Fresh" style (green→teal squircle + sparkles).
        let size: CGFloat = 512
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let r = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.06, dy: size * 0.06)
            let corner = r.width * 0.2237
            let cs = CGColorSpaceCreateDeviceRGB()

            // Squircle + diagonal green→teal gradient
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.clip()
            if let gradient = CGGradient(colorsSpace: cs, colors: [
                CGColor(red: 0.20, green: 0.82, blue: 0.55, alpha: 1),
                CGColor(red: 0.06, green: 0.62, blue: 0.74, alpha: 1),
            ] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
            }
            // Soft top highlight for depth
            if let hl = CGGradient(colorsSpace: cs, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray, locations: [0, 1]) {
                let c = CGPoint(x: r.midX, y: r.maxY - r.height * 0.12)
                ctx.drawRadialGradient(hl, startCenter: c, startRadius: 0, endCenter: c, endRadius: r.width * 0.75, options: [])
            }
            ctx.restoreGState()

            // Smaller white sparkles glyph with a soft shadow
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.34, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let symSize = symbol.size
                let tinted = NSImage(size: symSize)
                tinted.lockFocus()
                symbol.draw(in: NSRect(origin: .zero, size: symSize), from: .zero, operation: .sourceOver, fraction: 1.0)
                NSColor.white.set()
                NSRect(origin: .zero, size: symSize).fill(using: .sourceAtop)
                tinted.unlockFocus()

                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
                tinted.draw(in: NSRect(x: (size - symSize.width) / 2, y: (size - symSize.height) / 2,
                                       width: symSize.width, height: symSize.height))
                ctx.restoreGState()
            }
        }
        image.unlockFocus()
        NSApp.applicationIconImage = image
    }
}

#if canImport(Foundation)
// Make Bundle.module available for both SPM and Xcode builds
private extension Foundation.Bundle {
    static var _module: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }
}
#endif
