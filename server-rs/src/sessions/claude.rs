//! Live Claude Code sessions from the registry at ~/.claude/sessions/<pid>.json (port of ClaudeSource.swift).

use super::procs::Procs;
use super::{mtime_and_size, shells};
use crate::model::{jsonl_tail, now, one_line, Agent, AgentAction, AgentSession, SessionStatus, SubagentWork};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

pub fn sessions_dir(home: &Path) -> PathBuf {
    home.join(".claude").join("sessions")
}

pub fn projects_dir(home: &Path) -> PathBuf {
    home.join(".claude").join("projects")
}

pub fn load(home: &Path, procs: &Procs, en: bool) -> Vec<AgentSession> {
    let Ok(rd) = std::fs::read_dir(sessions_dir(home)) else { return vec![] };
    let mut files: Vec<PathBuf> =
        rd.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
    files.sort();
    files.iter().filter_map(|f| session(home, procs, f, en)).collect()
}

fn session(home: &Path, procs: &Procs, file: &Path, en: bool) -> Option<AgentSession> {
    let obj: Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    let pid = obj.get("pid").and_then(as_pid)?;
    if !procs.exists(pid) {
        return None;
    }
    let session_id = obj.get("sessionId")?.as_str()?.to_string();
    let cwd = obj.get("cwd").and_then(Value::as_str).unwrap_or("").to_string();
    let transcript = transcript_path(home, &session_id, &cwd);
    let info = transcript.as_deref().map(|p| transcript_info(p, en)).unwrap_or_default();
    let registry_name =
        obj.get("name").and_then(Value::as_str).map(String::from).unwrap_or_else(|| session_id.chars().take(8).collect());
    // A user-set name wins; otherwise the AI title beats the derived "project-8f" style name.
    let name = if obj.get("nameSource").and_then(Value::as_str) == Some("derived") {
        info.title.clone().unwrap_or(registry_name)
    } else {
        registry_name
    };
    let status = SessionStatus::from_raw(obj.get("status").and_then(Value::as_str).unwrap_or(""));
    let background_work = if status == SessionStatus::Shell { shells::working(&shells::shells(pid, procs)) } else { None };
    let mut s = AgentSession::new(format!("claude-{pid}"), Agent::Claude, name, cwd, status);
    // pid, not sessionId: a resumed conversation can run in two processes at once.
    s.started_at = date_ms(obj.get("startedAt"));
    s.updated_at = date_ms(obj.get("statusUpdatedAt").or(obj.get("updatedAt")));
    s.last_user = info.user;
    s.last_assistant = info.assistant;
    s.pid = Some(pid);
    s.action = info.action;
    s.subagents = transcript.as_deref().map(|t| subagents(t, en)).unwrap_or_default();
    s.transcript_path = transcript;
    s.conversation_id = Some(session_id);
    s.background_work = background_work;
    // hosted_name: phase 2 (terminals this server hosts).
    Some(s)
}

/// Swift `obj["pid"] as? Int32`.
fn as_pid(v: &Value) -> Option<u32> {
    let n = v.as_i64().or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))?;
    (1..=i32::MAX as i64).contains(&n).then_some(n as u32)
}

fn date_ms(v: Option<&Value>) -> Option<f64> {
    v?.as_f64().map(|ms| ms / 1000.0)
}

/// Claude Code marks its panels (/status, /usage, /config …) as `waitingFor: "dialog open"`; a dialog that asks for a
/// choice also says what it `needs`, and is answered, not closed.
pub fn is_panel(obj: &Value) -> bool {
    obj.get("waitingFor").and_then(Value::as_str) == Some("dialog open") && obj.get("needs").is_none()
}

/// Reads the registry now: it changes within 0.1 s of a panel opening or closing.
pub fn panel_open(home: &Path, pid: u32) -> bool {
    std::fs::read(sessions_dir(home).join(format!("{pid}.json")))
        .ok()
        .and_then(|d| serde_json::from_slice::<Value>(&d).ok())
        .is_some_and(|o| is_panel(&o))
}

/// Folder name Claude Code uses for a cwd: every character that is not a letter or digit becomes '-'.
pub fn slug(cwd: &str) -> String {
    cwd.chars().map(|c| if c.is_alphabetic() || c.is_numeric() { c } else { '-' }).collect()
}

