//! State changes for /api/events: port of Notifier.observe (Notifier.swift). An agent stopping on a question
//! ("asking") or finishing a turn ("done"); the last 100 are kept, numbered, under a boot id that changes per run.

use suhyeok::model::{one_line, AgentSession, SessionStatus};
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct Event {
    pub seq: u64,
    pub session: String,
    pub name: String,
    pub title: String,
    pub kind: &'static str,
    pub text: String,
    pub at: f64,
}

pub struct Events {
    pub boot: String,
    pub seq: u64,
    pub list: Vec<Event>,
    last: HashMap<String, SessionStatus>,
}

impl Events {
    pub fn new() -> Events {
        Events { boot: super::auth::random_hex(16), seq: 0, list: vec![], last: HashMap::new() }
    }

    /// Called after every refresh; the first call only records where everyone is.
    pub fn observe(&mut self, sessions: &[AgentSession], name_of: impl Fn(&AgentSession) -> String, now: f64, en: bool) {
        let first = self.last.is_empty();
        if !first {
            for s in sessions.iter().filter(|s| s.parent_id.is_none()) {
                let Some(before) = self.last.get(&s.id).copied() else { continue };
                if before == s.status {
                    continue;
                }
                let (kind, text) = if s.status == SessionStatus::Waiting {
                    ("asking", if en { format!("{} — stopped on a choice, waiting for an answer", s.name) } else { format!("{} — 선택지에서 멈춰 답을 기다림", s.name) })
                } else if before == SessionStatus::Busy && matches!(s.status, SessionStatus::Idle | SessionStatus::Shell) {
                    ("done", s.last_assistant.as_deref().map(|t| one_line(&plain(t), 160)).unwrap_or_else(|| s.name.clone()))
                } else {
                    continue;
                };
                self.seq += 1;
                self.list.push(Event { seq: self.seq, session: s.id.clone(), name: name_of(s), title: s.name.clone(), kind, text, at: now });
                if self.list.len() > 100 {
                    let extra = self.list.len() - 100;
                    self.list.drain(..extra);
                }
            }
        }
        self.last = sessions.iter().map(|s| (s.id.clone(), s.status)).collect();
    }

    /// Events after `after` for a client on this boot; another boot means the server restarted: nothing.
    pub fn since(&self, after: Option<u64>, boot: Option<&str>) -> Vec<&Event> {
        if boot != Some(self.boot.as_str()) {
            return vec![];
        }
        let after = after.unwrap_or(u64::MAX);
        self.list.iter().filter(|e| e.seq > after).collect()
    }
}

/// Speaker.plain (Voice.swift): code blocks and tables dropped, markdown markers and link targets removed,
/// cut at 1200 characters.
fn plain(s: &str) -> String {
    let marks = regex::Regex::new(r"[*_`#>\[\]]").unwrap();
    let links = regex::Regex::new(r"\(https?://[^)]*\)").unwrap();
    let mut out = vec![];
    let mut in_code = false;
    for line in s.split('\n') {
        let t = line.trim_matches(|c: char| c == ' ' || c == '\t');
        if t.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code || t.starts_with('|') {
            continue;
        }
        let t = marks.replace_all(t, "");
        out.push(links.replace_all(&t, "").into_owned());
    }
    out.into_iter().filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n").chars().take(1200).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use suhyeok::model::Agent;

    fn s(id: &str, st: SessionStatus) -> AgentSession {
        let mut x = AgentSession::new(id.into(), Agent::Claude, format!("t-{id}"), "/".into(), st);
        x.last_assistant = Some("**done** with `it`".into());
        x
    }

    #[test]
    fn asking_and_done_are_recorded_after_the_first_look() {
        let mut e = Events::new();
        let name = |x: &AgentSession| format!("n-{}", x.id);
        e.observe(&[s("a", SessionStatus::Busy)], name, 1.0, false);
        assert!(e.list.is_empty());
        e.observe(&[s("a", SessionStatus::Waiting)], name, 2.0, false);
        e.observe(&[s("a", SessionStatus::Busy)], name, 3.0, false);
        e.observe(&[s("a", SessionStatus::Idle)], name, 4.0, false);
        let kinds: Vec<_> = e.list.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, ["asking", "done"]);
        assert_eq!(e.list[1].text, "done with it");
        assert_eq!(e.since(Some(1), Some(&e.boot.clone())).len(), 1);
        assert!(e.since(Some(0), Some("other")).is_empty());
    }
}
