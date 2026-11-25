//! Past conversations that can be resumed (port of RecentSource in Workspace.swift): Claude transcripts, Codex threads
//! and Antigravity conversations updated within the last `days`, newest first, without the live ones.

use super::codex::{col_i64, col_text};
use super::{antigravity, claude, codex, mtime_and_size};
use crate::model::{jsonl_tail, one_line, Agent, AgentSession};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

#[derive(Clone, Debug, PartialEq)]
pub struct RecentConversation {
    /// Claude session id, Codex thread id or Antigravity conversation id.
    pub id: String,
    pub agent: Agent,
    pub title: String,
    pub cwd: String,
    /// Unix seconds.
    pub updated: f64,
}

/// Same defaults as the Mac: 7 days, 30 entries.
pub const DAYS: f64 = 7.0;
pub const LIMIT: usize = 30;

/// Ids of conversations already running, as the Mac excludes them (`conversationId ?? id` without "codex-").
pub fn live_ids(sessions: &[AgentSession]) -> HashSet<String> {
    sessions.iter().map(|s| s.conversation_id.clone().unwrap_or_else(|| s.id.replace("codex-", ""))).collect()
}

pub fn load(live: &HashSet<String>, en: bool) -> Vec<RecentConversation> {
    load_in(Path::new(&crate::model::home()), live, crate::model::now(), DAYS, LIMIT, en)
}

pub fn load_in(home: &Path, live: &HashSet<String>, now: f64, days: f64, limit: usize, en: bool) -> Vec<RecentConversation> {
    let since = now - days * 86400.0;
    let mut all: Vec<RecentConversation> = claude_recent(home, since)
        .into_iter()
        .chain(codex_recent(home, since, en))
        .chain(antigravity_recent(home, since, en))
        .filter(|r| !live.contains(&r.id))
        .collect();
    all.sort_by(|a, b| b.updated.total_cmp(&a.updated));
    all.truncate(limit);
    all
}

/// Folders seen in live and recent sessions, for the new-session picker (Swift `knownFolders`; hosted terminals'
/// folders join in phase 2).
pub fn known_folders(sessions: &[AgentSession], recent: &[RecentConversation]) -> Vec<String> {
    let mut seen = HashSet::new();
    sessions.iter().map(|s| &s.cwd).chain(recent.iter().map(|r| &r.cwd)).filter(|c| seen.insert(c.as_str())).cloned().collect()
}

/// Title and cwd per log, kept while the file's modification time is unchanged.
static PARSED: LazyLock<Mutex<HashMap<PathBuf, (f64, Option<String>, Option<String>)>>> = LazyLock::new(Default::default);

fn claude_recent(home: &Path, since: f64) -> Vec<RecentConversation> {
    let mut files: Vec<(PathBuf, f64)> = vec![];
    let Ok(projects) = std::fs::read_dir(claude::projects_dir(home)) else { return vec![] };
    for dir in projects.filter_map(|e| e.ok()) {
        let Ok(logs) = std::fs::read_dir(dir.path()) else { continue };
        for log in logs.filter_map(|e| e.ok()) {
            let path = log.path();
            if path.extension().is_none_or(|x| x != "jsonl") {
                continue;
            }
            if let Some((m, _)) = mtime_and_size(&path) {
                if m > since {
                    files.push((path, m));
                }
            }
        }
    }
    files.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut cache = PARSED.lock().unwrap();
    files
        .into_iter()
        .take(60)
        .filter_map(|(path, modified)| {
            let (title, cwd) = match cache.get(&path) {
                Some((m, t, c)) if *m == modified => (t.clone(), c.clone()),
                _ => {
                    let (mut title, mut cwd) = (None, None);
                    for line in jsonl_tail(&path.to_string_lossy(), 256 * 1024).iter().rev() {
                        if title.is_none() && line.get("type").and_then(Value::as_str) == Some("ai-title") {
                            title = line.get("aiTitle").and_then(Value::as_str).map(String::from);
                        }
                        if cwd.is_none() {
                            cwd = line.get("cwd").and_then(Value::as_str).map(String::from);
                        }
                        if title.is_some() && cwd.is_some() {
                            break;
                        }
                    }
                    cache.insert(path.clone(), (modified, title.clone(), cwd.clone()));
                    (title, cwd)
                }
            };
            // Headless runs (claude -p) have no title and are not worth resuming by hand.
            let (title, cwd) = (title?, cwd?);
            let id = path.file_stem()?.to_string_lossy().into_owned();
            Some(RecentConversation { id, agent: Agent::Claude, title, cwd, updated: modified })
        })
        .collect()
}

fn codex_recent(home: &Path, since: f64, en: bool) -> Vec<RecentConversation> {
    let Some(conn) = codex::open(&codex::db_path(home)) else { return vec![] };
    let sql = "SELECT id, cwd, title, updated_at_ms FROM threads \
               WHERE archived = 0 AND source != 'exec' AND updated_at_ms > ? ORDER BY updated_at_ms DESC LIMIT 30";
    let Ok(mut stmt) = conn.prepare(sql) else { return vec![] };
    let Ok(rows) = stmt.query_map([(since * 1000.0) as i64], |r| {
        let title = col_text(r, 2).unwrap_or_default();
        Ok(RecentConversation {
            id: col_text(r, 0).unwrap_or_default(),
            agent: Agent::Codex,
            cwd: col_text(r, 1).unwrap_or_default(),
            title: if title.is_empty() { if en { "Codex chat" } else { "Codex 대화" }.into() } else { one_line(&title, 60) },
            updated: col_i64(r, 3) as f64 / 1000.0,
        })
    }) else {
        return vec![];
    };
    rows.filter_map(Result::ok).collect()
}

