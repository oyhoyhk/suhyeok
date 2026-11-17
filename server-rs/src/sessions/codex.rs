//! Codex sessions (port of CodexSource.swift). Codex has no live-session registry, so "live" means a thread updated
//! within `WINDOW` (and, for an interactive thread, a codex process still running it).

use super::procs::Procs;
use crate::model::{jsonl_tail, one_line, ActionKind, Agent, AgentAction, AgentSession, SessionStatus};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, Row};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

pub const WINDOW: f64 = 30.0 * 60.0;

pub fn db_path(home: &Path) -> PathBuf {
    home.join(".codex").join("state_5.sqlite")
}

pub(crate) fn open(path: &Path) -> Option<Connection> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()
}

/// Swift `sqlite3_column_text`: any stored type as text, NULL as None.
pub(crate) fn col_text(r: &Row, i: usize) -> Option<String> {
    match r.get_ref(i).ok()? {
        ValueRef::Null => None,
        ValueRef::Integer(n) => Some(n.to_string()),
        ValueRef::Real(f) => Some(f.to_string()),
        ValueRef::Text(t) | ValueRef::Blob(t) => Some(String::from_utf8_lossy(t).into_owned()),
    }
}

/// Swift `sqlite3_column_int64`: NULL as 0.
pub(crate) fn col_i64(r: &Row, i: usize) -> i64 {
    match r.get_ref(i) {
        Ok(ValueRef::Integer(n)) => n,
        Ok(ValueRef::Real(f)) => f as i64,
        Ok(ValueRef::Text(t)) => std::str::from_utf8(t).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0),
        _ => 0,
    }
}

struct Thread {
    id: String,
    rollout_path: Option<String>,
    cwd: String,
    title: Option<String>,
    created_ms: i64,
    updated_ms: i64,
    source: String,
}

fn threads(db: &Path, since_ms: i64) -> Vec<Thread> {
    let Some(conn) = open(db) else { return vec![] };
    let sql = "SELECT id, rollout_path, cwd, title, created_at_ms, updated_at_ms, source \
               FROM threads WHERE archived = 0 AND updated_at_ms > ? ORDER BY updated_at_ms DESC";
    let Ok(mut stmt) = conn.prepare(sql) else { return vec![] };
    let Ok(rows) = stmt.query_map([since_ms], |r| {
        Ok(Thread {
            id: col_text(r, 0).unwrap_or_default(),
            rollout_path: col_text(r, 1),
            cwd: col_text(r, 2).unwrap_or_default(),
            title: col_text(r, 3),
            created_ms: col_i64(r, 4),
            updated_ms: col_i64(r, 5),
            source: col_text(r, 6).unwrap_or_default(),
        })
    }) else {
        return vec![];
    };
    rows.filter_map(Result::ok).collect()
}

