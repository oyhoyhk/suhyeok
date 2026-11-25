//! 수혁's agent terminals, written down while they run so the ones a server restart closed can be opened again with
//! the same conversation (SessionRestore.swift + `SessionStore.recordOpenSessions` / `reopen` in App.swift).
//! The hosted terminals end with the server process; the conversations stay on disk and `--resume` brings them back.

use super::host::{Host, Hosted};
use super::launch::Launch;
use crate::characters::Character;
use crate::model::{Agent, AgentSession};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// One open conversation. Field names match the Mac's open-sessions.json; `character` and `name` are added so a
/// reopened agent keeps its face and its terminal name (links and pinned characters keyed by name stay valid).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Entry {
    /// `Agent::raw()`.
    pub agent: String,
    pub cwd: String,
    pub conversation: String,
    pub title: String,
    /// The conversation log (Claude jsonl, Codex rollout, Antigravity step db): Codex and Antigravity keep the model
    /// it last ran with there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub character: Option<String>,
    /// Terminal name it ran in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// `<data dir>/open-sessions.json`.
pub fn default_path(data_dir: &Path) -> PathBuf {
    data_dir.join("open-sessions.json")
}

pub fn load(path: &Path) -> Vec<Entry> {
    std::fs::read(path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

/// Writes the record atomically (temp file + rename), creating the folder.
pub fn save(path: &Path, entries: &[Entry]) -> bool {
    let Ok(data) = serde_json::to_vec(entries) else { return false };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, data).is_ok() && std::fs::rename(&tmp, path).is_ok()
}

/// Agent terminals by the conversation each one has open. A session belongs to a terminal when the sessions layer
/// set its `hosted_name` (`Host::owner_of`). One entry per conversation: two terminals can have the same one open,
/// and reopening both would fork it. No log yet = nothing said yet = nothing to resume.
pub fn live(hosted: &[Hosted], sessions: &[AgentSession]) -> Vec<Entry> {
    let mut seen = HashSet::new();
    hosted
        .iter()
        .filter_map(|h| {
            let agent = h.agent?;
            let s = sessions.iter().find(|s| s.agent == agent && s.hosted_name.as_deref() == Some(h.name.as_str()))?;
            let conversation = s.conversation_id.clone()?;
            let log = s.transcript_path.clone().filter(|p| Path::new(p).exists())?;
            Some(Entry {
                agent: agent.raw().into(),
                cwd: h.cwd.clone(),
                conversation,
                title: s.name.clone(),
                log: Some(log),
                character: h.character.clone(),
                name: Some(h.name.clone()),
            })
        })
        .filter(|e| seen.insert(e.conversation.clone()))
        .collect()
}

/// What to write down: the live sessions, plus closed ones still waiting to be reopened.
pub fn merged(live: Vec<Entry>, pending: &[Entry]) -> Vec<Entry> {
    let mut out = live;
    let extra: Vec<Entry> = pending.iter().filter(|p| !out.iter().any(|l| l.conversation == p.conversation)).cloned().collect();
    out.extend(extra);
    out
}

/// The model and effort the conversation last ran with; without them a resumed agent starts on the defaults.
/// Claude: the status line copy kept per conversation (`usage::status_dir()`). Codex: the newest turn in its
/// rollout. Antigravity: the model name in its step db (it carries the effort, "Gemini 3.8 Flash (High)").
pub fn resume_flags(e: &Entry, status_dir: &Path) -> Vec<String> {
    let s = |x: &str| x.to_string();
    match Agent::from_raw(&e.agent) {
        Some(Agent::Claude) => {
            let Some(json) = std::fs::read(status_dir.join(format!("{}.json", e.conversation)))
                .ok()
                .and_then(|d| serde_json::from_slice::<Value>(&d).ok())
            else {
                return vec![];
            };
            let mut flags = vec![];
            if let Some(id) = json.pointer("/model/id").and_then(Value::as_str).filter(|v| !v.is_empty()) {
                flags.extend([s("--model"), s(id)]);
            }
            if let Some(level) = json.pointer("/effort/level").and_then(Value::as_str).filter(|v| !v.is_empty()) {
                flags.extend([s("--effort"), s(level)]);
            }
            flags
        }
        Some(Agent::Codex) => {
            let Some(info) = e.log.as_deref().and_then(|l| crate::usage::codex(l, false)) else { return vec![] };
            let Some(model) = info.model else { return vec![] };
            let mut flags = vec![s("-m"), model];
            if let Some(effort) = info.effort {
                flags.extend([s("-c"), format!("model_reasoning_effort={}", super::launch::toml_string(&effort))]);
            }
            flags
        }
        Some(Agent::Antigravity) => e.log.as_deref().and_then(antigravity_model).map(|m| vec![s("--model"), m]).unwrap_or_default(),
        None => vec![],
    }
}

/// AntigravitySource.model: the newest generation's model name.
fn antigravity_model(path: &str) -> Option<String> {
    use crate::sessions::antigravity::{proto, query};
    let mut model = None;
    query(Path::new(path), "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 1", |row| {
        if let Ok(blob) = row.get::<_, Vec<u8>>(0) {
            model = proto::strings(&blob, &[1, 21]).into_iter().next();
        }
    });
    model
}

/// The record and the conversations a restart closed. Open it once at start, before anything rewrites the file:
/// the server has no terminals yet, so everything in the record was closed by the restart.
pub struct Restore {
    path: PathBuf,
    closed: Vec<Entry>,
    last: Option<Vec<Entry>>,
}

impl Restore {
    pub fn open(path: PathBuf) -> Restore {
        let closed = load(&path).into_iter().filter(|e| Path::new(&e.cwd).is_dir()).collect();
        Restore { path, closed, last: None }
    }

    /// Closed conversations not reopened yet (the Mac's sidebar offer).
    pub fn closed(&self) -> &[Entry] {
        &self.closed
    }

    /// Stops offering the closed conversations; the next `record` forgets them.
    pub fn dismiss(&mut self) {
        self.closed.clear();
    }

    /// Call after every refresh of the sessions: writes the record when the set of open conversations changed.
    /// Returns whether it wrote.
    pub fn record(&mut self, hosted: &[Hosted], sessions: &[AgentSession]) -> bool {
        // Already open again somewhere (e.g. from recent conversations): a second process would fork it.
        let open: HashSet<&str> = sessions.iter().filter_map(|s| s.conversation_id.as_deref()).collect();
        self.closed.retain(|e| !open.contains(e.conversation.as_str()));
        let entries = merged(live(hosted, sessions), &self.closed);
        if self.last.as_ref() == Some(&entries) {
            return false;
        }
        let ok = save(&self.path, &entries);
        if ok {
            self.last = Some(entries);
        }
        ok
    }

    /// Reopens closed conversations, each resuming with the model it ran with, under its old terminal name when
    /// free, with its character (`character` looks the id up in the roster). Returns the new terminal names.
    pub fn reopen(
        &mut self,
        host: &Host,
        entries: &[Entry],
        character: impl Fn(&str) -> Option<Character>,
        voice: bool,
        skip_permissions: bool,
        en: bool,
    ) -> Vec<Option<String>> {
        entries
            .iter()
            .map(|e| {
                let mut l = Launch::new(Agent::from_raw(&e.agent).unwrap_or(Agent::Claude), &e.cwd);
                l.resume = Some(e.conversation.clone());
                l.extra_args = resume_flags(e, &crate::usage::status_dir());
                l.character = e.character.as_deref().and_then(&character);
                l.voice = voice;
                l.skip_permissions = skip_permissions;
                l.en = en;
                l.name = e.name.clone().filter(|n| !host.exists(n));
                let name = host.create_agent(&l);
                self.closed.retain(|c| c != e);
                name
            })
            .collect()
    }

    /// `reopen` for everything the restart closed.
    pub fn reopen_closed(
        &mut self,
        host: &Host,
        character: impl Fn(&str) -> Option<Character>,
        voice: bool,
        skip_permissions: bool,
        en: bool,
    ) -> Vec<Option<String>> {
        let entries = self.closed.clone();
        self.reopen(host, &entries, character, voice, skip_permissions, en)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SessionStatus;

    fn hosted(name: &str, agent: Option<Agent>, cwd: &str) -> Hosted {
        Hosted {
            name: name.into(),
            agent,
            cwd: cwd.into(),
            title: name.into(),
            created: 0.0,
            character: Some("ranger".into()),
            pid: Some(1),
        }
    }

    fn session(agent: Agent, term: &str, conv: &str, log: &Path) -> AgentSession {
        let mut s = AgentSession::new(format!("x-{conv}"), agent, format!("talk {conv}"), "/w".into(), SessionStatus::Idle);
        s.hosted_name = Some(term.into());
        s.conversation_id = Some(conv.into());
        s.transcript_path = Some(log.to_string_lossy().into_owned());
        s
    }

    #[test]
    fn live_merged_and_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("a.jsonl");
        std::fs::write(&log, "{}\n").unwrap();
        let cwd = dir.path().to_string_lossy().into_owned();
        let hosted = vec![
            hosted("sh-1", Some(Agent::Claude), &cwd),
            hosted("sh-2", Some(Agent::Claude), &cwd), // same conversation as sh-1
            hosted("sh-3", None, &cwd),                 // a shell
            hosted("sh-4", Some(Agent::Codex), &cwd),   // no log yet
        ];
        let sessions = vec![
            session(Agent::Claude, "sh-1", "c1", &log),
            session(Agent::Claude, "sh-2", "c1", &log),
            session(Agent::Codex, "sh-4", "c4", &dir.path().join("missing")),
        ];
        let l = live(&hosted, &sessions);
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].conversation, "c1");
        assert_eq!(l[0].title, "talk c1");
        assert_eq!(l[0].name.as_deref(), Some("sh-1"));
        assert_eq!(l[0].character.as_deref(), Some("ranger"));

        let pending = vec![
            Entry { conversation: "c1".into(), ..l[0].clone() },
            Entry { conversation: "c9".into(), ..l[0].clone() },
        ];
        let m = merged(l.clone(), &pending);
        assert_eq!(m.iter().map(|e| e.conversation.as_str()).collect::<Vec<_>>(), ["c1", "c9"]);

        let path = dir.path().join("sub").join("open-sessions.json");
        assert!(save(&path, &m));
        assert_eq!(load(&path), m);
        // The Mac's record (no character/name) still loads.
        std::fs::write(&path, r#"[{"agent":"Codex","cwd":"/nope","conversation":"t","title":"x"}]"#).unwrap();
        assert_eq!(load(&path)[0].name, None);
    }

    #[test]
    fn restore_offers_closed_until_open_again_and_writes_on_change() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().to_string_lossy().into_owned();
        let path = default_path(dir.path());
        let gone = Entry {
            agent: "Claude".into(),
            cwd: "/no/such/folder".into(),
            conversation: "old".into(),
            title: "t".into(),
            log: None,
            character: None,
            name: None,
        };
        let keep = Entry { cwd: cwd.clone(), conversation: "c2".into(), ..gone.clone() };
        assert!(save(&path, &[gone, keep.clone()]));
        let mut r = Restore::open(path.clone());
        assert_eq!(r.closed(), [keep.clone()]);
        assert!(r.record(&[], &[]));
        assert!(!r.record(&[], &[]), "unchanged: not written again");
        assert_eq!(load(&path), [keep.clone()]);
        // The conversation was resumed elsewhere: no longer offered, dropped from the record.
        let mut s = AgentSession::new("x".into(), Agent::Claude, "n".into(), cwd, SessionStatus::Idle);
        s.conversation_id = Some("c2".into());
        assert!(r.record(&[], &[s]));
        assert!(r.closed().is_empty());
        assert!(load(&path).is_empty());
    }

    #[test]
    fn resume_flags_per_agent() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("c1.json"), r#"{"model":{"id":"claude-opus-5-5"},"effort":{"level":"high"}}"#).unwrap();
        let e = Entry {
            agent: "Claude".into(),
            cwd: "/".into(),
            conversation: "c1".into(),
            title: "t".into(),
            log: None,
            character: None,
            name: None,
        };
        assert_eq!(resume_flags(&e, dir.path()), ["--model", "claude-opus-5-5", "--effort", "high"]);
        assert!(resume_flags(&Entry { conversation: "none".into(), ..e.clone() }, dir.path()).is_empty());

        let rollout = dir.path().join("rollout.jsonl");
        std::fs::write(&rollout, "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"effort\":\"high\"}}\n").unwrap();
        let c = Entry { agent: "Codex".into(), log: Some(rollout.to_string_lossy().into_owned()), ..e };
        assert_eq!(resume_flags(&c, dir.path()), ["-m", "gpt-5.5", "-c", "model_reasoning_effort=\"high\""]);
    }
}
