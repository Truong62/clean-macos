import AVFoundation
import CoreAudio
import Foundation

struct PlaybackItem: Equatable, Sendable {
    let id: String
    let url: URL
    let format: TrackFormat
}

enum StreamKind: Equatable, Sendable {
    case pcm, dop, dsdToPCM
}

struct OutputStatus: Equatable, Sendable {
    let deviceName: String
    let deviceUID: String
    let device: DeviceFormat
    let isBluetooth: Bool
    let streamRate: Double
    let kind: StreamKind
}

enum PlaybackEvent: Sendable {
    case started(PlaybackItem)
    case finished(PlaybackItem)
    case failed(PlaybackItem, String)
    case output(OutputStatus)
    case deviceLost
}

enum PlaybackEngineError: LocalizedError {
    case noOutputDevice

    var errorDescription: String? { "No audio output device is available." }
}

final class PlaybackEngine: @unchecked Sendable {
    static let bufferSeconds = 0.5
    static let bufferCount = 3

    private struct Plan: Equatable {
        let device: AudioOutputDevice
        let deviceRate: Double
        let kind: StreamKind
        let dsdOutput: DSDOutput?
    }

    private struct Route {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let plan: Plan
        let format: AVAudioFormat
        let observer: NSObjectProtocol
    }

    private struct Timeline {
        var player: AVAudioPlayerNode?
        var base: AVAudioFramePosition = 0
        var origin: AVAudioFramePosition = 0
        var rate: Double = 1
        var frozen: Double? = 0
    }

    private let queue = DispatchQueue(label: "click.ngoctruong.CleanMacOS.playback", qos: .userInitiated)
    private let onEvent: @MainActor (PlaybackEvent) -> Void
    private let timelineLock = NSLock()
    private var timeline = Timeline()

    private var route: Route?
    private var generation = 0
    private var current: PlaybackItem?
    private var source: PCMSource?
    private var sourceItem: PlaybackItem?
    private var next: PlaybackItem?
    private var boundaries: [(frame: AVAudioFramePosition, item: PlaybackItem)] = []
    private var pending = 0
    private var scheduled: AVAudioFramePosition = 0
    private var isPlaying = false
    private var isEndOfStream = false
    private var volume: Float = 1
    private var outputUID: String?
    private var dopDevices: Set<String> = []

    init(onEvent: @escaping @MainActor (PlaybackEvent) -> Void) {
        self.onEvent = onEvent
        AudioHardware.listen(to: kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in self?.routeChanged(force: false) }
        AudioHardware.listen(to: kAudioHardwarePropertyDevices, queue: queue) { [weak self] in self?.routeChanged(force: false) }
    }

    var currentTime: Double {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return timeline.frozen ?? liveTime()
    }

    func play(_ item: PlaybackItem, at seconds: Double = 0, next: PlaybackItem?, autoplay: Bool = true) {
        queue.async { [self] in
            self.next = next
            start(item, at: seconds, autoplay: autoplay)
        }
    }

    func pause() { queue.async { [self] in pauseOnQueue() } }
    func resume() { queue.async { [self] in resumeOnQueue() } }
    func stop() { queue.async { [self] in stopOnQueue() } }
    func setNext(_ item: PlaybackItem?) { queue.async { [self] in updateNext(item) } }

    func seek(to seconds: Double) {
        queue.async { [self] in
            guard let current else { return }
            start(current, at: seconds, autoplay: isPlaying)
        }
    }

    func setVolume(_ value: Float) {
        queue.async { [self] in
            volume = value
            applyVolume()
        }
    }

    func setOutput(uid: String?, dopDevices: Set<String>) {
        queue.async { [self] in
            guard uid != outputUID || dopDevices != self.dopDevices else { return }
            outputUID = uid
            self.dopDevices = dopDevices
            guard let current, route != nil else { return }
            let position = currentTime
            tearDownRoute()
            start(current, at: position, autoplay: isPlaying)
        }
    }

    private func start(_ item: PlaybackItem, at seconds: Double, autoplay: Bool) {
        generation += 1
        resetStream()
        current = item
        do {
            let plan = try makePlan(for: item)
            let newSource = try makeSource(item, plan: plan)
            let startFrame = min(AVAudioFramePosition(max(0, seconds) * newSource.format.sampleRate), newSource.length)
            try newSource.seek(to: startFrame)
            let route = try ensureRoute(plan: plan, format: newSource.format)
            source = newSource
            sourceItem = item
            setTimeline(player: route.player, base: startFrame, origin: 0, rate: newSource.format.sampleRate,
                        frozen: autoplay ? nil : Double(startFrame) / newSource.format.sampleRate)
            isPlaying = autoplay
            fill()
            if autoplay {
                if !route.engine.isRunning { try route.engine.start() }
                route.player.play()
            }
            emit(.started(item))
            emitOutput(route)
        } catch {
            isPlaying = false
            setTimeline(player: nil, base: 0, origin: 0, rate: 1, frozen: 0)
            emit(.failed(item, error.localizedDescription))
        }
    }

