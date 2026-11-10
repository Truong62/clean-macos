import AppKit
import AVFoundation
import AVKit
import CoreAudio
import MacKitAudioBridge

struct AirPlayResampler {
    private var pending: [Float] = []
    private var position = 0.0

    var bufferedFrames: Int { pending.count / 2 }

    mutating func append(_ stereo: [Float]) { pending.append(contentsOf: stereo) }

    mutating func render(frames: Int, sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0, frames > 0 else { return [] }
        if pending.count > Int(sampleRate * 0.2) * 2 {
            pending = Array(pending.suffix(Int(sampleRate * 0.05) * 2))
            position = 0
        }
        let step = sampleRate / 44100
        var output = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let left = Int(position)
            guard (left + 1) * 2 + 1 < pending.count else { break }
            let fraction = Float(position - Double(left))
            for channel in 0..<2 {
                let first = pending[left * 2 + channel]
                let second = pending[(left + 1) * 2 + channel]
                output[index * 2 + channel] = first + (second - first) * fraction
            }
            position += step
        }
        let consumed = min(Int(position), pending.count / 2)
        pending.removeFirst(consumed * 2)
        position -= Double(consumed)
        return output
    }
}

enum AirPlayRouteLogic {
    static let uid = "mackit.airplay.shared"

    static func name(_ names: [String]) -> String? {
        let usable = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && !["unknown", "unknown device", "output device"].contains($0.lowercased())
        })
        return usable.isEmpty ? nil : usable.sorted().joined(separator: " + ")
    }

    static func pcm(_ samples: [Float]) -> [Int16] {
        let peak = samples.filter(\.isFinite).map(abs).max() ?? 0
        let gain: Float = peak > 0.944 ? 0.944 / peak : 1
        return samples.map { $0.isFinite ? Int16((min(1, max(-1, $0 * gain)) * 32767).rounded()) : 0 }
    }
}

final class AirPlayStream: @unchecked Sendable {
    let ring: OpaquePointer
    var sampleRate = 48000.0
    var resampler = AirPlayResampler()

    init?() {
        guard let ring = MKAudioRingCreate() else { return nil }
        self.ring = ring
    }

    deinit { MKAudioRingDestroy(ring) }

    var readyFrames: Int { Int(Double(MKAudioRingCount(ring) + resampler.bufferedFrames) * 44100 / max(1, sampleRate)) }

    func render(frames: Int) -> [Float] {
        let count = MKAudioRingCount(ring)
        var input = [Float](repeating: 0, count: count * 2)
        if count > 0 {
            let read = MKAudioRingRead(ring, &input, count)
            resampler.append(Array(input.prefix(read * 2)))
        }
        return resampler.render(frames: frames, sampleRate: sampleRate)
    }
}

@MainActor
final class AirPlayRoutes: NSObject, ObservableObject, @preconcurrency AVRoutePickerViewDelegate {
    @Published private(set) var available = false
    @Published private(set) var speaker: String?
    @Published private(set) var warning: String?
    static var pickerIsOpen = false
    static var dismissalAllowedAfter = Date.distantPast
    var onChange: (() -> Void)?
    private var context: AnyObject?
    private var contextID: String?
    private var renderer: AVSampleBufferAudioRenderer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var pickerWindow: NSWindow?
    private var picker: AVRoutePickerView?
    private var timer: Timer?
    private var contextObserver: NSObjectProtocol?
    private var streams: [String: AirPlayStream] = [:]
    private var failedSpeaker: String?
    private var nextTime = 0.0
    private var started = Date()
    private var lastFed = Date()
    private var lastPlaying = Date()
    private var lastRefresh = Date.distantPast
    private var playing = false
    private var timeout: DispatchWorkItem?

