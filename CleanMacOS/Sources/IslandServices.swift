import AppKit
import EventKit
import IOKit.ps
import IOBluetooth

@MainActor
final class IslandCalendarService: ObservableObject {
    @Published private(set) var events: [IslandEvent] = []
    @Published private(set) var status = "Calendar is off"
    @Published private(set) var isRequestingAccess = false
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var enabled = false

    func setEnabled(_ enabled: Bool, request: Bool = false) {
        self.enabled = enabled
        if !enabled {
            events = []
            status = "Calendar is off"
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { refresh() }
        else if request {
            isRequestingAccess = true
            Task {
                defer { isRequestingAccess = false }
                do {
                    let granted = try await store.requestFullAccessToEvents()
                    guard self.enabled else { return }
                    if granted { refresh() } else { status = "Calendar access is off" }
                } catch { status = "Could not read calendars. Try again." }
            }
        } else { status = "Allow calendar access to show your agenda" }
    }

    func refresh() {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { events = []; return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map { event in
            IslandEvent(id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "Untitled event", start: event.startDate,
                        end: event.endDate, allDay: event.isAllDay, calendar: event.calendar.title, cancelled: event.status == .canceled,
                        declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true)
        }
        status = events.isEmpty ? "No events in the next seven days" : ""
    }
}

struct IslandDownload: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var name: String
    var bytes: Int64
    var modified: Date
    var inode: UInt64
    var finished = false
    var fraction: Double?
}

@MainActor
final class IslandDownloads: ObservableObject {
    static let bookmarkKey = "island.downloadFolder"
    @Published private(set) var items: [IslandDownload] = []
    @Published private(set) var status = "Choose a downloads folder"
    private var folder: URL?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var enabled = false
    private var generation = 0
    private var subscriber: Any?
    private var progress: [String: Progress] = [:]
    private var observations: [String: [NSKeyValueObservation]] = [:]
    private var progressWork: DispatchWorkItem?
    var onFinish: ((String) -> Void)?

    func setEnabled(_ value: Bool) {
        stop()
        enabled = value
        guard value else { items = []; return }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, FileManager.default.fileExists(atPath: url.path) else { status = "Folder unavailable. Choose it again."; return }
            _ = url.startAccessingSecurityScopedResource()
            folder = url
            status = url.lastPathComponent
            let token = generation
            subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] item in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.subscribe(item)
                }
                return { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == token, let path = item.fileURL?.path else { return }
                        self.progress.removeValue(forKey: path)
                        self.observations.removeValue(forKey: path)
                        self.scheduleScan()
                    }
                }
            }
            scan()
        } catch { status = "Folder unavailable. Choose it again." }
    }

    func choose() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            setEnabled(enabled)
        } catch { status = "Could not save folder access" }
    }

    func forget() {
        stop()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        items = []
        status = "Choose a downloads folder"
    }

    private func stop() {
        generation += 1
        pending?.cancel()
        pending = nil
        progressWork?.cancel()
        progressWork = nil
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        progress = [:]
        observations = [:]
        sources.forEach { $0.cancel() }
        sources = []
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
    }

    private func subscribe(_ item: Progress) {
        guard let folder, let url = item.fileURL, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              progress.count < 32, item.fileOperationKind == .downloading || item.fileOperationKind == .receiving else { return }
        progress[url.path] = item
        let changed: @Sendable (Progress, NSKeyValueObservedChange<Int64>) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleProgress() }
        }
        observations[url.path] = [item.observe(\.completedUnitCount, options: [.new], changeHandler: changed),
                                  item.observe(\.totalUnitCount, options: [.new], changeHandler: changed)]
        scheduleProgress()
    }

    private func scheduleProgress() {
        guard progressWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.progressWork = nil
                self?.scan()
            }
        }
        progressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func watch(_ urls: [URL]) {
        sources.forEach { $0.cancel() }
        sources = urls.compactMap { url in
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleScan() }
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            return source
        }
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scan() {
        guard enabled, let folder else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            status = "Folder unavailable. Choose it again."
            items = []
            return
        }
        let previous = items
        var partials: [IslandDownload] = []
        var watches = [folder]
        for url in urls where IslandDownloadLogic.finalName(url.lastPathComponent) != nil {
            guard partials.count < 32, let name = IslandDownloadLogic.finalName(url.lastPathComponent) else { continue }
            var payload = url
            if url.pathExtension == "download", let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
               let child = children.first(where: { $0.lastPathComponent != "Info.plist" }) { payload = child }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: payload.path) else { continue }
            partials.append(IslandDownload(url: url, name: name, bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                           modified: attrs[.modificationDate] as? Date ?? .distantPast,
                                           inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0))
            watches.append(url)
            if payload != url { watches.append(payload) }
        }
        var finished = previous.filter(\.finished)
        for old in previous where !old.finished && !partials.contains(where: { $0.url == old.url }) {
            let final = folder.appendingPathComponent(old.name)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: final.path),
               IslandDownloadLogic.completed(originalInode: old.inode, finalInode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                                             publisherFinished: (progress[old.url.path] ?? progress[final.path])?.isFinished == true) {
                let item = IslandDownload(url: final, name: old.name, bytes: (attrs[.size] as? NSNumber)?.int64Value ?? old.bytes,
                                          modified: Date(), inode: old.inode, finished: true)
                finished.removeAll { $0.url == final }
                finished.insert(item, at: 0)
                onFinish?(old.name)
            }
        }
        for index in partials.indices {
            let finalPath = folder.appendingPathComponent(partials[index].name).path
            if let publisher = progress[partials[index].url.path] ?? progress[finalPath] {
                partials[index].fraction = IslandDownloadLogic.fraction(completed: publisher.completedUnitCount, total: publisher.totalUnitCount)
                partials[index].modified = Date()
            }
        }
        items = partials.sorted { $0.modified > $1.modified } + finished.prefix(200)
        watch(watches)
    }
}