/// Subagent conversations are left out; so are rows without a folder (the desktop app's, imported into the table).
fn antigravity_recent(home: &Path, since: f64, en: bool) -> Vec<RecentConversation> {
    antigravity::summaries(home, 200)
        .into_iter()
        .filter_map(|s| {
            let updated = s.updated?;
            if updated <= since || s.cwd.is_empty() || !s.parent.is_empty() {
                return None;
            }
            let title = if s.title.is_empty() {
                if en { "Antigravity chat" } else { "Antigravity 대화" }.into()
            } else {
                one_line(&s.title, 60)
            };
            Some(RecentConversation { id: s.id, agent: Agent::Antigravity, title, cwd: s.cwd, updated })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::antigravity::tests::make_summaries;
    use super::super::codex::tests::make_db;
    use super::super::tests::write;
    use super::*;
    use crate::model::SessionStatus;
    use serde_json::json;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn log(home: &Path, id: &str, title: Option<&str>, age_days: u64) {
        let path = claude::projects_dir(home).join("-w").join(format!("{id}.jsonl"));
        let mut lines = vec![json!({"type": "user", "cwd": "/w/old", "message": {"content": "hi"}}).to_string()];
        if let Some(t) = title {
            lines.push(json!({"type": "ai-title", "aiTitle": t}).to_string());
        }
        lines.push(json!({"type": "assistant", "cwd": format!("/w/{id}"), "message": {"content": []}}).to_string());
        write(&path, &lines.join("\n"));
        let t = SystemTime::now() - Duration::from_secs(age_days * 86400 + 60);
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(t).unwrap();
    }

    #[test]
    fn recent_across_agents() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
        log(home, "c-titled", Some("Plan the port"), 1);
        log(home, "c-headless", None, 1);
        log(home, "c-old", Some("Too old"), 8);
        log(home, "c-live", Some("Running now"), 0);
        write(&claude::projects_dir(home).join("stray.txt"), "x");
        let ms = |s: f64| (s * 1000.0) as i64;
        make_db(
            home,
            &[
                ("t-1", "", "/w/codex", Some(""), 0, ms(now - 2.0 * 86400.0), "cli"),
                ("t-exec", "", "/w/codex", Some("Exec"), 0, ms(now - 3600.0), "exec"),
            ],
        );
        make_summaries(
            home,
            &[
                ("a-1", "Agy\nwork", r#"["file:///w/agy"]"#, "", "", "2000-01-01 00:00:00+00:00"),
                ("a-2", "", r#"["file:///w/agy"]"#, "", "", &fmt_utc(now - 3.0 * 86400.0)),
                ("a-sub", "", r#"["file:///w/agy"]"#, "", "a-2", &fmt_utc(now - 3600.0)),
                ("a-nofolder", "", "[]", "", "", &fmt_utc(now - 3600.0)),
            ],
        );
        let live = HashSet::from(["c-live".to_string()]);
        let r = load_in(home, &live, now, DAYS, LIMIT, true);
        let got: Vec<(&str, Agent, &str, &str)> =
            r.iter().map(|r| (r.id.as_str(), r.agent, r.title.as_str(), r.cwd.as_str())).collect();
        assert_eq!(
            got,
            [
                ("c-titled", Agent::Claude, "Plan the port", "/w/c-titled"),
                ("t-1", Agent::Codex, "Codex chat", "/w/codex"),
                ("a-2", Agent::Antigravity, "Antigravity chat", "/w/agy"),
            ]
        );
        assert!((r[1].updated - (now - 2.0 * 86400.0)).abs() < 0.01);
        assert_eq!(load_in(home, &live, now, DAYS, 2, false).len(), 2);
        assert_eq!(load_in(home, &live, now, DAYS, 2, false)[1].title, "Codex 대화");

        let mut s = AgentSession::new("codex-t-9".into(), Agent::Codex, "x".into(), "/w/codex".into(), SessionStatus::Idle);
        assert_eq!(live_ids(std::slice::from_ref(&s)), HashSet::from(["t-9".to_string()]));
        s.conversation_id = Some("t-9b".into());
        assert_eq!(live_ids(std::slice::from_ref(&s)), HashSet::from(["t-9b".to_string()]));
        assert_eq!(known_folders(&[s], &r), ["/w/codex", "/w/c-titled", "/w/agy"]);
    }

    /// Unix seconds as "YYYY-MM-DD HH:MM:SS+00:00".
    fn fmt_utc(t: f64) -> String {
        let secs = t as i64;
        let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
        // Civil from days (Hinnant).
        let z = days + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
        format!("{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}+00:00", rem / 3600, rem % 3600 / 60, rem % 60)
    }
}
