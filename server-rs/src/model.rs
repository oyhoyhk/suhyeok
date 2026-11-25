//! Session model shared by every module: a port of Sources/AgentDeck/Model.swift.
//! Times are Unix seconds (f64) so they map 1:1 onto the JSON the contract sends.

use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Agent {
    Claude,
    Codex,
    Antigravity,
}

impl Agent {
    /// The contract's `agent` value ("Claude", "Codex", "Antigravity").
    pub fn raw(self) -> &'static str {
        match self {
            Agent::Claude => "Claude",
            Agent::Codex => "Codex",
            Agent::Antigravity => "Antigravity",
        }
    }
    pub fn from_raw(s: &str) -> Option<Agent> {
        match s {
            "Claude" => Some(Agent::Claude),
            "Codex" => Some(Agent::Codex),
            "Antigravity" => Some(Agent::Antigravity),
            _ => None,
        }
    }
    /// Can start a new conversation from a copy of an existing one (agy has no fork).
    pub fn can_fork(self) -> bool {
        !matches!(self, Agent::Antigravity)
    }
}

/// Claude Code registry values: busy = in a turn, waiting = asking you, shell = turn over but background shells
/// still running, idle = done.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionStatus {
    Busy,
    Waiting,
    Shell,
    Idle,
    Unknown,
}

impl SessionStatus {
    pub fn raw(self) -> &'static str {
        match self {
            SessionStatus::Busy => "busy",
            SessionStatus::Waiting => "waiting",
            SessionStatus::Shell => "shell",
            SessionStatus::Idle => "idle",
            SessionStatus::Unknown => "unknown",
        }
    }
    pub fn from_raw(s: &str) -> SessionStatus {
        match s {
            "busy" => SessionStatus::Busy,
            "waiting" => SessionStatus::Waiting,
            "shell" => SessionStatus::Shell,
            "idle" => SessionStatus::Idle,
            _ => SessionStatus::Unknown,
        }
    }
}

/// What the map shows: raw status folded into three activities.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Activity {
    Working,
    Waiting,
    Resting,
}

impl Activity {
    /// The contract's `activityCode` (Swift's "\(activity)").
    pub fn code(self) -> &'static str {
        match self {
            Activity::Working => "working",
            Activity::Waiting => "waiting",
            Activity::Resting => "resting",
        }
    }
    pub fn label(self, en: bool) -> &'static str {
        match (self, en) {
            (Activity::Working, false) => "작업 중",
            (Activity::Waiting, false) => "대기 중",
            (Activity::Resting, false) => "휴식 중",
            (Activity::Working, true) => "Working",
            (Activity::Waiting, true) => "Waiting",
            (Activity::Resting, true) => "Resting",
        }
    }
    pub fn sort_rank(self) -> i32 {
        match self {
            Activity::Working => 0,
            Activity::Waiting => 1,
            Activity::Resting => 2,
        }
    }
}

/// An idle session longer than this goes to rest (Swift default 10 minutes).
pub const REST_AFTER: f64 = 10.0 * 60.0;
/// A background shell that could not be looked at counts as work for this long (Swift default 6 hours).
pub const WAIT_LOOP_LIMIT: f64 = 6.0 * 3600.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ActionKind {
    Editing,
    Reading,
    Shell,
    Web,
    Delegating,
    Thinking,
    Replying,
    Other,
}

/// What a working agent is doing right now, from the newest assistant entry in its transcript.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentAction {
    pub kind: ActionKind,
    pub detail: String,
}

