import SwiftUI
import Sparkle

struct PendingUpdate: Equatable {
    let version: String
    let notes: [String]
    let isDownloaded: Bool
}

final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private var installDownloadedUpdate: (() -> Void)?

    @Published var canCheckForUpdates = false
    @Published private(set) var pendingUpdate: PendingUpdate?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        pendingUpdate = nil
        updaterController.checkForUpdates(nil)
    }

    func installPendingUpdate() {
        guard let installDownloadedUpdate else { return checkForUpdates() }
        pendingUpdate = nil
        installDownloadedUpdate()
    }

    func dismissPendingUpdate() {
        pendingUpdate = nil
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

    private func offer(_ item: SUAppcastItem, isDownloaded: Bool) {
        let update = PendingUpdate(version: item.displayVersionString,
                                   notes: ReleaseFeed.bulletItems(fromHTML: item.itemDescription ?? ""),
                                   isDownloaded: isDownloaded)
        withAnimation(.spring(duration: 0.35)) { pendingUpdate = update }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installDownloadedUpdate = immediateInstallHandler
        offer(item, isDownloaded: true)
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        offer(update, isDownloaded: false)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        if installDownloadedUpdate == nil { pendingUpdate = nil }
    }
}

struct UpdateModal: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        if let update = updater.pendingUpdate {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { updater.dismissPendingUpdate() }
                UpdateCard(update: update, currentVersion: updater.currentVersion,
                           onLater: { withAnimation(.easeOut(duration: 0.2)) { updater.dismissPendingUpdate() } },
                           onInstall: updater.installPendingUpdate)
            }
            .transition(.opacity)
        }
    }
}

struct UpdateCard: View {
    let update: PendingUpdate
    let currentVersion: String
    let onLater: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clean macOS \(update.version) is available").font(.title3).fontWeight(.bold)
                    Text(update.isDownloaded ? "Downloaded and ready — you have \(currentVersion)." : "You have \(currentVersion).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !update.notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(update.notes, id: \.self) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "sparkle").font(.caption).foregroundStyle(.orange)
                                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(update.isDownloaded ? "Restart to Update" : "Update Now", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .glassCard(cornerRadius: 20)
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}
