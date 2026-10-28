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
    }

    static var path: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Suhyeok/open-sessions.json").path

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
    static func live(hosted: [TmuxEngine.Hosted], sessions: [AgentSession]) -> [Entry] {
        hosted.compactMap { h in
            guard let agent = h.agent,
                  let s = sessions.first(where: { $0.agent == agent && runs($0, in: h.name) }),
                  let conversation = s.conversationId,
                  // No log until the first message: such a conversation cannot be resumed (and holds nothing).
                  let log = s.transcriptPath, FileManager.default.fileExists(atPath: log) else { return nil }
            return Entry(agent: agent.rawValue, cwd: h.cwd, conversation: conversation, title: s.name)
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