impl AgentAction {
    /// SF Symbol name, sent as `actionSymbol` (the page maps it to its own icon).
    pub fn symbol(&self) -> &'static str {
        match self.kind {
            ActionKind::Editing => "pencil",
            ActionKind::Reading => "book.fill",
            ActionKind::Shell => "hammer.fill",
            ActionKind::Web => "globe",
            ActionKind::Delegating => "person.2.fill",
            ActionKind::Thinking => "brain.head.profile",
            ActionKind::Replying => "text.bubble.fill",
            ActionKind::Other => "wrench.and.screwdriver.fill",
        }
    }

    pub fn tool(name: &str, input: &Value) -> AgentAction {
        let kind = match name {
            "Edit" | "Write" | "MultiEdit" | "NotebookEdit" | "write_file" | "edit_file" => ActionKind::Editing,
            "Read" | "Grep" | "Glob" | "LS" | "LSP" | "read_file" => ActionKind::Reading,
            "Bash" | "exec" | "shell" | "exec_command" | "run_command" => ActionKind::Shell,
            "WebFetch" | "WebSearch" | "search_web" => ActionKind::Web,
            "Agent" | "Task" | "Workflow" | "invoke_subagent" => ActionKind::Delegating,
            _ => ActionKind::Other,
        };
        // The most telling input field per tool, e.g. the command or the file name.
        let keys = [
            "description", "toolSummary", "command", "CommandLine", "file_path", "Path", "pattern", "url", "query",
            "prompt", "cmd",
        ];
        let raw = keys.iter().find_map(|k| input.get(*k).and_then(Value::as_str)).unwrap_or("");
        // NSString.lastPathComponent: a trailing "/" does not count ("/a/b/" → "b"; "/" stays "/").
        let detail = if raw.starts_with('/') {
            let t = raw.trim_end_matches('/');
            if t.is_empty() { "/" } else { t.rsplit('/').next().unwrap_or(t) }
        } else {
            raw
        };
        let text = if detail.is_empty() { name.to_string() } else { format!("{name} · {detail}") };
        AgentAction { kind, detail: one_line(&text, 80) }
    }

    /// Claude transcript `message.content` of an assistant entry.
    pub fn from_claude(content: Option<&Value>, en: bool) -> Option<AgentAction> {
        let last = content?.as_array()?.last()?;
        match last.get("type").and_then(Value::as_str)? {
            "tool_use" => Some(AgentAction::tool(
                last.get("name").and_then(Value::as_str).unwrap_or(""),
                last.get("input").unwrap_or(&Value::Null),
            )),
            "thinking" | "redacted_thinking" => Some(AgentAction {
                kind: ActionKind::Thinking,
                detail: if en { "Thinking" } else { "생각하는 중" }.into(),
            }),
            "text" => Some(AgentAction {
                kind: ActionKind::Replying,
                detail: if en { "Writing a reply" } else { "답변 작성 중" }.into(),
            }),
            _ => None,
        }
    }
}

/// A Claude Agent-tool subagent running inside a session's process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubagentWork {
    pub id: String,
    pub title: String,
    pub action: Option<AgentAction>,
}

#[derive(Clone, Debug)]
pub struct AgentSession {
    /// "claude-<pid>", "codex-<thread id>", … (same ids as the Mac).
    pub id: String,
    pub agent: Agent,
    pub name: String,
    pub generated_name: Option<String>,
    pub cwd: String,
    pub status: SessionStatus,
    pub started_at: Option<f64>,
    pub updated_at: Option<f64>,
    pub last_user: Option<String>,
    pub last_assistant: Option<String>,
    /// Liveness inferred from file recency rather than a live process registry.
    pub estimated: bool,
    pub pid: Option<u32>,
    pub action: Option<AgentAction>,
    pub transcript_path: Option<String>,
    /// Set when the agent runs in a terminal this server hosts (phase 2): the terminal's name.
    pub hosted_name: Option<String>,
    pub conversation_id: Option<String>,
    pub parent_id: Option<String>,
    pub background_work: Option<bool>,
    pub subagents: Vec<SubagentWork>,
}

impl AgentSession {
    pub fn new(id: String, agent: Agent, name: String, cwd: String, status: SessionStatus) -> AgentSession {
        AgentSession {
            id,
            agent,
            name,
            generated_name: None,
            cwd,
            status,
            started_at: None,
            updated_at: None,
            last_user: None,
            last_assistant: None,
            estimated: false,
            pid: None,
            action: None,
            transcript_path: None,
            hosted_name: None,
            conversation_id: None,
            parent_id: None,
            background_work: None,
            subagents: vec![],
        }
    }

