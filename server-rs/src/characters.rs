//! Characters: a port of Sources/AgentDeck/Characters.swift (`Character`, `Art.bundled`, `Lineup`,
//! `CharacterAssigner`, `AgentNames`), the character bookkeeping of `SessionStore` in App.swift (`assignments`,
//! `names`, `pins`, `character(resuming:)`, `pick`) and `DesktopAPI.colorIndex`.
//!
//! Persistence: the Mac keeps the guild lineup, the random-assignment switch and the conversation → character map
//! in UserDefaults (`characterLineup`, `characterAssignmentRandom`, `conversationCharacters`); here they live in
//! `<data_dir>/characters.json` with the same key names. Live assignments are in memory on both, so after a
//! restart only pinned sessions get the same character back.
//!
//! Later phases: market characters (AssetLibrary) and the crystal ledger's unlocked set. With the bundled roster
//! only, `Recruit.freeCount` (32) opens every character, so the whole roster is allowed here.

use crate::model::AgentSession;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Character {
    pub id: String,
    /// English name, shown under the agent's name (`agents[].charName`).
    pub name: String,
    /// Korean name the agent is called by; market characters have none and use `name`.
    #[serde(default)]
    pub ko: Option<String>,
    /// Class in Korean, e.g. "고양이 마법사".
    #[serde(default)]
    pub role: Option<String>,
    /// Class in English, e.g. "Cat Mage" (bundled roster only).
    #[serde(default)]
    pub role_en: Option<String>,
    #[serde(default)]
    pub visual: Option<String>,
    /// How the character talks, in Korean.
    #[serde(default)]
    pub tone: Option<String>,
}

impl Character {
    pub fn new(id: &str, name: &str, ko: Option<&str>) -> Character {
        Character {
            id: id.into(),
            name: name.into(),
            ko: ko.map(Into::into),
            role: None,
            role_en: None,
            visual: None,
            tone: None,
        }
    }

    pub fn call_name(&self) -> &str {
        self.ko.as_deref().unwrap_or(&self.name)
    }

    /// Name shown in the UI: the English name in English, else the Korean one.
    pub fn display_name(&self, en: bool) -> &str {
        if en {
            &self.name
        } else {
            self.call_name()
        }
    }

    pub fn display_role(&self, en: bool) -> Option<&str> {
        if en {
            self.role_en.as_deref().or(self.role.as_deref())
        } else {
            self.role.as_deref()
        }
    }
}

