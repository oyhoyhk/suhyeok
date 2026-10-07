import Foundation

/// Renders the tail of a Claude or Codex conversation log as terminal-style text.
enum TranscriptRenderer {
    static func render(path: String, agent: Agent, maxBlocks: Int = 120) -> String {
        let lines = JSONLTail.lines(path: path, maxBytes: 2 * 1024 * 1024)
        let blocks = agent == .claude ? claude(lines) : codex(lines)
        return blocks.suffix(maxBlocks).joined(separator: "\n\n")
    }

    private static func claude(_ lines: [[String: Any]]) -> [String] {
        var out: [String] = []
        for line in lines {
            guard line["isMeta"] as? Bool != true, let msg = line["message"] as? [String: Any] else { continue }
            let type = line["type"] as? String
            if let s = msg["content"] as? String {
                if type == "user", !s.hasPrefix("<") { out.append("❯ " + s) }
                continue
            }
            for item in msg["content"] as? [[String: Any]] ?? [] {
                switch (type, item["type"] as? String) {
                case ("user", "text"?):
                    if let t = item["text"] as? String, !t.hasPrefix("<") { out.append("❯ " + t) }
                case ("assistant", "text"?):
                    if let t = item["text"] as? String { out.append("⏺ " + t) }
                case ("assistant", "tool_use"?):
                    let a = AgentAction.tool(item["name"] as? String ?? "", input: item["input"] as? [String: Any] ?? [:])
                    out.append("⏺ " + a.detail)
                case ("user", "tool_result"?):
                    out.append(result(item["content"]))
                default: break
                }
            }
        }
        return out
    }

    private static func codex(_ lines: [[String: Any]]) -> [String] {
        var out: [String] = []
        for line in lines where line["type"] as? String == "response_item" {
            guard let p = line["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "message":
                let texts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                    .filter { !$0.hasPrefix("<") && !$0.hasPrefix("# AGENTS.md") }
                guard let t = texts.first else { continue }
                if p["role"] as? String == "user" { out.append("❯ " + t) }
                if p["role"] as? String == "assistant" { out.append("⏺ " + t) }
            case "function_call", "custom_tool_call":
                let args = p["arguments"] as? String ?? p["input"] as? String ?? ""
                let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
                out.append("⏺ " + AgentAction.tool(p["name"] as? String ?? "", input: input ?? ["cmd": args]).detail)
            case "function_call_output", "custom_tool_call_output":
                out.append(result(p["output"]))
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
