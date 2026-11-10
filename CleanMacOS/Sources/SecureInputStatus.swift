import AppKit
import Carbon
import IOKit
import SwiftUI

struct SecureInputSettings: Codable, Equatable {
    var isEnabled = false
}

enum SecureInputAttribution: Equatable {
    case inactive, unattributed, unknown
    case app(pid: Int32, name: String)

    static func resolve(enabled: Bool, readSucceeded: Bool, pid: Int32?, ownPID: Int32, name: String?, regular: Bool, running: Bool) -> Self {
        guard enabled else { return .inactive }
        guard readSucceeded else { return .unknown }
        guard let pid, running else { return .unattributed }
        guard pid != ownPID, regular, let name, !name.isEmpty else { return .unknown }
        return .app(pid: pid, name: name)
    }

    static func holder(in sessions: [[String: Any]], uid: UInt32) -> Int32? {
        sessions.first { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }
            .flatMap { ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value }
    }
}

@MainActor
final class SecureInputController: ObservableObject {
    static let key = "secureInput.settings"
    @Published var settings: SecureInputSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.key)
            updateTimer()
        }
    }
    @Published private(set) var state = SecureInputAttribution.inactive
    private var pages: Set<UUID> = []
    private var timer: Timer?

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SecureInputSettings.self, from: $0) } ?? SecureInputSettings()
    }

    func visibility(_ visible: Bool, page: UUID) {
        if visible { pages.insert(page) } else { pages.remove(page) }
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.isEnabled, !pages.isEmpty else { state = .inactive; return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.8
        self.timer = timer
    }

    private func refresh() {
        guard IsSecureEventInputEnabled() else { state = .inactive; return }
        let resource = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOResources"))
        guard resource != IO_OBJECT_NULL else { state = .unknown; return }
        defer { IOObjectRelease(resource) }
        guard let value = IORegistryEntryCreateCFProperty(resource, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let sessions = value as? [[String: Any]] else { state = .unknown; return }
        let pid = SecureInputAttribution.holder(in: sessions, uid: getuid())
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        state = .resolve(enabled: true, readSucceeded: true, pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier,
                         name: app?.localizedName, regular: app?.activationPolicy == .regular, running: app != nil)
    }
}

struct SecureInputStatusCard: View {
    @EnvironmentObject var controller: SecureInputController
    @State private var page = UUID()

    var body: some View {
        CardSection(title: "Secure Input", icon: "lock.shield") {
            Toggle("Show Secure Input status on this page", isOn: $controller.settings.isEnabled)
            if controller.settings.isEnabled {
                switch controller.state {
                case .inactive:
                    Text("Secure Input is not active.").foregroundStyle(.secondary)
                case .unknown:
                    Text("Secure Input is active; its owner could not be identified.").foregroundStyle(.orange)
                case .unattributed:
                    Text("Dismiss password fields, or log out and back in, to release Secure Input.").foregroundStyle(.orange)
                case .app(let pid, let name):
                    HStack {
                        Text("Secure Input may be held by \(name).").foregroundStyle(.orange)
                        Spacer()
                        Button("Show App") { NSRunningApplication(processIdentifier: pid)?.activate() }
                    }
                }
            }
        }
        .onAppear { controller.visibility(true, page: page) }
        .onDisappear { controller.visibility(false, page: page) }
    }
}
