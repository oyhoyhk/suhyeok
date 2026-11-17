//! Antigravity CLI (`agy`) sessions (port of AntigravitySource.swift, session part). A running CLI holds
//! presence/<conversation id>.lock open; the summary table has title, folder, run status and parent; each
//! conversation's steps sit in their own SQLite file as protobuf (fields read off agy 1.4.12, no published schema).

use super::codex::{col_i64, col_text};
use super::procs::Procs;
use crate::model::{one_line, ActionKind, Agent, AgentAction, AgentSession, SessionStatus};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, Row};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub fn dir(home: &Path) -> PathBuf {
    home.join(".gemini").join("antigravity-cli")
}

pub fn summaries_path(home: &Path) -> PathBuf {
    dir(home).join("conversation_summaries.db")
}

pub fn conversation_path(home: &Path, id: &str) -> PathBuf {
    dir(home).join("conversations").join(format!("{id}.db"))
}

#[derive(Clone, Debug, PartialEq)]
pub struct Summary {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub status: String,
    pub parent: String,
    pub updated: Option<f64>,
}

pub fn load(home: &Path, procs: &Procs, en: bool) -> Vec<AgentSession> {
    let live: HashMap<String, u32> = if procs.open_files.is_some() {
        let locks = procs.antigravity_locks();
        if locks.is_empty() {
            return vec![];
        }
        locks
    } else {
        // No open-file listing on this OS: pair each agy process with the newest conversation in its folder.
        if procs.pids_named("agy").is_empty() {
            return vec![];
        }
        live_by_folder(procs, &summaries(home, 200))
    };
    // A CLI that has not been sent a message yet holds its lock but has no summary row: terminal only until then.
    summaries(home, 200)
        .into_iter()
        .filter_map(|s| {
            let pid = *live.get(&s.id)?;
            let path = conversation_path(home, &s.id);
            let turn = last_turn(&path, en);
            let name = if s.title.is_empty() { s.id.chars().take(8).collect() } else { one_line(&s.title, 60) };
            // workspace_uris can be empty (a `-i` start in a folder); the process still runs in the folder.
            let cwd = if s.cwd.is_empty() { procs.cwd(pid).unwrap_or_default() } else { s.cwd.clone() };
            // A permission prompt is still RUNNING here; the menu on screen is what tells it apart.
            let status =
                if s.status == "CASCADE_RUN_STATUS_RUNNING" { SessionStatus::Busy } else { SessionStatus::Idle };
            let mut a = AgentSession::new(format!("antigravity-{}", s.id), Agent::Antigravity, name, cwd, status);
            a.started_at = procs.start(pid);
            a.updated_at = s.updated;
            a.last_user = turn.user;
            a.last_assistant = turn.assistant;
            a.pid = Some(pid);
            a.action = turn.action;
            a.transcript_path = Some(path.to_string_lossy().into_owned());
            a.conversation_id = Some(s.id.clone());
            a.parent_id = (!s.parent.is_empty()).then(|| format!("antigravity-{}", s.parent));
            // hosted_name: phase 2.
            Some(a)
        })
        .collect()
}

/// Windows fallback for `antigravity_locks`: each agy process (newest first) takes the newest top-level conversation
/// whose folder is the process's working folder and that no other process took.
fn live_by_folder(procs: &Procs, summaries: &[Summary]) -> HashMap<String, u32> {
    let mut agy: Vec<u32> = procs.pids_named("agy");
    agy.sort_by(|a, b| procs.start(*b).unwrap_or(0.0).total_cmp(&procs.start(*a).unwrap_or(0.0)));
    let mut out = HashMap::new();
    let mut taken = HashSet::new();
    for pid in agy {
        let Some(cwd) = procs.cwd(pid) else { continue };
        if let Some(s) = summaries.iter().find(|s| s.parent.is_empty() && s.cwd == cwd && !taken.contains(&s.id)) {
            taken.insert(s.id.clone());
            out.insert(s.id.clone(), pid);
        }
    }
    out
}

