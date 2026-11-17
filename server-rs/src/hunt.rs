//! Hunting: a port of Sources/AgentDeck/Hunt.swift (`Hunt`, `HuntClock`) and of the hunting part of
//! `SessionStore` in App.swift (`hunt[session.id]`, `ground(for:)`, `huntLine(for:)`, `placements()`,
//! `lastActivity(for:)`). Times are Unix seconds (f64); every "now" is a parameter so results are reproducible.
//!
//! Not ported: crystal balances (CrystalBank / Ledger: the `crystals` total in /api/state) and `BossPattern`
//! (boss animation, drawn by the page). `Progress::earned` only reads transcripts, so it is complete here.

use crate::model::{Agent, AgentSession, SessionStatus};
use crate::world::{Point, World};
use regex::bytes::Regex as BytesRegex;
use regex::Regex;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Tier {
    Low = 0,
    Mid = 1,
    High = 2,
}

impl Tier {
    pub const ALL: [Tier; 3] = [Tier::Low, Tier::Mid, Tier::High];

    pub fn label(self, en: bool) -> &'static str {
        match (self, en) {
            (Tier::Low, false) => "하급 사냥터",
            (Tier::Mid, false) => "중급 사냥터",
            (Tier::High, false) => "상급 사냥터",
            (Tier::Low, true) => "Low hunting ground",
            (Tier::Mid, true) => "Mid hunting ground",
            (Tier::High, true) => "High hunting ground",
        }
    }

    pub fn boss(self, en: bool) -> &'static str {
        match (self, en) {
            (Tier::Low, false) => "숲의 슬라임 왕",
            (Tier::Mid, false) => "수정 동굴 골렘",
            (Tier::High, false) => "화염 용왕",
            (Tier::Low, true) => "Forest Slime King",
            (Tier::Mid, true) => "Crystal Cave Golem",
            (Tier::High, true) => "Flame Dragon King",
        }
    }

    /// Crystals per 10 active minutes.
    pub fn yield_per_10min(self) -> i64 {
        self as i64 + 1
    }

    /// Under 5 h of continuous activity: low; under 24 h: mid; beyond: high.
    pub fn of(run: f64) -> Tier {
        if run < 5.0 * 3600.0 {
            Tier::Low
        } else if run < 24.0 * 3600.0 {
            Tier::Mid
        } else {
            Tier::High
        }
    }
}

/// Earning-formula version, written on every ledger entry (ledger: later phase).
pub const RULE: i64 = 1;
/// Crystals for each finished turn and each successful `git commit`, on top of active time.
pub const TURN_BONUS: i64 = 1;
pub const COMMIT_BONUS: i64 = 3;
/// A pause this long ends the run: the agent goes back to camp and the clock starts over.
pub const RESET_AFTER: f64 = 3600.0;
/// Gaps shorter than this between log entries count as active time.
pub const ACTIVE_GAP: f64 = 5.0 * 60.0;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Progress {
    /// Start of the current run.
    pub run_start: Option<f64>,
    /// Newest activity.
    pub last: Option<f64>,
    pub active_seconds: f64,
    /// From active time.
    pub crystals: i64,
    pub crystal_remainder: f64,
    pub turns: i64,
    pub commits: i64,
    /// Output tokens: shown as cost, never paid out.
    pub mana: i64,
}

impl Progress {
    /// Everything this log has earned so far under the current rule.
    pub fn earned(&self) -> i64 {
        self.crystals + self.turns * TURN_BONUS + self.commits * COMMIT_BONUS
    }

    pub fn run(&self, now: f64) -> Option<f64> {
        let (start, last) = (self.run_start?, self.last?);
        (now - last < RESET_AFTER).then_some(now - start)
    }

    pub fn tier(&self, now: f64) -> Option<Tier> {
        self.run(now).map(Tier::of)
    }

    fn add(&mut self, t: f64) {
        if let Some(last) = self.last {
            let gap = t - last;
            if gap < 0.0 {
                return; // out-of-order lines (queue records) do not move the clock back
            }
            if gap >= RESET_AFTER {
                self.run_start = Some(t);
            } else if gap < ACTIVE_GAP {
                self.active_seconds += gap;
                // Crystals at the rate of the tier the agent was in at that moment.
                let tier = Tier::of(t - self.run_start.unwrap_or(t));
                self.crystal_remainder += gap / 600.0 * tier.yield_per_10min() as f64;
                let whole = self.crystal_remainder as i64;
                self.crystals += whole;
                self.crystal_remainder -= whole as f64;
            }
        } else {
            self.run_start = Some(t);
        }
        self.last = Some(t);
    }
}

