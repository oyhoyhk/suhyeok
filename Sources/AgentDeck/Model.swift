import Foundation

enum Agent: String {
    case claude = "Claude"
    case codex = "Codex"
    case antigravity = "Antigravity"

    /// Can start a new conversation from a copy of an existing one (agy has no fork).
    var canFork: Bool {
        switch self {
        case .claude, .codex: return true
        case .antigravity: return false
        }
    }

    /// What ends the CLI when typed into its input box.
    var quitCommand: String {
        switch self {
        case .claude, .antigravity: return "/exit"
        case .codex: return "/quit"
        }
    }

    /// Runs the agent without asking before it edits files or runs commands.
    var skipPermissionsFlag: String {
        switch self {
        case .claude, .antigravity: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        }
    }

    /// Arguments that add `text` to the agent's system instructions; nil when the CLI has no way to (agy).
    func instructionArgs(_ text: String) -> [String]? {
        switch self {
        case .claude: return ["--append-system-prompt", text]
        case .codex: return ["-c", "developer_instructions=" + TmuxEngine.tomlString(text)]
        case .antigravity: return nil
        }
    }

    /// The first prompt on the command line: agy rejects a bare argument; -i sends it and stays interactive.
    func promptArgs(_ prompt: String) -> [String] {
        switch self {
        case .claude, .codex: return [prompt]
        case .antigravity: return ["-i", prompt]
        }
    }
}

enum SessionStatus: String {
    /// Claude Code registry values: busy = in a turn, waiting = asking you (permission / question menu),
    /// shell = turn over but background shells still running, idle = done.
    case busy, waiting, shell, idle, unknown

    var label: String {
        switch self {
        case .busy: return String(localized: "작업 중")
        case .waiting: return String(localized: "선택 기다리는 중")
        case .shell: return String(localized: "셸 실행")
        case .idle: return String(localized: "대기")
        case .unknown: return String(localized: "알 수 없음")
        }
    }

    var sortRank: Int {
        switch self {
        case .waiting: return 0
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
    /// Live session whose process launched this one, e.g. a `claude -p` run from that session's script.
    var parentId: String? = nil
    /// With status "shell": whether a background shell runs real work (true) or only wait loops (false); nil when unknown.
    var backgroundWork: Bool? = nil
    /// Claude Agent-tool subagents running inside this session's process (they have no session of their own).
    var subagents: [SubagentWork] = []

    var project: String { Worktree.project(of: cwd) }
}

/// What a running Agent-tool subagent is doing: its task description and newest tool call.
struct SubagentWork: Identifiable {
    let id: String
    let title: String
    let action: AgentAction?
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

    /// A wait loop older than this is killed (BackgroundShells.reap); a background shell that could not be looked at
    /// counts as work for this long. Default 6 hours; override with `defaults write com.pickuma.agentdeck waitLoopHours <n>`.
    static var waitLoopLimit: TimeInterval {
        let h = UserDefaults.standard.double(forKey: "waitLoopHours")
        return (h > 0 ? h : 6) * 3600
    }

    var label: String {
        switch self {
        case .working: return String(localized: "작업 중")
        case .waiting: return String(localized: "대기 중")
        case .resting: return String(localized: "휴식 중")
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
        case .busy: return .working
        // Blocked on a permission prompt or a question: not working, needs you.
        case .waiting: return .waiting
        // Claude Code reports "shell" when its turn is over but background shells it started are still
        // running (the "N shells still running" footer). An experiment or build is still work; wait loops alone
        // are not, and the agent is waiting for you.
        case .shell where backgroundWork ?? (-(updatedAt ?? .distantPast).timeIntervalSinceNow < Activity.waitLoopLimit):
            return .working
        case .shell, .idle, .unknown:
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
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "write_file", "edit_file": kind = .editing
        case "Read", "Grep", "Glob", "LS", "LSP", "read_file": kind = .reading
        case "Bash", "exec", "shell", "exec_command", "run_command": kind = .shell
        case "WebFetch", "WebSearch", "search_web": kind = .web
        case "Agent", "Task", "Workflow", "invoke_subagent": kind = .delegating
        default: kind = .other
        }
        // The most telling input field per tool, e.g. the command or the file name. Antigravity: toolSummary, CommandLine, Path.
        let keys = ["description", "toolSummary", "command", "CommandLine", "file_path", "Path", "pattern", "url", "query", "prompt", "cmd"]
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
            return AgentAction(kind: .thinking, detail: String(localized: "생각하는 중"))
        case "text":
            return AgentAction(kind: .replying, detail: String(localized: "답변 작성 중"))
        default:
            return nil
        }
    }
}