/// Transcript lives at ~/.claude/projects/<slug>/<sessionId>.jsonl; any project folder is tried if the slug misses.
pub fn transcript_path(home: &Path, session_id: &str, cwd: &str) -> Option<String> {
    let projects = projects_dir(home);
    let file = format!("{session_id}.jsonl");
    let direct = projects.join(slug(cwd)).join(&file);
    if direct.is_file() {
        return Some(direct.to_string_lossy().into_owned());
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&projects).ok()?.filter_map(|e| e.ok().map(|e| e.path())).collect();
    dirs.sort();
    dirs.into_iter().map(|d| d.join(&file)).find(|p| p.is_file()).map(|p| p.to_string_lossy().into_owned())
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TranscriptInfo {
    pub title: Option<String>,
    pub user: Option<String>,
    pub assistant: Option<String>,
    pub action: Option<AgentAction>,
}

/// Parsed tail per transcript, reused while the file's size and mtime (and the label language) stay the same.
static INFO_CACHE: LazyLock<Mutex<HashMap<String, (String, TranscriptInfo)>>> = LazyLock::new(Default::default);

pub fn transcript_info(path: &str, en: bool) -> TranscriptInfo {
    let stamp = match mtime_and_size(Path::new(path)) {
        Some((m, size)) => format!("{size}|{m}|{en}"),
        None => format!("||{en}"),
    };
    if let Some((s, info)) = INFO_CACHE.lock().unwrap().get(path) {
        if *s == stamp {
            return info.clone();
        }
    }
    let info = parse_transcript(path, en);
    INFO_CACHE.lock().unwrap().insert(path.to_string(), (stamp, info.clone()));
    info
}

pub fn parse_transcript(path: &str, en: bool) -> TranscriptInfo {
    let mut t = TranscriptInfo::default();
    let mut saw_assistant = false;
    // Large tool results (screenshots) can fill the tail, so widen the window if needed.
    for max_bytes in [512 * 1024, 4 * 1024 * 1024] {
        for line in jsonl_tail(path, max_bytes).iter().rev() {
            if t.title.is_some() && t.user.is_some() && t.assistant.is_some() {
                break;
            }
            match line.get("type").and_then(Value::as_str) {
                Some("ai-title") => {
                    if t.title.is_none() {
                        t.title = line.get("aiTitle").and_then(Value::as_str).map(String::from);
                    }
                }
                Some("last-prompt") => {
                    if t.user.is_none() {
                        t.user = line.get("lastPrompt").and_then(Value::as_str).map(|s| one_line(s, 400));
                    }
                }
                Some("assistant") => {
                    if line.get("isMeta").and_then(Value::as_bool) == Some(true) {
                        continue;
                    }
                    let Some(message) = line.get("message").filter(|m| m.is_object()) else { continue };
                    if !saw_assistant {
                        // Only the newest entry says what is happening now.
                        saw_assistant = true;
                        t.action = AgentAction::from_claude(message.get("content"), en);
                    }
                    if t.assistant.is_none() {
                        t.assistant = text(message.get("content"));
                    }
                }
                _ => {}
            }
        }
        if t.user.is_some() && t.assistant.is_some() {
            break;
        }
    }
    t
}

/// Plain text only; skips tool results and harness-injected <tags>.
fn text(content: Option<&Value>) -> Option<String> {
    let parts: Vec<&str> = match content {
        Some(Value::String(s)) => vec![s.as_str()],
        Some(Value::Array(items)) => items
            .iter()
            .filter(|i| i.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|i| i.get("text").and_then(Value::as_str))
            .collect(),
        _ => vec![],
    };
    let joined = parts.into_iter().filter(|p| !p.starts_with('<')).collect::<Vec<_>>().join(" ");
    let trimmed = joined.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(one_line(trimmed, 400))
    }
}

/// A subagent log that has not grown for this long is gone (a stopped subagent never writes end_turn).
pub const SUBAGENT_STALE: f64 = 10.0 * 60.0;

struct SubagentEntry {
    stamp: String,
    modified: f64,
    work: Option<SubagentWork>,
}

static SUBAGENT_CACHE: LazyLock<Mutex<HashMap<String, SubagentEntry>>> = LazyLock::new(Default::default);