/// Incremental scan state of one log (Swift `HuntClock.State`).
#[derive(Clone, Debug, Default)]
struct ClockState {
    offset: u64,
    p: Progress,
    /// Bash `git commit` tool_use ids awaiting their result.
    pending_commits: HashSet<String>,
    /// Claude repeats a message's usage on each of its records.
    last_usage_message: String,
}

/// Scans conversation logs (incrementally, from where it stopped) for entry timestamps, finished turns,
/// successful commits and output tokens (Swift `HuntClock`, whose state is a process-wide static; here it is
/// owned by the caller).
#[derive(Debug, Default)]
pub struct HuntClock {
    states: HashMap<String, ClockState>,
}

const CHUNK: u64 = 8 << 20;

struct Pat(&'static OnceLock<BytesRegex>, &'static str);

impl Pat {
    fn find(&self, line: &[u8]) -> Option<usize> {
        self.0.get_or_init(|| BytesRegex::new(&regex::escape(self.1)).unwrap()).find(line).map(|m| m.end())
    }
}

macro_rules! pat {
    ($name:ident, $s:expr) => {
        static $name: Pat = {
            static CELL: OnceLock<BytesRegex> = OnceLock::new();
            Pat(&CELL, $s)
        };
    };
}

pat!(KEY, "\"timestamp\":\"");
pat!(CLAUDE_TURN, "\"subtype\":\"turn_duration\"");
pat!(CODEX_TURN, "\"type\":\"task_complete\"");
pat!(TOOL_USE, "\"type\":\"tool_use\"");
pat!(TOOL_RESULT, "\"tool_result\"");
pat!(BASH, "\"name\":\"Bash\"");
pat!(GIT_COMMIT, "commit");
pat!(MESSAGE_ID, "\"id\":\"msg_");
pat!(CLAUDE_USAGE, "\"output_tokens\":");
pat!(CODEX_USAGE, "\"total_token_usage\"");

impl HuntClock {
    pub fn new() -> HuntClock {
        HuntClock::default()
    }

    pub fn progress(&mut self, path: &str) -> Progress {
        let mut st = self.states.get(path).cloned().unwrap_or_default();
        let Ok(mut f) = std::fs::File::open(path) else { return st.p };
        let size = f.seek(SeekFrom::End(0)).unwrap_or(0);
        if size < st.offset {
            st = ClockState::default();
        }
        // Read in 8 MB chunks; only whole lines are scanned. Like Swift, a single line longer than 8 MB stops the
        // scan at that line (it is retried on every call and never passed).
        while st.offset < size {
            if f.seek(SeekFrom::Start(st.offset)).is_err() {
                break;
            }
            let mut data = Vec::new();
            if (&mut f).take(CHUNK.min(size - st.offset)).read_to_end(&mut data).is_err() {
                break;
            }
            let Some(last_nl) = data.iter().rposition(|b| *b == b'\n') else { break };
            let chunk = &data[..=last_nl];
            for line in chunk[..last_nl].split(|b| *b == b'\n') {
                if let Some(t) = timestamp(line) {
                    st.p.add(t);
                }
                scan_work(line, &mut st);
            }
            st.offset += chunk.len() as u64;
        }
        let p = st.p.clone();
        self.states.insert(path.to_string(), st);
        p
    }
}

