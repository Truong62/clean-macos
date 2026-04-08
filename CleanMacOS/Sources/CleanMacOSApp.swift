import SwiftUI

@main
struct CleanMacOSApp: App {
    @StateObject private var vm = AppViewModel()
    @StateObject private var updater = UpdaterViewModel()
    private let menuBar = MenuBarController.shared

    var body: some Scene {
        Window("Clean macOS", id: "main") {
            ContentView()
                .environmentObject(vm)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setAppIcon()
                    menuBar.setup(showMenuBar: vm.showMenuBar)
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
        // Fallback: render icon programmatically
        do {
            let size: CGFloat = 512
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                let rect = CGRect(x: size * 0.02, y: size * 0.02, width: size * 0.96, height: size * 0.96)
                let path = CGPath(roundedRect: rect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
                ctx.addPath(path)
                ctx.clip()

                let colors = [
                    CGColor(red: 0.2, green: 0.45, blue: 1.0, alpha: 1.0),
                    CGColor(red: 0.35, green: 0.3, blue: 0.95, alpha: 1.0),
                ]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
                }

                let config = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .medium)
                if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let symSize = symbol.size
                    let x = (size - symSize.width) / 2
                    let y = (size - symSize.height) / 2
                    let tinted = NSImage(size: symSize)
                    tinted.lockFocus()
                    NSColor.white.set()
                    symbol.draw(in: NSRect(origin: .zero, size: symSize), from: .zero, operation: .sourceOver, fraction: 1.0)
                    NSRect(origin: .zero, size: symSize).fill(using: .sourceAtop)
                    tinted.unlockFocus()
                    tinted.draw(in: NSRect(x: x, y: y, width: symSize.width, height: symSize.height), from: .zero, operation: .sourceOver, fraction: 0.95)
                }
            }
            image.unlockFocus()
            NSApp.applicationIconImage = image
        }
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