    private func makePlan(for item: PlaybackItem) throws -> Plan {
        guard let device = resolveDevice() else { throw PlaybackEngineError.noOutputDevice }
        let rates = device.sampleRates
        guard item.format.isDSD else {
            return Plan(device: device, deviceRate: SampleRatePlan.deviceRate(for: item.format.sampleRate, supported: rates), kind: .pcm, dsdOutput: nil)
        }
        let allowDoP = dopDevices.contains(device.uid) && device.canCarryDoP && item.format.channels == 2
        let output = SampleRatePlan.dsdOutput(dsdRate: item.format.sampleRate, supported: rates, allowDoP: allowDoP)
        switch output {
        case .dop(let rate): return Plan(device: device, deviceRate: rate, kind: .dop, dsdOutput: output)
        case .pcm(let rate): return Plan(device: device, deviceRate: SampleRatePlan.deviceRate(for: rate, supported: rates), kind: .dsdToPCM, dsdOutput: output)
        }
    }

    private func resolveDevice() -> AudioOutputDevice? {
        let devices = AudioHardware.outputDevices()
        if let outputUID, let chosen = devices.first(where: { $0.uid == outputUID }) { return chosen }
        let defaultID = AudioHardware.defaultOutputDeviceID()
        return devices.first { $0.id == defaultID } ?? devices.first
    }

    private func makeSource(_ item: PlaybackItem, plan: Plan) throws -> PCMSource {
        if let output = plan.dsdOutput { return try DSDSource(url: item.url, output: output) }
        return try PCMFileSource(url: item.url)
    }

