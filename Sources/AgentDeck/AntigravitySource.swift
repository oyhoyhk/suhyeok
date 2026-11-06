import Foundation
import SQLite3

/// Antigravity CLI (`agy`) sessions. A running CLI holds presence/<conversation id>.lock open; the summary table
/// has title, folder, run status and parent; each conversation's steps sit in their own SQLite file as protobuf.
/// The step fields were read off agy 1.4.12 (no published schema): if an update moves them, the texts go empty
/// but the session stays listed.
enum AntigravitySource {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.gemini/antigravity-cli"
    static let summariesPath = dir + "/conversation_summaries.db"
    static func conversationPath(_ id: String) -> String { dir + "/conversations/\(id).db" }

    struct Summary { let id: String, title: String, cwd: String, status: String, parent: String, updated: Date? }

    static func load() -> [AgentSession] {
        let live = SessionTree.antigravityLocks()
        guard !live.isEmpty else { return [] }
        // A CLI that has not been sent a message yet holds its lock but has no summary row: terminal only until then.
        return summaries().compactMap { s in
            guard let pid = live[s.id] else { return nil }
            let path = conversationPath(s.id)
            let turn = lastTurn(path: path)
            return AgentSession(
                id: "antigravity-\(s.id)",
                agent: .antigravity,
                name: s.title.isEmpty ? String(s.id.prefix(8)) : oneLine(s.title, limit: 60),
                // workspace_uris can be empty (a `-i` start in a folder, agy 1.4.12); the process still runs in the folder.
                cwd: s.cwd.isEmpty ? SessionTree.processCwd(pid) ?? "" : s.cwd,
                // A permission prompt is still RUNNING here; the menu on screen is what tells it apart.
                status: s.status == "CASCADE_RUN_STATUS_RUNNING" ? .busy : .idle,
                startedAt: SessionTree.processStart(pid),
                updatedAt: s.updated,
                lastUser: turn.user,
                lastAssistant: turn.assistant,
                estimated: false,
                pid: pid,
                action: turn.action,
                transcriptPath: path,
                hostedName: ClaudeSource.hostedName(pid: pid),
                conversationId: s.id,
                parentId: s.parent.isEmpty ? nil : "antigravity-\(s.parent)"
            )
        }
    }

    /// Newest first.
    static func summaries(limit: Int = 200) -> [Summary] {
        var out: [Summary] = []
        query(summariesPath, """
            SELECT conversation_id, title, workspace_uris, status, parent_conversation_id, last_modified_time
            FROM conversation_summaries WHERE killed = 0 ORDER BY last_modified_time DESC LIMIT \(limit)
            """) { stmt in
            func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            // workspace_uris: ["file:///path"]
            let uris = (try? JSONSerialization.jsonObject(with: Data(col(2).utf8))) as? [String]
            out.append(Summary(id: col(0), title: col(1), cwd: uris?.first.flatMap { URL(string: $0)?.path } ?? "",
                               status: col(3), parent: col(4), updated: date(col(5))))
        }
        return out
    }

    /// "2026-10-31 06:03:33.726135+00:00" (always UTC); the fraction is dropped.
    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    private static var cache: [String: (stamp: [Date?], entries: [(ChatItem.Role, String)])] = [:]
    private static let lock = NSLock()

    /// The conversation as chat entries, oldest first. Parsed again only when the database or its WAL changed.
    static func entries(path: String) -> [(ChatItem.Role, String)] {
        let stamp = [path, path + "-wal"].map { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path], c.stamp == stamp { return c.entries }
        let out = parse(path: path)
        cache[path] = (stamp, out)
        return out
    }

    private static func parse(path: String) -> [(ChatItem.Role, String)] {
        var out: [(ChatItem.Role, String)] = []
        steps(path: path, newestFirst: false, limit: 2000) { type, payload in
            switch type {
            case 14:
                if let t = Proto.strings(payload, [19, 2]).first { out.append((.me, t)) }
            case 15:
                for t in Proto.strings(payload, [20, 1]) where !t.isEmpty { out.append((.agent, t)) }
                for call in Proto.messages(payload, [20, 7]) { out.append((.tool, action(call).detail)) }
            default:
                // Tool results (run_command, read_file, …) share this field.
                if let t = Proto.strings(payload, [140, 2, 1]).first { out.append((.result, TranscriptRenderer.clip(t))) }
            }
        }
        return out
    }