/// Turns, commits and tokens. Lines are only decoded when a cheap byte search says they matter.
fn scan_work(line: &[u8], st: &mut ClockState) {
    if CLAUDE_TURN.find(line).is_some() || CODEX_TURN.find(line).is_some() {
        st.p.turns += 1;
    }
    if TOOL_USE.find(line).is_some() && BASH.find(line).is_some() && GIT_COMMIT.find(line).is_some() {
        if let Some(blocks) = content_blocks(line) {
            for b in blocks {
                if b.get("type").and_then(Value::as_str) == Some("tool_use") && b.get("name").and_then(Value::as_str) == Some("Bash") {
                    let id = b.get("id").and_then(Value::as_str);
                    let cmd = b.get("input").and_then(|i| i.get("command")).and_then(Value::as_str);
                    if let (Some(id), Some(cmd)) = (id, cmd) {
                        if is_commit(cmd) {
                            st.pending_commits.insert(id.to_string());
                        }
                    }
                }
            }
        }
    }
    if !st.pending_commits.is_empty() && TOOL_RESULT.find(line).is_some() {
        if let Some(blocks) = content_blocks(line) {
            for b in blocks {
                if b.get("type").and_then(Value::as_str) != Some("tool_result") {
                    continue;
                }
                let Some(id) = b.get("tool_use_id").and_then(Value::as_str) else { continue };
                if !st.pending_commits.remove(id) {
                    continue;
                }
                if b.get("is_error").and_then(Value::as_bool) != Some(true) {
                    st.p.commits += 1;
                }
            }
        }
    }
    let codex_usage = CODEX_USAGE.find(line).is_some();
    if !codex_usage {
        if let (Some(u), Some(m)) = (CLAUDE_USAGE.find(line), MESSAGE_ID.find(line)) {
            if let Some(out) = integer_at(u, line) {
                // Read the id and the count straight from the bytes: assistant lines can be megabytes long.
                let start = m - 4; // back to the "msg_" prefix
                let end = line[start..].iter().position(|b| *b == b'"').map(|e| start + e);
                let id = end.map(|e| String::from_utf8_lossy(&line[start..e]).into_owned()).unwrap_or_default();
                if id != st.last_usage_message {
                    st.last_usage_message = id;
                    st.p.mana += out;
                }
            }
        }
    }
    if codex_usage {
        let out = json(line)
            .and_then(|v| v.get("payload")?.get("info")?.get("total_token_usage")?.get("output_tokens").cloned())
            .and_then(|o| as_int(&o));
        if let Some(out) = out {
            st.p.mana = st.p.mana.max(out); // a running total
        }
    }
}

/// `as? Int` on a JSONSerialization number: integers, and floats with no fraction.
fn as_int(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18).map(|f| f as i64))
}

fn integer_at(i: usize, line: &[u8]) -> Option<i64> {
    let digits = line[i..].iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 {
        return None;
    }
    // Swift's Int would trap on overflow; wrapping keeps the server alive instead.
    Some(line[i..i + digits].iter().fold(0i64, |n, b| n.wrapping_mul(10).wrapping_add((b - b'0') as i64)))
}

fn json(line: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(line).ok().filter(Value::is_object)
}

/// `message.content` when it is an array of objects (Swift casts to `[[String: Any]]`, which fails otherwise).
fn content_blocks(line: &[u8]) -> Option<Vec<Value>> {
    let v = json(line)?;
    let arr = v.get("message")?.get("content")?.as_array()?;
    arr.iter().all(Value::is_object).then(|| arr.clone())
}

/// True for a shell command that runs `git commit` (not `--dry-run`, not `commit-tree`, not inside quotes).
pub fn is_commit(command: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    if command.contains("--dry-run") {
        return false;
    }
    RE.get_or_init(|| Regex::new(r"(^|[\s;&|(])git(\s+-[Cc]\s+\S+)*\s+commit(\s|$)").unwrap()).is_match(command)
}

fn timestamp(line: &[u8]) -> Option<f64> {
    // Find the first "timestamp":"…" without decoding the whole JSON line.
    let start = KEY.find(line)?;
    let end = start + line[start..].iter().position(|b| *b == b'"')?;
    parse_iso8601(std::str::from_utf8(&line[start..end]).ok()?)
}

/// `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`:
/// `YYYY-MM-DDTHH:MM:SS.fff` then `Z` or `±HH:MM`. The fraction is required (a timestamp without one does not
/// parse, as on the Mac) and kept to millisecond precision like Foundation's formatter.
pub fn parse_iso8601(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let part = b.get(r)?;
        part.iter().all(u8::is_ascii_digit).then(|| part.iter().fold(0i64, |n, d| n * 10 + (d - b'0') as i64))
    };
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'.' {
        return None;
    }
    let (year, month, day) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hour, minute, second) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let frac_len = b[20..].iter().take_while(|c| c.is_ascii_digit()).count();
    if frac_len == 0 {
        return None;
    }
    let millis = num(20..20 + frac_len.min(3))? * 10i64.pow(3 - frac_len.min(3) as u32);
    let zone = &b[20 + frac_len..];
    let offset = match zone {
        [b'Z'] => 0,
        [sign @ (b'+' | b'-'), _, _, b':', _, _] => {
            let at = 20 + frac_len;
            let (h, m) = (num(at + 1..at + 3)?, num(at + 4..at + 6)?);
            if h > 23 || m > 59 {
                return None;
            }
            (h * 3600 + m * 60) * if *sign == b'+' { 1 } else { -1 }
        }
        _ => return None,
    };
    let secs = days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset;
    Some(secs as f64 + millis as f64 / 1000.0)
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Where a session stands on the map (Swift `placements()` tuple).
#[derive(Clone, Debug, PartialEq)]
pub struct Placement {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub tier: Option<Tier>,
}

