import AppKit
import SwiftUI

struct VolumeEntry: Equatable {
    let name: String
    let isLink: Bool
}

enum DiskImageInfo {
    static func imagePath(mountedAt mountPoint: String, in data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let paths = images
            .filter { image in
                (image["system-entities"] as? [[String: Any]] ?? []).contains { ($0["mount-point"] as? String) == mountPoint }
            }
            .compactMap { $0["image-path"] as? String }
        return paths.count == 1 ? paths[0] : nil
    }

    static func imagePath(mountedAt mountPoint: String, runner: CommandRunning = SystemCommandRunner()) -> String? {
        let result = runner.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.status == 0 else { return nil }
        return imagePath(mountedAt: mountPoint, in: Data(result.output.utf8))
    }
}

enum InstallPlan {
    static let homebrewCache = "Library/Caches/Homebrew"

    static func appName(in entries: [VolumeEntry]) -> String? {
        let apps = entries.filter { !$0.isLink && ($0.name as NSString).pathExtension.lowercased() == "app" }
        return apps.count == 1 ? apps[0].name : nil
    }

    static func isDownloadedImage(_ path: String, home: URL) -> Bool {
        let cache = home.appendingPathComponent(homebrewCache).path + "/"
        return (path as NSString).pathExtension.lowercased() == "dmg" && !path.hasPrefix(cache)
    }

    static func targetFolder(inHome: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        inHome ? home.appendingPathComponent("Applications", isDirectory: true) : URL(fileURLWithPath: "/Applications", isDirectory: true)
    }
}

enum InstallResult: Equatable {
    case installed(URL)
    case alreadyInstalled
    case unverified
    case copyFailed
}

enum DiskImageInstaller {
    static let stagingPrefix = ".MacKit-Install-"

    static func install(_ app: URL, into folder: URL, fileManager: FileManager = .default, verify: (URL) -> Bool = verifySignature) -> InstallResult {
        let destination = folder.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return .alreadyInstalled }
        let staging = folder.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        guard (try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)) != nil,
              CommandRunner.run("/usr/bin/ditto", ["--noqtn", app.path, staged.path]).status == 0 else { return .copyFailed }
        guard verify(staged) else { return .unverified }
        guard !fileManager.fileExists(atPath: destination.path) else { return .alreadyInstalled }
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            return .copyFailed
        }
        return .installed(destination)
    }

    static func verifySignature(_ app: URL) -> Bool {
        guard CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { return false }
        if CommandRunner.run("/usr/sbin/spctl", ["--status"]).output.contains("disabled") { return true }
        return CommandRunner.run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path]).status == 0
    }
}

struct InstallOutcome: Equatable {
    var installed: Bool
    var ejected: Bool
    var trashed: Bool
    var wantedTrash = true

    func message(app: String) -> String {
        guard installed else { return "Couldn't install \(app)" }
        if !ejected { return "Installed \(app) · couldn't eject the disk image" }
        if wantedTrash && !trashed { return "Installed \(app) · couldn't move the disk image to the Trash" }
        return "Installed \(app)"
    }
}

struct DiskImageOffer: Identifiable, Equatable {
    let id = UUID()
    let volume: URL
    let imagePath: String
    let app: URL
    let imageFile: (device: Int, inode: Int)?

    var name: String { (app.lastPathComponent as NSString).deletingPathExtension }

    static func == (lhs: DiskImageOffer, rhs: DiskImageOffer) -> Bool { lhs.id == rhs.id }

    static func fileIdentity(_ path: String) -> (device: Int, inode: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? Int, let inode = attributes[.systemFileNumber] as? Int else { return nil }
        return (device, inode)
    }
}

struct DiskImageSettings: Codable, Equatable {
    var offersInstall = false
    var trashesImage = true
    var revealsApp = false
    var usesHomeApplications = false
}

@MainActor
final class DiskImageWatcher: ObservableObject {
    static let settingsKey = "diskImages.settings"
    static let messageTime: TimeInterval = 2.5