/// Agent-tool subagents still running in this conversation. They run inside the parent's process, so they have no
/// registry entry: only logs at <transcript>/subagents/agent-<id>.jsonl, with the task in agent-<id>.meta.json.
pub fn subagents(transcript: &str, en: bool) -> Vec<SubagentWork> {
    let base = transcript.strip_suffix(".jsonl").unwrap_or(transcript);
    let dir = Path::new(base).join("subagents");
    let Ok(rd) = std::fs::read_dir(&dir) else { return vec![] };
    let t = now();
    let mut cache = SUBAGENT_CACHE.lock().unwrap();
    cache.retain(|_, e| t - e.modified < SUBAGENT_STALE);
    let mut files: Vec<String> = rd
        .filter_map(|e| e.ok().and_then(|e| e.file_name().into_string().ok()))
        .filter(|f| f.starts_with("agent-") && f.ends_with(".jsonl"))
        .collect();
    files.sort();
    files
        .into_iter()
        .filter_map(|file| {
            let path = dir.join(&file);
            let (modified, size) = mtime_and_size(&path)?;
            if t - modified >= SUBAGENT_STALE {
                return None;
            }
            // Read every time, not cached: "finished": true lands in the meta file without the log changing.
            let stem = file.strip_suffix(".jsonl").unwrap_or(&file).to_string();
            let meta: Option<Value> =
                std::fs::read(dir.join(format!("{stem}.meta.json"))).ok().and_then(|d| serde_json::from_slice(&d).ok());
            if meta.as_ref().and_then(|m| m.get("finished")).and_then(Value::as_bool) == Some(true) {
                return None;
            }
            let key = path.to_string_lossy().into_owned();
            let stamp = format!("{size}|{modified}|{en}");
            if let Some(hit) = cache.get(&key) {
                if hit.stamp == stamp {
                    return hit.work.clone();
                }
            }
            let title = meta
                .as_ref()
                .and_then(|m| m.get("description"))
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
                .map(String::from)
                .unwrap_or_else(|| if en { "Subagent" } else { "서브에이전트" }.to_string());
            let work = subagent_work(&key, stem, title, en);
            cache.insert(key, SubagentEntry { stamp, modified, work: work.clone() });
            work
        })
        .collect()
}

fn subagent_work(path: &str, id: String, title: String, en: bool) -> Option<SubagentWork> {
    // Request records can fill the tail, so widen the window until the newest assistant entry shows up.
    let mut message: Option<Value> = None;
    for max_bytes in [64 * 1024, 512 * 1024, 4 * 1024 * 1024] {
        if message.is_some() {
            break;
        }
        message = jsonl_tail(path, max_bytes)
            .into_iter()
            .rev()
            .find(|l| {
                l.get("type").and_then(Value::as_str) == Some("assistant")
                    && l.get("isMeta").and_then(Value::as_bool) != Some(true)
            })
            .and_then(|l| l.get("message").filter(|m| m.is_object()).cloned());
    }
    // Not started yet counts as running; a turn that ended is finished.
    if message.as_ref().and_then(|m| m.get("stop_reason")).and_then(Value::as_str) == Some("end_turn") {
        return None;
    }
    Some(SubagentWork { id, title, action: AgentAction::from_claude(message.as_ref().and_then(|m| m.get("content")), en) })
}

#[cfg(test)]
mod tests {
    use super::super::procs::tests::proc;
    use super::super::procs::Procs;
    use super::super::tests::{fixture, write};
    use super::*;
    use crate::model::ActionKind;
    use serde_json::json;

    fn registry(home: &Path, pid: u32, extra: Value) {
        let mut obj = json!({"pid": pid, "sessionId": format!("sess-{pid}"), "cwd": "/Users/a/my_proj.x",
            "startedAt": 1_794_000_000_000u64, "updatedAt": 1_794_000_100_000u64, "statusUpdatedAt": 1_794_000_200_000u64,
            "name": "proj-8f", "nameSource": "derived", "status": "idle"});
        for (k, v) in extra.as_object().unwrap() {
            obj[k] = v.clone();
        }
        write(&sessions_dir(home).join(format!("{pid}.json")), &obj.to_string());
    }

    fn transcript_with_tail(home: &Path, session: &str, slug_dir: &str) -> PathBuf {
        let path = projects_dir(home).join(slug_dir).join(format!("{session}.jsonl"));
        let tail = [
            json!({"type": "ai-title", "aiTitle": "Fix the login bug"}),
            json!({"type": "last-prompt", "lastPrompt": "please\ncommit it"}),
        ];
        let mut body = fixture("claude-session.jsonl");
        // Title and prompt records sit in the middle, the newest assistant entry is still the fixture's last one.
        let lines: Vec<&str> = body.lines().collect();
        let (head, rest) = lines.split_at(3);
        body = format!("{}\n{}\n{}\n{}\n", head.join("\n"), tail[0], tail[1], rest.join("\n"));
        write(&path, &body);
        path
    }

    #[test]
    fn slug_keeps_letters_and_digits() {
        assert_eq!(slug("/Users/a/my_proj.x"), "-Users-a-my-proj-x");
        assert_eq!(slug("/Users/a/삼일PwC_폴더"), "-Users-a-삼일PwC-폴더");
        assert_eq!(slug("C:\\Users\\a\\proj"), "C--Users-a-proj");
    }

    #[test]
    fn registry_and_transcript() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        registry(home, 4242, json!({}));
        registry(home, 4343, json!({})); // not running
        registry(home, 4444, json!({"nameSource": "user", "name": "my name", "status": "busy", "sessionId": "other"}));
        write(&sessions_dir(home).join("4242.abcdef.key"), "x");
        transcript_with_tail(home, "sess-4242", "-Users-a-my-proj-x");
        let procs = Procs::from_list(vec![proc(4242, 1, "claude", "claude"), proc(4444, 1, "claude", "claude")], None);