impl Placement {
    /// `agents[].tier`: "low" / "mid" / "high", or None for the camp (JSON null).
    pub fn tier_key(&self) -> Option<&'static str> {
        self.tier.map(World::key)
    }
}

/// The hunting state `SessionStore` keeps: the log clock plus `hunt[session.id]` from the latest refresh.
#[derive(Debug, Default)]
pub struct HuntTracker {
    clock: HuntClock,
    hunt: HashMap<String, Progress>,
}

impl HuntTracker {
    pub fn new() -> HuntTracker {
        HuntTracker::default()
    }

    /// Each refresh: progress of every session with a log (Antigravity has none the clock can read).
    pub fn update(&mut self, sessions: &[AgentSession]) {
        let mut hunt = HashMap::new();
        for s in sessions {
            if s.agent == Agent::Antigravity {
                continue;
            }
            if let Some(p) = &s.transcript_path {
                hunt.insert(s.id.clone(), self.clock.progress(p));
            }
        }
        self.hunt = hunt;
    }

    pub fn progress(&self, id: &str) -> Option<&Progress> {
        self.hunt.get(id)
    }

    /// Hunting ground for a session, or None for the camp. Only agents in a turn (or stopped on a question
    /// mid-turn) hunt; the ground is picked by how long their run has lasted.
    pub fn ground(&self, s: &AgentSession, now: f64) -> Option<Tier> {
        if s.status != SessionStatus::Busy && s.status != SessionStatus::Waiting {
            return None;
        }
        Some(self.hunt.get(&s.id).and_then(|p| p.tier(now)).unwrap_or(Tier::Low))
    }

    /// "중급 사냥터 · 연속 6.2시간 · 결정 31 · 마나 1200" (`agents[].hunt`).
    pub fn hunt_line(&self, s: &AgentSession, now: f64, en: bool) -> String {
        let empty = Progress::default();
        let p = self.hunt.get(&s.id).unwrap_or(&empty);
        let place = self.ground(s, now).map(|t| t.label(en)).unwrap_or(if en { "Camp" } else { "대기소" });
        // `String(format: "%.1f")`: no grouping, '.' decimal point; Rust's `{:.1}` rounds the same way as printf.
        let run = p
            .run(now)
            .map(|r| if en { format!(" · {:.1} h streak", r / 3600.0) } else { format!(" · 연속 {:.1}시간", r / 3600.0) })
            .unwrap_or_default();
        let tail = if en {
            format!(" · {} crystals · {} mana", grouped(p.earned()), grouped(p.mana))
        } else {
            format!(" · 결정 {} · 마나 {}", grouped(p.earned()), grouped(p.mana))
        };
        format!("{place}{run}{tail}")
    }

    /// Where every agent stands: its hunting ground's attack spots, or the camp. Within a ground, agents take spots
    /// in order of their start time. Returned in the order of `sessions` (Swift returns ground groups in
    /// Dictionary order, which changes per launch).
    pub fn placements(&self, sessions: &[AgentSession], world: &World, now: f64) -> Vec<Placement> {
        let grounds: Vec<Option<Tier>> = sessions.iter().map(|s| self.ground(s, now)).collect();
        let mut spot_of: Vec<Option<Point>> = vec![None; sessions.len()];
        for tier in [None, Some(Tier::Low), Some(Tier::Mid), Some(Tier::High)] {
            let mut members: Vec<usize> = (0..sessions.len()).filter(|&i| grounds[i] == tier).collect();
            // Stable, like Swift's sort: equal start times keep the sessions' order.
            members.sort_by(|&a, &b| start(&sessions[a]).total_cmp(&start(&sessions[b])));
            let spots = match tier {
                Some(t) => world.attack_spots(t),
                None => world.camp_spots(),
            };
            for (i, &m) in members.iter().enumerate() {
                spot_of[m] = Some(world.nearest(World::spot(spots, i)));
            }
        }
        sessions
            .iter()
            .zip(spot_of)
            .zip(grounds)
            .map(|((s, p), tier)| {
                let p = p.expect("every session has a ground");
                Placement { id: s.id.clone(), x: p.x, y: p.y, tier }
            })
            .collect()
    }