pub fn load(home: &Path, procs: &Procs, now: f64, en: bool) -> Vec<AgentSession> {
    let rows = threads(&db_path(home), ((now - WINDOW) * 1000.0) as i64);
    let running = procs.codex_rollouts();
    let mut sessions: Vec<AgentSession> = vec![];
    for t in rows {
        let title = t.title.as_deref().map(|s| one_line(s, 60));
        let rollout_path = t.rollout_path.clone().unwrap_or_default();
        let rollout = scan(&rollout_path, en);
        // Codex's own subagents record their parent thread as JSON in `source`.
        let source_json: Option<Value> = serde_json::from_str(&t.source).ok();
        let spawn = source_json.as_ref().and_then(|v| v.get("subagent"));
        let parent_thread = spawn
            .and_then(|s| s.get("thread_spawn"))
            .and_then(|s| s.get("parent_thread_id"))
            .and_then(Value::as_str)
            .map(String::from);
        let started = t.created_ms as f64 / 1000.0;
        let pid = running.get(&rollout_path).copied().or_else(|| {
            if spawn.is_none() && t.source != "exec" {
                let excluding: HashSet<u32> =
                    sessions.iter().filter_map(|s| s.pid).chain(running.values().copied()).collect();
                procs.codex_process(&t.cwd, started, &excluding)
            } else {
                None
            }
        });
        // An interactive thread whose process is gone has ended; finished `codex exec` and subagent threads stay,
        // under their parent.
        if pid.is_none() && spawn.is_none() && t.source != "exec" {
            continue;
        }
        let shown = match &title {
            Some(t) if !t.is_empty() => t.clone(),
            _ => t.id.chars().take(8).collect(),
        };
        let kind = if spawn.is_none() { t.source.clone() } else { "subagent".into() };
        let mut s = AgentSession::new(
            format!("codex-{}", t.id),
            Agent::Codex,
            format!("{shown} · {kind}"),
            t.cwd.clone(),
            rollout.status,
        );
        s.started_at = Some(started);
        s.updated_at = Some(t.updated_ms as f64 / 1000.0);
        s.last_user = rollout.user;
        s.last_assistant = rollout.assistant;
        s.estimated = true;
        s.pid = pid;
        s.action = rollout.action;
        s.transcript_path = t.rollout_path.clone();
        s.conversation_id = Some(t.id.clone());
        s.parent_id = parent_thread.map(|p| format!("codex-{p}"));
        // hosted_name: phase 2.
        sessions.push(s);
    }
    sessions
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rollout {
    pub status: SessionStatus,
    pub user: Option<String>,
    pub assistant: Option<String>,
    pub action: Option<AgentAction>,
}

/// busy = the last turn event is task_started with no later task_complete/turn_aborted.
pub fn scan(path: &str, en: bool) -> Rollout {
    let (mut status, mut user, mut assistant, mut action) = (None, None::<String>, None::<String>, None);
    let mut saw_item = false;
    for line in jsonl_tail(path, 512 * 1024).iter().rev() {
        if status.is_some() && user.is_some() && assistant.is_some() {
            break;
        }
        let Some(payload) = line.get("payload").filter(|p| p.is_object()) else { continue };
        let kind = payload.get("type").and_then(Value::as_str);
        let line_type = line.get("type").and_then(Value::as_str);
        if status.is_none() && line_type == Some("event_msg") {
            if kind == Some("task_started") {
                status = Some(SessionStatus::Busy);
            }
            if kind == Some("task_complete") || kind == Some("turn_aborted") {
                status = Some(SessionStatus::Idle);
            }
        }
        if !saw_item && line_type == Some("response_item") {
            saw_item = true;
            match kind {
                Some("function_call") | Some("custom_tool_call") => {
                    let args = payload
                        .get("arguments")
                        .and_then(Value::as_str)
                        .or_else(|| payload.get("input").and_then(Value::as_str))
                        .unwrap_or("");
                    let input = serde_json::from_str::<Value>(args).ok().filter(Value::is_object).unwrap_or(json!({"cmd": args}));
                    action = Some(AgentAction::tool(payload.get("name").and_then(Value::as_str).unwrap_or(""), &input));
                }
                Some("reasoning") => {
                    action = Some(AgentAction {
                        kind: ActionKind::Thinking,
                        detail: if en { "Thinking" } else { "생각하는 중" }.into(),
                    })
                }
                Some("message") => {
                    action = Some(AgentAction {
                        kind: ActionKind::Replying,
                        detail: if en { "Writing a reply" } else { "답변 작성 중" }.into(),
                    })
                }
                _ => saw_item = false,
            }
        }
        if line_type != Some("response_item") || kind != Some("message") {
            continue;
        }
        let role = payload.get("role").and_then(Value::as_str);
        let first = payload
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|c| c.get("text").and_then(Value::as_str))
            .find(|t| !t.starts_with('<') && !t.starts_with("# AGENTS.md"));
        let Some(text) = first.map(|t| one_line(t, 400)).filter(|t| !t.is_empty()) else { continue };
        if role == Some("user") && user.is_none() {
            user = Some(text.clone());
        }
        if role == Some("assistant") && assistant.is_none() {
            assistant = Some(text);
        }
    }
    Rollout { status: status.unwrap_or(SessionStatus::Idle), user, assistant, action }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::super::procs::tests::proc;
    use super::super::tests::{fixture, write};
    use super::*;
    use std::collections::HashMap;

    pub fn make_db(home: &Path, rows: &[(&str, &str, &str, Option<&str>, i64, i64, &str)]) {
        let path = db_path(home);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT, created_at_ms INTEGER,
             updated_at_ms INTEGER, source TEXT, archived INTEGER NOT NULL DEFAULT 0)",
        )
        .unwrap();
        for (id, rollout, cwd, title, created, updated, source) in rows {
            conn.execute(
                "INSERT INTO threads (id, rollout_path, cwd, title, created_at_ms, updated_at_ms, source) VALUES (?,?,?,?,?,?,?)",
                rusqlite::params![id, rollout, cwd, title, created, updated, source],
            )
            .unwrap();
        }
    }

    #[test]
    fn fixture_rollout_is_idle() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("r.jsonl");
        write(&p, &fixture("codex-rollout.jsonl"));
        let r = scan(&p.to_string_lossy(), false);
        assert_eq!(r.status, SessionStatus::Idle);
        assert_eq!((r.user, r.assistant, r.action), (None, None, None));
    }

    #[test]
    fn busy_rollout_with_a_tool_call() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("r.jsonl");
        let lines = [
            json!({"type": "event_msg", "payload": {"type": "task_complete"}}),
            json!({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "<environment_context>x</environment_context>"},
                {"type": "input_text", "text": "fix\nthe test"}]}}),
            json!({"type": "event_msg", "payload": {"type": "task_started"}}),
            json!({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [
                {"type": "output_text", "text": "Looking."}]}}),
            json!({"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
                "arguments": "{\"cmd\":\"cargo test\"}"}}),
            json!({"type": "response_item", "payload": {"type": "function_call_output", "output": "ok"}}),
        ];
        write(&p, &lines.iter().map(Value::to_string).collect::<Vec<_>>().join("\n"));
        let r = scan(&p.to_string_lossy(), true);
        assert_eq!(r.status, SessionStatus::Busy);
        assert_eq!(r.user.as_deref(), Some("fix the test"));
        assert_eq!(r.assistant.as_deref(), Some("Looking."));
        let a = r.action.unwrap();
        assert_eq!(a.kind, ActionKind::Shell);
        assert_eq!(a.detail, "exec_command · cargo test");
    }

    #[test]
    fn threads_need_a_process_unless_exec_or_subagent() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let now = 1_800_000_000.0;
        let ms = |s: f64| (s * 1000.0) as i64;
        let rollout = home.join(".codex/sessions/2026/r-live.jsonl");
        write(&rollout, &fixture("codex-rollout.jsonl"));
        let rp = rollout.to_string_lossy().into_owned();
        let sub_source = r#"{"subagent":{"thread_spawn":{"parent_thread_id":"t-live","depth":1}}}"#;
        make_db(
            home,
            &[
                ("t-live", &rp, "/w", Some("Live\nthread"), ms(now - 100.0), ms(now - 10.0), "cli"),
                ("t-cwd", "/none.jsonl", "/w2", None, ms(now - 100.0), ms(now - 20.0), "vscode"),
                ("t-gone", "/none.jsonl", "/w", Some("Gone"), ms(now - 100.0), ms(now - 30.0), "cli"),
                ("t-exec", "/none.jsonl", "/w", Some(""), ms(now - 100.0), ms(now - 40.0), "exec"),
                ("t-sub", "/none.jsonl", "/w", Some("Sub"), ms(now - 100.0), ms(now - 50.0), sub_source),
                ("t-old", &rp, "/w", Some("Old"), ms(now - 9000.0), ms(now - 3000.0), "cli"),
            ],
        );
        let mut list = vec![proc(1, 0, "launchd", ""), proc(9, 1, "zsh", "-zsh"), proc(10, 9, "codex", "codex"), proc(11, 9, "codex", "codex")];
        list[3].cwd = Some("/w2".into());
        list[3].start = now - 101.0;
        let procs = Procs::from_list(list, Some(HashMap::from([(10, vec![rp.clone()])])));

        let all = load(home, &procs, now, false);
        let ids: Vec<&str> = all.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["codex-t-live", "codex-t-cwd", "codex-t-exec", "codex-t-sub"]);
        assert_eq!(all[0].name, "Live thread · cli");
        assert_eq!(all[0].pid, Some(10));
        assert!(all[0].estimated);
        assert_eq!(all[0].status, SessionStatus::Idle);
        assert_eq!(all[0].started_at, Some(now - 100.0));
        assert_eq!(all[0].updated_at, Some(now - 10.0));
        assert_eq!(all[1].pid, Some(11));
        assert_eq!(all[1].name, "t-cwd · vscode");
        assert_eq!(all[2].name, "t-exec · exec");
        assert_eq!(all[2].pid, None);
        assert_eq!(all[3].name, "Sub · subagent");
        assert_eq!(all[3].parent_id.as_deref(), Some("codex-t-live"));
    }

    #[test]
    fn missing_database_is_empty() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(load(tmp.path(), &Procs::from_list(vec![], None), 0.0, false).is_empty());
    }
}
