//! The session store: refreshed every 3 seconds like SessionStore (App.swift), and the JSON the read API sends.

use super::events::Events;
use super::sidebar::{self, Row, Sort};
use super::Config;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use suhyeok::characters::{color_index, Party};
use suhyeok::hunt::{HuntTracker, Placement};
use suhyeok::menu::{self, LiveReply, Term, TerminalMenu, SCREEN_SCROLLBACK};
use suhyeok::model::{now, AgentSession, SessionStatus};
use suhyeok::pty::{Host, Hosted, PANEL_NAME};
use suhyeok::sessions::procs::Procs;
use suhyeok::sessions::recent::{self, RecentConversation};
use suhyeok::world::World;

pub struct Store {
    pub en: bool,
    pub sessions: Vec<AgentSession>,
    /// This server's terminals as of the last refresh (TmuxEngine.list).
    pub terms: Vec<Hosted>,
    pub events: Events,
    pub world: World,
    pub hunt: HuntTracker,
    pub party: Party,
    pub recent: Vec<RecentConversation>,
    /// Names the owner gave sessions (SessionStore.setSummary), by conversation id; shown instead of the title.
    pub summaries: HashMap<String, String>,
    /// Agents still starting that wait on a menu (the folder-trust question): /api/state "prompts".
    prompts: Vec<Value>,
    last_recent_load: f64,
}