/// The bundled roster, `<art_dir>/roster.json` (the app bundle's Resources/art; art/roster.json in the repo).
/// Empty when the file is missing or does not decode, like Swift.
pub fn load_roster(art_dir: &Path) -> Vec<Character> {
    std::fs::read(art_dir.join("roster.json"))
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// `agents[].color`: index into the Mac's project color palette for this folder (`DesktopAPI.colorIndex`).
pub fn color_index(cwd: &str) -> i64 {
    (fnv1a(cwd) % 10) as i64
}

/// Roster indices in guild lineup order: the saved ids first, then characters it does not name yet in roster order
/// (Swift `Lineup.order`).
pub fn lineup_order(roster: &[Character], saved: &[String]) -> Vec<usize> {
    let mut index: HashMap<&str, usize> = HashMap::new();
    for (i, c) in roster.iter().enumerate() {
        index.entry(c.id.as_str()).or_insert(i);
    }
    let mut seen = HashSet::new();
    let mut out = vec![];
    for id in saved {
        if let Some(&i) = index.get(id.as_str()) {
            if seen.insert(i) {
                out.push(i);
            }
        }
    }
    for i in 0..roster.len() {
        if seen.insert(i) {
            out.push(i);
        }
    }
    out
}

/// `startedAt ?? .distantPast`.
fn start(s: &AgentSession) -> f64 {
    s.started_at.unwrap_or(f64::MIN)
}

/// Gives each live session its own character while it lives; reuses characters only past roster size.
#[derive(Clone, Debug, Default)]
pub struct CharacterAssigner {
    assigned: HashMap<String, usize>,
}

impl CharacterAssigner {
    /// `allowed`: roster indices the crystal ledger has opened (None: the whole roster).
    /// `pinned`: sessions whose character was chosen when 수혁 started them; they always keep it.
    /// `order`: the guild lineup; a new session takes the first character in it that no live session has.
    /// `random`: a new session takes a free character chosen by its id's hash instead (stable across refreshes).
    pub fn update(
        &mut self,
        sessions: &[AgentSession],
        allowed: Option<&HashSet<usize>>,
        pinned: &HashMap<String, usize>,
        order: Option<&[usize]>,
        random: bool,
        roster_count: usize,
    ) -> HashMap<String, usize> {
        let count = roster_count.max(1);
        let default_order: Vec<usize> = (0..count).collect();
        let lineup: Vec<usize> = order
            .unwrap_or(&default_order)
            .iter()
            .copied()
            .filter(|&i| i < count && allowed.is_none_or(|a| a.contains(&i)))
            .collect();
        let pool = if lineup.is_empty() { default_order } else { lineup };
        let live: HashSet<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
        self.assigned.retain(|k, _| live.contains(k.as_str()));
        // Two sessions pinned to one character: the older keeps it and the other draws below.
        let mut starts: HashMap<&str, f64> = HashMap::new();
        for s in sessions {
            starts.entry(s.id.as_str()).or_insert(start(s));
        }
        let mut candidates: Vec<(&String, usize)> =
            pinned.iter().filter(|(k, &v)| live.contains(k.as_str()) && v < count).map(|(k, &v)| (k, v)).collect();
        candidates.sort_by(|a, b| starts[a.0.as_str()].total_cmp(&starts[b.0.as_str()]).then_with(|| a.0.cmp(b.0)));
        let mut pins: HashMap<String, usize> = HashMap::new();
        for (id, i) in candidates {
            if !pins.values().any(|&v| v == i) {
                pins.insert(id.clone(), i);
            }
        }
        // An unpinned session holding a pinned character gives it up and draws another below.
        let taken: HashSet<usize> = pins.values().copied().collect();
        self.assigned.retain(|k, v| pins.contains_key(k) || !taken.contains(v));
        self.assigned.extend(pins);
        let mut used: HashSet<usize> = self.assigned.values().copied().collect();
        let mut by_start: Vec<&AgentSession> = sessions.iter().collect();
        by_start.sort_by(|a, b| start(a).total_cmp(&start(b))); // stable, like Swift's sort
        for s in by_start {
            if self.assigned.contains_key(&s.id) {
                continue;
            }
            // Past the roster size characters repeat; the hash spreads the repeats.
            let free: Vec<usize> = pool.iter().copied().filter(|i| !used.contains(i)).collect();
            let h = fnv1a(&s.id);
            let pick = if free.is_empty() {
                pool[(h % pool.len() as u64) as usize]
            } else if random {
                free[(h % free.len() as u64) as usize]
            } else {
                free[0]
            };
            self.assigned.insert(s.id.clone(), pick);
            used.insert(pick);
        }
        self.assigned.clone()
    }
}

/// Each session is called by its character's name (Korean, or English in an English UI). Past the roster size
/// characters repeat; the later sessions get a number ("미라 2") to keep names unique (Swift `AgentNames.assign`).
pub fn assign_names(
    sessions: &[AgentSession],
    assignments: &HashMap<String, usize>,
    roster: &[Character],
    english: bool,
) -> HashMap<String, String> {
    let mut sorted: Vec<&AgentSession> = sessions.iter().collect();
    sorted.sort_by(|a, b| start(a).total_cmp(&start(b)).then_with(|| a.id.cmp(&b.id)));
    let mut result = HashMap::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    for s in sorted {
        let Some(c) = assignments.get(&s.id).and_then(|&i| roster.get(i)) else { continue };
        let base = if english { c.name.as_str() } else { c.call_name() };
        let n = seen.entry(base.to_string()).or_insert(0);
        *n += 1;
        result.insert(s.id.clone(), if *n == 1 { base.to_string() } else { format!("{base} {n}") });
    }
    result
}

/// The first in the lineup nobody uses; failing that the first no starting session took; failing that the first
/// (more agents than characters). `random` draws from the same tier instead of taking its first
/// (Swift `SessionStore.pick`).
pub fn pick(lineup: &[usize], live: &HashSet<usize>, starting: &HashSet<usize>, random: bool) -> Option<usize> {
    use rand::seq::IndexedRandom;
    let free: Vec<usize> = lineup.iter().copied().filter(|i| !live.contains(i) && !starting.contains(i)).collect();
    let not_starting: Vec<usize> = lineup.iter().copied().filter(|i| !starting.contains(i)).collect();
    for tier in [free.as_slice(), not_starting.as_slice(), lineup] {
        if !tier.is_empty() {
            return if random { tier.choose(&mut rand::rng()).copied() } else { tier.first().copied() };
        }
    }
    None
}

/// A terminal on 수혁's own tmux server (`tmux -L suhyeok`), as the Mac's `TmuxEngine.list` sees it. The Mac
/// pins every hosted agent to the character stored in the session's `@character` option, and that option lives
/// on the tmux server, so it survives restarts of either app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostedTerminal {
    /// tmux session name, e.g. "sh-5e112c" (`AgentSession::hosted_name`).
    pub name: String,
    /// `@character`: roster id the agent was launched with; None for shells and older terminals.
    pub character: Option<String>,
    /// pid of every pane's first process; the agent runs under one of them.
    pub pane_pids: Vec<u32>,
}

