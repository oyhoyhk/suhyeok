import Foundation

/// Background shells a Claude Code session left running after its turn (registry status "shell"). Claude runs each
/// Bash command as `<shell> -c source ~/.claude/shell-snapshots/… && eval '<command>'`, a child of the claude process.
/// A shell whose whole process tree is wait-loop programs does no work of its own: it waits for a condition that may
/// never come true (`pgrep -f` matching a sibling waiter, a marker a killed job never prints, stdin that never closes).
enum BackgroundShells {
    struct Proc: Equatable {
        let pid: Int32
        let ppid: Int32
        let age: TimeInterval
        let command: String
        var program: String { ((command.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent }
    }

    struct Shell: Equatable {
        let pid: Int32
        let age: TimeInterval
        let command: String
        /// Every process in the shell's tree, deepest last.
        let tree: [Int32]
        /// Only wait-loop programs run in the tree.
        let waiting: Bool
    }

    /// Programs a wait loop runs between checks.
    static let waitPrograms: Set<String> = ["zsh", "bash", "sh", "sleep", "pgrep", "grep", "cat", "tail"]

    /// Set only by the app itself, so CLI checks that load sessions never kill anything.
    nonisolated(unsafe) static var reaping = false
    nonisolated(unsafe) static var logPath = AgentMail.dir + "/reaped-shells.log"

    /// `ps -axww -o pid=,ppid=,etime=,command=`, parsed.
    static func table() -> [Proc] {
        parse(TerminalSource.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,etime=,command="]) ?? "")
    }

    static func parse(_ ps: String) -> [Proc] {
        ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]), let age = elapsed(String(f[2])) else { return nil }
            return Proc(pid: pid, ppid: ppid, age: age, command: String(f[3]))
        }
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss`.
    static func elapsed(_ s: String) -> TimeInterval? {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        guard let days, (2...3).contains(clock.count) else { return nil }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// The background shells of one claude process.
    static func shells(of pid: Int32, in procs: [Proc]) -> [Shell] {
        let children = Dictionary(grouping: procs, by: \.ppid)
        func tree(_ p: Proc) -> [Proc] { [p] + (children[p.pid] ?? []).flatMap(tree) }
        return (children[pid] ?? []).filter { $0.command.contains("/.claude/shell-snapshots/") }.map { sh in
            let all = tree(sh)
            return Shell(pid: sh.pid, age: sh.age, command: sh.command, tree: all.map(\.pid),
                         waiting: all.allSatisfy { waitPrograms.contains($0.program) })
        }
    }

    /// Whether a session's background shells do real work: nil when it has none to look at.
    static func working(_ shells: [Shell]) -> Bool? {
        shells.isEmpty ? nil : shells.contains { !$0.waiting }
    }

    /// Kills wait loops that outlived `Activity.waitLoopLimit` in sessions whose turn is over, and logs each one.
    /// Shells that run anything else are never touched, however long they run.
    static func reap(_ sessions: [AgentSession]) {
        let idle = sessions.filter { $0.agent == .claude && $0.status == .shell && $0.pid != nil }
        guard reaping, !idle.isEmpty else { return }
        let procs = table()
        for s in idle {
            for sh in shells(of: s.pid!, in: procs) where sh.waiting && sh.age > Activity.waitLoopLimit {
                for pid in sh.tree.reversed() { kill(pid, SIGTERM) }
                log("\(s.id) \(s.cwd) · pid \(sh.pid), \(Int(sh.age / 3600))h · \(script(sh.command))")
            }
        }
    }

    /// The user's command inside Claude's wrapper, on one line.
    static func script(_ command: String) -> String {
        let body = command.range(of: "eval '").map { String(command[$0.upperBound...]) } ?? command
        return String(body.replacingOccurrences(of: "\n", with: " ").prefix(300))
    }

    private static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) · \(line) · wait loop past \(Int(Activity.waitLoopLimit / 3600))h · SIGTERM\n"
        NSLog("[reap] %@", entry)
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(entry.utf8))
        }
    }
}
