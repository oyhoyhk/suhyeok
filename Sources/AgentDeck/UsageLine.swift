import SwiftUI

/// What the agent's own status line shows: model, context used, and the account's 5-hour / weekly limits.
struct UsageInfo: Equatable {
    struct Limit: Equatable {
        let label: String
        private let used: Double
        let resetsAt: Date?

        init(label: String, percent: Double, resetsAt: Date?) {
            self.label = label; self.used = percent; self.resetsAt = resetsAt
        }

        /// Read when the agent last reported; past the reset time the window has started over.
        var percent: Double { (resetsAt.map { $0 < Date() } ?? false) ? 0 : used }
    }

    var model: String?
    /// Reasoning effort the model runs at ("medium", "high", ...).
    var effort: String?
    var contextUsed: Int?
    var contextWindow: Int?
    var limits: [Limit] = []

    var contextPercent: Double? {
        guard let u = contextUsed, let w = contextWindow, w > 0 else { return nil }
        return Double(u) / Double(w) * 100
    }

    static func load(_ s: AgentSession) -> UsageInfo? {
        switch s.agent {
        case .claude: return claude(s)
        case .codex: return s.transcriptPath.flatMap(codex)
        }
    }

    // MARK: Claude

    /// Claude Code hands its status line command a JSON with model, context and rate limits; the user's
    /// statusline.sh copies it to this folder per conversation. Without that copy, the transcript gives
    /// model and context, and limits come from any other conversation's copy (limits are per account).
    static let statusDir = FileManager.default.homeDirectoryForCurrentUser.path
        + "/Library/Application Support/Suhyeok/statusline"

    private static func claude(_ s: AgentSession) -> UsageInfo? {
        let own = s.conversationId.flatMap { readJSON(statusDir + "/\($0).json") }
        var info = UsageInfo()
        if let own {
            let model = own["model"] as? [String: Any]
            info.model = model?["display_name"] as? String ?? (model?["id"] as? String).map(prettyModel)
            info.effort = (own["effort"] as? [String: Any])?["level"] as? String
            if let cw = own["context_window"] as? [String: Any] {
                info.contextWindow = cw["context_window_size"] as? Int
                if let cur = cw["current_usage"] as? [String: Any] {
                    info.contextUsed = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                        .compactMap { cur[$0] as? Int }.reduce(0, +)
                }
            }
        }
        if info.model == nil || info.contextUsed == nil, let path = s.transcriptPath {
            for line in JSONLTail.lines(path: path, maxBytes: 4 * 1024 * 1024).reversed() {
                guard line["type"] as? String == "assistant", let m = line["message"] as? [String: Any],
                      let usage = m["usage"] as? [String: Any], let id = m["model"] as? String, id != "<synthetic>"
                else { continue }
                info.model = info.model ?? prettyModel(id)
                info.contextUsed = info.contextUsed ?? ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .compactMap { usage[$0] as? Int }.reduce(0, +)
                info.contextWindow = info.contextWindow ?? windowSeen(for: id) ?? ((info.contextUsed ?? 0) > 200_000 ? 1_000_000 : 200_000)
                break
            }
        }
        // Limits are per account: the newest copy from any conversation is the freshest.
        if let rl = newestRateLimits() {
            for (key, label) in [("five_hour", String(localized: "5시간")), ("seven_day", String(localized: "주간"))] {
                guard let l = rl[key] as? [String: Any], let p = number(l["used_percentage"]) else { continue }
                info.limits.append(Limit(label: label, percent: p, resetsAt: number(l["resets_at"]).map { Date(timeIntervalSince1970: $0) }))
            }
        }
        return info.model == nil && info.limits.isEmpty ? nil : info
    }

    /// Rate limits from the most recently updated conversation copy.
    private static func newestRateLimits() -> [String: Any]? {
        newestCopies().lazy.compactMap { readJSON($0)?["rate_limits"] as? [String: Any] }.first
    }

    /// The context window another conversation on the same model reported (e.g. 1M for Opus).
    private static func windowSeen(for modelId: String) -> Int? {
        for path in newestCopies().prefix(20) {
            guard let j = readJSON(path), (j["model"] as? [String: Any])?["id"] as? String == modelId else { continue }
            if let w = (j["context_window"] as? [String: Any])?["context_window_size"] as? Int { return w }
        }
        return nil
    }