    func setRunning(_ running: Bool) {
        guard running else {
            timer?.invalidate()
            timer = nil
            stopRenderer()
            streams = [:]
            context = nil
            contextID = nil
            available = false
            closePicker()
            if let contextObserver { NotificationCenter.default.removeObserver(contextObserver) }
            contextObserver = nil
            return
        }
        guard timer == nil else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            warning = "AirPlay app routing requires macOS 27 or later."
            return
        }
        guard let context = MKAudioContext() as AnyObject?, let id = MKAudioRead(context, "contextID") as? String, !id.isEmpty,
              MKAudioSupports(AVRoutePickerView(), "setOutputContextID:"),
              MKAudioSupports(AVSampleBufferAudioRenderer(), "setOutputContext:") else {
            warning = "AirPlay self-test: required system routing hooks are unavailable."
            return
        }
        self.context = context
        contextID = id
        available = true
        warning = nil
        refresh()
        contextObserver = NotificationCenter.default.addObserver(forName: Notification.Name("AVOutputContextOutputDevicesDidChangeNotification"), object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var title: String { speaker.map { $0 + " · AirPlay" } ?? "AirPlay" }
    var connected: Bool { speaker != nil && speaker != failedSpeaker }

    func stream(for appID: String) -> AirPlayStream? {
        guard connected, startRenderer() else { return nil }
        return AirPlayStream()
    }

    func attach(_ stream: AirPlayStream, for appID: String) { streams[appID] = stream }

    func retainStreams(_ ids: Set<String>, playing: Bool) {
        streams = streams.filter { ids.contains($0.key) }
        if playing {
            if !self.playing && Date().timeIntervalSince(lastPlaying) >= 1 { stopRenderer() }
            lastPlaying = Date()
        }
        self.playing = playing
    }

    func chooseSpeaker() {
        guard available, let contextID else { return }
        failedSpeaker = nil
        refresh()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closePicker()
            let point = NSEvent.mouseLocation
            let window = NSWindow(contentRect: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.alphaValue = 0.01
            window.level = .popUpMenu
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            guard MKAudioSet(picker, "setOutputContextID:", contextID as NSString) else { return }
            picker.delegate = self
            window.contentView = picker
            self.picker = picker
            self.pickerWindow = window
            Self.pickerIsOpen = true
            window.orderFrontRegardless()
            func button(in view: NSView) -> NSButton? {
                if let button = view as? NSButton { return button }
                return view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            button(in: picker)?.performClick(nil)
            let timeout = DispatchWorkItem { [weak self] in self?.closePicker() }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
        }
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        closePicker()
        refresh()
        for delay in [1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    private func closePicker() {
        timeout?.cancel()
        pickerWindow?.orderOut(nil)
        pickerWindow = nil
        picker = nil
        if Self.pickerIsOpen { Self.dismissalAllowedAfter = Date(timeIntervalSinceNow: 0.35) }
        Self.pickerIsOpen = false
    }

    private func refresh() {
        guard let context else { return }
        let devices = MKAudioRead(context, "outputDevices") as? [AnyObject] ?? []
        let name = AirPlayRouteLogic.name(devices.compactMap { MKAudioRead($0, "deviceName") as? String })
        if name != speaker {
            speaker = name
            stopRenderer()
            onChange?()
        }
        lastRefresh = Date()
    }

    private func startRenderer() -> Bool {
        if renderer != nil { return true }
        guard let context, connected else { return false }
        let renderer = AVSampleBufferAudioRenderer()
        guard MKAudioSet(renderer, "setOutputContext:", context) else { return false }
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        synchronizer.setRate(1, time: .zero)
        guard renderer.status != .failed else { synchronizer.rate = 0; return false }
        self.renderer = renderer
        self.synchronizer = synchronizer
        started = Date()
        lastFed = started
        nextTime = 0.05
        return true
    }

    private func stopRenderer() {
        synchronizer?.rate = 0
        renderer?.flush()
        renderer = nil
        synchronizer = nil
    }

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastRefresh) >= 1.5 { refresh() }
        if !playing && now.timeIntervalSince(lastPlaying) >= 10 { stopRenderer(); return }
        guard !streams.isEmpty, connected else { return }
        guard startRenderer(), let renderer, let synchronizer else { return }
        if renderer.status == .failed || (playing && now.timeIntervalSince(lastFed) > 10) || (playing && renderer.status != .rendering && now.timeIntervalSince(started) > 60) {
            failedSpeaker = speaker
            warning = "AirPlay stopped responding. Choose a speaker to try again."
            stopRenderer()
            onChange?()
            return
        }
        let current = CMTimeGetSeconds(synchronizer.currentTime())
        if nextTime < current { nextTime = current + 0.05 }
        guard renderer.isReadyForMoreMediaData, nextTime + 2048.0 / 44100 - current <= 0.75 else { return }
        let frames = 2048
        guard streams.values.contains(where: { $0.readyFrames >= frames + 1 }) else { return }
        var mixed = [Float](repeating: 0, count: frames * 2)
        for stream in streams.values {
            let samples = stream.render(frames: frames)
            for index in mixed.indices { mixed[index] += samples[index] }
        }
        guard let sample = Self.buffer(AirPlayRouteLogic.pcm(mixed), at: nextTime) else { return }
        renderer.enqueue(sample)
        nextTime += Double(frames) / 44100
        lastFed = now
    }

    private static func buffer(_ samples: [Int16], at time: Double) -> CMSampleBuffer? {
        var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
                                            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                                                                   sampleCount: samples.count / 2, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 44100),
                                                                   packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
