import Foundation

/// Hunting rules: how long an agent has been at it decides its hunting ground, and active time earns crystals.
enum Hunt {
    enum Tier: Int, CaseIterable {
        case low, mid, high

        var label: String {
            switch self {
            case .low: return "하급 사냥터"
            case .mid: return "중급 사냥터"
            case .high: return "상급 사냥터"
            }
        }
        var boss: String {
            switch self {
            case .low: return "숲의 슬라임 왕"
            case .mid: return "수정 동굴 골렘"
            case .high: return "화염 용왕"
            }
        }
        /// Crystals per 10 active minutes.
        var yield: Int { rawValue + 1 }

        /// Under 5 h of continuous activity: low; under 24 h: mid; beyond: high.
        static func of(run: TimeInterval) -> Tier { run < 5 * 3600 ? .low : run < 24 * 3600 ? .mid : .high }
    }

    /// A pause this long ends the run: the agent goes back to camp and the clock starts over.
    static let resetAfter: TimeInterval = 3600
    /// Gaps shorter than this between log entries count as active time.
    static let activeGap: TimeInterval = 5 * 60

    struct Progress: Equatable {
        var runStart: Date?      // start of the current run (nil when resting)
        var last: Date?          // newest activity
        var activeSeconds: Double = 0
        var crystals: Int = 0
        var crystalRemainder: Double = 0

        func run(at now: Date = Date()) -> TimeInterval? {
            guard let runStart, let last, now.timeIntervalSince(last) < Hunt.resetAfter else { return nil }
            return now.timeIntervalSince(runStart)
        }
        func tier(at now: Date = Date()) -> Tier? { run(at: now).map(Tier.of) }
    }
}

/// Scans conversation logs for entry timestamps (incrementally, from where it stopped) to measure runs and crystals.
/// Works for time the app was not running, since the log keeps every timestamp.
enum HuntClock {
    private struct State { var offset: UInt64 = 0; var p = Hunt.Progress() }
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
                if let t = timestamp(chunk[lineStart..<i]) { add(t, to: &st.p) }
                lineStart = chunk.index(after: i)
            }
            st.offset += UInt64(chunk.count)
        }
        states[path] = st
        return st.p
    }

    private static let key = Array("\"timestamp\":\"".utf8)

    private static func timestamp(_ line: Data.SubSequence) -> Date? {
        // Find the first "timestamp":"…" without decoding the whole JSON line.
        guard let r = line.firstRange(of: key) else { return nil }
        let start = r.upperBound
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