/// Newest first.
pub fn summaries(home: &Path, limit: usize) -> Vec<Summary> {
    let mut out = vec![];
    let sql = format!(
        "SELECT conversation_id, title, workspace_uris, status, parent_conversation_id, last_modified_time \
         FROM conversation_summaries WHERE killed = 0 ORDER BY last_modified_time DESC LIMIT {limit}"
    );
    query(&summaries_path(home), &sql, |r| {
        let col = |i| col_text(r, i).unwrap_or_default();
        // workspace_uris: ["file:///path"]
        let uris: Option<Vec<String>> = serde_json::from_str(&col(2)).ok();
        let cwd = uris.and_then(|u| u.into_iter().next()).map(|u| file_url_path(&u)).unwrap_or_default();
        out.push(Summary { id: col(0), title: col(1), cwd, status: col(3), parent: col(4), updated: parse_utc(&col(5)) });
    });
    out
}

/// `URL(string:)?.path` for a file URL: the percent-decoded path ("/C:/x" on Windows loses its leading slash).
fn file_url_path(uri: &str) -> String {
    let Some(rest) = uri.strip_prefix("file://") else { return String::new() };
    // Skip the host part ("file://host/path"), normally empty.
    let path = match rest.find('/') {
        Some(i) => &rest[i..],
        None => return String::new(),
    };
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let decoded = percent_decode(path);
    let b = decoded.as_bytes();
    if cfg!(windows) && b.len() >= 3 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b':' {
        return decoded[1..].to_string();
    }
    if decoded.len() > 1 {
        decoded.trim_end_matches('/').to_string()
    } else {
        decoded
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// "2026-10-31 06:03:33.726135+00:00" (always UTC); the fraction is dropped.
pub(crate) fn parse_utc(s: &str) -> Option<f64> {
    let s = s.get(..19)?;
    let b = s.as_bytes();
    if b[4] != b'-' || b[7] != b'-' || b[10] != b' ' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r).filter(|t| t.bytes().all(|c| c.is_ascii_digit()))?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    Some((days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se) as f64)
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[derive(Default)]
struct Turn {
    user: Option<String>,
    assistant: Option<String>,
    action: Option<AgentAction>,
}

fn last_turn(path: &Path, en: bool) -> Turn {
    let mut t = Turn::default();
    let mut saw_step = false;
    steps(path, true, 200, |kind, payload| {
        if kind == 14 && t.user.is_none() {
            t.user = proto::strings(payload, &[19, 2]).into_iter().next().map(|s| one_line(&s, 400));
        }
        if kind == 15 {
            let text = proto::strings(payload, &[20, 1]).into_iter().find(|s| !s.is_empty());
            if t.assistant.is_none() {
                if let Some(text) = &text {
                    t.assistant = Some(one_line(text, 400));
                }
            }
            if !saw_step {
                t.action = if let Some(call) = proto::messages(payload, &[20, 7]).last() {
                    Some(action(call))
                } else if text.is_some() {
                    Some(AgentAction { kind: ActionKind::Replying, detail: if en { "Writing a reply" } else { "답변 작성 중" }.into() })
                } else {
                    Some(AgentAction { kind: ActionKind::Thinking, detail: if en { "Thinking" } else { "생각하는 중" }.into() })
                };
            }
            saw_step = true;
        }
    });
    t
}

/// A tool call: name in field 2, JSON arguments in field 3.
pub fn action(call: &[u8]) -> AgentAction {
    let args = proto::strings(call, &[3]).into_iter().next().unwrap_or_default();
    let input = serde_json::from_str::<Value>(&args).ok().filter(Value::is_object).unwrap_or(json!({"cmd": args}));
    AgentAction::tool(&proto::strings(call, &[2]).into_iter().next().unwrap_or_default(), &input)
}

/// Each step's type and protobuf payload, oldest or newest first.
pub fn steps(path: &Path, newest_first: bool, limit: usize, mut each: impl FnMut(i64, &[u8])) {
    let sql = format!(
        "SELECT step_type, step_payload FROM steps ORDER BY idx {} LIMIT {limit}",
        if newest_first { "DESC" } else { "ASC" }
    );
    query(path, &sql, |r| {
        let payload: &[u8] = match r.get_ref(1) {
            Ok(ValueRef::Blob(b)) | Ok(ValueRef::Text(b)) => b,
            _ => &[],
        };
        each(col_i64(r, 0), payload);
    });
}

/// Runs `sql` read-only on an agy database. These are WAL databases; agy removes -wal and -shm once idle, and a
/// read-only connection cannot open a WAL database without -shm. With no -wal the main file holds everything, so it
/// is read as immutable then.
pub fn query(path: &Path, sql: &str, mut row: impl FnMut(&Row)) {
    if !path.is_file() {
        return;
    }
    let mut wal = path.as_os_str().to_owned();
    wal.push("-wal");
    let uri = file_uri(path) + if Path::new(&wal).exists() { "?mode=ro" } else { "?immutable=1" };
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let Ok(conn) = Connection::open_with_flags(&uri, flags) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(200)); // the CLI writes these files while it runs
    let Ok(mut stmt) = conn.prepare(sql) else { return };
    let Ok(mut rows) = stmt.query([]) else { return };
    while let Ok(Some(r)) = rows.next() {
        row(r);
    }
}

/// `file:///abs/path` with reserved characters percent-encoded; Windows drive paths become `file:///C:/…`.
fn file_uri(path: &Path) -> String {
    let p = path.to_string_lossy().replace('\\', "/");
    let p = if p.starts_with('/') { p } else { format!("/{p}") };
    let mut out = String::from("file://");
    for b in p.bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~:".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Just enough protobuf to pull length-delimited fields out by number, following a path of nested messages.
pub mod proto {
    pub fn messages<'a>(b: &'a [u8], path: &[u64]) -> Vec<&'a [u8]> {
        path.iter().fold(vec![b], |level, n| level.into_iter().flat_map(|m| fields(m, *n)).collect())
    }

    pub fn strings(b: &[u8], path: &[u64]) -> Vec<String> {
        messages(b, path).into_iter().filter_map(|m| std::str::from_utf8(m).ok().map(String::from)).collect()
    }

    /// The length-delimited fields numbered `number` at the top level of `b`; stops at the first malformed byte.
    fn fields(b: &[u8], number: u64) -> Vec<&[u8]> {
        let mut out = vec![];
        let mut i = 0usize;
        while i < b.len() {
            let Some(key) = varint(b, &mut i) else { break };
            match key & 7 {
                0 => {
                    if varint(b, &mut i).is_none() {
                        return out;
                    }
                }
                1 => i += 8,
                5 => i += 4,
                2 => {
                    let Some(n) = varint(b, &mut i) else { return out };
                    if n > (b.len() - i) as u64 {
                        return out;
                    }
                    let n = n as usize;
                    if key >> 3 == number {
                        out.push(&b[i..i + n]);
                    }
                    i += n;
                }
                _ => return out,
            }
        }
        out
    }

    fn varint(b: &[u8], i: &mut usize) -> Option<u64> {
        let (mut r, mut shift) = (0u64, 0u32);
        while *i < b.len() && shift < 64 {
            let c = b[*i];
            *i += 1;
            r |= ((c & 0x7f) as u64) << shift;
            if c < 0x80 {
                return Some(r);
            }
            shift += 7;
        }
        None
    }

    #[cfg(test)]
    pub fn field(number: u64, body: &[u8]) -> Vec<u8> {
        fn put(mut v: u64, out: &mut Vec<u8>) {
            while v >= 0x80 {
                out.push((v as u8) | 0x80);
                v >>= 7;
            }
            out.push(v as u8);
        }
        let mut out = vec![];
        put(number << 3 | 2, &mut out);
        put(body.len() as u64, &mut out);
        out.extend_from_slice(body);
        out
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::super::procs::tests::proc;
    use super::proto::field;
    use super::*;

    pub fn make_summaries(home: &Path, rows: &[(&str, &str, &str, &str, &str, &str)]) {
        let path = summaries_path(home);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, workspace_uris TEXT, status TEXT,
             parent_conversation_id TEXT, last_modified_time TEXT, killed INTEGER DEFAULT 0)",
        )
        .unwrap();
        for r in rows {
            conn.execute(
                "INSERT INTO conversation_summaries (conversation_id, title, workspace_uris, status, parent_conversation_id,
                 last_modified_time) VALUES (?,?,?,?,?,?)",
                rusqlite::params![r.0, r.1, r.2, r.3, r.4, r.5],
            )
            .unwrap();
        }
    }

    fn make_conversation(home: &Path, id: &str) {
        let path = conversation_path(home, id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE steps (idx INTEGER, step_type INTEGER, step_payload BLOB)").unwrap();
        let user = field(19, &field(2, "list\nfiles".as_bytes()));
        let call = [field(2, b"run_command"), field(3, br#"{"CommandLine":"ls -la"}"#)].concat();
        let reply = field(20, &[field(1, "Here they are".as_bytes()), field(7, &call)].concat());
        // A varint and a fixed64 field before the wanted one must be skipped.
        let noisy = [vec![0x08, 0x96, 0x01, 0x11, 1, 2, 3, 4, 5, 6, 7, 8], reply].concat();
        for (i, (t, p)) in [(14, user), (15, noisy)].into_iter().enumerate() {
            conn.execute("INSERT INTO steps VALUES (?,?,?)", rusqlite::params![i as i64, t, p]).unwrap();
        }
    }

    #[test]
    fn utc_dates() {
        assert_eq!(parse_utc("1970-01-01 00:00:00"), Some(0.0));
        assert_eq!(parse_utc("2026-10-31 06:03:33.726135+00:00"), Some(1_793_426_613.0));
        assert_eq!(parse_utc("2026-10-31"), None);
        assert_eq!(parse_utc("garbage-in-here-xxxx"), None);
    }

    #[test]
    fn file_urls() {
        assert_eq!(file_url_path("file:///Users/a/my%20proj"), "/Users/a/my proj");
        assert_eq!(file_url_path("file:///Users/a/%ED%95%9C"), "/Users/a/한");
        assert_eq!(file_url_path("not a url"), "");
    }

    #[test]
    fn live_conversation_from_lock_and_steps() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        make_summaries(
            home,
            &[
                ("conv-1", "Tidy\nthe repo", r#"["file:///w/repo"]"#, "CASCADE_RUN_STATUS_RUNNING", "", "2026-10-31 06:03:33.7+00:00"),
                ("conv-2", "", "[]", "CASCADE_RUN_STATUS_IDLE", "conv-1", "2026-10-31 06:00:00+00:00"),
                ("conv-3", "Not running", r#"["file:///w/repo"]"#, "CASCADE_RUN_STATUS_IDLE", "", "2026-10-30 06:00:00+00:00"),
            ],
        );
        make_conversation(home, "conv-1");
        let lock = |id: &str| format!("{}/.gemini/antigravity-cli/presence/{id}.lock", home.to_string_lossy());
        let mut list = vec![proc(1, 0, "launchd", ""), proc(20, 1, "agy", "agy"), proc(21, 1, "agy", "agy")];
        list[2].cwd = Some("/w/other".into());
        let procs = Procs::from_list(
            list,
            Some(HashMap::from([(20, vec![lock("conv-1")]), (21, vec![lock("conv-2"), "/x.lock".into()])])),
        );
        let all = load(home, &procs, true);
        assert_eq!(all.len(), 2);
        let a = &all[0];
        assert_eq!(a.id, "antigravity-conv-1");
        assert_eq!(a.name, "Tidy the repo");
        assert_eq!(a.cwd, "/w/repo");
        assert_eq!(a.status, SessionStatus::Busy);
        assert_eq!(a.updated_at, Some(1_793_426_613.0));
        assert_eq!(a.started_at, Some(1000.0));
        assert_eq!(a.last_user.as_deref(), Some("list files"));
        assert_eq!(a.last_assistant.as_deref(), Some("Here they are"));
        assert_eq!(a.action.as_ref().unwrap().detail, "run_command · ls -la");
        assert_eq!(a.action.as_ref().unwrap().kind, ActionKind::Shell);
        let b = &all[1];
        assert_eq!(b.name, "conv-2");
        assert_eq!(b.cwd, "/w/other"); // empty workspace_uris: the process's folder
        assert_eq!(b.parent_id.as_deref(), Some("antigravity-conv-1"));
        assert_eq!(b.status, SessionStatus::Idle);
        assert_eq!(b.action, None);
    }

    #[test]
    fn folder_fallback_without_open_files() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        make_summaries(
            home,
            &[
                ("new", "New", r#"["file:///w/repo"]"#, "", "", "2026-10-31 06:00:00+00:00"),
                ("old", "Old", r#"["file:///w/repo"]"#, "", "", "2026-10-30 06:00:00+00:00"),
            ],
        );
        let mut list = vec![proc(1, 0, "launchd", ""), proc(20, 1, "agy", "agy")];
        list[1].cwd = Some("/w/repo".into());
        let all = load(home, &Procs::from_list(list, None), false);
        assert_eq!(all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["antigravity-new"]);
    }

    #[test]
    fn no_agy_running_is_empty() {
        let tmp = tempfile::tempdir().unwrap();
        make_summaries(tmp.path(), &[("x", "X", "[]", "", "", "2026-10-31 06:00:00+00:00")]);
        assert!(load(tmp.path(), &Procs::from_list(vec![], Some(HashMap::new())), false).is_empty());
    }
}