    private func ensureRoute(plan: Plan, format: AVAudioFormat) throws -> Route {
        if let route, route.plan == plan, route.format.sampleRate == format.sampleRate, route.format.channelCount == format.channelCount,
           AudioHardware.currentFormat(plan.device.id)?.sampleRate == plan.deviceRate {
            return route
        }
        tearDownRoute()
        AudioHardware.setFormat(plan.device.id, sampleRate: plan.deviceRate)
        let engine = AVAudioEngine()
        try engine.outputNode.auAudioUnit.setDeviceID(plan.device.id)
        let player = Self.attachPlayer(to: engine, format: format)
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.configurationChanged(engine) }
        }
        let route = Route(engine: engine, player: player, plan: plan, format: format, observer: observer)
        self.route = route
        applyVolume()
        engine.prepare()
        return route
    }

    static func attachPlayer(to engine: AVAudioEngine, format: AVAudioFormat) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: engine.outputNode.outputFormat(forBus: 0))
        return player
    }

    private func tearDownRoute() {
        guard let route else { return }
        NotificationCenter.default.removeObserver(route.observer)
        route.player.stop()
        route.engine.stop()
        self.route = nil
        timelineLock.lock()
        timeline.player = nil
        timelineLock.unlock()
    }

    private func resetStream() {
        route?.player.stop()
        pending = 0
        boundaries = []
        scheduled = 0
        source = nil
        sourceItem = nil
        isEndOfStream = false
    }

    private func fill() {
        guard let route else { return }
        while pending < Self.bufferCount, let source {
            let capacity = AVAudioFrameCount(source.format.sampleRate * Self.bufferSeconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: capacity) else { break }
            do {
                try source.read(into: buffer)
            } catch {
                if let sourceItem { emit(.failed(sourceItem, error.localizedDescription)) }
                endStream()
                break
            }
            guard buffer.frameLength > 0 else {
                if !chainNext(route: route) { endStream() }
                continue
            }
            let end = scheduled + AVAudioFramePosition(buffer.frameLength)
            let token = generation
            route.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { self?.bufferPlayed(token: token, end: end) }
            }
            scheduled = end
            pending += 1
        }
        if isEndOfStream && pending == 0 { finishStream() }
    }

    private func endStream() {
        source = nil
        sourceItem = nil
        isEndOfStream = true
    }

    private func chainNext(route: Route) -> Bool {
        guard let next, let plan = try? makePlan(for: next), plan == route.plan,
              let nextSource = try? makeSource(next, plan: plan),
              nextSource.format.sampleRate == route.format.sampleRate,
              nextSource.format.channelCount == route.format.channelCount else { return false }
        boundaries.append((scheduled, next))
        source = nextSource
        sourceItem = next
        self.next = nil
        return true
    }

    private func bufferPlayed(token: Int, end: AVAudioFramePosition) {
        guard token == generation else { return }
        pending -= 1
        while let boundary = boundaries.first, boundary.frame <= end {
            boundaries.removeFirst()
            current = boundary.item
            timelineLock.lock()
            timeline.base = 0
            timeline.origin = boundary.frame
            timelineLock.unlock()
            emit(.started(boundary.item))
        }
        fill()
    }

    private func finishStream() {
        isEndOfStream = false
        isPlaying = false
        freezeTimeline()
        if let current { emit(.finished(current)) }
    }

    private func updateNext(_ item: PlaybackItem?) {
        if let prefetched = boundaries.first, prefetched.item != item, let current {
            next = item
            start(current, at: currentTime, autoplay: isPlaying)
            return
        }
        guard boundaries.isEmpty else { return }
        next = item
        guard item != nil, source == nil, isEndOfStream, pending > 0, let route else { return }
        isEndOfStream = false
        if chainNext(route: route) { fill() } else { isEndOfStream = true }
    }

    private func pauseOnQueue() {
        guard isPlaying, let route else { return }
        freezeTimeline()
        route.player.pause()
        route.engine.pause()
        isPlaying = false
    }

    private func resumeOnQueue() {
        guard !isPlaying, let current else { return }
        guard let route, source != nil || pending > 0,
              AudioHardware.currentFormat(route.plan.device.id)?.sampleRate == route.plan.deviceRate else {
            return start(current, at: currentTime, autoplay: true)
        }
        do {
            if !route.engine.isRunning { try route.engine.start() }
            timelineLock.lock()
            timeline.frozen = nil
            timelineLock.unlock()
            route.player.play()
            isPlaying = true
        } catch {
            start(current, at: currentTime, autoplay: true)
        }
    }

    private func stopOnQueue() {
        generation += 1
        resetStream()
        tearDownRoute()
        current = nil
        next = nil
        isPlaying = false
        setTimeline(player: nil, base: 0, origin: 0, rate: 1, frozen: 0)
    }

    private func configurationChanged(_ engine: AVAudioEngine) {
        guard let route, route.engine === engine else { return }
        routeChanged(force: true)
    }

    private func routeChanged(force: Bool) {
        guard let route, let current else { return }
        let position = currentTime
        guard AudioHardware.device(route.plan.device.id) != nil else {
            generation += 1
            resetStream()
            tearDownRoute()
            isPlaying = false
            setTimeline(player: nil, base: 0, origin: 0, rate: 1, frozen: position)
            emit(.deviceLost)
            return
        }
        guard force || resolveDevice()?.id != route.plan.device.id else { return }
        let wasPlaying = isPlaying
        generation += 1
        resetStream()
        tearDownRoute()
        if wasPlaying {
            start(current, at: position, autoplay: true)
        } else {
            setTimeline(player: nil, base: 0, origin: 0, rate: 1, frozen: position)
        }
    }

    private func applyVolume() {
        guard let route else { return }
        route.engine.mainMixerNode.outputVolume = route.plan.kind == .dop ? 1 : volume
    }

    private func emitOutput(_ route: Route) {
        guard let format = AudioHardware.currentFormat(route.plan.device.id) else { return }
        emit(.output(OutputStatus(deviceName: route.plan.device.name, deviceUID: route.plan.device.uid, device: format,
                                  isBluetooth: route.plan.device.isBluetooth, streamRate: route.format.sampleRate, kind: route.plan.kind)))
    }

    private func setTimeline(player: AVAudioPlayerNode?, base: AVAudioFramePosition, origin: AVAudioFramePosition, rate: Double, frozen: Double?) {
        timelineLock.lock()
        timeline = Timeline(player: player, base: base, origin: origin, rate: rate, frozen: frozen)
        timelineLock.unlock()
    }

    private func freezeTimeline() {
        timelineLock.lock()
        timeline.frozen = liveTime()
        timelineLock.unlock()
    }

    private func liveTime() -> Double {
        let rate = max(timeline.rate, 1)
        guard let player = timeline.player, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return Double(timeline.base) / rate }
        return Double(timeline.base + max(0, playerTime.sampleTime - timeline.origin)) / rate
    }

    private func emit(_ event: PlaybackEvent) {
        let handler = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }
}
