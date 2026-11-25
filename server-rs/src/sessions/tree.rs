//! Nests a session under the live session whose process launched it (`claude -p` or `codex exec` run from an
//! agent's shell, whichever model the child is). Port of SessionTree.link; the process-table helpers it uses live in
//! procs.rs.

use super::procs::Procs;
use crate::model::{Agent, AgentSession};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// Where child -> parent links are kept between runs, so a finished `codex exec` thread stays under its parent after a
/// restart. Separate from the Mac app's `~/Library/Application Support/Suhyeok/session-links.json`, so this server
/// running on a Mac never rewrites the Swift app's file.
pub fn links_path() -> Option<PathBuf> {
    dirs::data_dir().map(|d| d.join("suhyeok-server").join("session-links.json"))
}

pub fn read_links(path: &std::path::Path) -> HashMap<String, String> {
    std::fs::read(path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn write_links(path: &std::path::Path, links: &HashMap<String, String>) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(d) = serde_json::to_vec(links) {
        let _ = std::fs::write(path, d);
    }
}

/// Sets `parent_id` on each session; returns the sessions and the child -> parent links now in force. `known` holds the
/// links from earlier runs; one is kept, after the child's process exits, as long as the parent is still listed.
pub fn link(sessions: Vec<AgentSession>, procs: &Procs, known: &HashMap<String, String>) -> (Vec<AgentSession>, HashMap<String, String>) {
    let ids: HashSet<String> = sessions.iter().map(|s| s.id.clone()).collect();
    let mut live: HashMap<u32, String> = HashMap::new();
    for s in &sessions {
        if let Some(pid) = s.pid {
            live.entry(pid).or_insert_with(|| s.id.clone());
        }
    }
    // Claude conversations, for the scratchpad rule below: (session id, conversation id).
    let claude: Vec<(String, String)> = sessions
        .iter()
        .filter(|o| o.agent == Agent::Claude)
        .filter_map(|o| o.conversation_id.clone().map(|c| (o.id.clone(), c)))
        .collect();
    let linked: Vec<AgentSession> = sessions
        .into_iter()
        .map(|mut s| {
            if s.parent_id.is_none() {
                if let Some(pid) = s.pid {
                    let mut p = procs.parent_pid(pid);
                    for _ in 0..32 {
                        if p <= 1 {
                            break;
                        }
                        // The child inherits the parent's terminal; the hosted pane belongs to the parent.
                        if let Some(owner) = live.get(&p).filter(|o| **o != s.id) {
                            s.parent_id = Some(owner.clone());
                            s.hosted_name = None;
                            break;
                        }
                        p = procs.parent_pid(p);
                    }
                }
            }
            if s.parent_id.is_none() {
                if let Some(owner) = known.get(&s.id).filter(|o| ids.contains(*o)) {
                    s.parent_id = Some(owner.clone());
                    s.hosted_name = None;
                }
            }
            // (Swift's paneOwner rule, for shells detached from a hosted tmux pane, needs hosted terminals: phase 2.)
            // No process left to trace: a run inside a Claude session's scratchpad (…/<sessionId>/scratchpad) is that
            // session's.
            if s.parent_id.is_none() {
                if let Some((owner, _)) = claude.iter().find(|(id, conv)| {
                    *id != s.id && (s.cwd.contains(&format!("/{conv}/")) || s.cwd.contains(&format!("\\{conv}\\")))
                }) {
                    s.parent_id = Some(owner.clone());
                    s.hosted_name = None;
                }
            }
            // A parent that is no longer listed would hide the child entirely.
            if s.parent_id.as_ref().is_some_and(|o| !ids.contains(o)) {
                s.parent_id = None;
            }
            s
        })
        .collect();
    let mut now: HashMap<String, String> = HashMap::new();
    for s in &linked {
        if let Some(p) = &s.parent_id {
            now.entry(s.id.clone()).or_insert_with(|| p.clone());
        }
    }
    (linked, now)
}

#[cfg(test)]
mod tests {
    use super::super::procs::tests::proc;
    use super::*;
    use crate::model::SessionStatus;

    fn session(id: &str, agent: Agent, pid: Option<u32>, cwd: &str) -> AgentSession {
        let mut s = AgentSession::new(id.into(), agent, id.into(), cwd.into(), SessionStatus::Idle);
        s.pid = pid;
        s
    }

    #[test]
    fn child_process_nests_under_its_launcher() {
        let procs = Procs::from_list(
            vec![
                proc(1, 0, "launchd", ""),
                proc(100, 1, "claude", "claude"),
                proc(101, 100, "zsh", "zsh -c codex exec"),
                proc(102, 101, "codex", "codex exec"),
                proc(200, 1, "claude", "claude"),
            ],
            None,
        );
        let mut parent = session("claude-100", Agent::Claude, Some(100), "/w");
        parent.conversation_id = Some("conv-a".into());
        let sessions = vec![
            parent,
            session("codex-x", Agent::Codex, Some(102), "/w"),
            session("claude-200", Agent::Claude, Some(200), "/w"),
            session("codex-done", Agent::Codex, None, "/w"),
            session("codex-scratch", Agent::Codex, None, "/tmp/claude-501/-Users-a/conv-a/scratchpad"),
            session("codex-orphan", Agent::Codex, None, "/w"),
        ];
        let known = HashMap::from([
            ("codex-done".to_string(), "claude-200".to_string()),
            ("codex-orphan".to_string(), "claude-gone".to_string()),
        ]);
        let (linked, now) = link(sessions, &procs, &known);
        let parent_of = |id: &str| linked.iter().find(|s| s.id == id).unwrap().parent_id.clone();
        assert_eq!(parent_of("claude-100"), None);
        assert_eq!(parent_of("codex-x").as_deref(), Some("claude-100"));
        assert_eq!(parent_of("claude-200"), None);
        assert_eq!(parent_of("codex-done").as_deref(), Some("claude-200"));
        assert_eq!(parent_of("codex-scratch").as_deref(), Some("claude-100"));
        assert_eq!(parent_of("codex-orphan"), None);
        assert_eq!(now.len(), 3);
    }

    #[test]
    fn explicit_parent_that_is_not_listed_is_dropped() {
        let mut s = session("codex-sub", Agent::Codex, None, "/w");
        s.parent_id = Some("codex-missing".into());
        let (linked, now) = link(vec![s], &Procs::from_list(vec![], None), &HashMap::new());
        assert_eq!(linked[0].parent_id, None);
        assert!(now.is_empty());
    }

    #[test]
    fn links_round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("d").join("links.json");
        let links = HashMap::from([("a".to_string(), "b".to_string())]);
        write_links(&p, &links);
        assert_eq!(read_links(&p), links);
    }
}
