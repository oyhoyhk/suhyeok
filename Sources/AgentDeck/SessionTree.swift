import Foundation

/// Nests a session under the live session whose process launched it: `claude -p` or `codex exec`
/// run from an agent's shell, whichever model the child is.
enum SessionTree {
    /// child id -> parent id, kept after the child's process exits (a finished `codex exec` thread
    /// stays listed for a while) as long as the parent is still listed. Saved so a restart keeps it.
    private static let linksPath = FileManager.default.homeDirectoryForCurrentUser.path
        + "/Library/Application Support/Suhyeok/session-links.json"
    private static var known: [String: String] = {
        guard let d = FileManager.default.contents(atPath: linksPath) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }()

    static func link(_ sessions: [AgentSession]) -> [AgentSession] {
        let ids = Set(sessions.map(\.id))
        let live = Dictionary(sessions.compactMap { s in s.pid.map { ($0, s.id) } }, uniquingKeysWith: { a, _ in a })
        let linked = sessions.map { s -> AgentSession in
            var s = s
            if s.parentId == nil, var p = s.pid.map(parentPid) {
                for _ in 0..<32 where p > 1 {
                    // The child inherits the parent's TMUX env; the hosted pane belongs to the parent.
                    if let owner = live[p], owner != s.id { s.parentId = owner; s.hostedName = nil; break }
                    p = parentPid(p)
                }
            }
            if s.parentId == nil, let owner = known[s.id], ids.contains(owner) { s.parentId = owner; s.hostedName = nil }
            // No process left to trace: a run inside a Claude session's scratchpad (…/<sessionId>/scratchpad) is that session's.
            if s.parentId == nil, let owner = sessions.first(where: { o in
                o.id != s.id && o.agent == .claude && o.conversationId.map { s.cwd.contains("/\($0)/") } == true
            }) { s.parentId = owner.id; s.hostedName = nil }
            // A parent that is no longer listed would hide the child entirely.
            if let owner = s.parentId, !ids.contains(owner) { s.parentId = nil }
            return s
        }
        let now = Dictionary(linked.compactMap { s in s.parentId.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if now != known {
            known = now
            if let d = try? JSONEncoder().encode(now) { try? d.write(to: URL(fileURLWithPath: linksPath)) }
        }
        return linked
    }

    static func parentPid(_ pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// Rollout file -> pid of the `codex` process writing it (`codex exec` keeps its rollout open while it runs).
    /// Codex's shared app-server daemon also holds rollouts open, for the TUI sessions it serves; its pid says nothing
    /// about where the session runs, so it is skipped and those sessions are matched by `codexProcess(cwd:startedAt:)`.
    static func codexRollouts() -> [String: Int32] {
        var out: [String: Int32] = [:]
        for pid in codexPids() where !isCodexDaemon(pid) {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)) / MemoryLayout<proc_fdinfo>.stride
            for fd in fds.prefix(got) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var vi = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi,
                                     Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = withUnsafeBytes(of: vi.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") { out[path] = pid }
            }
        }
        return out
    }

    /// Interactive Codex (its daemon writes the rollout): the newest `codex` process in `cwd` started before the thread.
    static func codexProcess(cwd: String, startedAt: Date, excluding: Set<Int32>) -> Int32? {
        codexPids().filter { !excluding.contains($0) && !isCodexDaemon($0) && processCwd($0) == cwd }
            .compactMap { p in processStart(p).map { (p, $0) } }
            .filter { $0.1 <= startedAt.addingTimeInterval(5) }
            .max { $0.1 < $1.1 }?.0
    }

    private static func codexPids() -> [Int32] {
        var pids = [Int32](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        return pids.prefix(max(0, n)).filter { pid in
            var name = [CChar](repeating: 0, count: 64)
            return pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name) == "codex"
        }
    }

    /// The app-server daemon runs under launchd (directly or under its own `codex` supervisor), not under a shell.
    private static func isCodexDaemon(_ pid: Int32) -> Bool {
        let parent = parentPid(pid)
        guard parent > 1 else { return true }
        var name = [CChar](repeating: 0, count: 64)
        return proc_name(parent, &name, UInt32(name.count)) > 0 && String(cString: name) == "codex" && parentPid(parent) <= 1
    }

    private static func processCwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