@MainActor
final class IslandMediaRemote: ObservableObject {
    @Published private(set) var sample: IslandMediaSample?
    private var library: UnsafeMutableRawPointer?
    private var generation = 0
    private var pending = false
    private var lastRequest = Date.distantPast

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
    }

    func stop() { generation += 1; sample = nil; pending = false }

    func refresh() {
        guard !pending || Date().timeIntervalSince(lastRequest) > 2 else { return }
        guard Date().timeIntervalSince(lastRequest) >= 2 else { return }
        guard let library, let symbol = dlsym(library, "MRMediaRemoteGetNowPlayingInfo") else { return }
        typealias Read = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
        let read = unsafeBitCast(symbol, to: Read.self)
        pending = true
        lastRequest = Date()
        let token = generation
        read(.main) { [weak self] dictionary in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.pending = false
                guard let values = dictionary as? [String: Any], let title = values["kMRMediaRemoteNowPlayingInfoTitle"] as? String else {
                    self.sample = nil
                    return
                }
                let rate = (values["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                self.sample = IslandMediaSample(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                                                artist: String((values["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "").prefix(300)),
                                                duration: (values["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0,
                                                elapsed: (values["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0,
                                                sampled: values["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(), rate: rate, playing: rate > 0)
            }
        }
    }
}

@MainActor
final class IslandPowerMonitor {
    private var source: CFRunLoopSource?
    private var edges = IslandBatteryEdges()
    var onNotice: ((String) -> Void)?

    func start() {
        guard source == nil else { return }
        edges = IslandBatteryEdges()
        read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<IslandPowerMonitor>.fromOpaque(context).takeUnretainedValue().read() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = value[kIOPSCurrentCapacityKey] as? Int, let maximum = value[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            if let message = edges.update(percent: current * 100 / maximum, connected: value[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue) { onNotice?(message) }
        }
    }
}

@MainActor
final class IslandBluetoothMonitor: NSObject {
    private var notification: IOBluetoothUserNotification?
    private var known = Set<String>()
    var onNotice: ((String) -> Void)?

    func start() {
        guard notification == nil else { return }
        known = Set((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }.compactMap(\.addressString))
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    func stop() { notification?.unregister(); notification = nil; known = [] }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString, let name = device.name, !name.isEmpty,
              device.deviceClassMajor != 1, device.deviceClassMajor != 2, known.insert(address).inserted else { return }
        onNotice?("\(name) connected")
    }
}
