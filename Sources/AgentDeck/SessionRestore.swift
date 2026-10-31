import Foundation

/// 수혁's agent sessions, written down while they run so the ones a reboot closed can be opened again
/// (the tmux server, and with it every session, ends when the Mac restarts; the conversations stay on disk).
enum SessionRestore {
    struct Entry: Codable, Hashable, Identifiable {
        var id: String { conversation }
        let agent: String  // Agent.rawValue
        let cwd: String
        let conversation: String
        let title: String
        /// The conversation log (Claude jsonl, Codex rollout, Antigravity step db): Codex and Antigravity keep the model
        /// it last ran with there.
        var log: String? = nil
    }

    /// SUHYEOK_RESTORE_FILE: another record, so a check does not race the running app, which rewrites this one.
    static var path: String = ProcessInfo.processInfo.environment["SUHYEOK_RESTORE_FILE"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Suhyeok/open-sessions.json").path

    static func load() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Agent sessions running on 수혁's tmux server, by the conversation each one has open.
    /// One entry per conversation: two panes can have the same one open, and reopening both would fork it.
    static func live(hosted: [TmuxEngine.Hosted], sessions: [AgentSession]) -> [Entry] {
        var seen = Set<String>()
        return hosted.compactMap { h -> Entry? in
            guard let agent = h.agent,
                  let s = sessions.first(where: { $0.agent == agent && runs($0, in: h.name) }),
                  let conversation = s.conversationId,
                  // No log until the first message: such a conversation cannot be resumed (and holds nothing).
                  let log = s.transcriptPath, FileManager.default.fileExists(atPath: log) else { return nil }
            return Entry(agent: agent.rawValue, cwd: h.cwd, conversation: conversation, title: s.name, log: log)
        }.filter { seen.insert($0.conversation).inserted }
    }

    /// The model and effort the conversation last ran with; without them a resumed agent starts on the defaults.
    /// Claude: the status line copy kept per conversation. Codex: the newest turn in its rollout.
    static func resumeFlags(_ e: Entry, statusDir: String = UsageInfo.statusDir) -> [String] {
        switch Agent(rawValue: e.agent) {
        case .claude:
            guard let data = FileManager.default.contents(atPath: statusDir + "/\(e.conversation).json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            var flags: [String] = []
            if let id = (json["model"] as? [String: Any])?["id"] as? String, !id.isEmpty { flags += ["--model", id] }
            if let level = (json["effort"] as? [String: Any])?["level"] as? String, !level.isEmpty { flags += ["--effort", level] }
            return flags
        case .codex:
            guard let log = e.log, let info = UsageInfo.codex(log), let model = info.model else { return [] }
            return ["-m", model] + (info.effort.map { ["-c", "model_reasoning_effort=" + TmuxEngine.tomlString($0)] } ?? [])
        case .antigravity:
            // The display name carries the effort ("Gemini 3.8 Flash (High)"), and --model takes it as is.
            return e.log.flatMap(AntigravitySource.model).map { ["--model", $0] } ?? []
        case nil:
            return []
        }
    }

    /// What to write down: the live sessions, plus closed ones still offered for reopening (not dropped just
    /// because a new session started before the user answered).
    static func merged(live: [Entry], pending: [Entry]) -> [Entry] {
        live + pending.filter { p in !live.contains { $0.conversation == p.conversation } }
    }

    /// Claude sessions know their tmux session; Codex ones are matched by the variable 수혁 sets on each session.
    private static func runs(_ s: AgentSession, in name: String) -> Bool {
        if let h = s.hostedName { return h == name }
        guard let pid = s.pid else { return false }
        return ProcessEnv.of(pid)["SUHYEOK_SESSION"] == name
    }
}