        let all = load(home, &procs, false);
        assert_eq!(all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["claude-4242", "claude-4444"]);
        let s = &all[0];
        assert_eq!(s.name, "Fix the login bug");
        assert_eq!(s.agent, Agent::Claude);
        assert_eq!(s.cwd, "/Users/a/my_proj.x");
        assert_eq!(s.status, SessionStatus::Idle);
        assert_eq!(s.started_at, Some(1_794_000_000.0));
        assert_eq!(s.updated_at, Some(1_794_000_200.0));
        assert_eq!(s.last_user.as_deref(), Some("please commit it"));
        assert_eq!(s.last_assistant.as_deref(), Some("done"));
        let action = s.action.clone().unwrap();
        assert_eq!(action.kind, ActionKind::Shell);
        assert_eq!(action.detail, "Bash · git log --grep='git commit'");
        assert_eq!(s.conversation_id.as_deref(), Some("sess-4242"));
        assert_eq!(s.pid, Some(4242));
        assert!(s.transcript_path.as_deref().unwrap().ends_with("sess-4242.jsonl"));
        assert!(!s.estimated);
        assert_eq!(s.background_work, None);

        // A user-set name wins over the AI title; no transcript means no texts.
        let u = &all[1];
        assert_eq!(u.name, "my name");
        assert_eq!(u.status, SessionStatus::Busy);
        assert_eq!(u.transcript_path, None);
        assert_eq!(u.last_assistant, None);
    }

    #[test]
    fn transcript_found_outside_the_slug_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let p = transcript_with_tail(tmp.path(), "abc", "somewhere-else");
        assert_eq!(transcript_path(tmp.path(), "abc", "/x/y"), Some(p.to_string_lossy().into_owned()));
        assert_eq!(transcript_path(tmp.path(), "missing", "/x/y"), None);
    }

    #[test]
    fn shell_status_reads_background_shells() {
        let tmp = tempfile::tempdir().unwrap();
        registry(tmp.path(), 77, json!({"status": "shell"}));
        let snap = "/bin/zsh -c source /h/.claude/shell-snapshots/s.sh && eval 'while true; do sleep 1; done'";
        let procs = Procs::from_list(
            vec![proc(77, 1, "claude", "claude"), proc(78, 77, "zsh", snap), proc(79, 78, "sleep", "sleep 1")],
            None,
        );
        let s = &load(tmp.path(), &procs, true)[0];
        assert_eq!(s.status, SessionStatus::Shell);
        assert_eq!(s.background_work, Some(false));
        // No transcript: the derived name stays.
        assert_eq!(s.name, "proj-8f");
    }

    #[test]
    fn running_subagents_only() {
        let tmp = tempfile::tempdir().unwrap();
        let transcript = transcript_with_tail(tmp.path(), "parent", "p");
        let dir = PathBuf::from(transcript.to_string_lossy().trim_end_matches(".jsonl")).join("subagents");
        let busy = json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/a/b.rs"}}]}});
        let done = json!({"type": "assistant", "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": "ok"}]}});
        write(&dir.join("agent-1.jsonl"), &format!("{busy}\n"));
        write(&dir.join("agent-1.meta.json"), r#"{"description":"Scan the repo"}"#);
        write(&dir.join("agent-2.jsonl"), &format!("{busy}\n"));
        write(&dir.join("agent-2.meta.json"), r#"{"finished":true}"#);
        write(&dir.join("agent-3.jsonl"), &format!("{done}\n"));
        write(&dir.join("agent-4.jsonl"), &format!("{busy}\n"));
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(11 * 60);
        std::fs::File::options().write(true).open(dir.join("agent-4.jsonl")).unwrap().set_modified(old).unwrap();
        write(&dir.join("agent-5.jsonl"), "");

        let subs = subagents(&transcript.to_string_lossy(), true);
        assert_eq!(subs.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["agent-1", "agent-5"]);
        assert_eq!(subs[0].title, "Scan the repo");
        assert_eq!(subs[0].action.as_ref().unwrap().detail, "Read · b.rs");
        // Not started yet: running, default title, no action.
        assert_eq!(subs[1].title, "Subagent");
        assert_eq!(subs[1].action, None);
    }

    #[test]
    fn panel_detection() {
        assert!(is_panel(&json!({"waitingFor": "dialog open"})));
        assert!(!is_panel(&json!({"waitingFor": "dialog open", "needs": "choice"})));
        assert!(!is_panel(&json!({"waitingFor": "input needed"})));
    }
}