/// tmux socket name the Mac app uses (`TmuxEngine.socketName`).
pub const TMUX_SOCKET: &str = "suhyeok";

/// Same lookup as `TmuxEngine.tmux`; None where tmux is not installed (Windows).
fn tmux_binary() -> Option<&'static str> {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].into_iter().find(|p| Path::new(p).is_file())
}

fn tmux(args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(tmux_binary()?)
        .args(["-L", TMUX_SOCKET])
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Terminals on the `suhyeok` tmux server; empty without tmux or without a running server.
pub fn tmux_hosted() -> Vec<HostedTerminal> {
    let Some(list) = tmux(&["list-sessions", "-F", "#{session_name}\t#{@character}"]) else { return vec![] };
    let mut panes: HashMap<String, Vec<u32>> = HashMap::new();
    for row in tmux(&["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"]).unwrap_or_default().lines() {
        if let Some((name, pid)) = row.split_once('\t') {
            if let Ok(pid) = pid.trim().parse() {
                panes.entry(name.to_string()).or_default().push(pid);
            }
        }
    }
    list.lines()
        .filter_map(|row| {
            let (name, character) = row.split_once('\t')?;
            Some(HostedTerminal {
                name: name.to_string(),
                character: (!character.is_empty()).then(|| character.to_string()),
                pane_pids: panes.remove(name).unwrap_or_default(),
            })
        })
        .collect()
}

/// The `launched` argument of `Party::update`: hosted terminal name → character id.
pub fn launched_characters(hosted: &[HostedTerminal]) -> HashMap<String, String> {
    hosted.iter().filter_map(|h| Some((h.name.clone(), h.character.clone()?))).collect()
}

/// Saved choices (UserDefaults on the Mac), `<data_dir>/characters.json`.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Prefs {
    /// Guild lineup: character ids in the order new agents take them (`characterLineup`).
    #[serde(default, rename = "characterLineup")]
    lineup: Vec<String>,
    /// New agents take a random free character (`characterAssignmentRandom`).
    #[serde(default, rename = "characterAssignmentRandom")]
    random: bool,
    /// Character id of each conversation 수혁 started (`conversationCharacters`).
    #[serde(default, rename = "conversationCharacters")]
    conversation_characters: HashMap<String, String>,
}

