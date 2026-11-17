//! Live agent sessions read from the agents' own files: a port of ClaudeSource, CodexSource, AntigravitySource,
//! BackgroundShells, SessionTree and the merge in SessionStore.refresh() (App.swift).
//! Terminals this server hosts (Swift `hostedName`, tmux) come in phase 2: `hosted_name` stays None for now.

pub mod antigravity;
pub mod claude;
pub mod codex;
pub mod procs;
pub mod recent;
pub mod shells;
pub mod tree;
pub mod worktree;

use crate::model::AgentSession;
use procs::Procs;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, Mutex};

/// Links from earlier runs (None until read from `tree::links_path()`).
static KNOWN_LINKS: LazyLock<Mutex<Option<HashMap<String, String>>>> = LazyLock::new(Default::default);

/// Every live session on this machine, working first, then newest first (SessionStore.refresh).
pub fn load_all(en: bool) -> Vec<AgentSession> {
    let procs = Procs::snapshot();
    let path = tree::links_path();
    let mut known = KNOWN_LINKS.lock().unwrap();
    let links = known.get_or_insert_with(|| path.as_deref().map(tree::read_links).unwrap_or_default());
    let (all, now_links) = collect(Path::new(&crate::model::home()), &procs, crate::model::now(), en, links);
    if now_links != *links {
        if let Some(p) = &path {
            tree::write_links(p, &now_links);
        }
        *links = now_links;
    }
    all
}

/// `load_all` with the home folder, process table, clock and earlier links given; returns the links now in force.
pub fn collect(
    home: &Path,
    procs: &Procs,
    now: f64,
    en: bool,
    known: &HashMap<String, String>,
) -> (Vec<AgentSession>, HashMap<String, String>) {
    let mut found = claude::load(home, procs, en);
    found.extend(codex::load(home, procs, now, en));
    found.extend(antigravity::load(home, procs, en));
    let (mut all, links) = tree::link(found, procs, known);
    all.sort_by(|a, b| {
        let (ra, rb) = (a.activity_at(now).sort_rank(), b.activity_at(now).sort_rank());
        ra.cmp(&rb).then_with(|| b.updated_at.unwrap_or(f64::MIN).total_cmp(&a.updated_at.unwrap_or(f64::MIN)))
    });
    (all, links)
}

/// Modification time (Unix seconds) and size of a file.
pub(crate) fn mtime_and_size(path: &Path) -> Option<(f64, u64)> {
    let m = std::fs::metadata(path).ok()?;
    let t = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
    Some((t, m.len()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::procs::tests::proc;
    use super::*;
    use crate::model::{Activity, SessionStatus};
    use serde_json::json;

    pub fn fixture(name: &str) -> String {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../Tests/AgentDeckTests/Fixtures");
        std::fs::read_to_string(dir.join(name)).unwrap()
    }

    pub fn write(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }

    #[test]
    fn merged_and_ordered_like_the_mac() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let now = 1_800_000_000.0;
        let reg = |pid: u32, status: &str, updated_s: f64| {
            let obj = json!({"pid": pid, "sessionId": format!("s{pid}"), "cwd": "/w", "status": status,
                "statusUpdatedAt": updated_s * 1000.0, "name": format!("n{pid}")});
            write(&claude::sessions_dir(home).join(format!("{pid}.json")), &obj.to_string());
        };
        reg(10, "idle", now - 3600.0); // resting
        reg(11, "idle", now - 60.0); // waiting (idle under 10 min)
        reg(12, "busy", now - 7200.0); // working, older
        reg(13, "busy", now - 5.0); // working, newer
        reg(14, "waiting", now - 30.0); // waiting, newer
        let ms = |s: f64| (s * 1000.0) as i64;
        super::codex::tests::make_db(home, &[("t", "", "/w", Some("exec run"), ms(now - 50.0), ms(now - 40.0), "exec")]);
        let list = vec![
            proc(1, 0, "launchd", ""),
            proc(10, 1, "claude", "claude"),
            proc(11, 1, "claude", "claude"),
            proc(12, 1, "claude", "claude"),
            proc(13, 1, "claude", "claude"),
            proc(14, 1, "claude", "claude"),
        ];
        let procs = Procs::from_list(list, Some(HashMap::new()));
        let known = HashMap::from([("codex-t".to_string(), "claude-13".to_string())]);
        let (all, links) = collect(home, &procs, now, false, &known);
        let ids: Vec<&str> = all.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["claude-13", "claude-12", "claude-14", "codex-t", "claude-11", "claude-10"]);
        assert_eq!(all[0].activity_at(now), Activity::Working);
        assert_eq!(all[5].activity_at(now), Activity::Resting);
        assert_eq!(all[3].status, SessionStatus::Idle);
        assert_eq!(all[3].parent_id.as_deref(), Some("claude-13"));
        assert_eq!(links, known);
    }

    /// Prints what this machine shows. Run with `cargo test --lib sessions -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_machine() {
        let all = load_all(false);
        println!("{} live sessions", all.len());
        for s in &all {
            println!(
                "{:<48} {:<8} {:<8} {:<8} parent={:<44} subs={} project={} name={:?} action={:?}",
                s.id,
                s.status.raw(),
                s.activity().code(),
                s.pid.map(|p| p.to_string()).unwrap_or_default(),
                s.parent_id.clone().unwrap_or_default(),
                s.subagents.len(),
                s.project(),
                s.name,
                s.action.as_ref().map(|a| a.detail.clone()),
            );
        }
        let recent = recent::load(&recent::live_ids(&all), false);
        println!("{} recent conversations", recent.len());
        for r in recent.iter().take(10) {
            println!("{:<40} {:<12} {:.0} {} {:?}", r.id, r.agent.raw(), r.updated, r.cwd, r.title);
        }
        println!("{} known folders", recent::known_folders(&all, &recent).len());
    }
}
