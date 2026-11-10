import AppKit
import CoreAudio
import MediaPlayer
import SwiftUI

@MainActor
final class MusicPlayer: ObservableObject {
    enum Keys {
        static let volume = "music.volume"
        static let outputUID = "music.outputUID"
        static let dopDevices = "music.dopDevices"
        static let shuffle = "music.shuffle"
        static let repeatMode = "music.repeat"
    }

    static let restartThreshold = 3.0

    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var isPlaying = false
    @Published private(set) var output: OutputStatus?
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var outputUID: String?
    @Published private(set) var dopDevices: Set<String>
    @Published var message: String?
    @Published var volume: Double {
        didSet {
            engine.setVolume(Float(volume))
            defaults.set(volume, forKey: Keys.volume)
        }
    }

    private let library: MusicLibrary
    private let defaults: UserDefaults
    private var isLoaded = false
    private var hasRemoteCommands = false
    private var artwork: (id: String, value: MPMediaItemArtwork?)?
    private lazy var engine = PlaybackEngine { [weak self] event in self?.handle(event) }

    init(library: MusicLibrary, defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 1
        outputUID = defaults.string(forKey: Keys.outputUID)
        dopDevices = Set(defaults.stringArray(forKey: Keys.dopDevices) ?? [])
        queue = PlaybackQueue(tracks: [], startAt: 0, shuffled: defaults.bool(forKey: Keys.shuffle),
                              repeatMode: RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off)
        engine.setVolume(Float(volume))
        engine.setOutput(uid: outputUID, dopDevices: dopDevices)
        AudioHardware.listen(to: kAudioHardwarePropertyDevices, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    var current: Track? { queue.current }
    var currentTime: Double { isLoaded ? engine.currentTime : 0 }
    var selectedDevice: AudioOutputDevice? {
        devices.first { $0.uid == outputUID } ?? devices.first { $0.id == AudioHardware.defaultOutputDeviceID() }
    }

    func play(_ tracks: [Track], startAt index: Int) {
        let shuffled = defaults.bool(forKey: Keys.shuffle)
        queue = PlaybackQueue(tracks: tracks, startAt: index, shuffled: shuffled, repeatMode: queue.repeatMode)
        startCurrent(at: 0)
    }

    func togglePlayPause() {
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else if isLoaded {
            engine.resume()
            isPlaying = true
        } else if queue.current != nil {
            return startCurrent(at: 0)
        }
        updateNowPlaying()
    }

    func next() {
        guard queue.advance(automatic: false) != nil else { return stopAtEnd() }
        startCurrent(at: 0)
    }

    func previous() {
        if currentTime > Self.restartThreshold || queue.retreat() == nil { return seek(to: 0) }
        startCurrent(at: 0)
    }

    func seek(to seconds: Double) {
        guard let track = queue.current else { return }
        if isLoaded {
            engine.seek(to: seconds)
        } else {
            engine.play(item(track), at: seconds, next: queue.peekNext().map(item), autoplay: false)
            isLoaded = true
        }
        updateNowPlaying(elapsed: seconds)
    }

    func toggleShuffle() {
        queue.setShuffled(!queue.isShuffled)
        defaults.set(queue.isShuffled, forKey: Keys.shuffle)
        syncNext()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        defaults.set(queue.repeatMode.rawValue, forKey: Keys.repeatMode)
        syncNext()
    }

    func playNext(_ tracks: [Track]) {
        guard queue.current != nil else { return play(tracks, startAt: 0) }
        queue.playNext(tracks)
        syncNext()
    }

    func addToQueue(_ tracks: [Track]) {
        guard queue.current != nil else { return play(tracks, startAt: 0) }
        queue.append(tracks)
        syncNext()
    }

    func removeFromQueue(at offset: Int) {
        queue.removeUpcoming(at: offset)
        syncNext()
    }

    func jump(toUpcoming offset: Int) {
        guard queue.jump(toUpcoming: offset) != nil else { return }
        startCurrent(at: 0)
    }

    func refreshDevices() {
        devices = AudioHardware.outputDevices()
    }

    func selectOutput(_ uid: String?) {
        outputUID = uid
        defaults.set(uid, forKey: Keys.outputUID)
        engine.setOutput(uid: uid, dopDevices: dopDevices)
    }

    func setDoP(_ enabled: Bool, for uid: String) {
        if enabled { dopDevices.insert(uid) } else { dopDevices.remove(uid) }
        defaults.set(Array(dopDevices), forKey: Keys.dopDevices)
        engine.setOutput(uid: outputUID, dopDevices: dopDevices)
    }

    private func startCurrent(at seconds: Double) {
        guard let track = queue.current else { return stopAtEnd() }
        setUpRemoteCommands()
        engine.play(item(track), at: seconds, next: queue.peekNext().map(item))
        isPlaying = true
        isLoaded = true
        message = nil
        updateNowPlaying(elapsed: seconds)
    }

    private func stopAtEnd() {
        engine.stop()
        isPlaying = false
        isLoaded = false
        output = nil
        updateNowPlaying(elapsed: 0)
    }

    private func syncNext() {
        guard isLoaded else { return }
        engine.setNext(queue.peekNext().map(item))
    }

    private func item(_ track: Track) -> PlaybackItem {
        PlaybackItem(id: track.id, url: library.url(for: track), format: track.format)
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .started(let item):
            if queue.current?.id != item.id, let offset = queue.upcoming.firstIndex(where: { $0.id == item.id }) {
                _ = queue.jump(toUpcoming: offset)
            }
            syncNext()
            updateNowPlaying()
        case .finished(let item):
            guard item.id == queue.current?.id else { return }
            guard queue.advance(automatic: true) != nil else { return stopAtEnd() }
            startCurrent(at: 0)
        case .failed(let item, let reason):
            let title = queue.tracks.first { $0.id == item.id }?.title ?? item.url.lastPathComponent
            guard item.id == queue.current?.id else { return }
            if queue.advance(automatic: false) != nil, queue.current?.id != item.id {
                startCurrent(at: 0)
            } else {
                stopAtEnd()
            }
            message = "Could not play “\(title)”: \(reason)"
        case .output(let status):
            output = status
        case .deviceLost:
            isPlaying = false
            message = "The output device was disconnected, so playback is paused."
            updateNowPlaying()
        }
    }

    private func setUpRemoteCommands() {
        guard !hasRemoteCommands else { return }
        hasRemoteCommands = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, @MainActor (MusicPlayer) -> Void)] = [
            (center.togglePlayPauseCommand, { $0.togglePlayPause() }),
            (center.playCommand, { if !$0.isPlaying { $0.togglePlayPause() } }),
            (center.pauseCommand, { if $0.isPlaying { $0.togglePlayPause() } }),
            (center.nextTrackCommand, { $0.next() }),
            (center.previousTrackCommand, { $0.previous() }),
        ]
        for (command, action) in commands {
            command.addTarget { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { if let self { action(self) } } }
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.seek(to: position) } }
            return .success
        }
    }

    private func updateNowPlaying(elapsed: Double? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        guard isLoaded, let track = queue.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed ?? currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if artwork?.id != track.id {
            let image = library.coverURL(for: track).flatMap(NSImage.init(contentsOf:))
            artwork = (track.id, image.map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } })
        }
        if let value = artwork?.value { info[MPMediaItemPropertyArtwork] = value }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
