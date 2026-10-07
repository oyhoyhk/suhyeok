import Foundation

enum Agent: String {
    case claude = "Claude"
    case codex = "Codex"
}

enum SessionStatus: String {
    case busy, shell, idle, unknown

    var label: String {
        switch self {
        case .busy: return "작업 중"
        case .shell: return "셸 실행"
        case .idle: return "대기"
        case .unknown: return "알 수 없음"
        }
    }

    var sortRank: Int {
        switch self {
        case .busy: return 0
        case .shell: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }
}

struct AgentSession: Identifiable {
    let id: String
    let agent: Agent
    var name: String
    /// The title Claude/Codex generated, kept when the user sets their own summary as `name`.
    var generatedName: String? = nil
    let cwd: String
    let status: SessionStatus
    let startedAt: Date?
    let updatedAt: Date?
    let lastUser: String?
    let lastAssistant: String?
    /// true when liveness is inferred from file recency rather than a live process registry.
    let estimated: Bool
    /// OS process id when known (Claude registry); used to locate the hosting terminal.
    var pid: Int32? = nil
    /// Newest tool call or step; drives the working animation.
    var action: AgentAction? = nil
    /// Conversation log (Claude jsonl or Codex rollout); readable no matter which terminal hosts the agent.
    var transcriptPath: String? = nil
    /// Set when the agent runs on 수혁's own tmux server: the session name to attach to.
    var hostedName: String? = nil
    /// Claude conversation id, used to resume the conversation elsewhere.
    var conversationId: String? = nil

    var project: String { (cwd as NSString).lastPathComponent }
}

/// Reads the trailing JSONL lines of a file without loading the whole transcript.
enum JSONLTail {
    static func lines(path: String, maxBytes: Int = 512 * 1024) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var chunks = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !chunks.isEmpty { chunks.removeFirst() } // first line is partial
        return chunks.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }
}

func oneLine(_ s: String, limit: Int = 400) -> String {
    let collapsed = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
}

/// What the map shows: raw agent status folded into three activities.
enum Activity: CaseIterable {
    case working, waiting, resting

    /// An idle session longer than this goes to rest. Default 10 minutes;
    /// override with `defaults write com.pickuma.agentdeck restAfterMinutes <n>`.
    static var restAfter: TimeInterval {
        let m = UserDefaults.standard.double(forKey: "restAfterMinutes")
        return (m > 0 ? m : 10) * 60
    }

    var label: String {
        switch self {
        case .working: return "작업 중"
        case .waiting: return "대기 중"
        case .resting: return "휴식 중"
        }
    }

    var sortRank: Int {
        switch self {
        case .working: return 0
        case .waiting: return 1
        case .resting: return 2
        }
    }
}

extension AgentSession {
    var activity: Activity {
        switch status {
        case .busy, .shell: return .working
        case .idle, .unknown:
            let idleFor = -(updatedAt ?? .distantPast).timeIntervalSinceNow
            return idleFor < Activity.restAfter ? .waiting : .resting
        }
    }
}

/// What a working agent is doing right now, from the newest assistant entry in its transcript.
struct AgentAction: Equatable {
    enum Kind { case editing, reading, shell, web, delegating, thinking, replying, other }
    let kind: Kind
    let detail: String

    var symbol: String {
        switch kind {
        case .editing: return "pencil"
        case .reading: return "book.fill"
        case .shell: return "hammer.fill"
        case .web: return "globe"
        case .delegating: return "person.2.fill"
        case .thinking: return "brain.head.profile"
        case .replying: return "text.bubble.fill"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    static func tool(_ name: String, input: [String: Any]) -> AgentAction {
        let kind: Kind
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": kind = .editing
        case "Read", "Grep", "Glob", "LS", "LSP": kind = .reading
        case "Bash", "exec", "shell", "exec_command": kind = .shell
        case "WebFetch", "WebSearch": kind = .web
        case "Agent", "Task", "Workflow": kind = .delegating
        default: kind = .other
        }
        // The most telling input field per tool, e.g. the command or the file name.
        let keys = ["description", "command", "file_path", "pattern", "url", "query", "prompt", "cmd"]
        let raw = keys.lazy.compactMap { input[$0] as? String }.first ?? ""
        let detail = raw.hasPrefix("/") ? (raw as NSString).lastPathComponent : raw
        return AgentAction(kind: kind, detail: oneLine(detail.isEmpty ? name : "\(name) · \(detail)", limit: 80))
    }

    /// Claude transcript `message.content` of an assistant entry.
    static func fromClaude(_ content: Any?) -> AgentAction? {
        guard let items = content as? [[String: Any]], let last = items.last else { return nil }
        switch last["type"] as? String {
        case "tool_use":
            return tool(last["name"] as? String ?? "", input: last["input"] as? [String: Any] ?? [:])
        case "thinking", "redacted_thinking":
            return AgentAction(kind: .thinking, detail: "생각하는 중")
        case "text":
            return AgentAction(kind: .replying, detail: "답변 작성 중")
        default:
            return nil
        }
    }
}