fn file_name(path: &str) -> String {
    std::path::Path::new(path).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

impl Store {
    pub fn new(config: &Config) -> Store {
        // roster.json sits next to walkmap.json in an installed art folder, one level up in the repo (art/roster.json).
        let roster_dir = if config.art_dir.join("roster.json").exists() {
            config.art_dir.clone()
        } else {
            config.art_dir.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| config.art_dir.clone())
        };
        Store {
            en: config.en,
            sessions: vec![],
            terms: vec![],
            events: Events::new(),
            world: World::load(&config.art_dir),
            hunt: HuntTracker::new(),
            party: Party::load(&roster_dir, &config.data_dir),
            recent: vec![],
            summaries: HashMap::new(),
            prompts: vec![],
            last_recent_load: f64::MIN,
        }
    }

    pub fn refresh(&mut self, host: &Host) {
        let mut sessions = suhyeok::sessions::load_all(self.en);
        let t = now();
        self.terms = host.list();
        // Which terminal each agent runs in: this server's PTYs, and on a Mac also the Swift app's tmux server
        // (so this server can be compared with the Mac's). Their agents keep the character they were launched with.
        let tmux = if cfg!(target_os = "macos") { suhyeok::characters::tmux_hosted() } else { vec![] };
        let procs = Procs::snapshot();
        // A terminal of this server is a boundary, as a tmux pane is on the Mac: the agent in it is a top-level 수혁
        // session, even when the server itself was started inside another agent's process tree. A session keeps its
        // parent only when the parent runs in the same terminal (e.g. `claude -p` run from a hosted agent).
        let owners: HashMap<String, String> = sessions
            .iter()
            .filter_map(|s| Some((s.id.clone(), host.owner_of(s.pid?, &procs)?)))
            .collect();
        for s in sessions.iter_mut() {
            if let Some(term) = owners.get(&s.id) {
                let same = s.parent_id.as_ref().and_then(|p| owners.get(p)) == Some(term);
                if !same {
                    s.parent_id = None;
                    s.hosted_name = Some(term.clone());
                }
            } else if s.parent_id.is_none() && s.hosted_name.is_none() {
                if let Some(pid) = s.pid {
                    s.hosted_name =
                        tmux.iter().find(|h| h.pane_pids.iter().any(|&p| procs.descends(pid, p))).map(|h| h.name.clone());
                }
            }
        }
        for s in sessions.iter_mut() {
            if let Some(name) = s.conversation_id.as_ref().and_then(|c| self.summaries.get(c)) {
                s.generated_name = Some(std::mem::replace(&mut s.name, name.clone()));
            }
        }
        let mut launched = suhyeok::characters::launched_characters(&tmux);
        for h in &self.terms {
            if let Some(c) = &h.character {
                launched.insert(h.name.clone(), c.clone());
            }
        }
        self.hunt.update(&sessions);
        self.party.update(&sessions, &launched);
        let names: HashMap<String, String> = sessions.iter().map(|s| (s.id.clone(), self.agent_name(s))).collect();
        self.events.observe(&sessions, |s| names.get(&s.id).cloned().unwrap_or_default(), t, self.en);
        // Recent conversations every 30 seconds, as the Mac does.
        if t - self.last_recent_load > 30.0 {
            self.recent = recent::load(&recent::live_ids(&sessions), self.en);
            self.last_recent_load = t;
        }
        // HostedMenu.pending: agent terminals with no session yet that show a menu.
        let known: HashSet<&str> = sessions.iter().filter_map(|s| s.hosted_name.as_deref()).collect();
        self.prompts = self
            .terms
            .iter()
            .filter(|h| h.agent.is_some() && !known.contains(h.name.as_str()))
            .filter_map(|h| {
                let term = host.term(&h.name, None)?;
                let m = menu::hosted_menu(&term)?;
                Some(json!({
                    "name": h.name, "agent": h.agent.map(|a| a.raw()).unwrap_or(""), "cwd": h.cwd,
                    "question": m.question.as_deref().map(|q| menu::translate(q, self.en)).unwrap_or_default(),
                    "context": m.context.clone().unwrap_or_default(),
                    "menu": m.options.iter().map(|o| json!({"label": o.label, "detail": o.detail.clone().unwrap_or_default()})).collect::<Vec<_>>(),
                }))
            })
            .collect();
        self.sessions = sessions;
    }

    pub fn agent_name(&self, s: &AgentSession) -> String {
        self.party.agent_name(s, self.en)
    }

    pub fn last_activity(&self, s: &AgentSession) -> Option<f64> {
        self.hunt.last_activity(s)
    }

    /// Whether this server can type into the session: it runs in one of this server's terminals.
    pub fn can_send(&self, s: &AgentSession) -> bool {
        s.hosted_name.as_ref().is_some_and(|n| self.terms.iter().any(|h| &h.name == n))
    }

    fn agent_json(&self, s: &AgentSession, p: &Placement, t: f64) -> Value {
        let a = s.activity_at(t);
        let ch = self.party.character(s);
        let mut o = json!({
            "id": s.id, "name": self.agent_name(s), "title": s.name, "project": s.project(), "cwd": s.cwd,
            "agent": s.agent.raw(), "status": s.status.raw(), "activity": a.label(self.en), "activityCode": a.code(),
            "character": ch.map(|c| c.id.clone()).unwrap_or_default(), "x": p.x, "y": p.y,
            "tier": p.tier_key().map(Value::from).unwrap_or(Value::Null), "hunt": self.hunt.hunt_line(s, t, self.en),
            "action": s.action.as_ref().map(|x| x.detail.clone()).unwrap_or_default(),
            "last": self.last_activity(s).unwrap_or(0.0), "canSend": self.can_send(s),
            "hosted": s.hosted_name.is_some(), "canClone": s.conversation_id.is_some(), "canFork": s.agent.can_fork(),
            "color": color_index(&s.cwd), "estimated": s.estimated,
            "charName": ch.map(|c| c.name.clone()).unwrap_or_default(),
            "started": s.started_at.unwrap_or(0.0), "updated": s.updated_at.unwrap_or(0.0),
            "lastUser": s.last_user.clone().unwrap_or_default(), "lastAssistant": s.last_assistant.clone().unwrap_or_default(),
            "parent": s.parent_id.clone().unwrap_or_default(),
            "actionSymbol": s.action.as_ref().map(|x| x.symbol()).unwrap_or(""),
        });
        if let Some(h) = &s.hosted_name {
            o["term"] = json!(h);
        }
        o
    }

    pub fn state_json(&self) -> Value {
        let t = now();
        let agents: Vec<Value> = self
            .hunt
            .placements(&self.sessions, &self.world, t)
            .iter()
            .filter_map(|p| self.sessions.iter().find(|s| s.id == p.id).map(|s| self.agent_json(s, p, t)))
            .collect();
        json!({
            "agents": agents, "bosses": self.world.bosses_json(self.en),
            // The crystal ledger comes in phase 5.
            "crystals": 0,
            "world": {"w": suhyeok::world::WIDTH, "h": suhyeok::world::HEIGHT}, "avatar": suhyeok::world::AVATAR_HEIGHT,
            "prompts": self.prompts,
        })
    }

    /// /api/chat (MobileServer.chat): the conversation, the usage line and, when this server hosts the agent's
    /// terminal, the screen, the menu it is stopped on, or the reply being written.
    pub fn chat_json(s: &AgentSession, term: Option<&dyn Term>, screen: bool, en: bool) -> Value {
        let a = s.activity();
        let mut out = json!({
            "items": suhyeok::transcript::chat_items(s.transcript_path.as_deref(), s.agent, &s.cwd, en),
            "status": s.status.raw(), "activity": a.label(en), "activityCode": a.code(),
            "action": s.action.as_ref().map(|x| x.detail.clone()).unwrap_or_default(),
        });
        if let Some(u) = suhyeok::usage::load(s, en) {
            out["usage"] = u.to_json();
        }
        if let Some(text) = term.and_then(|t| t.screen(SCREEN_SCROLLBACK)) {
            if screen {
                out["screen"] = json!(menu::screen_view(&text));
            }
            if let Some(m) = TerminalMenu::parse(&text) {
                out["menu"] = json!((0..m.options.len())
                    .map(|i| json!({"label": m.options[i].label, "detail": m.options[i].detail.clone().unwrap_or_default(), "free": m.is_free_text(i)}))
                    .collect::<Vec<_>>());
                out["menuQuestion"] = json!(m.question.as_deref().map(|q| menu::translate(q, en)).unwrap_or_default());
                out["menuContext"] = json!(m.context.clone().unwrap_or_default());
            } else if s.status == SessionStatus::Busy {
                out["live"] = json!(LiveReply::turn(&text));
            }
        }
        out
    }

    fn item_json(&self, r: &Row) -> Value {
        let mut o = json!({"key": r.key, "title": r.title, "subtitle": r.subtitle});
        if let Some(t) = &r.term {
            o["term"] = json!(t);
        }
        if let Some(s) = r.session {
            o["id"] = json!(s.id);
            o["name"] = json!(self.agent_name(s));
            o["color"] = json!(color_index(&s.cwd));
            o["status"] = json!(s.status.raw());
            o["activityCode"] = json!(s.activity().code());
            o["last"] = json!(self.last_activity(s).unwrap_or(0.0));
            o["children"] = json!(self
                .sessions
                .iter()
                .filter(|c| c.parent_id.as_deref() == Some(&s.id))
                .map(|c| json!({"id": c.id, "name": self.agent_name(c), "title": c.name, "activityCode": c.activity().code()}))
                .collect::<Vec<_>>());
            o["subagents"] = json!(s
                .subagents
                .iter()
                .map(|w| json!({"title": w.title, "detail": w.action.as_ref().map(|a| a.detail.clone()).unwrap_or_default()}))
                .collect::<Vec<_>>());
        }
        o
    }

    /// A terminal row (SessionStore.hostedItem): the agent's session when it has one, else the terminal itself.
    fn hosted_row<'a>(&'a self, h: &Hosted) -> Row<'a> {
        let s = self.sessions.iter().find(|s| s.hosted_name.as_deref() == Some(h.name.as_str()));
        let kind = h.agent.map(|a| a.raw().to_string()).unwrap_or_else(|| if self.en { "Terminal" } else { "터미널" }.into());
        Row {
            key: h.name.clone(),
            title: s.map(|s| s.name.clone()).unwrap_or_else(|| h.title.clone()),
            subtitle: format!("{kind} · {}", file_name(&h.cwd)),
            term: Some(h.name.clone()),
            session: s,
            cwd: h.cwd.clone(),
            created: s.and_then(|s| s.started_at).or(Some(h.created)),
        }
    }

    pub fn sidebar_json(&self, sort: Option<&str>, ascending: bool) -> Value {
        let by = sort.and_then(Sort::from_key).unwrap_or(Sort::LastActivity);
        let t = now();
        let groups = |rows: Vec<Row>| -> Value {
            let out = sidebar::ordered(rows, by, ascending, &|s| self.last_activity(s), &|s| self.agent_name(s), t);
            json!(out
                .into_iter()
                .map(|(folder, items)| json!({"folder": folder.unwrap_or_default(), "items": items.iter().map(|r| self.item_json(r)).collect::<Vec<_>>()}))
                .collect::<Vec<_>>())
        };
        // 수혁 세션: agent terminals this server hosts, plus (on a Mac) agents in the Swift app's tmux.
        let mut hosted: Vec<Row> = self.terms.iter().filter(|h| h.agent.is_some()).map(|h| self.hosted_row(h)).collect();
        for s in self.sessions.iter().filter(|s| s.parent_id.is_none()) {
            let Some(name) = &s.hosted_name else { continue };
            if self.terms.iter().any(|h| &h.name == name) {
                continue;
            }
            hosted.push(Row {
                key: name.clone(),
                title: s.name.clone(),
                subtitle: format!("{} · {}", s.agent.raw(), file_name(&s.cwd)),
                term: Some(name.clone()),
                session: Some(s),
                cwd: s.cwd.clone(),
                created: s.started_at,
            });
        }
        let shells: Vec<Row> =
            self.terms.iter().filter(|h| h.agent.is_none() && h.name != PANEL_NAME).map(|h| self.hosted_row(h)).collect();
        let external: Vec<Row> = self
            .sessions
            .iter()
            .filter(|s| s.hosted_name.is_none() && s.parent_id.is_none())
            .map(|s| Row {
                key: s.id.clone(),
                title: s.name.clone(),
                subtitle: format!("{} · {}", s.agent.raw(), s.project()),
                term: None,
                session: Some(s),
                cwd: s.cwd.clone(),
                created: s.started_at,
            })
            .collect();
        json!({
            "hosted": groups(hosted), "shells": groups(shells), "external": groups(external),
            "recent": self.recent.iter().take(15).map(|r| json!({
                "id": r.id, "agent": r.agent.raw(), "title": r.title, "folder": file_name(&r.cwd), "updated": r.updated,
            })).collect::<Vec<_>>(),
            "sorts": Sort::ALL.iter().map(|s| json!({"key": s.key(), "label": s.label(self.en)})).collect::<Vec<_>>(),
            "sort": by.key(), "ascending": ascending, "panel": self.terms.iter().any(|h| h.name == PANEL_NAME),
        })
    }

    pub fn known_folders(&self) -> Vec<String> {
        let mut out = recent::known_folders(&self.sessions, &self.recent);
        for h in &self.terms {
            if !out.contains(&h.cwd) {
                out.insert(0, h.cwd.clone());
            }
        }
        out
    }
}
