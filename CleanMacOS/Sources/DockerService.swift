import Foundation

/// Reclaimable space reported by `docker system df`, in bytes.
struct DockerUsage: Sendable {
    let imagesReclaimable: Int64
    let containersReclaimable: Int64
    let buildCacheReclaimable: Int64
    let volumesReclaimable: Int64

    /// Reclaimable without losing persistent data — images can be re-pulled, build cache
    /// regenerates, stopped containers are disposable. Volumes are intentionally excluded.
    var safeReclaimable: Int64 {
        imagesReclaimable + containersReclaimable + buildCacheReclaimable
    }
}

/// Talks to the Docker CLI to report and reclaim space the *safe* way (prune unused data)
/// instead of deleting Docker's whole VM disk image.
final class DockerService: Sendable {

    static let knownBinaryPaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// Path to a usable `docker` executable, or nil if Docker CLI isn't installed.
    func dockerBinary() -> String? {
        let fm = FileManager.default
        let homeBin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin/docker").path
        for path in [homeBin] + Self.knownBinaryPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    var isInstalled: Bool { dockerBinary() != nil }

    /// Parsed `docker system df`. Returns nil when the CLI is missing or the daemon isn't running.
    func usage() -> DockerUsage? {
        guard let bin = dockerBinary(),
              let out = Self.run(bin, ["system", "df", "--format", "{{json .}}"]),
              !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var images: Int64 = 0, containers: Int64 = 0, cache: Int64 = 0, volumes: Int64 = 0
        var sawRow = false

        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["Type"] as? String,
                  let reclaimable = obj["Reclaimable"] as? String
            else { continue }

            sawRow = true
            let bytes = Self.parseSize(reclaimable)
            switch type {
            case "Images": images = bytes
            case "Containers": containers = bytes
            case "Local Volumes": volumes = bytes
            case "Build Cache": cache = bytes
            default: break
            }
        }

        guard sawRow else { return nil }
        return DockerUsage(
            imagesReclaimable: images,
            containersReclaimable: containers,
            buildCacheReclaimable: cache,
            volumesReclaimable: volumes
        )
    }

    /// `docker system prune -af` — removes unused images, build cache and stopped containers.
    /// Volumes are deliberately NOT pruned: they hold persistent data (databases, etc.).
    func pruneStrategy() -> ReclaimStrategy? {
        guard let bin = dockerBinary() else { return nil }
        return .command(tool: bin, args: ["system", "prune", "-af"])
    }

    // MARK: - Helpers

    /// Parses Docker's human-readable size strings into bytes, e.g.
    /// "1.2GB (50%)" -> 1_200_000_000, "800MB" -> 800_000_000, "0B" -> 0.
    /// Docker's `system df` uses base-1000 units (kB, MB, GB).
    static func parseSize(_ raw: String) -> Int64 {
        let head = raw.split(separator: "(").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? raw
        let pattern = #"^([0-9]*\.?[0-9]+)\s*([A-Za-z]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let numRange = Range(m.range(at: 1), in: head),
              let unitRange = Range(m.range(at: 2), in: head),
              let value = Double(head[numRange])
        else { return 0 }

        let multiplier: Double
        switch head[unitRange].uppercased() {
        case "B":          multiplier = 1
        case "KB":         multiplier = 1_000
        case "KIB":        multiplier = 1_024
        case "MB":         multiplier = 1_000_000
        case "MIB":        multiplier = 1_048_576
        case "GB":         multiplier = 1_000_000_000
        case "GIB":        multiplier = 1_073_741_824
        case "TB":         multiplier = 1_000_000_000_000
        case "TIB":        multiplier = 1_099_511_627_776
        default:           multiplier = 1
        }
        return Int64(value * multiplier)
    }

    static func run(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