/// The character state `SessionStore` keeps: roster, assignments and names, updated each refresh.
#[derive(Debug)]
pub struct Party {
    roster: Vec<Character>,
    prefs_path: PathBuf,
    prefs: Prefs,
    assigner: CharacterAssigner,
    assignments: HashMap<String, usize>,
    names_ko: HashMap<String, String>,
    names_en: HashMap<String, String>,
    /// Characters just given to sessions that are still starting (roster index → Unix time).
    launching: HashMap<usize, f64>,
}

impl Party {
    /// Bundled roster from `<art_dir>/roster.json`; saved choices from `<data_dir>/characters.json`.
    pub fn load(art_dir: &Path, data_dir: &Path) -> Party {
        Party::new(load_roster(art_dir), data_dir)
    }

    pub fn new(roster: Vec<Character>, data_dir: &Path) -> Party {
        let prefs_path = data_dir.join("characters.json");
        let prefs = std::fs::read(&prefs_path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        Party {
            roster,
            prefs_path,
            prefs,
            assigner: CharacterAssigner::default(),
            assignments: HashMap::new(),
            names_ko: HashMap::new(),
            names_en: HashMap::new(),
            launching: HashMap::new(),
        }
    }

    pub fn roster(&self) -> &[Character] {
        &self.roster
    }

    fn lineup(&self) -> Vec<usize> {
        lineup_order(&self.roster, &self.prefs.lineup)
    }

    /// Each refresh. `launched`: hosted terminal name → character id it was started with (tmux `@character`).
    pub fn update(&mut self, sessions: &[AgentSession], launched: &HashMap<String, String>) {
        let pinned = self.pins(sessions, launched);
        let order = self.lineup();
        self.assignments =
            self.assigner.update(sessions, None, &pinned, Some(&order), self.prefs.random, self.roster.len());
        self.names_ko = assign_names(sessions, &self.assignments, &self.roster, false);
        self.names_en = assign_names(sessions, &self.assignments, &self.roster, true);
    }

    /// Roster index per session whose character is fixed: chosen at launch or remembered for its conversation.
    /// Newly seen conversations of pinned sessions are remembered (and saved).
    fn pins(&mut self, sessions: &[AgentSession], launched: &HashMap<String, String>) -> HashMap<String, usize> {
        let mut pins = HashMap::new();
        let mut changed = false;
        for s in sessions {
            let by_launch = s.hosted_name.as_ref().and_then(|n| launched.get(n));
            let by_conversation = s.conversation_id.as_ref().and_then(|c| self.prefs.conversation_characters.get(c));
            let Some(id) = by_launch.or(by_conversation).cloned() else { continue };
            let Some(i) = self.roster.iter().position(|c| c.id == id) else { continue };
            pins.insert(s.id.clone(), i);
            if let Some(c) = &s.conversation_id {
                if self.prefs.conversation_characters.get(c) != Some(&id) {
                    self.prefs.conversation_characters.insert(c.clone(), id);
                    changed = true;
                }
            }
        }
        if changed {
            self.save();
        }
        pins
    }

    fn save(&self) {
        let Ok(data) = serde_json::to_vec_pretty(&self.prefs) else { return };
        if let Some(dir) = self.prefs_path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = self.prefs_path.with_extension("json.tmp");
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, &self.prefs_path);
        }
    }

    /// Roster index of the session's character.
    pub fn character_index(&self, s: &AgentSession) -> Option<usize> {
        self.assignments.get(&s.id).copied().filter(|&i| i < self.roster.len())
    }

    /// Its id is `agents[].character`, its `name` is `agents[].charName`.
    pub fn character(&self, s: &AgentSession) -> Option<&Character> {
        self.character_index(s).map(|i| &self.roster[i])
    }

    /// `agents[].name`: the character's name in the UI language, numbered past the roster size.
    pub fn agent_name(&self, s: &AgentSession, en: bool) -> String {
        let names = if en { &self.names_en } else { &self.names_ko };
        names.get(&s.id).cloned().unwrap_or_else(|| if en { "Adventurer" } else { "모험가" }.to_string())
    }

    /// The Korean name, for voice features, which stay Korean in any UI language.
    pub fn spoken_name(&self, s: &AgentSession) -> String {
        self.names_ko.get(&s.id).cloned().unwrap_or_else(|| "모험가".to_string())
    }

    /// The character a new 수혁 session gets: the conversation's own when resuming, then the one `from` already
    /// shows, else one no live or starting agent has (Swift `character(resuming:from:)`).
    pub fn character_for_launch(
        &mut self,
        conversation: Option<&str>,
        from: Option<&AgentSession>,
        now: f64,
    ) -> Option<Character> {
        if let Some(c) = conversation
            .and_then(|c| self.prefs.conversation_characters.get(c))
            .and_then(|id| self.roster.iter().find(|r| &r.id == id))
        {
            return Some(c.clone());
        }
        if let Some(c) = from.and_then(|s| self.character(s)) {
            return Some(c.clone());
        }
        self.launching.retain(|_, t| now - *t < 60.0);
        let live: HashSet<usize> = self.assignments.values().copied().collect();
        let starting: HashSet<usize> = self.launching.keys().copied().collect();
        let i = pick(&self.lineup(), &live, &starting, self.prefs.random)?;
        self.launching.insert(i, now);
        Some(self.roster[i].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Agent, SessionStatus};

    fn session(n: usize) -> AgentSession {
        let mut s = AgentSession::new(format!("s{n}"), Agent::Claude, "".into(), "/".into(), SessionStatus::Busy);
        s.started_at = Some(n as f64);
        s
    }

    fn art() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../art")
    }

    #[test]
    fn color_index_matches_the_swift_formula() {
        // Values from the Swift formula (FNV-1a over UTF-8, % 10), computed independently in Python.
        assert_eq!(color_index(""), 7);
        assert_eq!(color_index("/"), 8);
        assert_eq!(color_index("/Users/owen/project/agent-deck"), 2);
        assert_eq!(color_index(r"C:\Users\a\proj"), 4);
        assert_eq!(color_index("/home/u/수혁"), 2);
        assert_eq!(fnv1a("/home/u/수혁"), 16108976503773703302);
    }

    #[test]
    fn agent_is_called_by_its_characters_korean_name() {
        let roster = vec![Character::new("mage", "Mira", Some("미라")), Character::new("market.x", "Zed", None)];
        let sessions: Vec<_> = (0..3).map(session).collect();
        let a = HashMap::from([("s0".to_string(), 0), ("s1".to_string(), 1), ("s2".to_string(), 0)]);
        let ko = assign_names(&sessions, &a, &roster, false);
        assert_eq!(ko, HashMap::from([("s0".into(), "미라".into()), ("s1".into(), "Zed".into()), ("s2".into(), "미라 2".into())]));
        let en = assign_names(&sessions, &a, &roster, true);
        assert_eq!(en, HashMap::from([("s0".into(), "Mira".into()), ("s1".into(), "Zed".into()), ("s2".into(), "Mira 2".into())]));
    }

    #[test]
    fn pinned_session_keeps_its_character_and_others_move_aside() {
        let mut a = CharacterAssigner::default();
        let first = a.update(&[session(0)], None, &HashMap::new(), None, false, 4);
        let taken = first["s0"];
        let next = a.update(&[session(0), session(1)], None, &HashMap::from([("s1".into(), taken)]), None, false, 4);
        assert_eq!(next["s1"], taken);
        assert_ne!(next["s0"], taken);
    }

    #[test]
    fn two_sessions_pinned_to_one_character_do_not_share_it() {
        let mut a = CharacterAssigner::default();
        let pinned = HashMap::from([("s1".into(), 0), ("s2".into(), 0)]);
        let picks = a.update(&[session(2), session(1)], None, &pinned, None, false, 4);
        assert_eq!(picks["s1"], 0);
        assert_ne!(picks["s2"], 0);
    }

    #[test]
    fn back_to_back_launches_follow_the_lineup() {
        let lineup = [5, 2, 9, 0];
        let mut starting = HashSet::new();
        let mut picked = vec![];
        for _ in lineup {
            let i = pick(&lineup, &HashSet::new(), &starting, false).unwrap();
            starting.insert(i);
            picked.push(i);
        }
        assert_eq!(picked, lineup);
        assert_eq!(pick(&lineup, &HashSet::from([5]), &HashSet::from([2]), false), Some(9));
        assert_eq!(pick(&[0], &HashSet::from([0]), &HashSet::from([0]), false), Some(0));
    }

    #[test]
    fn random_launches_take_free_characters() {
        let lineup: Vec<usize> = (0..20).collect();
        let mut starting = HashSet::new();
        let mut picked = vec![];
        for _ in &lineup {
            let i = pick(&lineup, &HashSet::from([3]), &starting, true).unwrap();
            if picked.len() < lineup.len() - 1 {
                assert_ne!(i, 3);
            }
            starting.insert(i);
            picked.push(i);
        }
        assert_eq!(picked.iter().collect::<HashSet<_>>().len(), lineup.len());
        assert_eq!(pick(&[7], &HashSet::from([7]), &HashSet::from([7]), true), Some(7));
    }

    #[test]
    fn random_assigner_spreads_sessions_and_keeps_them() {
        let sessions: Vec<_> = (0..6)
            .map(|n| {
                let mut s = session(n);
                s.id = format!("r{n}");
                s
            })
            .collect();
        let mut a = CharacterAssigner::default();
        let first = a.update(&sessions, None, &HashMap::new(), None, true, 30);
        assert_eq!(first.values().collect::<HashSet<_>>().len(), 6);
        let mut values: Vec<usize> = first.values().copied().collect();
        values.sort();
        assert_ne!(values, (0..6).collect::<Vec<_>>());
        assert_eq!(a.update(&sessions, None, &HashMap::new(), None, true, 30), first);
    }

    #[test]
    fn lineup_keeps_saved_order_and_appends_new_characters() {
        let roster: Vec<_> = ["a", "b", "c", "market.x"].iter().map(|i| Character::new(i, i, None)).collect();
        let saved: Vec<String> = ["c", "gone", "a", "c"].iter().map(|s| s.to_string()).collect();
        assert_eq!(lineup_order(&roster, &saved), [2, 0, 1, 3]);
        assert_eq!(lineup_order(&roster, &[]), [0, 1, 2, 3]);
    }

    #[test]
    fn assigner_gives_new_sessions_the_lineup_in_order() {
        let mut a = CharacterAssigner::default();
        let sessions: Vec<_> = (0..3).map(session).collect();
        let picks = a.update(&sessions, None, &HashMap::new(), Some(&[3, 1, 0, 2]), false, 4);
        assert_eq!([picks["s0"], picks["s1"], picks["s2"]], [3, 1, 0]);
    }

    #[test]
    fn assigner_only_uses_unlocked_characters() {
        let mut a = CharacterAssigner::default();
        let sessions: Vec<_> = (0..10).map(session).collect();
        let allowed: HashSet<usize> = (0..8).collect();
        let picks = a.update(&sessions, Some(&allowed), &HashMap::new(), None, false, 32 + 4);
        assert_eq!(picks.len(), 10);
        assert!(picks.values().all(|v| allowed.contains(v)));
    }

    #[test]
    fn bundled_roster_loads_with_names_and_voices() {
        let roster = load_roster(&art());
        assert_eq!(roster.len(), 32);
        assert_eq!(roster[0].id, "knight");
        assert_eq!(roster[1].call_name(), "미라");
        assert_eq!(roster[1].display_name(true), "Mira");
        assert!(roster.iter().all(|c| c.tone.as_deref().is_some_and(|t| !t.is_empty())));
        assert!(load_roster(Path::new("/nonexistent-art-dir")).is_empty());
    }

    /// Live check against this machine: `cargo test --lib live_assignments -- --ignored --nocapture`.
    /// Resolves hosted names by pane ancestry (what the sessions port must do) and prints id → character.
    #[test]
    #[ignore]
    fn live_assignments() {
        let procs = crate::sessions::procs::Procs::snapshot();
        let hosted = tmux_hosted();
        let mut sessions = crate::sessions::load_all(false);
        for s in &mut sessions {
            let Some(mut pid) = s.pid else { continue };
            for _ in 0..64 {
                if let Some(h) = hosted.iter().find(|h| h.pane_pids.contains(&pid)) {
                    s.hosted_name = Some(h.name.clone());
                    break;
                }
                let up = procs.parent_pid(pid);
                if up == 0 || up == pid {
                    break;
                }
                pid = up;
            }
        }
        let data = tempfile::tempdir().unwrap();
        let mut party = Party::load(&art(), data.path());
        party.update(&sessions, &launched_characters(&hosted));
        for s in &sessions {
            let want = s.hosted_name.as_ref().and_then(|n| hosted.iter().find(|h| &h.name == n)).and_then(|h| h.character.clone());
            let got = party.character(s).map(|c| c.id.clone());
            println!("{}\t{:?}\t{:?}\tpinned={:?}", s.id, s.hosted_name, got, want);
        }
    }

    #[test]
    fn party_names_sessions_and_remembers_pinned_conversations() {
        let data = tempfile::tempdir().unwrap();
        let mut party = Party::load(&art(), data.path());
        let mut hosted = session(1);
        hosted.hosted_name = Some("suhyeok-1".into());
        hosted.conversation_id = Some("conv-1".into());
        let sessions = vec![session(0), hosted.clone(), session(2)];
        let launched = HashMap::from([("suhyeok-1".to_string(), "ranger".to_string())]);
        party.update(&sessions, &launched);
        assert_eq!(party.character(&sessions[0]).map(|c| c.id.as_str()), Some("knight"));
        assert_eq!(party.character(&hosted).map(|c| c.id.as_str()), Some("ranger"));
        assert_eq!(party.character(&sessions[2]).map(|c| c.id.as_str()), Some("mage"));
        assert_eq!(party.agent_name(&sessions[2], false), "미라");
        assert_eq!(party.agent_name(&sessions[2], true), "Mira");
        assert_eq!(party.spoken_name(&hosted), "로빈");
        let stranger = session(9);
        assert_eq!(party.agent_name(&stranger, false), "모험가");
        assert_eq!(party.agent_name(&stranger, true), "Adventurer");

        // After a restart the conversation, now in an unhosted session, keeps its character.
        let mut again = Party::load(&art(), data.path());
        let mut resumed = session(5);
        resumed.conversation_id = Some("conv-1".into());
        again.update(&[session(0), resumed.clone()], &HashMap::new());
        assert_eq!(again.character(&resumed).map(|c| c.id.as_str()), Some("ranger"));
        assert_eq!(again.character_for_launch(Some("conv-1"), None, 0.0).map(|c| c.id), Some("ranger".into()));
        // A fresh launch takes the first free one in the lineup, and back-to-back launches do not repeat.
        let a = again.character_for_launch(None, None, 100.0).unwrap();
        let b = again.character_for_launch(None, None, 101.0).unwrap();
        assert_eq!((a.id.as_str(), b.id.as_str()), ("mage", "alchemist"));
    }
}
