import Foundation
import SQLite3

/// Codex has no live-session registry, so "live" means a thread updated within `window`.
enum CodexSource {
    static let dbPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.codex/state_5.sqlite"
    static let window: TimeInterval = 30 * 60

    static func load() -> [AgentSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, rollout_path, cwd, title, created_at_ms, updated_at_ms, source
            FROM threads WHERE archived = 0 AND updated_at_ms > ? ORDER BY updated_at_ms DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64((Date().timeIntervalSince1970 - window) * 1000))

        var sessions: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = column(stmt, 0) ?? ""
            let title = column(stmt, 3).map { oneLine($0, limit: 60) }
            let source = column(stmt, 6) ?? ""
            let rollout = scan(path: column(stmt, 1) ?? "")
            sessions.append(AgentSession(
                id: "codex-\(id)",
                agent: .codex,
                name: (title?.isEmpty == false ? title! : String(id.prefix(8))) + " · \(source)",
                cwd: column(stmt, 2) ?? "",
                status: rollout.status,
                startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)) / 1000),
                lastUser: rollout.user,
                lastAssistant: rollout.assistant,
                estimated: true,
                action: rollout.action,
                transcriptPath: column(stmt, 1)
            ))
        }
        return sessions
    }

    private static func column(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    /// busy = the last turn event is task_started with no later task_complete/turn_aborted.
    private static func scan(path: String) -> (status: SessionStatus, user: String?, assistant: String?, action: AgentAction?) {
        var status: SessionStatus?, user: String?, assistant: String?, action: AgentAction?, sawItem = false
        for line in JSONLTail.lines(path: path).reversed() {
            if status != nil, user != nil, assistant != nil { break }
            guard let payload = line["payload"] as? [String: Any] else { continue }
            let kind = payload["type"] as? String
            if status == nil, line["type"] as? String == "event_msg" {
                if kind == "task_started" { status = .busy }
                if kind == "task_complete" || kind == "turn_aborted" { status = .idle }
            }
            if !sawItem, line["type"] as? String == "response_item" {
                sawItem = true
                switch kind {
                case "function_call", "custom_tool_call":
                    let args = (payload["arguments"] as? String ?? payload["input"] as? String ?? "")
                    let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
                    action = AgentAction.tool(payload["name"] as? String ?? "", input: input ?? ["cmd": args])
                case "reasoning": action = AgentAction(kind: .thinking, detail: "생각하는 중")
                case "message": action = AgentAction(kind: .replying, detail: "답변 작성 중")
                default: sawItem = false
                }
            }
            guard line["type"] as? String == "response_item", kind == "message" else { continue }
            let role = payload["role"] as? String
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                .filter { !$0.hasPrefix("<") && !$0.hasPrefix("# AGENTS.md") }
            guard let text = texts.first.map({ oneLine($0) }), !text.isEmpty else { continue }
            if role == "user", user == nil { user = text }
            if role == "assistant", assistant == nil { assistant = text }
        }
        return (status ?? .idle, user, assistant, action)
    }
}
