import Foundation

/// Hunting rules: how long an agent has been at it decides its hunting ground, and active time earns crystals.
enum Hunt {
    enum Tier: Int, CaseIterable {
        case low, mid, high

        var label: String {
            switch self {
            case .low: return String(localized: "하급 사냥터")
            case .mid: return String(localized: "중급 사냥터")
            case .high: return String(localized: "상급 사냥터")
            }
        }
        var boss: String {
            switch self {
            case .low: return String(localized: "숲의 슬라임 왕")
            case .mid: return String(localized: "수정 동굴 골렘")
            case .high: return String(localized: "화염 용왕")
            }
        }
        /// Crystals per 10 active minutes.
        var yield: Int { rawValue + 1 }

        /// Under 5 h of continuous activity: low; under 24 h: mid; beyond: high.
        static func of(run: TimeInterval) -> Tier { run < 5 * 3600 ? .low : run < 24 * 3600 ? .mid : .high }
    }

    /// Earning-formula version, written on every ledger entry so later formula changes stay distinguishable.
    static let rule = 1
    /// Crystals for each finished turn and each successful `git commit`, on top of active time.
    static let turnBonus = 1
    static let commitBonus = 3

    /// A pause this long ends the run: the agent goes back to camp and the clock starts over.
    static let resetAfter: TimeInterval = 3600
    /// Gaps shorter than this between log entries count as active time.
    static let activeGap: TimeInterval = 5 * 60

    struct Progress: Equatable {
        var runStart: Date?      // start of the current run (nil when resting)
        var last: Date?          // newest activity
        var activeSeconds: Double = 0
        var crystals: Int = 0    // from active time
        var crystalRemainder: Double = 0
        var turns = 0
        var commits = 0
        var mana = 0             // output tokens: shown as cost, never paid out

        /// Everything this log has earned so far under the current rule.
        var earned: Int { crystals + turns * Hunt.turnBonus + commits * Hunt.commitBonus }

        func run(at now: Date = Date()) -> TimeInterval? {
            guard let runStart, let last, now.timeIntervalSince(last) < Hunt.resetAfter else { return nil }
            return now.timeIntervalSince(runStart)
        }
        func tier(at now: Date = Date()) -> Tier? { run(at: now).map(Tier.of) }
    }
}

