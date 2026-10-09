import SwiftUI
import Sparkle

final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController!

    @Published var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        availableVersion = nil
        updaterController.checkForUpdates(nil)
    }

    func dismissAvailableUpdate() {
        availableVersion = nil
    }

    var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { self.updaterController.updater.automaticallyChecksForUpdates },
            set: { self.updaterController.updater.automaticallyChecksForUpdates = $0 }
        )
    }

    var automaticallyDownloadsUpdates: Binding<Bool> {
        Binding(
            get: { self.updaterController.updater.automaticallyDownloadsUpdates },
            set: { self.updaterController.updater.automaticallyDownloadsUpdates = $0 }
        )
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        withAnimation(.spring(duration: 0.45)) { availableVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

struct UpdateAvailableToast: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        if let version = updater.availableVersion {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available").font(.system(size: 13, weight: .semibold))
                    Text("Clean macOS \(version) is ready to install").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Later") { withAnimation(.easeOut(duration: 0.25)) { updater.dismissAvailableUpdate() } }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                Button("Update") { updater.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .pointerCursor()
            }
            .padding(14)
            .frame(width: 380)
            .glassCard(cornerRadius: 16)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .padding(20)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}
