import AppKit

enum IslandMusicSource: String, CaseIterable {
    case local, remote, music, spotify, helper
    var bundleID: String? {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        default: return nil
        }
    }
}

struct IslandMusicReading: Equatable {
    var source: IslandMusicSource
    var sample: IslandMediaSample
    var pid: Int32?
}

enum IslandMusicParsing {
    static func select(_ readings: [IslandMusicReading]) -> IslandMusicReading? {
        let valid = readings.filter { !$0.sample.title.isEmpty }
        return valid.first { $0.sample.playing } ?? valid.first
    }

    static func appleScript(_ fields: [String], source: IslandMusicSource, now: Date) -> IslandMediaSample? {
        guard fields.count == 7, source == .music || source == .spotify,
              let duration = Double(fields[3].replacingOccurrences(of: ",", with: ".")), let position = Double(fields[4].replacingOccurrences(of: ",", with: ".")),
              duration.isFinite, position.isFinite, ["playing", "paused", "stopped"].contains(fields[5]) else { return nil }
        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, fields[5] != "stopped" else { return nil }
        return IslandMediaSample(title: String(title.prefix(300)), artist: String(fields[1].prefix(300)),
                                 duration: max(0, duration / (source == .spotify ? 1000 : 1)), elapsed: max(0, position),
                                 sampled: now, rate: fields[5] == "playing" ? 1 : 0, playing: fields[5] == "playing",
                                 album: String(fields[2].prefix(300)), artworkURL: URL(string: fields[6]).flatMap { $0.scheme == "https" ? $0 : nil })
    }

    static func helper(_ data: Data, now: Date) -> IslandMusicReading? {
        guard data.count <= 4 * 1024 * 1024,
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = row["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let duration = (row["duration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (row["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let rate = (row["rate"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = (row["timestamp"] as? NSNumber)?.doubleValue
        guard duration.isFinite, elapsed.isFinite, rate.isFinite, timestamp?.isFinite != false else { return nil }
        let sample = IslandMediaSample(title: String(title.prefix(300)), artist: String((row["artist"] as? String ?? "").prefix(300)),
                                       duration: max(0, duration), elapsed: max(0, elapsed),
                                       sampled: timestamp.map { Date(timeIntervalSince1970: $0) } ?? now,
                                       rate: rate, playing: (row["playing"] as? Bool) ?? (rate > 0),
                                       album: String((row["album"] as? String ?? "").prefix(300)),
                                       artwork: (row["artwork"] as? String).flatMap { Data(base64Encoded: $0) })
        let pid = (row["pid"] as? NSNumber)?.int32Value
        return IslandMusicReading(source: .helper, sample: sample, pid: pid.flatMap { $0 > 0 ? $0 : nil })
    }
}

struct IslandMusicLines {
    private var pending = Data()
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            if end <= 4 * 1024 * 1024 { lines.append(Data(pending[..<end])) }
            pending.removeSubrange(...end)
        }
        if pending.count > 4 * 1024 * 1024 { pending.removeAll() }
        return lines
    }
}

enum IslandAppleScript {
    static func script(source: IslandMusicSource, command: String? = nil) -> String? {
        guard let bundle = source.bundleID else { return nil }
        let artwork = source == .spotify ? "set artURL to artwork url of current track" : "set artData to raw data of artwork 1 of current track"
        return """
        if application id "\(bundle)" is not running then return {}
        with timeout of 3 seconds
            tell application id "\(bundle)"
                \(command ?? "")
                if player state is stopped then return {}
                set artURL to ""
                set artData to ""
                try
                    \(artwork)
                end try
                return {name of current track, artist of current track, album of current track, duration of current track as text, player position as text, player state as text, artURL, artData}
            end tell
        end timeout
        """
    }

    static func read(source: IslandMusicSource, command: String? = nil) -> IslandMediaSample? {
        guard let text = script(source: source, command: command), let script = NSAppleScript(source: text) else { return nil }
        var error: NSDictionary?
        let reply = script.executeAndReturnError(&error)
        guard error == nil, reply.numberOfItems == 8 else { return nil }
        let fields = (1...7).map { reply.atIndex($0)?.stringValue ?? "" }
        var sample = IslandMusicParsing.appleScript(fields, source: source, now: Date())
        if source == .music, let data = reply.atIndex(8)?.data, data.count <= 3 * 1024 * 1024, NSImage(data: data) != nil { sample?.artwork = data }
        return sample
    }
}

@MainActor
final class IslandMusicFallbacks {
    private let queue = DispatchQueue(label: "MacKit.Island.AppleScript", qos: .utility)
    private var pending = Set<IslandMusicSource>()
    private var generation = 0
    private var lastPoll = Date.distantPast
    private var helper: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var lines = IslandMusicLines()
    private var lastHelper = Date.distantPast
    private var retryAfter = Date.distantPast
    private(set) var readings: [IslandMusicSource: IslandMusicReading] = [:]

