import SwiftUI

@main
struct CleanMacOSApp: App {
    @StateObject private var vm = AppViewModel()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") {
                    Task { await vm.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: updater.automaticallyChecksForUpdates)
            }
        }
    }
}