    /// The model the conversation last ran with, as `agy --model` takes it ("Gemini 3.8 Flash (High)").
    static func model(path: String) -> String? {
        var model: String?
        query(path, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 1") { stmt in
            model = Proto.strings(blob(stmt, 0), [1, 21]).first
        }
        return model
    }

    private static func lastTurn(path: String) -> (user: String?, assistant: String?, action: AgentAction?) {
        var user: String?, assistant: String?, action: AgentAction?, sawStep = false
        steps(path: path, newestFirst: true, limit: 200) { type, payload in
            if type == 14, user == nil { user = Proto.strings(payload, [19, 2]).first.map { oneLine($0) } }
            if type == 15 {
                let text = Proto.strings(payload, [20, 1]).first { !$0.isEmpty }
                if assistant == nil, let text { assistant = oneLine(text) }
                if !sawStep {
                    if let call = Proto.messages(payload, [20, 7]).last { action = self.action(call) }
                    else if text != nil { action = AgentAction(kind: .replying, detail: String(localized: "답변 작성 중")) }
                    else { action = AgentAction(kind: .thinking, detail: String(localized: "생각하는 중")) }
                }
                sawStep = true
            }
        }
        return (user, assistant, action)
    }

    /// A tool call: name in field 2, JSON arguments in field 3.
    private static func action(_ call: ArraySlice<UInt8>) -> AgentAction {
        let args = Proto.strings(call, [3]).first ?? ""
        let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
        return AgentAction.tool(Proto.strings(call, [2]).first ?? "", input: input ?? ["cmd": args])
    }

    private static func steps(path: String, newestFirst: Bool, limit: Int, _ each: (Int, ArraySlice<UInt8>) -> Void) {
        query(path, "SELECT step_type, step_payload FROM steps ORDER BY idx \(newestFirst ? "DESC" : "ASC") LIMIT \(limit)") { stmt in
            each(Int(sqlite3_column_int(stmt, 0)), blob(stmt, 1))
        }
    }

    private static func blob(_ stmt: OpaquePointer?, _ i: Int32) -> ArraySlice<UInt8> {
        guard let p = sqlite3_column_blob(stmt, i) else { return [] }
        return ArraySlice(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_column_bytes(stmt, i))))
    }

    private static func query(_ path: String, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        // These are WAL databases. agy removes -wal and -shm once idle (seen with 1.4.12), and a read-only connection cannot
        // open a WAL database without -shm ("unable to open database file"). With no -wal the main file holds
        // everything, so read it as immutable then.
        let wal = FileManager.default.fileExists(atPath: path + "-wal")
        let uri = URL(fileURLWithPath: path).absoluteString + (wal ? "?mode=ro" : "?immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)  // the CLI writes these files while it runs
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}

/// Just enough protobuf to pull length-delimited fields out by number, following a path of nested messages.
enum Proto {
    static func messages(_ b: ArraySlice<UInt8>, _ path: [Int]) -> [ArraySlice<UInt8>] {
        path.reduce([b]) { level, n in level.flatMap { fields($0, n) } }
    }

    static func strings(_ b: ArraySlice<UInt8>, _ path: [Int]) -> [String] {
        messages(b, path).compactMap { String(bytes: $0, encoding: .utf8) }
    }

    /// The length-delimited fields numbered `number` at the top level of `b`; stops at the first malformed byte.
    private static func fields(_ b: ArraySlice<UInt8>, _ number: Int) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = b.startIndex
        while i < b.endIndex {
            guard let key = varint(b, &i) else { break }
            switch key & 7 {
            case 0: guard varint(b, &i) != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(b, &i), n <= UInt64(b.endIndex - i) else { return out }
                if key >> 3 == number { out.append(b[i..<(i + Int(n))]) }
                i += Int(n)
            default: return out
            }
        }
        return out
    }

    private static func varint(_ b: ArraySlice<UInt8>, _ i: inout Int) -> UInt64? {
        var r: UInt64 = 0, shift: UInt64 = 0
        while i < b.endIndex, shift < 64 {
            let c = b[i]
            i += 1
            r |= UInt64(c & 0x7f) << shift
            if c < 0x80 { return r }
            shift += 7
        }
        return nil
    }
}