    func refresh() {
        if Date().timeIntervalSince(lastHelper) > 4 { readings[.helper] = nil }
        startHelper()
        guard Date().timeIntervalSince(lastPoll) >= 1 else { return }
        lastPoll = Date()
        for source in [IslandMusicSource.music, .spotify] {
            guard let bundle = source.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                readings[source] = nil
                continue
            }
            poll(source, pid: app.processIdentifier)
        }
    }

    func command(_ command: String, source: IslandMusicSource) {
        guard let bundle = source.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        poll(source, pid: app.processIdentifier, command: command)
    }

    private func poll(_ source: IslandMusicSource, pid: Int32, command: String? = nil) {
        guard command != nil || !pending.contains(source) else { return }
        pending.insert(source)
        let token = generation
        queue.async {
            let sample = IslandAppleScript.read(source: source, command: command)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.pending.remove(source)
                self.readings[source] = sample.map { IslandMusicReading(source: source, sample: $0, pid: pid) }
            }
        }
    }

    func stop() {
        generation += 1
        pending.removeAll()
        readings.removeAll()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        helper = nil
        lines = IslandMusicLines()
        lastPoll = .distantPast
    }

    private func startHelper() {
        guard helper == nil, Date() >= retryAfter else { return }
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                for line in self.lines.append(data) {
                    self.lastHelper = Date()
                    self.readings[.helper] = IslandMusicParsing.helper(line, now: Date())
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.helper = nil
                self.input = nil
                self.output = nil
                self.readings[.helper] = nil
                self.lines = IslandMusicLines()
                self.retryAfter = Date().addingTimeInterval(3)
            }
        }
        do {
            try process.run()
            helper = process
            input = stdin
            output = stdout
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            retryAfter = Date().addingTimeInterval(3)
        }
    }

    static let script = #"""
    use strict;
    use warnings;
    use Foundation;
    use DynaLoader;
    use JSON::PP;
    use Encode qw(decode);
    use IO::Select;
    use Scalar::Util qw(blessed);
    DynaLoader::dl_load_file('/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote', 1) or die 'MediaRemote unavailable';
    package MRNowPlayingRequest;
    our @ISA = qw(PerlObjCBridge);
    package main;
    $| = 1;
    my $input = IO::Select->new(\*STDIN);
    while (1) {
        my %row;
        eval {
            my $item = MRNowPlayingRequest->localNowPlayingItem();
            if (blessed($item)) {
                my $info = $item->nowPlayingInfo();
                for my $field (['title', 'Title'], ['artist', 'Artist'], ['album', 'Album']) {
                    my $value = $info->objectForKey_('kMRMediaRemoteNowPlayingInfo' . $field->[1]);
                    $row{$field->[0]} = decode('UTF-8', $value->UTF8String()) if blessed($value);
                }
                for my $field (['duration', 'Duration'], ['elapsed', 'ElapsedTime'], ['rate', 'PlaybackRate']) {
                    my $value = $info->objectForKey_('kMRMediaRemoteNowPlayingInfo' . $field->[1]);
                    $row{$field->[0]} = $value->doubleValue() if blessed($value);
                }
                my $stamp = $info->objectForKey_('kMRMediaRemoteNowPlayingInfoTimestamp');
                $row{timestamp} = $stamp->timeIntervalSince1970() if blessed($stamp);
                my $art = $info->objectForKey_('kMRMediaRemoteNowPlayingInfoArtworkData');
                $row{artwork} = $art->base64EncodedStringWithOptions_(0)->UTF8String() if blessed($art) && $art->length() < 3000000;
                $row{playing} = MRNowPlayingRequest->localIsPlaying() ? JSON::PP::true : JSON::PP::false;
                my $path = MRNowPlayingRequest->localNowPlayingPlayerPath();
                $row{pid} = $path->client()->processIdentifier() if blessed($path);
            }
        };
        print JSON::PP->new->utf8->encode(\%row), "\n";
        if ($input->can_read(1)) {
            my $count = sysread(STDIN, my $buffer, 64);
            last unless $count;
        }
    }
    """#
}