    /// Newest thing the agent did: its last log entry, else the last status change (`agents[].last`).
    pub fn last_activity(&self, s: &AgentSession) -> Option<f64> {
        [self.hunt.get(&s.id).and_then(|p| p.last), s.updated_at].into_iter().flatten().reduce(f64::max)
    }
}

/// An Int interpolated into `String(localized:)`: formatted with the locale's grouping, "163,116" in ko and en.
pub fn grouped(n: i64) -> String {
    let digits = n.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 {
        out.insert(0, '-');
    }
    out
}

/// `startedAt ?? .distantPast`.
fn start(s: &AgentSession) -> f64 {
    s.started_at.unwrap_or(f64::MIN)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Tests/AgentDeckTests/Fixtures").join(name)
    }

    /// A private copy, so each test scans from a fresh incremental state.
    fn copy(dir: &tempfile::TempDir, name: &str) -> String {
        let to = dir.path().join(name);
        std::fs::copy(fixture(name), &to).unwrap();
        to.to_string_lossy().into_owned()
    }

    #[test]
    fn claude_session_earns_activity_turns_and_commits() {
        let dir = tempfile::tempdir().unwrap();
        let p = HuntClock::new().progress(&copy(&dir, "claude-session.jsonl"));
        assert_eq!(p.active_seconds as i64, 20 * 60);
        assert_eq!(p.crystals, 2); // 20 active minutes in the low ground
        assert_eq!(p.turns, 2); // turn_duration records, not the repeated end_turn
        assert_eq!(p.commits, 1); // the failed commit and `git log --grep='git commit'` do not count
        assert_eq!(p.earned(), 2 + 2 * TURN_BONUS + COMMIT_BONUS);
        assert_eq!(p.mana, 160); // output tokens, one count per message id
    }

    #[test]
    fn codex_rollout_earns_turns() {
        let dir = tempfile::tempdir().unwrap();
        let p = HuntClock::new().progress(&copy(&dir, "codex-rollout.jsonl"));
        assert_eq!(p.turns, 2);
        assert_eq!(p.commits, 0);
        assert_eq!(p.crystals, 1); // 16 active minutes
        assert_eq!(p.earned(), 1 + 2 * TURN_BONUS);
        assert_eq!(p.mana, 90); // last cumulative output total
    }

    #[test]
    fn incremental_scan_matches_full_scan() {
        let dir = tempfile::tempdir().unwrap();
        let full = HuntClock::new().progress(&copy(&dir, "claude-session.jsonl"));

        let text = std::fs::read_to_string(fixture("claude-session.jsonl")).unwrap();
        let lines: Vec<&str> = text.split('\n').collect();
        let path = dir.path().join("inc.jsonl");
        // Cut between a tool_use and its tool_result, so the pending commit must survive the gap.
        std::fs::write(&path, lines[..2].join("\n") + "\n").unwrap();
        let mut clock = HuntClock::new();
        let path_s = path.to_string_lossy().into_owned();
        clock.progress(&path_s);
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(lines[2..].join("\n").as_bytes()).unwrap();
        drop(f);
        let inc = clock.progress(&path_s);

        assert_eq!(inc.earned(), full.earned());
        assert_eq!(inc.commits, full.commits);
        assert_eq!(inc.turns, full.turns);
        assert_eq!(inc.mana, full.mana);
    }

    #[test]
    fn git_commit_command_matching() {
        assert!(is_commit("git commit -m x"));
        assert!(is_commit("cd a && git add . && git commit -q -m \"y\""));
        assert!(is_commit("git -C repo commit -m wip"));
        assert!(!is_commit("git log --grep='git commit'"));
        assert!(!is_commit("git commit --dry-run"));
        assert!(!is_commit("git commit-tree abc"));
    }

    #[test]
    fn iso8601_like_foundation() {
        assert_eq!(parse_iso8601("1970-01-01T00:00:00.000Z"), Some(0.0));
        assert_eq!(parse_iso8601("2026-10-01T09:00:00.250Z"), Some(1_790_845_200.25));
        assert_eq!(parse_iso8601("2026-10-01T18:00:00.000+09:00"), Some(1_790_845_200.0));
        assert_eq!(parse_iso8601("2026-10-01T09:00:00.123456Z"), Some(1_790_845_200.123));
        assert_eq!(parse_iso8601("2026-10-01T09:00:00Z"), None); // fractional seconds are required
        assert_eq!(parse_iso8601("2026-02-30T09:00:00.000Z"), None);
    }

    fn session(id: &str, status: SessionStatus, started: f64) -> AgentSession {
        let mut s = AgentSession::new(id.into(), Agent::Claude, "".into(), "/".into(), status);
        s.started_at = Some(started);
        s
    }

    #[test]
    fn hunt_line_groups_integers_like_the_mac() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1000), "1,000");
        assert_eq!(grouped(163116), "163,116");
        assert_eq!(grouped(1234567), "1,234,567");
        assert_eq!(grouped(-1234), "-1,234");
        let mut t = HuntTracker::new();
        let idle = session("b", SessionStatus::Idle, 0.0);
        let now = 2_000_000.0;
        // 19 earned = 16 crystals + 3 turns; a run of 1.25 h prints "1.2" like printf's %.1f (round half to even).
        let p = Progress {
            run_start: Some(now - 4500.0),
            last: Some(now - 10.0),
            crystals: 16,
            turns: 3,
            mana: 163116,
            ..Progress::default()
        };
        t.hunt.insert("b".into(), p);
        assert_eq!(t.hunt_line(&idle, now, false), "대기소 · 연속 1.2시간 · 결정 19 · 마나 163,116");
        assert_eq!(t.hunt_line(&idle, now, true), "Camp · 1.2 h streak · 19 crystals · 163,116 mana");
    }

    #[test]
    fn ground_follows_the_run_and_status() {
        let mut t = HuntTracker::new();
        let busy = session("a", SessionStatus::Busy, 0.0);
        let idle = session("b", SessionStatus::Idle, 0.0);
        assert_eq!(t.ground(&busy, 100.0), Some(Tier::Low)); // no log yet: low
        assert_eq!(t.ground(&idle, 100.0), None);
        let now = 1_000_000.0;
        let p = Progress { run_start: Some(now - 6.0 * 3600.0), last: Some(now - 60.0), ..Progress::default() };
        t.hunt.insert("a".into(), p.clone());
        assert_eq!(t.ground(&busy, now), Some(Tier::Mid));
        assert_eq!(t.hunt_line(&busy, now, false), "중급 사냥터 · 연속 6.0시간 · 결정 0 · 마나 0");
        assert_eq!(t.hunt_line(&busy, now, true), "Mid hunting ground · 6.0 h streak · 0 crystals · 0 mana");
        // Rested an hour: the run is over, back to low while busy, camp when idle.
        assert_eq!(t.ground(&busy, now + 3600.0), Some(Tier::Low));
        assert_eq!(t.hunt_line(&idle, now, false), "대기소 · 결정 0 · 마나 0");
        assert_eq!(t.hunt_line(&idle, now, true), "Camp · 0 crystals · 0 mana");
        let mut late = busy.clone();
        late.updated_at = Some(now + 10.0);
        assert_eq!(t.last_activity(&late), Some(now + 10.0));
        assert_eq!(t.last_activity(&busy), Some(now - 60.0));
        assert_eq!(t.last_activity(&idle), None);
    }

    #[test]
    fn placements_fill_spots_by_start_time_and_are_deterministic() {
        let world = World::load(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../art/out"));
        let sessions = vec![
            session("late", SessionStatus::Busy, 30.0),
            session("idle", SessionStatus::Idle, 5.0),
            session("early", SessionStatus::Waiting, 10.0),
            session("rest", SessionStatus::Idle, 1.0),
        ];
        let t = HuntTracker::new();
        let out = t.placements(&sessions, &world, 100.0);
        assert_eq!(out.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["late", "idle", "early", "rest"]);
        let at = |p: &Placement| Point { x: p.x, y: p.y };
        let low = world.attack_spots(Tier::Low);
        let camp = world.camp_spots();
        assert_eq!(at(&out[2]), world.nearest(low[0])); // earliest hunter takes the first spot
        assert_eq!(at(&out[0]), world.nearest(low[1]));
        assert_eq!(at(&out[3]), world.nearest(camp[0]));
        assert_eq!(at(&out[1]), world.nearest(camp[1]));
        assert_eq!(out[0].tier_key(), Some("low"));
        assert_eq!(out[1].tier_key(), None);
        assert_eq!(t.placements(&sessions, &world, 100.0), out);
    }
}