    pub fn project(&self) -> String {
        crate::sessions::worktree::project(&self.cwd)
    }

    /// Same folding as the Swift `activity` property, at time `now` (Unix seconds).
    pub fn activity_at(&self, now: f64) -> Activity {
        let idle_for = now - self.updated_at.unwrap_or(f64::MIN / 2.0);
        match self.status {
            SessionStatus::Busy => Activity::Working,
            SessionStatus::Waiting => Activity::Waiting,
            SessionStatus::Shell if self.background_work.unwrap_or(idle_for < WAIT_LOOP_LIMIT) => Activity::Working,
            _ => {
                if idle_for < REST_AFTER {
                    Activity::Waiting
                } else {
                    Activity::Resting
                }
            }
        }
    }

    pub fn activity(&self) -> Activity {
        self.activity_at(now())
    }
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Collapses newlines and cuts at `limit` characters with an ellipsis (Swift `oneLine`).
pub fn one_line(s: &str, limit: usize) -> String {
    let collapsed = s.lines().filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ");
    let collapsed = collapsed.trim();
    if collapsed.chars().count() > limit {
        format!("{}…", collapsed.chars().take(limit).collect::<String>())
    } else {
        collapsed.to_string()
    }
}

/// The trailing JSONL lines of a file without loading the whole transcript (Swift `JSONLTail`).
pub fn jsonl_tail(path: &str, max_bytes: u64) -> Vec<Value> {
    let Ok(mut f) = std::fs::File::open(path) else { return vec![] };
    let size = f.seek(SeekFrom::End(0)).unwrap_or(0);
    let start = size.saturating_sub(max_bytes);
    if f.seek(SeekFrom::Start(start)).is_err() {
        return vec![];
    }
    let mut buf = Vec::new();
    if f.read_to_end(&mut buf).is_err() {
        return vec![];
    }
    let mut chunks: Vec<&[u8]> = buf.split(|b| *b == b'\n').filter(|c| !c.is_empty()).collect();
    if start > 0 && !chunks.is_empty() {
        chunks.remove(0); // first line is partial
    }
    chunks.into_iter().filter_map(|c| serde_json::from_slice::<Value>(c).ok()).filter(Value::is_object).collect()
}

/// The user's home folder, as the agents' own CLIs see it.
pub fn home() -> String {
    dirs::home_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_line_collapses_and_cuts() {
        assert_eq!(one_line("a\n\nb  ", 400), "a b");
        assert_eq!(one_line("가나다라", 2), "가나…");
    }

    #[test]
    fn tool_action_uses_the_telling_field() {
        let a = AgentAction::tool("Bash", &serde_json::json!({"command": "cargo test"}));
        assert_eq!(a.kind, ActionKind::Shell);
        assert_eq!(a.detail, "Bash · cargo test");
        let r = AgentAction::tool("Read", &serde_json::json!({"file_path": "/a/b/c.rs"}));
        assert_eq!(r.detail, "Read · c.rs");
        let d = AgentAction::tool("LS", &serde_json::json!({"Path": "/a/b/"}));
        assert_eq!(d.detail, "LS · b");
    }

    #[test]
    fn activity_folding_matches_swift() {
        let mut s = AgentSession::new("x".into(), Agent::Claude, "n".into(), "/".into(), SessionStatus::Idle);
        s.updated_at = Some(1000.0);
        assert_eq!(s.activity_at(1000.0 + 60.0), Activity::Waiting);
        assert_eq!(s.activity_at(1000.0 + 11.0 * 60.0), Activity::Resting);
        s.status = SessionStatus::Busy;
        assert_eq!(s.activity_at(99999.0), Activity::Working);
        s.status = SessionStatus::Shell;
        s.background_work = Some(false);
        assert_eq!(s.activity_at(1000.0 + 60.0), Activity::Waiting);
    }
}
