import Foundation
import SwiftUI

struct IslandAgentTurn: Equatable, Identifiable {
    var agent: AIAgent
    var session: String
    var start: Date
    var updated: Date
    var end: Date?
    var id: String { "\(agent.rawValue)|\(session)|\(start.timeIntervalSince1970)" }
    func working(at now: Date) -> Bool { end == nil && now >= updated && now.timeIntervalSince(updated) < 600 }
    func duration(at now: Date) -> Double { max(0, (end ?? now).timeIntervalSince(start)) }
}

enum IslandAgentLogs {
    static func parse(_ data: Data, agent: AIAgent, session: String) -> [IslandAgentTurn] {
        var turns: [IslandAgentTurn] = []
        var active: IslandAgentTurn?
        var sessionID = session
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let stamp = row["timestamp"] as? String, let date = formatter.date(from: stamp) ?? plain.date(from: stamp),
                  let type = row["type"] as? String else { continue }
            let payload = row["payload"] as? [String: Any] ?? [:]
            let message = row["message"] as? [String: Any] ?? [:]
            if type == "session_meta", let id = payload["id"] as? String { sessionID = id }
            if let id = row["sessionId"] as? String { sessionID = id }
            let starts: Bool
            let ends: Bool
            let activity: Bool
            if agent == .codex {
                starts = type == "event_msg" && payload["type"] as? String == "task_started"
                ends = type == "event_msg" && ["task_complete", "turn_aborted"].contains(payload["type"] as? String ?? "")
                activity = type == "event_msg" || type == "response_item"
            } else {
                let content = message["content"] as? [[String: Any]] ?? []
                starts = type == "user" && !content.contains { $0["type"] as? String == "tool_result" }
                ends = type == "assistant" && ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "")
                activity = type == "assistant" || type == "progress" || type == "user"
            }
            if starts {
                active = IslandAgentTurn(agent: agent, session: sessionID, start: date, updated: date)
            }
            if activity, let last = active?.updated, date >= last { active?.updated = date }
            if ends, var turn = active, date >= turn.start {
                turn.end = date
                turns.append(turn)
                active = nil
            }
        }
        if let active { turns.append(active) }
        return turns
    }

    static func read(paths: AIUsagePaths, now: Date) -> [IslandAgentTurn] {
        var turns: [IslandAgentTurn] = []
        for (agent, roots) in [(AIAgent.claude, paths.claude), (.codex, paths.codex)] {
            var recent: [(URL, Date)] = []
            for root in roots {
                guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in files where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                          let modified = values.contentModificationDate, now.timeIntervalSince(modified) < 600 else { continue }
                    recent.append((url, modified))
                }
            }
            for (url, _) in recent.sorted(by: { $0.1 > $1.1 }).prefix(64) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                guard let length = try? handle.seekToEnd() else { continue }
                let start = length > 2 * 1024 * 1024 ? length - 2 * 1024 * 1024 : 0
                try? handle.seek(toOffset: start)
                guard var data = try? handle.read(upToCount: 2 * 1024 * 1024) else { continue }
                if start > 0, let newline = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: newline)) }
                turns += parse(data, agent: agent, session: url.deletingPathExtension().lastPathComponent)
            }
        }
        return turns
    }
}

enum IslandAgentReading: String, Codable, CaseIterable { case elapsed, tokens, cost, limit }

struct IslandAgentNotices {
    private var completed = Set<String>()
    private var warned: [Int: Int64] = [:]

    mutating func finished(_ turns: [IslandAgentTurn], now: Date, minimum: Double) -> [IslandAgentTurn] {
        turns.filter { turn in
            guard let end = turn.end, end <= now, now.timeIntervalSince(end) < 300,
                  turn.duration(at: now) >= minimum else { return false }
            return completed.insert(turn.id).inserted
        }
    }

    mutating func limits(_ limits: CodexLimits?, now: Date, threshold: Double) -> [String] {
        guard let limits, now.timeIntervalSince1970 - Double(limits.observedAt) <= 600 else { return [] }
        var messages: [String] = []
        for (index, window) in limits.windows.enumerated() {
            guard let reset = window.resetsAt else { continue }
            if let previous = warned[index], previous != reset || Double(previous) <= now.timeIntervalSince1970 {
                messages.append("Codex \(window.title) limit renewed")
                warned.removeValue(forKey: index)
            }
            if window.percent(at: now) >= threshold, warned[index] == nil {
                messages.append("Codex \(window.title) · \(Int(window.percent(at: now)))% used")
                warned[index] = reset
            }
        }
        return messages
    }

    static func pace(_ window: CodexLimitWindow, now: Date) -> Double? {
        guard let minutes = window.windowMinutes, minutes > 0, let reset = window.resetDate else { return nil }
        let duration = Double(minutes) * 60
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / duration))
    }
}

struct IslandAgentsView: View {
    @ObservedObject var monitor: AIUsageMonitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !monitor.settings.isEnabled {
                    Text("AI usage monitoring is off").foregroundStyle(.secondary)
                    Button("Enable AI Usage") { monitor.settings.isEnabled = true }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        ForEach(monitor.islandTurns.filter { $0.working(at: timeline.date) }) { turn in
                            LabeledContent(turn.agent.title, value: IslandTimer.clock(turn.duration(at: timeline.date), countdown: false))
                        }
                        ForEach(Array((monitor.limits?.windows ?? []).enumerated()), id: \.offset) { _, window in
                            let percent = window.percent(at: timeline.date)
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent("Codex \(window.title)", value: "\(Int(percent))%")
                                GeometryReader { geometry in
                                    ProgressView(value: percent, total: 100)
                                        .tint(percent >= 95 ? .red : percent >= 80 ? .orange : .accentColor)
                                    if let pace = IslandAgentNotices.pace(window, now: timeline.date) {
                                        Rectangle().fill(.white).frame(width: 1, height: 8).offset(x: geometry.size.width * pace)
                                    }
                                }.frame(height: 8)
                                if let reset = window.resetDate { Text("Resets in " + IslandTimer.clock(max(0, reset.timeIntervalSince(timeline.date)), countdown: true)).font(.caption) }
                            }.opacity(timeline.date.timeIntervalSince1970 - Double(monitor.limits?.observedAt ?? 0) > 600 ? 0.35 : 1)
                        }
                    }
                    Button("Refresh") { monitor.refresh() }
                    Text("Active turns are read from Claude Code and Codex logs. OpenCode and Copilot activity are not available.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
