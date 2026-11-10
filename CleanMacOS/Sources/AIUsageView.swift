import Charts
import SwiftUI

struct AIUsageView: View {
    static let sliceLimit = 12

    @EnvironmentObject var usage: AIUsageMonitor
    @State private var window = UsageWindow.today

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "chart.bar.xaxis", title: "AI Usage", subtitle: "Tokens and estimated cost of Claude Code and Codex on this Mac.",
                           colors: [.purple, .indigo])
                CardSection(title: "Tracking", icon: "power") {
                    Toggle("Track Claude Code and Codex usage", isOn: $usage.settings.isEnabled)
                    Text("Reads the session logs in ~/.claude and ~/.codex on this Mac. Nothing is sent anywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                    if usage.settings.isEnabled { status }
                }
                if usage.settings.isEnabled, usage.updatedAt != nil { report(now: Date()) }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { usage.refresh() }
    }

    @ViewBuilder private var status: some View {
        if let message = usage.message {
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        if let updated = usage.updatedAt {
            Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) · \(usage.files) log files").font(.caption).foregroundStyle(.secondary)
        } else if usage.isReading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the logs for the first time…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func report(now: Date) -> some View {
        let summary = UsageMath.summary(of: usage.rows, window: window, now: now, calendar: .current, prices: usage.prices)
        Picker("Period", selection: $window) {
            ForEach(UsageWindow.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
        overview(summary)
        chart(summary)
        live(now: now)
        breakdown("By agent", icon: "person.2.fill", summary.byAgent)
        breakdown("By model", icon: "cpu", summary.byModel)
        breakdown("By project", icon: "folder.fill", summary.byProject)
    }

    private func overview(_ summary: UsageSummary) -> some View {
        CardSection(title: window.title, icon: "dollarsign.circle") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.money(summary.total.cost)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("estimated").foregroundStyle(.secondary)
                Spacer()
                Text("\(Self.count(summary.total.tokens.total)) tokens").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow {
                    figure("Input", summary.total.tokens.input)
                    figure("Output", summary.total.tokens.output)
                    figure("Cache read", summary.total.tokens.cacheRead)
                    figure("Cache write", summary.total.tokens.cacheWrite)
                }
            }
            Text("Cache saved \(Self.money(summary.savings)) · \(summary.total.requests) requests · \(summary.sessions) sessions")
                .font(.callout).foregroundStyle(.secondary)
            Text("Estimated at API list prices as of \(AIPricing.asOf).").font(.caption).foregroundStyle(.secondary)
            if !summary.unpricedModels.isEmpty {
                Text("Not priced: \(summary.unpricedModels.map { $0.isEmpty ? "unknown model" : $0 }.joined(separator: ", ")) · \(Self.count(summary.total.unpricedTokens)) tokens")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func figure(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Self.count(value)).font(.body.weight(.semibold)).monospacedDigit()
        }
    }

    private func chart(_ summary: UsageSummary) -> some View {
        let showsCost = summary.total.cost > 0
        return CardSection(title: window == .today ? "Per hour" : "Per day", icon: "chart.bar.fill") {
            Chart(summary.bars) { bar in
                BarMark(x: .value("Time", bar.start, unit: window.barUnit), y: .value(showsCost ? "Cost" : "Tokens", showsCost ? bar.cost : Double(bar.tokens)))
                    .foregroundStyle(.purple.gradient)
            }
            .frame(height: 160)
        }
    }

    private func live(now: Date) -> some View {
        let burn = UsageMath.burnRate(of: usage.rows, now: now, prices: usage.prices)
        let block = UsageMath.activeBlock(of: usage.rows, now: now, prices: usage.prices)
        return CardSection(title: "Right now", icon: "gauge.with.dots.needle.33percent") {
            LabeledContent("Burn rate, last 30 minutes", value: "\(Self.money(burn.costPerHour))/h · \(Self.count(burn.tokensPerHour)) tokens/h")
            if let block {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Claude 5-hour block", value: "\(Self.money(block.usage.cost)) · \(Self.count(block.usage.tokens.total)) tokens")
                    ProgressView(value: min(now.timeIntervalSince(block.start), UsageBlock.length), total: UsageBlock.length)
                    Text("Started \(block.start.formatted(date: .omitted, time: .shortened)) · resets \(block.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Claude 5-hour block", value: "Not started")
            }
            ForEach(Array((usage.limits?.windows ?? []).enumerated()), id: \.offset) { _, limit in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Codex \(limit.title.lowercased()) limit", value: "\(Int(limit.percent(at: now).rounded()))% used")
                    ProgressView(value: limit.percent(at: now), total: 100)
                    if let reset = limit.resetDate {
                        Text(reset > now ? "Resets \(reset.formatted(date: .abbreviated, time: .shortened))" : "Reset since the last Codex request")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func breakdown(_ title: String, icon: String, _ slices: [UsageSlice]) -> some View {
        CardSection(title: title, icon: icon) {
            if slices.isEmpty {
                Text("No usage in this period.").foregroundStyle(.secondary)
            }
            ForEach(slices.prefix(Self.sliceLimit)) { slice in
                HStack {
                    Text(slice.name.isEmpty ? "Unknown" : slice.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Self.count(slice.tokens.total)) tokens").foregroundStyle(.secondary).monospacedDigit()
                    Text(slice.isPriced ? Self.money(slice.cost) + (slice.isPartlyPriced ? "+" : "") : "unpriced")
                        .monospacedDigit()
                        .frame(minWidth: 90, alignment: .trailing)
                }
            }
        }
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
