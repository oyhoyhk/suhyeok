import Foundation

/// One entry of a conversation log, in display order.
struct ChatItem: Identifiable, Equatable {
    enum Role { case me, agent, tool, result }
    let id: Int
    let role: Role
    let text: String
}

/// Reads the tail of a Claude or Codex conversation log; feeds both the chat view and the terminal-style view.
enum TranscriptRenderer {
    /// Parsed entries per log, extended incrementally as the file grows (logs only ever get appended to).
    private struct Cached { var offset: UInt64; var entries: [(ChatItem.Role, String)] }
    private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()
    /// How far back the first read goes. Screenshots make single lines over 1 MB, so a small tail
    /// can hold no conversation at all; the window is wide and huge lines are skipped unparsed.
    private static let window: UInt64 = 32 * 1024 * 1024
    private static let hugeLine = 256 * 1024
    private static let keep = 600

    static func items(path: String, agent: Agent) -> [ChatItem] {
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var c = cache[path] ?? Cached(offset: size > window ? size - window : 0, entries: [])
        if c.offset > size { c = Cached(offset: size > window ? size - window : 0, entries: []) }  // file was replaced
        let fresh = c.offset == 0 || cache[path] == nil
        if size > c.offset {
            try? handle.seek(toOffset: c.offset)
            let data = handle.readData(ofLength: Int(size - c.offset))
            // Only complete lines; a half-written last line is read again next time.
            guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { cache[path] = c; return wrap(c.entries) }
            var chunks = data[data.startIndex...lastNL].split(separator: UInt8(ascii: "\n"))
            if fresh, c.offset > 0, !chunks.isEmpty { chunks.removeFirst() }  // started mid-line
            var parsed: [[String: Any]] = []
            for chunk in chunks {
                if chunk.count > hugeLine {
                    parsed.append(["type": "huge"])  // an image-heavy tool result; shown as a placeholder
                } else if let obj = (try? JSONSerialization.jsonObject(with: Data(chunk))) as? [String: Any] {
                    parsed.append(obj)
                }
            }
            c.entries += agent == .claude ? claude(parsed) : codex(parsed)
            if c.entries.count > keep { c.entries.removeFirst(c.entries.count - keep) }
            c.offset += UInt64(data.distance(from: data.startIndex, to: lastNL) + 1)
        }
        cache[path] = c
        return wrap(c.entries)
    }

    private static func wrap(_ e: [(ChatItem.Role, String)]) -> [ChatItem] {
        e.enumerated().map { ChatItem(id: $0.offset, role: $0.element.0, text: $0.element.1) }
    }

    static func render(path: String, agent: Agent, maxBlocks: Int = 120) -> String {
        items(path: path, agent: agent).suffix(maxBlocks).map { item in
            switch item.role {
            case .me: return "❯ " + item.text
            case .agent, .tool: return "⏺ " + item.text
            case .result: return item.text
            }
        }.joined(separator: "\n\n")
    }

    private static func claude(_ lines: [[String: Any]]) -> [(ChatItem.Role, String)] {
        var out: [(ChatItem.Role, String)] = []
        for line in lines {
            if line["type"] as? String == "huge" { out.append((.result, "  ⎿ (이미지 등 큰 결과)")); continue }
            // A message typed while the agent is busy is logged at once as a queue "enqueue", and again as a
            // queued_command attachment when the agent picks it up; show the first, skip the repeat below.
            if line["type"] as? String == "queue-operation", line["operation"] as? String == "enqueue",
               let p = line["content"] as? String, !p.hasPrefix("<") {
                out.append((.me, p))
                continue
            }
            // Messages typed while the agent was busy are stored as queued_command attachments.
            if let a = line["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
               (a["origin"] as? [String: Any])?["kind"] as? String == "human", let p = a["prompt"] as? String {
                if !out.contains(where: { $0.0 == .me && $0.1 == p }) { out.append((.me, p)) }
                continue
            }
            guard line["isMeta"] as? Bool != true, let msg = line["message"] as? [String: Any] else { continue }
            let type = line["type"] as? String
            if let s = msg["content"] as? String {
                if type == "user", !s.hasPrefix("<") { out.append((.me, s)) }
                else if type == "user", let c = slashCommand(s) { out.append((.me, c)) }
                continue
            }
            for item in msg["content"] as? [[String: Any]] ?? [] {
                switch (type, item["type"] as? String) {
                case ("user", "text"?):
                    if let t = item["text"] as? String, !t.hasPrefix("<") { out.append((.me, t)) }
                case ("assistant", "text"?):
                    if let t = item["text"] as? String { out.append((.agent, t)) }
                case ("assistant", "tool_use"?):
                    let a = AgentAction.tool(item["name"] as? String ?? "", input: item["input"] as? [String: Any] ?? [:])
                    out.append((.tool, a.detail))
                case ("user", "tool_result"?):
                    out.append((.result, result(item["content"])))
                default: break
                }
            }
        }
        return out
    }

    /// A slash command the user typed ("/clear", "/model haiku"), logged as <command-name>…<command-args>… tags.
    private static func slashCommand(_ s: String) -> String? {
        func tag(_ t: String) -> String? {
            guard let a = s.range(of: "<\(t)>"), let b = s.range(of: "</\(t)>", range: a.upperBound..<s.endIndex) else { return nil }
            return s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = tag("command-name"), name.hasPrefix("/") else { return nil }
        let args = tag("command-args") ?? ""
        return args.isEmpty ? name : name + " " + args
    }

    private static func codex(_ lines: [[String: Any]]) -> [(ChatItem.Role, String)] {
        var out: [(ChatItem.Role, String)] = []
        for line in lines where line["type"] as? String == "response_item" {
            guard let p = line["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "message":
                let texts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                    .filter { !$0.hasPrefix("<") && !$0.hasPrefix("# AGENTS.md") }
                guard let t = texts.first else { continue }
                if p["role"] as? String == "user" { out.append((.me, t)) }
                if p["role"] as? String == "assistant" { out.append((.agent, t)) }
            case "function_call", "custom_tool_call":
                let args = p["arguments"] as? String ?? p["input"] as? String ?? ""
                let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
                out.append((.tool, AgentAction.tool(p["name"] as? String ?? "", input: input ?? ["cmd": args]).detail))
            case "function_call_output", "custom_tool_call_output":
                out.append((.result, result(p["output"])))
            default: break
            }
        }
        return out
    }

    /// Tool output, clipped to a few lines like the CLI does.
    private static func result(_ content: Any?) -> String {
        var text = ""
        if let s = content as? String { text = s }
        else if let items = content as? [[String: Any]] {
            text = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if text.isEmpty, !items.isEmpty { text = "(이미지 등 \(items.count)개 항목)" }
        } else if let d = content as? [String: Any], let s = d["output"] as? String { text = s }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = rows.prefix(6).map { "  ⎿ " + $0 }.joined(separator: "\n")
        return rows.count > 6 ? shown + "\n  ⎿ … +\(rows.count - 6)줄" : shown
    }
}