    @Published var settings: DiskImageSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applyObserver()
        }
    }
    @Published private(set) var offers: [DiskImageOffer] = []
    @Published private(set) var isInstalling = false

    private var mountObserver: NSObjectProtocol?
    private var panel: NSPanel?
    private let queue = DispatchQueue(label: "mackit.diskimages", qos: .userInitiated)
    private let hud = InputHUD()

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DiskImageSettings.self, from: $0) }
            ?? DiskImageSettings()
        applyObserver()
    }

    var current: DiskImageOffer? { offers.first }

    func dismiss(_ offer: DiskImageOffer) {
        offers.removeAll { $0.id == offer.id }
        showNextOffer()
    }

    func install(_ offer: DiskImageOffer) {
        guard !isInstalling else { return }
        isInstalling = true
        let target = InstallPlan.targetFolder(inHome: settings.usesHomeApplications)
        queue.async {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let result = DiskImageInstaller.install(offer.app, into: target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(offer, result: result) }
            }
        }
    }

    private func applyObserver() {
        if settings.offersInstall, mountObserver == nil {
            mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    if let volume { self?.inspect(volume) }
                }
            }
        } else if !settings.offersInstall, let mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(mountObserver)
            self.mountObserver = nil
        }
    }

    private func inspect(_ volume: URL) {
        let target = InstallPlan.targetFolder(inHome: settings.usesHomeApplications)
        queue.async {
            guard let imagePath = DiskImageInfo.imagePath(mountedAt: volume.path),
                  InstallPlan.isDownloadedImage(imagePath, home: FileManager.default.homeDirectoryForCurrentUser) else { return }
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isAliasFileKey]
            let entries = ((try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: keys)) ?? []).map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return VolumeEntry(name: url.lastPathComponent, isLink: values?.isSymbolicLink == true || values?.isAliasFile == true)
            }
            guard let name = InstallPlan.appName(in: entries) else { return }
            let app = volume.appendingPathComponent(name)
            guard let executable = Bundle(url: app)?.executableURL, FileManager.default.fileExists(atPath: executable.path),
                  !FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path) else { return }
            let offer = DiskImageOffer(volume: volume, imagePath: imagePath, app: app, imageFile: DiskImageOffer.fileIdentity(imagePath))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.offers.append(offer)
                    if self.offers.count == 1 { self.showNextOffer() }
                }
            }
        }
    }

    private func finish(_ offer: DiskImageOffer, result: InstallResult) {
        isInstalling = false
        offers.removeAll { $0.id == offer.id }
        switch result {
        case .installed(let installed):
            var outcome = InstallOutcome(installed: true, ejected: true, trashed: false, wantedTrash: settings.trashesImage)
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: offer.volume)
            } catch {
                outcome.ejected = false
            }
            if outcome.ejected && settings.trashesImage, let identity = offer.imageFile,
               let now = DiskImageOffer.fileIdentity(offer.imagePath), now == identity {
                outcome.trashed = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: offer.imagePath), resultingItemURL: nil)) != nil
            }
            if settings.revealsApp { NSWorkspace.shared.activateFileViewerSelecting([installed]) }
            hud.show(outcome.message(app: offer.name), for: Self.messageTime)
        case .alreadyInstalled:
            hud.show("\(offer.name) is already in Applications", for: Self.messageTime)
        case .unverified:
            hud.show("Couldn't verify \(offer.name), so it wasn't installed", for: Self.messageTime)
        case .copyFailed:
            hud.show("Couldn't copy \(offer.name). Nothing was changed.", for: Self.messageTime)
        }
        showNextOffer()
    }

    private func showNextOffer() {
        guard let offer = current else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        let panel = self.panel ?? KeyablePanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        let host = NSHostingController(rootView: DiskImageOfferView(offer: offer, watcher: self))
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

struct DiskImageOfferView: View {
    let offer: DiskImageOffer
    @ObservedObject var watcher: DiskImageWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: offer.app.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install \(offer.name)?").font(.headline)
                    Text("From \(URL(fileURLWithPath: offer.imagePath).lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Move the disk image to the Trash afterwards", isOn: $watcher.settings.trashesImage)
            Toggle("Show the app in Finder", isOn: $watcher.settings.revealsApp)
            Toggle("Install in my own Applications folder", isOn: $watcher.settings.usesHomeApplications)
            Text("The app is checked with Gatekeeper before it is moved. An app that is already installed is never replaced.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if watcher.isInstalling { ProgressView().controlSize(.small) }
                Spacer()
                Button("Not Now") { watcher.dismiss(offer) }.keyboardShortcut(.cancelAction).disabled(watcher.isInstalling)
                Button("Install") { watcher.install(offer) }.keyboardShortcut(.defaultAction).disabled(watcher.isInstalling)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