    private static func newestCopies() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: statusDir)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { statusDir + "/" + $0 }
            .map { ($0, (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5"
    static func prettyModel(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return name.prefix(1).uppercased() + name.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    // MARK: Codex

    /// Codex writes token_count events (context use, rate limits) and turn_context (model, effort) into its rollout.
    static func codex(_ path: String) -> UsageInfo? {
        var info = UsageInfo()
        var gotTokens = false, gotLimits = false
        for line in JSONLTail.lines(path: path).reversed() {
            guard let p = line["payload"] as? [String: Any] else { continue }
            if info.model == nil, line["type"] as? String == "turn_context", let m = p["model"] as? String {
                info.model = m
                info.effort = effort(p)
            }
            if line["type"] as? String == "event_msg", p["type"] as? String == "token_count" {
                if !gotTokens, let i = p["info"] as? [String: Any], let last = i["last_token_usage"] as? [String: Any] {
                    gotTokens = true
                    info.contextUsed = last["total_tokens"] as? Int
                    info.contextWindow = i["model_context_window"] as? Int
                }
                if !gotLimits, let rl = p["rate_limits"] as? [String: Any] {
                    gotLimits = true
                    let windows = ["primary", "secondary"].compactMap { rl[$0] as? [String: Any] }
                        .sorted { (number($0["window_minutes"]) ?? 0) < (number($1["window_minutes"]) ?? 0) }
                    for w in windows {
                        guard let pct = number(w["used_percent"]) else { continue }
                        let minutes = number(w["window_minutes"]) ?? 0
                        let label = minutes == 300 ? String(localized: "5시간") : minutes == 10080 ? String(localized: "주간")
                            : minutes >= 1440 ? String(localized: "\(Int(minutes / 1440))일") : String(localized: "\(Int(minutes / 60))시간")
                        info.limits.append(Limit(label: label, percent: pct,
                                                 resetsAt: number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }))
                    }
                }
            }
            if info.model != nil && gotTokens && gotLimits { break }
        }
        // A long turn can push turn_context out of the tail; the session's first one names the model too.
        if info.model == nil, let head = FileHandle(forReadingAtPath: path).flatMap({ h in defer { try? h.close() }; return try? h.read(upToCount: 256 * 1024) }) {
            for chunk in head.split(separator: UInt8(ascii: "\n")) {
                guard let line = (try? JSONSerialization.jsonObject(with: Data(chunk))) as? [String: Any],
                      line["type"] as? String == "turn_context", let p = line["payload"] as? [String: Any],
                      let m = p["model"] as? String else { continue }
                info.model = m
                info.effort = effort(p)
                break
            }
        }
        return info.model == nil && !gotTokens && !gotLimits ? nil : info
    }

    private static func effort(_ turnContext: [String: Any]) -> String? {
        turnContext["effort"] as? String ?? turnContext["reasoning_effort"] as? String
            ?? ((turnContext["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["reasoning_effort"] as? String
    }

    // MARK: helpers

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

/// One line under the input, like the status line under Claude Code's prompt.
struct UsageLine: View {
    let info: UsageInfo

    var body: some View {
        HStack(spacing: 10) {
            if let m = info.model {
                Text("◆ " + m).foregroundStyle(Color(red: 0.85, green: 0.6, blue: 1)).bold()
                    + Text(info.effort.map { " · " + $0 } ?? "").foregroundColor(.secondary)
            }
            if let used = info.contextUsed {
                HStack(spacing: 4) {
                    Text("컨텍스트").foregroundStyle(.secondary)
                    if let p = info.contextPercent {
                        Text("\(Self.tokens(used))/\(Self.tokens(info.contextWindow ?? 0)) \(Int(p.rounded()))%")
                            .foregroundStyle(Self.color(p))
                    } else {
                        Text(Self.tokens(used))
                    }
                }
                .help("지금 대화가 차지한 컨텍스트 (입력 + 캐시 토큰)")
            }
            ForEach(info.limits, id: \.label) { l in
                HStack(spacing: 4) {
                    Text(l.label).foregroundStyle(.secondary)
                    Self.bar(l.percent)
                    Text("\(Int(l.percent.rounded()))%").foregroundStyle(Self.color(l.percent))
                    if let r = l.resetsAt, let left = Self.left(r) { Text("↻" + left).foregroundStyle(.secondary) }
                }
                .help(l.resetsAt.map { String(localized: "\(l.label) 사용량 · \($0.formatted(date: .abbreviated, time: .shortened))에 초기화") }
                      ?? String(localized: "\(l.label) 사용량"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(1)
    }

    private static func bar(_ p: Double) -> some View {
        let filled = max(0, min(10, Int(p / 10)))
        return Text(String(repeating: "▰", count: filled)).foregroundColor(color(p))
            + Text(String(repeating: "▱", count: 10 - filled)).foregroundColor(.gray)
    }

    static func color(_ p: Double) -> Color { p >= 80 ? .red : p >= 50 ? .yellow : .green }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000)
            : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    static func left(_ date: Date) -> String? {
        let s = Int(date.timeIntervalSinceNow)
        guard s > 0 else { return nil }
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        return d > 0 ? String(localized: "\(d)일\(h)h") : h > 0 ? String(format: "%dh%02dm", h, m) : "\(m)m"
    }
}
