import Foundation

/// An installed application discovered under /Applications or ~/Applications.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let bundleID: String
    let path: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
}

/// Lists installed apps and locates every file an app leaves behind, so an uninstall is complete.
final class UninstallerService: Sendable {

    private static let appDirectories = ["/Applications", "/Applications/Utilities"]

    func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var dirs = Self.appDirectories
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path)

        var apps: [InstalledApp] = []
        var seenPaths = Set<String>()

        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") && !entry.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(entry)
                guard !seenPaths.contains(path),
                      let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.hasPrefix("com.apple.") // don't offer to uninstall Apple system apps
                else { continue }

                seenPaths.insert(path)
                let name = (entry as NSString).deletingPathExtension
                apps.append(InstalledApp(name: name, bundleID: bundleID, path: path))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app bundle plus every associated support/cache/preference/container file we can find.
    func leftovers(for app: InstalledApp) -> [Artifact] {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let id = app.bundleID
        let name = app.name

        // (path, description) for exact, bundle-ID / name based locations.
        var candidates: [(String, String)] = [
            (app.path, "Application bundle"),
            ("\(lib)/Application Support/\(id)", "Application support data"),
            ("\(lib)/Application Support/\(name)", "Application support data"),
            ("\(lib)/Caches/\(id)", "Cache"),
            ("\(lib)/Caches/\(name)", "Cache"),
            ("\(lib)/Preferences/\(id).plist", "Preferences"),
            ("\(lib)/Containers/\(id)", "Sandbox container"),
            ("\(lib)/Saved Application State/\(id).savedState", "Saved window state"),
            ("\(lib)/HTTPStorages/\(id)", "HTTP storage"),
            ("\(lib)/WebKit/\(id)", "WebKit data"),
            ("\(lib)/Cookies/\(id).binarycookies", "Cookies"),
            ("\(lib)/Logs/\(id)", "Logs"),
            ("\(lib)/Logs/\(name)", "Logs"),
            ("\(lib)/LaunchAgents/\(id).plist", "Launch agent"),
        ]

        // Group containers are prefixed with a team ID, so match by substring.
        let groupContainers = "\(lib)/Group Containers"
        if let entries = try? fm.contentsOfDirectory(atPath: groupContainers) {
            for entry in entries where entry.contains(id) {
                candidates.append(("\(groupContainers)/\(entry)", "Group container"))
            }
        }

        var artifacts: [Artifact] = []
        var seen = Set<String>()
        for (path, desc) in candidates {
            guard !seen.contains(path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            seen.insert(path)

            let size = isDir.boolValue
                ? ScannerService.calculateDirSize(path: path)
                : ScannerService.physicalSize(path: path)

            artifacts.append(Artifact(
                path: path,
                name: (path as NSString).lastPathComponent,
                size: size,
                category: .system,
                description: desc,
                needsSudo: false
            ))
        }

        return artifacts.sorted { $0.size > $1.size }
    }
}