/// Scans conversation logs (incrementally, from where it stopped) for entry timestamps, finished turns,
/// successful commits and output tokens. Works for time the app was not running, since the log keeps it all.
enum HuntClock {
    private struct State {
        var offset: UInt64 = 0
        var p = Hunt.Progress()
        var pendingCommits: Set<String> = []  // Bash `git commit` tool_use ids awaiting their result
        var lastUsageMessage = ""             // Claude repeats a message's usage on each of its records
    }
    private static var states: [String: State] = [:]
    private static let lock = NSLock()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func progress(path: String) -> Hunt.Progress {
        lock.lock(); defer { lock.unlock() }
        var st = states[path] ?? State()
        guard let h = FileHandle(forReadingAtPath: path) else { return st.p }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = State() }
        // Read in 8 MB chunks; only the "timestamp" field is pulled out of each line, so huge lines cost little.
        while st.offset < size {
            try? h.seek(toOffset: st.offset)
            let data = h.readData(ofLength: Int(min(8 << 20, size - st.offset)))
            guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { break }
            let chunk = data[data.startIndex...lastNL]
            var lineStart = chunk.startIndex
            for i in chunk.indices where chunk[i] == UInt8(ascii: "\n") {
                let line = chunk[lineStart..<i]
                if let t = timestamp(line) { add(t, to: &st.p) }
                scanWork(line, into: &st)
                lineStart = chunk.index(after: i)
            }
            st.offset += UInt64(chunk.count)
        }
        states[path] = st
        return st.p
    }

    private static let key = Array("\"timestamp\":\"".utf8)
    private static let claudeTurn = Array("\"subtype\":\"turn_duration\"".utf8)
    private static let codexTurn = Array("\"type\":\"task_complete\"".utf8)
    private static let toolUse = Array("\"type\":\"tool_use\"".utf8)
    private static let toolResult = Array("\"tool_result\"".utf8)
    private static let bash = Array("\"name\":\"Bash\"".utf8)
    private static let gitCommit = Array("commit".utf8)
    private static let messageID = Array("\"id\":\"msg_".utf8)
    private static let claudeUsage = Array("\"output_tokens\":".utf8)
    private static let codexUsage = Array("\"total_token_usage\"".utf8)

    /// Turns, commits and tokens. Lines are only decoded when a cheap byte search says they matter.
    private static func scanWork(_ line: Data.SubSequence, into st: inout State) {
        if find(claudeTurn, in: line) != nil || find(codexTurn, in: line) != nil { st.p.turns += 1 }
        if find(toolUse, in: line) != nil, find(bash, in: line) != nil, find(gitCommit, in: line) != nil,
           let blocks = contentBlocks(line) {
            for b in blocks where b["type"] as? String == "tool_use" && b["name"] as? String == "Bash" {
                if let id = b["id"] as? String, let cmd = (b["input"] as? [String: Any])?["command"] as? String, isCommit(cmd) {
                    st.pendingCommits.insert(id)
                }
            }
        }
        if !st.pendingCommits.isEmpty, find(toolResult, in: line) != nil, let blocks = contentBlocks(line) {
            for b in blocks where b["type"] as? String == "tool_result" {
                guard let id = b["tool_use_id"] as? String, st.pendingCommits.remove(id) != nil else { continue }
                if b["is_error"] as? Bool != true { st.p.commits += 1 }
            }
        }
        if find(codexUsage, in: line) == nil, let u = find(claudeUsage, in: line), let out = integer(at: u, in: line),
           let m = find(messageID, in: line) {
            // Read the id and the count straight from the bytes: assistant lines can be megabytes long.
            let start = m - 4  // back to the "msg_" prefix
            let id = line[start...].firstIndex(of: UInt8(ascii: "\"")).map { String(decoding: line[start..<$0], as: UTF8.self) } ?? ""
            if id != st.lastUsageMessage {
                st.lastUsageMessage = id
                st.p.mana += out
            }
        }
        if find(codexUsage, in: line) != nil,
           let info = (json(line)?["payload"] as? [String: Any])?["info"] as? [String: Any],
           let out = (info["total_token_usage"] as? [String: Any])?["output_tokens"] as? Int {
            st.p.mana = max(st.p.mana, out)  // a running total
        }
    }

    /// Index just past the first occurrence of `pattern` (memmem: far faster than a generic subsequence search).
    private static func find(_ pattern: [UInt8], in line: Data.SubSequence) -> Data.Index? {
        line.withUnsafeBytes { buf -> Int? in
            guard let base = buf.baseAddress, buf.count >= pattern.count else { return nil }
            return pattern.withUnsafeBytes { p in
                memmem(base, buf.count, p.baseAddress!, p.count).map { base.distance(to: UnsafeRawPointer($0)) + p.count }
            }
        }.map { line.startIndex + $0 }
    }

    private static func integer(at i: Data.Index, in line: Data.SubSequence) -> Int? {
        var n = 0, j = i, any = false
        while j < line.endIndex, line[j] >= UInt8(ascii: "0"), line[j] <= UInt8(ascii: "9") {
            n = n * 10 + Int(line[j] - UInt8(ascii: "0")); j += 1; any = true
        }
        return any ? n : nil
    }

    private static func json(_ line: Data.SubSequence) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    private static func contentBlocks(_ line: Data.SubSequence) -> [[String: Any]]? {
        (json(line)?["message"] as? [String: Any])?["content"] as? [[String: Any]]
    }

    private static let commitPattern = try! NSRegularExpression(
        pattern: #"(^|[\s;&|(])git(\s+-[Cc]\s+\S+)*\s+commit(\s|$)"#)

    /// True for a shell command that runs `git commit` (not `--dry-run`, not `commit-tree`, not inside quotes).
    static func isCommit(_ command: String) -> Bool {
        guard !command.contains("--dry-run") else { return false }
        return commitPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    private static func timestamp(_ line: Data.SubSequence) -> Date? {
        // Find the first "timestamp":"…" without decoding the whole JSON line.
        guard let start = find(key, in: line) else { return nil }
        guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")),
              let s = String(data: Data(line[start..<end]), encoding: .utf8) else { return nil }
        return iso.date(from: s)
    }

    private static func add(_ t: Date, to p: inout Hunt.Progress) {
        if let last = p.last {
            let gap = t.timeIntervalSince(last)
            guard gap >= 0 else { return }  // out-of-order lines (queue records) do not move the clock back
            if gap >= Hunt.resetAfter { p.runStart = t }
            else if gap < Hunt.activeGap {
                p.activeSeconds += gap
                // Crystals at the rate of the tier the agent was in at that moment.
                let tier = Hunt.Tier.of(run: t.timeIntervalSince(p.runStart ?? t))
                p.crystalRemainder += gap / 600 * Double(tier.yield)
                let whole = Int(p.crystalRemainder)
                p.crystals += whole
                p.crystalRemainder -= Double(whole)
            }
        } else {
            p.runStart = t
        }
        p.last = t
    }
}

/// What a boss is doing at a moment: each tier runs its own looping script of moves.
enum BossPattern {
    enum Move: Equatable {
        case idle
        case hop            // slime: a bounce in place (drawn in code)
        case attack         // ground slam, 6 frames over 1.2 s; impact on frame 3
        case special        // signature skill, 6 frames over 1.8 s; peak on frames 3-4
        case roar           // dragon: rears up and shakes, a warning before the special
    }

    struct Step { let move: Move; let length: Double }

    /// Slime: playful hops between slams. Golem: slow, a double slam then crystal spikes.
    /// Dragon: roar as a warning, fire, and gets faster when enraged (HP below 30%).
    static func script(_ tier: Hunt.Tier) -> [Step] {
        switch tier {
        case .low:
            return [Step(move: .idle, length: 2.5), Step(move: .hop, length: 0.8), Step(move: .hop, length: 0.8),
                    Step(move: .idle, length: 1.5), Step(move: .attack, length: 1.2), Step(move: .idle, length: 2),
                    Step(move: .special, length: 1.8)]
        case .mid:
            return [Step(move: .idle, length: 3.5), Step(move: .attack, length: 1.2), Step(move: .idle, length: 0.6),
                    Step(move: .attack, length: 1.2), Step(move: .idle, length: 3), Step(move: .special, length: 1.8)]
        case .high:
            return [Step(move: .idle, length: 2.5), Step(move: .attack, length: 1.2), Step(move: .idle, length: 1.5),
                    Step(move: .roar, length: 1.2), Step(move: .special, length: 1.8), Step(move: .idle, length: 2),
                    Step(move: .attack, length: 1.2), Step(move: .attack, length: 1.2)]
        }
    }

    /// Move and progress (0...1) within it. `enraged` speeds the script up by 40%.
    static func state(_ tier: Hunt.Tier, time: Double, enraged: Bool = false) -> (Move, Double) {
        let steps = script(tier)
        let total = steps.reduce(0) { $0 + $1.length }
        // Offset per tier so the three bosses never move in step.
        var t = ((time * (enraged ? 1.4 : 1)) + Double(tier.rawValue) * 3.7).truncatingRemainder(dividingBy: total)
        for s in steps {
            if t < s.length { return (s.move, t / s.length) }
            t -= s.length
        }
        return (.idle, 0)
    }

    /// 0...1 strength of the blow hitting the attackers right now (they get pushed back and flash).
    static func impact(_ tier: Hunt.Tier, time: Double, enraged: Bool = false) -> Double {
        let (move, k) = state(tier, time: time, enraged: enraged)
        switch move {
        case .attack: return k > 0.5 && k < 0.75 ? 1 - (k - 0.5) / 0.25 : 0
        case .special: return k > 0.45 && k < 0.8 ? 1 - (k - 0.45) / 0.35 : 0
        default: return 0
        }
    }
}
