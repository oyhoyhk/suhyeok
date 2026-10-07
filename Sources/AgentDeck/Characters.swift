import AppKit
import SwiftUI

struct Character: Decodable {
    let id: String
    let name: String
}

/// Character roster and art bundled under Contents/Resources/art (see build.sh).
enum Art {
    static let dir = Bundle.main.resourceURL?.appendingPathComponent("art")

    static let roster: [Character] = {
        guard let url = dir?.appendingPathComponent("roster.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Character].self, from: data)
        else { return [] }
        return list
    }()

    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let img = cache[name] { return img }
        guard let img = ["png", "jpg"].lazy
            .compactMap({ ext in dir.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name + "." + ext)) } }).first
        else { return nil }
        cache[name] = img
        return img
    }
}

/// Gives each live session its own character while it lives; reuses characters only past roster size.
struct CharacterAssigner {
    private var assigned: [String: Int] = [:]

    mutating func update(_ sessions: [AgentSession]) -> [String: Int] {
        let count = max(Art.roster.count, 1)
        let live = Set(sessions.map(\.id))
        assigned = assigned.filter { live.contains($0.key) }
        var used = Set(assigned.values)
        for s in sessions.sorted(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) })
        where assigned[s.id] == nil {
            let preferred = Int(UInt(bitPattern: stableHash(s.id)) % UInt(count))
            let free = (0..<count).map { (preferred + $0) % count }.first { !used.contains($0) }
            assigned[s.id] = free ?? preferred
            used.insert(assigned[s.id]!)
        }
        return assigned
    }

    /// FNV-1a; Swift's hashValue is randomized per launch.
    private func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }
}

/// Stable tag color per project directory.
func projectColor(_ cwd: String) -> Color {
    let palette: [Color] = [.blue, .pink, .teal, .orange, .purple, .mint, .yellow, .red, .cyan, .indigo]
    var h: UInt64 = 0xcbf29ce484222325
    for b in cwd.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return palette[Int(h % UInt64(palette.count))]
}

/// Random adventurer names, kept per live process across app restarts.
enum AgentNames {
    private static let pool = [
        "루미", "바크", "세라", "도윤", "카이", "모모", "하랑", "벨라", "토토", "린", "제이드", "노아",
        "아린", "보리", "솔", "다온", "피코", "레오", "하루", "미르", "코코", "단비", "이안", "로하",
        "새벽", "윤슬", "가온", "누리", "별하", "타르", "오딘", "펠릭스", "니코", "제나", "올리", "베리",
        "호두", "라임", "체리", "구름", "바람", "여울", "마루", "초코", "시엘", "리오", "유키", "한별",
    ]
    private static let key = "agentNames"

    /// Names for live sessions; new sessions get a random name not used by another live one.
    static func assign(_ sessions: [AgentSession]) -> [String: String] {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let keyed = sessions.map { ($0.id, $0.id + "@" + String(Int($0.startedAt?.timeIntervalSince1970 ?? 0))) }
        var result: [String: String] = [:]
        for (id, k) in keyed { if let n = map[k] { result[id] = n } }
        var used = Set(result.values)
        for (id, k) in keyed where result[id] == nil {
            let n = pool.filter { !used.contains($0) }.randomElement() ?? pool.randomElement()!
            used.insert(n)
            result[id] = n
            map[k] = n
        }
        // Keep only live entries; old processes never come back.
        let live = Set(keyed.map(\.1))
        UserDefaults.standard.set(map.filter { live.contains($0.key) }, forKey: key)
        return result
    }
}
