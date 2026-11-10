import AppKit
import SwiftUI
import UserNotifications

struct MonitorView: View {
    @EnvironmentObject var monitor: SystemMonitor

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)]
    private var snapshot: MonitorSnapshot { monitor.snapshot }
    private var history: MonitorHistory { monitor.history }
    private var settings: MonitorSettings { monitor.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "gauge.with.dots.needle.67percent", title: "Monitor",
                           subtitle: "CPU, GPU, memory, network, disk, power and sensors, updated live.", colors: [.green, .mint])
                LazyVGrid(columns: columns, spacing: 16) {
                    cpuCard
                    memoryCard
                    gpuCard
                    networkCard
                    diskCard
                    powerCard
                    sensorsCard
                }
                menuBarCard
                alertsCard
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { monitor.setPageVisible(true) }
        .onDisappear { monitor.setPageVisible(false) }
    }

    private var cpuCard: some View {
        CardSection(title: "CPU", icon: "cpu") {
            headline(MonitorFormat.percent(snapshot.cpu), detail: monitor.cpuName)
            Sparkline(values: history.cpu.values, colors: [.blue, .cyan]).frame(height: 44)
            ForEach(snapshot.cores) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(group.loads.enumerated()), id: \.offset) { _, load in CoreBar(load: load) }
                    }
                    .frame(height: 28)
                }
            }
            if !snapshot.processes.isEmpty {
                Divider()
                ForEach(snapshot.processes) { process in row(process.name, String(format: "%.1f%%", process.percent)) }
                Text("Shows your own processes. System processes need administrator access.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var memoryCard: some View {
        CardSection(title: "Memory", icon: "memorychip") {
            if let memory = snapshot.memory {
                headline(MonitorFormat.percent(memory.percent(settings.memoryMetric)),
                         detail: "\(bytes(memory.bytes(settings.memoryMetric))) of \(bytes(memory.total))")
                Sparkline(values: history.memory.values, colors: [.purple, .pink]).frame(height: 44)
                HStack(spacing: 6) {
                    Circle().fill(Self.color(memory.pressure)).frame(width: 8, height: 8)
                    Text("Pressure: \(memory.pressure?.title ?? MonitorFormat.missing)")
                }
                .font(.callout)
                row("App", bytes(memory.app))
                row("Wired", bytes(memory.wired))
                row("Compressed", bytes(memory.compressed))
                row("Cached files", bytes(memory.cached))
                row("Swap", "\(bytes(memory.swapUsed)) of \(bytes(memory.swapTotal))")
            } else {
                unavailable
            }
            Picker("Memory means", selection: $monitor.settings.memoryMetric) {
                ForEach(MemoryMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var gpuCard: some View {
        CardSection(title: "GPU", icon: "cube.transparent") {
            if snapshot.gpu == nil && history.gpu.values.isEmpty {
                unavailable
            } else {
                headline(MonitorFormat.percent(snapshot.gpu), detail: "Device utilization")
                Sparkline(values: history.gpu.values, colors: [.green, .mint]).frame(height: 44)
            }
        }
    }

    private var networkCard: some View {
        CardSection(title: "Network", icon: "network") {
            HStack {
                rate(MonitorFormat.downArrow, snapshot.network?.incoming, color: .blue)
                Spacer()
                rate(MonitorFormat.upArrow, snapshot.network?.outgoing, color: .orange)
            }
            Sparkline(values: history.download.scaled, colors: [.blue, .cyan]).frame(height: 30)
            Sparkline(values: history.upload.scaled, colors: [.orange, .yellow]).frame(height: 30)
            row("This session", "\(MonitorFormat.downArrow) \(bytes(snapshot.networkTotal.incoming))  \(MonitorFormat.upArrow) \(bytes(snapshot.networkTotal.outgoing))")
            Picker("Units", selection: $monitor.settings.networkUnit) {
                ForEach(NetworkUnit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var diskCard: some View {
        CardSection(title: "Disk", icon: "internaldrive") {
            ForEach(snapshot.volumes) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(volume.name).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text("\(formatBytes(volume.free)) free of \(formatBytes(volume.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView(value: volume.usedPercent, total: 100).tint(Self.color(MonitorReadouts.level(volume.usedPercent)))
                }
            }
            row("Read", MonitorFormat.rate(snapshot.diskIO?.incoming, unit: .bytes))
            row("Write", MonitorFormat.rate(snapshot.diskIO?.outgoing, unit: .bytes))
            Sparkline(values: history.diskRead.scaled, colors: [.teal, .green]).frame(height: 30)
            Sparkline(values: history.diskWrite.scaled, colors: [.orange, .red]).frame(height: 30)
        }
    }

    private var powerCard: some View {
        CardSection(title: "Power", icon: "bolt.fill") {
            if let battery = snapshot.battery {
                headline(MonitorFormat.percent(battery.charge), detail: battery.isCharging ? "Charging" : battery.isPluggedIn ? "Plugged in" : "On battery")
                row("Battery power", MonitorFormat.watts(battery.watts))
                if let minutes = battery.minutesRemaining { row("Time remaining", MonitorFormat.minutes(minutes)) }
                if let health = battery.health { row("Health", MonitorFormat.percent(health)) }
                if let cycles = battery.cycleCount { row("Cycle count", "\(cycles)") }
                if let charger = battery.chargerWatts { row("Charger", MonitorFormat.watts(charger)) }
            } else {
                Text("No battery").font(.headline)
            }
            if let power = snapshot.sensors?.systemPower { row("System power", MonitorFormat.watts(power)) }
        }
    }

    private var sensorsCard: some View {
        CardSection(title: "Sensors", icon: "thermometer.medium") {
            if let sensors = snapshot.sensors {
                row("CPU", MonitorFormat.temperature(sensors.cpu))
                row("GPU", MonitorFormat.temperature(sensors.gpu))
                if let battery = sensors.battery { row("Battery", MonitorFormat.temperature(battery)) }
                if sensors.fans.isEmpty {
                    row("Fans", "None")
                } else {
                    ForEach(sensors.fans.indices, id: \.self) { index in
                        row(sensors.fans.count == 1 ? "Fan" : "Fan \(index + 1)", MonitorFormat.rpm(sensors.fans[index]))
                    }
                }
            } else {
                Text("Temperatures and fan speeds are unavailable on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var menuBarCard: some View {
        CardSection(title: "Menu bar", icon: "menubar.rectangle") {
            Text("Show live readouts in the menu bar. Use the arrows to change their order.").font(.caption).foregroundStyle(.secondary)
            ForEach(settings.readoutOrder) { readout in
                HStack {
                    Toggle(readout.title, isOn: Binding(get: { monitor.settings.readouts.contains(readout) }, set: { isOn in
                        if isOn { monitor.settings.readouts.insert(readout) } else { monitor.settings.readouts.remove(readout) }
                    }))
                    Spacer()
                    Button { monitor.settings.move(readout, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(readout == settings.readoutOrder.first)
                    Button { monitor.settings.move(readout, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(readout == settings.readoutOrder.last)
                }
            }
            Picker("Style", selection: $monitor.settings.readoutStyle) {
                ForEach(ReadoutStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Picker("Memory shows", selection: $monitor.settings.memoryReadout) {
                ForEach(MemoryReadoutStyle.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 360)
            Picker("Update every", selection: $monitor.settings.interval) {
                ForEach(MonitorSettings.intervals, id: \.self) { Text("\($0) s").tag($0) }
            }
            .frame(maxWidth: 360)
        }
    }

    private var alertsCard: some View {
        CardSection(title: "Alerts", icon: "bell.badge") {
            Text("Alerts arrive as notifications. MacKit asks for permission when you turn on the first one.").font(.caption).foregroundStyle(.secondary)
            alertRow("CPU at or above", isOn: $monitor.settings.alerts.cpu, value: $monitor.settings.alerts.cpuPercent,
                     range: MonitorAlertSettings.cpuRange, step: 5, unit: "%", note: "for 12 s")
            alertRow("CPU temperature at or above", isOn: $monitor.settings.alerts.cpuTemperature, value: $monitor.settings.alerts.cpuTemperatureLimit,
                     range: MonitorAlertSettings.cpuTemperatureRange, unit: "°C", note: "for 12 s")
            alertRow("Battery temperature at or above", isOn: $monitor.settings.alerts.batteryTemperature,
                     value: $monitor.settings.alerts.batteryTemperatureLimit, range: MonitorAlertSettings.batteryTemperatureRange, unit: "°C")
            Toggle("Memory pressure turns critical", isOn: $monitor.settings.alerts.memoryPressure)
            alertRow("A volume of 10 GB or more has less than", isOn: $monitor.settings.alerts.lowDisk, value: $monitor.settings.alerts.lowDiskPercent,
                     range: MonitorAlertSettings.lowDiskRange, unit: "% free")
            alertRow("Battery at or below", isOn: $monitor.settings.alerts.lowBattery, value: $monitor.settings.alerts.lowBatteryPercent,
                     range: MonitorAlertSettings.lowBatteryRange, step: 5, unit: "%", note: "not charging")
            Picker("Repeat an alert at most every", selection: $monitor.settings.alerts.cooldownMinutes) {
                ForEach(MonitorAlertSettings.cooldowns, id: \.self) { Text("\($0) min").tag($0) }
            }
            .frame(maxWidth: 360)
        }
    }

    private var unavailable: some View {
        Text("Unavailable").font(.headline).foregroundStyle(.secondary)
    }

    private func headline(_ value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func rate(_ arrow: String, _ value: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(arrow).foregroundStyle(color)
            Text(MonitorFormat.rate(value, unit: settings.networkUnit)).monospacedDigit()
        }
        .font(.system(size: 18, weight: .semibold, design: .rounded))
    }

    private func bytes(_ count: UInt64) -> String {
        formatBytes(Int64(clamping: count))
    }

    private func alertRow(_ title: String, isOn: Binding<Bool>, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String,
                          note: String? = nil) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Stepper(value: value, in: range, step: step) { Text("\(value.wrappedValue)\(unit)").monospacedDigit() }
                .fixedSize()
                .disabled(!isOn.wrappedValue)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    static func color(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .critical: .red
        case .warning: .yellow
        case .normal: .green
        case nil: .gray
        }
    }

    static func color(_ level: ReadoutCell.Level) -> Color {
        switch level {
        case .critical: .red
        case .elevated: .orange
        case .normal: .blue
        }
    }
}

private struct CoreBar: View {
    let load: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(MonitorView.color(MonitorReadouts.level(load ?? 0)).gradient)
                    .frame(height: geo.size.height * CGFloat(min(max((load ?? 0) / 100, 0), 1)))
            }
        }
        .frame(maxWidth: 14)
        .help(MonitorFormat.percent(load))
    }
}

struct MonitorMenu: View {
    @ObservedObject var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(MonitorSummary.lines(monitor.snapshot, settings: monitor.settings).enumerated()), id: \.offset) { Text($0.element) }
        Divider()
        Button("Open Monitor") {
            openWindow(id: "main")
            DispatchQueue.main.async {
                MainWindowController.show()
                NotificationCenter.default.post(name: .openSidebarPage, object: SidebarPage.monitor)
            }
        }
        Button("Hide Readouts") { monitor.settings.readouts = [] }
    }
}

enum ReadoutImage {
    static let height: CGFloat = 22
    static let cellGap: CGFloat = 8
    static let innerGap: CGFloat = 3
    static let barSize = NSSize(width: 5, height: 14)
    static let dotSize: CGFloat = 7
    static let barRadius: CGFloat = 1.5
    static let trackAlpha: CGFloat = 0.25
    static let labelAlpha: CGFloat = 0.6

    private struct Layout {
        let label: CGFloat
        let dot: CGFloat
        let value: CGFloat

        var width: CGFloat {
            let parts = [label, dot, value].filter { $0 > 0 }
            return parts.reduce(0, +) + ReadoutImage.innerGap * CGFloat(max(parts.count - 1, 0))
        }
    }

    private static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    private static var stackedFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .medium) }
    private static var labelFont: NSFont { .systemFont(ofSize: 9, weight: .semibold) }

    static func make(_ cells: [ReadoutCell]) -> NSImage {
        let layouts = cells.map(layout)
        let width = layouts.map(\.width).reduce(0, +) + cellGap * CGFloat(max(layouts.count - 1, 0))
        let usesColor = cells.contains(where: \.needsColor)
        let image = NSImage(size: NSSize(width: max(ceil(width), 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (cell, layout) in zip(cells, layouts) {
                draw(cell, layout: layout, at: x, usesColor: usesColor)
                x += layout.width + cellGap
            }
            return true
        }
        image.isTemplate = !usesColor
        return image
    }

    private static func font(for cell: ReadoutCell) -> NSFont {
        cell.lines.count > 1 ? stackedFont : valueFont
    }

    private static func size(_ text: String, _ font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private static func layout(_ cell: ReadoutCell) -> Layout {
        let label = cell.label.map { size($0, labelFont).width } ?? 0
        let dot = cell.pressure == nil ? 0 : dotSize
        let font = font(for: cell)
        let value = cell.bar != nil ? barSize.width : (cell.templates + cell.lines).map { size($0, font).width }.max() ?? 0
        return Layout(label: ceil(label), dot: dot, value: ceil(value))
    }

    private static func draw(_ cell: ReadoutCell, layout: Layout, at origin: CGFloat, usesColor: Bool) {
        let ink = usesColor ? NSColor.labelColor : NSColor.black
        var x = origin
        if let label = cell.label {
            let text = size(label, labelFont)
            (label as NSString).draw(at: NSPoint(x: x, y: (height - text.height) / 2),
                                     withAttributes: [.font: labelFont, .foregroundColor: ink.withAlphaComponent(labelAlpha)])
            x += layout.label + innerGap
        }
        if let pressure = cell.pressure {
            dotColor(pressure).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: (height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
            x += dotSize + innerGap
        }
        if let bar = cell.bar {
            let track = NSRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
            ink.withAlphaComponent(trackAlpha).setFill()
            NSBezierPath(roundedRect: track, xRadius: barRadius, yRadius: barRadius).fill()
            barColor(cell.level, ink: ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: track.height * bar), xRadius: barRadius, yRadius: barRadius).fill()
            return
        }
        let font = font(for: cell)
        let lineHeight = size("0", font).height
        let top = (height + lineHeight * CGFloat(cell.lines.count)) / 2
        for (index, line) in cell.lines.enumerated() {
            let width = size(line, font).width
            (line as NSString).draw(at: NSPoint(x: x + layout.value - width, y: top - lineHeight * CGFloat(index + 1)),
                                    withAttributes: [.font: font, .foregroundColor: barColor(cell.level, ink: ink)])
        }
    }

    private static func dotColor(_ pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }

    private static func barColor(_ level: ReadoutCell.Level, ink: NSColor) -> NSColor {
        switch level {
        case .normal: ink
        case .elevated: .systemOrange
        case .critical: .systemRed
        }
    }
}

final class MonitorNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MonitorNotifier()

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        return center
    }

    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ alert: MonitorAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "monitor.\(alert.kind.rawValue)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
