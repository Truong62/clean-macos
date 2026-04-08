import SwiftUI
import Sparkle

final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { self.updaterController.updater.automaticallyChecksForUpdates },
            set: { self.updaterController.updater.automaticallyChecksForUpdates = $0 }
        )
    }
}
