import Foundation

/// Live Claude Code sessions from the registry at ~/.claude/sessions/<pid>.json.
enum ClaudeSource {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let sessionsDir = home + "/.claude/sessions"
    static let projectsDir = home + "/.claude/projects"

    static func load() -> [AgentSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let data = fm.contents(atPath: sessionsDir + "/" + file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = obj["pid"] as? Int32, kill(pid, 0) == 0,
                  let sessionId = obj["sessionId"] as? String
            else { return nil }
            let cwd = obj["cwd"] as? String ?? ""
            let info = transcriptInfo(sessionId: sessionId, cwd: cwd)
            let registryName = obj["name"] as? String ?? String(sessionId.prefix(8))
            // A user-set name wins; otherwise the AI title beats the derived "project-8f" style name.
            let name = obj["nameSource"] as? String == "derived" ? (info.title ?? registryName) : registryName
            return AgentSession(
                // pid, not sessionId: a resumed conversation can run in two processes at once.
                id: "claude-\(pid)",
                agent: .claude,
                name: name,
                cwd: cwd,
                status: SessionStatus(rawValue: obj["status"] as? String ?? "") ?? .unknown,
                startedAt: date(ms: obj["startedAt"]),
                updatedAt: date(ms: obj["statusUpdatedAt"] ?? obj["updatedAt"]),
                lastUser: info.user,
                lastAssistant: info.assistant,
                estimated: false,
                pid: pid,
                action: info.action,
                transcriptPath: transcriptPath(sessionId: sessionId, cwd: cwd),
                hostedName: hostedName(pid: pid),
                conversationId: sessionId
            )
        }
    }

    private static var paneSessions: [String: String] = [:]

    /// tmux session on 수혁's server that runs this process, if any.
    private static func hostedName(pid: Int32) -> String? {
        let env = ProcessEnv.of(pid)
        guard let tmux = env["TMUX"], TmuxEngine.isOurs(tmuxEnv: tmux), let pane = env["TMUX_PANE"] else { return nil }
        if let name = paneSessions[pane] { return name }
        let name = TmuxEngine.session(ofPane: pane)
        paneSessions[pane] = name
        return name
    }

    private static func date(ms: Any?) -> Date? {
        guard let v = ms as? Double else { return nil }
        return Date(timeIntervalSince1970: v / 1000)
    }

    /// Transcript lives at ~/.claude/projects/<cwd with non-alphanumerics as '-'>/<sessionId>.jsonl.
    static func transcriptPath(sessionId: String, cwd: String) -> String? {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let direct = "\(projectsDir)/\(slug)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projectsDir)) ?? []
        return dirs.lazy.map { "\(projectsDir)/\($0)/\(sessionId).jsonl" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private typealias TranscriptInfo = (title: String?, user: String?, assistant: String?, action: AgentAction?)
    /// Parsed tail per transcript, reused while the file's size and mtime stay the same.
    /// Only refresh() calls load(), one run at a time, so this needs no lock.
    private static var infoCache: [String: (stamp: String, info: TranscriptInfo)] = [:]

    private static func transcriptInfo(sessionId: String, cwd: String) -> TranscriptInfo {
        guard let path = transcriptPath(sessionId: sessionId, cwd: cwd) else { return (nil, nil, nil, nil) }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let stamp = "\(attrs[.size] ?? "")|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let hit = infoCache[path], hit.stamp == stamp { return hit.info }
        let info = parseTranscript(path: path)
        infoCache[path] = (stamp, info)
        return info
    }

    private static func parseTranscript(path: String) -> TranscriptInfo {
        var title: String?, user: String?, assistant: String?, action: AgentAction?, sawAssistant = false
        // Large tool results (screenshots) can fill the tail, so widen the window if needed.
        for maxBytes in [512 * 1024, 4 * 1024 * 1024] {
            for line in JSONLTail.lines(path: path, maxBytes: maxBytes).reversed() {
                if title != nil, user != nil, assistant != nil { break }
                switch line["type"] as? String {
                case "ai-title":
                    if title == nil { title = line["aiTitle"] as? String }
                case "last-prompt":
                    if user == nil { user = (line["lastPrompt"] as? String).map { oneLine($0) } }
                case "assistant":
                    guard line["isMeta"] as? Bool != true, let message = line["message"] as? [String: Any] else { break }
                    if !sawAssistant {  // only the newest entry says what is happening now
                        sawAssistant = true
                        action = AgentAction.fromClaude(message["content"])
                    }
                    if assistant == nil { assistant = text(from: message["content"]) }
                default: break
                }
            }
            if user != nil, assistant != nil { break }
        }
        return (title, user, assistant, action)
    }

    /// Plain text only; skips tool results and harness-injected <tags>.
    private static func text(from content: Any?) -> String? {
        var parts: [String] = []
        if let s = content as? String {
            parts = [s]
        } else if let items = content as? [[String: Any]] {
            parts = items.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        }
        let joined = parts.filter { !$0.hasPrefix("<") }.joined(separator: " ")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : oneLine(trimmed)
    }
}
