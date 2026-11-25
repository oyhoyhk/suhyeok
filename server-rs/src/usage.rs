//! The usage line: a port of `UsageInfo` (Sources/AgentDeck/UsageLine.swift) and the `usage` object of
//! `GET /api/chat` (MobileServer.chat): model, effort, context use and the account's rate limits.

use crate::model::{jsonl_tail, now, Agent, AgentSession};
use serde_json::{Map, Value};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct Limit {
    pub label: String,
    used: f64,
    /// Unix seconds.
    pub resets_at: Option<f64>,
}

impl Limit {
    pub fn new(label: String, percent: f64, resets_at: Option<f64>) -> Limit {
        Limit { label, used: percent, resets_at }
    }

    /// Read when the agent last reported; past the reset time the window has started over.
    pub fn percent(&self) -> f64 {
        self.percent_at(now())
    }

    pub fn percent_at(&self, now: f64) -> f64 {
        if self.resets_at.is_some_and(|r| r < now) {
            0.0
        } else {
            self.used
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UsageInfo {
    pub model: Option<String>,
    /// Reasoning effort the model runs at ("medium", "high", ...).
    pub effort: Option<String>,
    pub context_used: Option<i64>,
    pub context_window: Option<i64>,
    pub limits: Vec<Limit>,
}

impl UsageInfo {
    pub fn context_percent(&self) -> Option<f64> {
        let (u, w) = (self.context_used?, self.context_window?);
        (w > 0).then(|| u as f64 / w as f64 * 100.0)
    }

    /// The `usage` object of `GET /api/chat`.
    pub fn to_json(&self) -> Value {
        self.to_json_at(now())
    }

    pub fn to_json_at(&self, now: f64) -> Value {
        let limits = self
            .limits
            .iter()
            .map(|l| {
                let mut o = Map::new();
                o.insert("label".into(), l.label.clone().into());
                o.insert("percent".into(), l.percent_at(now).into());
                if let Some(r) = l.resets_at {
                    o.insert("resetsAt".into(), r.into());
                }
                Value::Object(o)
            })
            .collect::<Vec<_>>();
        let mut u = Map::new();
        u.insert("limits".into(), Value::Array(limits));
        if let Some(m) = &self.model {
            u.insert("model".into(), m.clone().into());
        }
        if let Some(e) = &self.effort {
            u.insert("effort".into(), e.clone().into());
        }
        if let Some(p) = self.context_percent() {
            u.insert("contextPercent".into(), p.into());
        }
        if let Some(c) = self.context_used {
            u.insert("contextUsed".into(), c.into());
        }
        if let Some(w) = self.context_window {
            u.insert("contextWindow".into(), w.into());
        }
        Value::Object(u)
    }
}

/// Swift `UsageInfo.load`. `en` picks the limit labels' language.
pub fn load(s: &AgentSession, en: bool) -> Option<UsageInfo> {
    load_with(s, en, &status_dir())
}

/// `load` reading the Claude status line copies from `status_dir` (tests).
pub fn load_with(s: &AgentSession, en: bool, status_dir: &Path) -> Option<UsageInfo> {
    match s.agent {
        Agent::Claude => claude(s, en, status_dir),
        Agent::Codex => s.transcript_path.as_deref().and_then(|p| codex(p, en)),
        Agent::Antigravity => None, // agy keeps no usage numbers on disk
    }
}

// MARK: Claude

/// Claude Code hands its status line command a JSON with model, context and rate limits; the user's statusline script
/// copies it to this folder per conversation (`<session id>.json`). On the Mac that is
/// ~/Library/Application Support/Suhyeok/statusline; elsewhere the platform's data folder (Linux ~/.local/share,
/// Windows %APPDATA%) + Suhyeok/statusline. Without that copy, the transcript gives model and context, and limits come
/// from any other conversation's copy (limits are per account).
pub fn status_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(crate::model::home())).join("Suhyeok").join("statusline")
}

const CONTEXT_KEYS: [&str; 3] = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"];

fn sum_tokens(usage: &Value) -> i64 {
    CONTEXT_KEYS.iter().filter_map(|k| int(usage.get(*k))).sum()
}

fn claude(s: &AgentSession, en: bool, dir: &Path) -> Option<UsageInfo> {
    let own = s.conversation_id.as_ref().and_then(|id| read_json(&dir.join(format!("{id}.json"))));
    let mut info = UsageInfo::default();
    if let Some(own) = &own {
        let model = own.get("model").filter(|m| m.is_object());
        info.model = model
            .and_then(|m| m.get("display_name"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| model.and_then(|m| m.get("id")).and_then(Value::as_str).map(pretty_model));
        info.effort = own.get("effort").and_then(|e| e.get("level")).and_then(Value::as_str).map(str::to_string);
        if let Some(cw) = own.get("context_window").filter(|c| c.is_object()) {
            info.context_window = int(cw.get("context_window_size"));
            if let Some(cur) = cw.get("current_usage").filter(|c| c.is_object()) {
                info.context_used = Some(sum_tokens(cur));
            }
        }
    }
    if info.model.is_none() || info.context_used.is_none() {
        if let Some(path) = &s.transcript_path {
            for line in jsonl_tail(path, 4 * 1024 * 1024).iter().rev() {
                if line.get("type").and_then(Value::as_str) != Some("assistant") {
                    continue;
                }
                let Some(m) = line.get("message").filter(|m| m.is_object()) else { continue };
                let Some(usage) = m.get("usage").filter(|u| u.is_object()) else { continue };
                let Some(id) = m.get("model").and_then(Value::as_str).filter(|id| *id != "<synthetic>") else {
                    continue;
                };
                info.model = info.model.or_else(|| Some(pretty_model(id)));
                info.context_used = info.context_used.or_else(|| Some(sum_tokens(usage)));
                info.context_window = info.context_window.or_else(|| window_seen(dir, id)).or_else(|| {
                    Some(if info.context_used.unwrap_or(0) > 200_000 { 1_000_000 } else { 200_000 })
                });
                break;
            }
        }
    }
    // Limits are per account: the newest copy from any conversation is the freshest.
    // Claude Code dropped the 5-hour limit (2026-11); only the weekly one is left.
    if let Some(l) = newest_rate_limits(dir).as_ref().and_then(|r| r.get("seven_day")).filter(|l| l.is_object()) {
        if let Some(p) = number(l.get("used_percentage")) {
            info.limits.push(Limit::new(weekly(en), p, number(l.get("resets_at"))));
        }
    }
    if info.model.is_none() && info.limits.is_empty() {
        None
    } else {
        Some(info)
    }
}

/// Rate limits from the most recently updated conversation copy.
fn newest_rate_limits(dir: &Path) -> Option<Value> {
    newest_copies(dir)
        .iter()
        .find_map(|p| read_json(p).and_then(|j| j.get("rate_limits").filter(|r| r.is_object()).cloned()))
}

/// The context window another conversation on the same model reported (e.g. 1M for Opus).
fn window_seen(dir: &Path, model_id: &str) -> Option<i64> {
    for path in newest_copies(dir).iter().take(20) {
        let Some(j) = read_json(path) else { continue };
        if j.get("model").and_then(|m| m.get("id")).and_then(Value::as_str) != Some(model_id) {
            continue;
        }
        if let Some(w) = int(j.get("context_window").and_then(|c| c.get("context_window_size"))) {
            return Some(w);
        }
    }
    None
}

fn newest_copies(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else { return vec![] };
    let mut files: Vec<(PathBuf, std::time::SystemTime)> = rd
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
        .map(|e| {
            let t = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
            (e.path(), t)
        })
        .collect();
    files.sort_by(|a, b| b.1.cmp(&a.1));
    files.into_iter().map(|f| f.0).collect()
}

/// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5"
pub fn pretty_model(id: &str) -> String {
    let mut parts: Vec<&str> = id.split('-').filter(|p| !p.is_empty()).collect();
    if parts.first() == Some(&"claude") {
        parts.remove(0);
    }
    if let Some(last) = parts.last() {
        if last.chars().count() == 8 && last.parse::<i64>().is_ok() {
            parts.pop();
        }
    }
    let Some(name) = parts.first() else { return id.to_string() };
    let version = parts[1..].join(".");
    let mut chars = name.chars();
    let head: String = chars.next().map(|c| c.to_uppercase().collect()).unwrap_or_default();
    let tail: String = chars.collect();
    if version.is_empty() {
        format!("{head}{tail}")
    } else {
        format!("{head}{tail} {version}")
    }
}

// MARK: Codex

/// Codex writes token_count events (context use, rate limits) and turn_context (model, effort) into its rollout.
pub fn codex(path: &str, en: bool) -> Option<UsageInfo> {
    let mut info = UsageInfo::default();
    let (mut got_tokens, mut got_limits) = (false, false);
    for line in jsonl_tail(path, 512 * 1024).iter().rev() {
        let Some(p) = line.get("payload").filter(|p| p.is_object()) else { continue };
        let ty = line.get("type").and_then(Value::as_str);
        if info.model.is_none() && ty == Some("turn_context") {
            if let Some(m) = p.get("model").and_then(Value::as_str) {
                info.model = Some(m.to_string());
                info.effort = effort(p);
            }
        }
        if ty == Some("event_msg") && p.get("type").and_then(Value::as_str) == Some("token_count") {
            if !got_tokens {
                if let Some(i) = p.get("info").filter(|i| i.is_object()) {
                    if let Some(last) = i.get("last_token_usage").filter(|l| l.is_object()) {
                        got_tokens = true;
                        info.context_used = int(last.get("total_tokens"));
                        info.context_window = int(i.get("model_context_window"));
                    }
                }
            }
            if !got_limits {
                if let Some(rl) = p.get("rate_limits").filter(|r| r.is_object()) {
                    got_limits = true;
                    let mut windows: Vec<&Value> =
                        ["primary", "secondary"].iter().filter_map(|k| rl.get(*k).filter(|w| w.is_object())).collect();
                    windows.sort_by(|a, b| {
                        let (x, y) = (number(a.get("window_minutes")).unwrap_or(0.0), number(b.get("window_minutes")).unwrap_or(0.0));
                        x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal)
                    });
                    for w in windows {
                        let Some(pct) = number(w.get("used_percent")) else { continue };
                        let minutes = number(w.get("window_minutes")).unwrap_or(0.0);
                        info.limits.push(Limit::new(window_label(minutes, en), pct, number(w.get("resets_at"))));
                    }
                }
            }
        }
        if info.model.is_some() && got_tokens && got_limits {
            break;
        }
    }
    // A long turn can push turn_context out of the tail; the session's first one names the model too.
    if info.model.is_none() {
        let mut head = Vec::new();
        if let Ok(f) = std::fs::File::open(path) {
            let _ = f.take(256 * 1024).read_to_end(&mut head);
        }
        for chunk in head.split(|b| *b == b'\n').filter(|c| !c.is_empty()) {
            let Ok(line) = serde_json::from_slice::<Value>(chunk) else { continue };
            if line.get("type").and_then(Value::as_str) != Some("turn_context") {
                continue;
            }
            let Some(p) = line.get("payload").filter(|p| p.is_object()) else { continue };
            let Some(m) = p.get("model").and_then(Value::as_str) else { continue };
            info.model = Some(m.to_string());
            info.effort = effort(p);
            break;
        }
    }
    if info.model.is_none() && !got_tokens && !got_limits {
        None
    } else {
        Some(info)
    }
}

fn effort(tc: &Value) -> Option<String> {
    tc.get("effort")
        .and_then(Value::as_str)
        .or_else(|| tc.get("reasoning_effort").and_then(Value::as_str))
        .or_else(|| {
            tc.get("collaboration_mode")
                .and_then(|c| c.get("settings"))
                .and_then(|s| s.get("reasoning_effort"))
                .and_then(Value::as_str)
        })
        .map(str::to_string)
}

fn weekly(en: bool) -> String {
    if en { "Weekly" } else { "주간" }.to_string()
}

/// Localizable.strings: "5시간" = "5h", "주간" = "Weekly", "%lld일" = "%lldd", "%lld시간" = "%lldh".
fn window_label(minutes: f64, en: bool) -> String {
    if minutes == 300.0 {
        if en { "5h" } else { "5시간" }.to_string()
    } else if minutes == 10080.0 {
        weekly(en)
    } else if minutes >= 1440.0 {
        let d = (minutes / 1440.0) as i64;
        if en { format!("{d}d") } else { format!("{d}일") }
    } else {
        let h = (minutes / 60.0) as i64;
        if en { format!("{h}h") } else { format!("{h}시간") }
    }
}

// MARK: helpers

fn read_json(path: &Path) -> Option<Value> {
    let d = std::fs::read(path).ok()?;
    serde_json::from_slice::<Value>(&d).ok().filter(Value::is_object)
}

/// Swift `as? NSNumber` → Double, or a numeric string.
fn number(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

/// Swift `as? Int` on a JSON number: integers, and doubles with no fraction.
fn int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18).map(|f| f as i64)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SessionStatus;
    use serde_json::json;
    use std::time::{Duration, SystemTime};

    fn session(agent: Agent, transcript: Option<&str>, conversation: Option<&str>) -> AgentSession {
        let mut s = AgentSession::new("x".into(), agent, "n".into(), "/".into(), SessionStatus::Idle);
        s.transcript_path = transcript.map(str::to_string);
        s.conversation_id = conversation.map(str::to_string);
        s
    }

    fn write(path: &Path, v: &Value, age_secs: u64) {
        std::fs::write(path, v.to_string()).unwrap();
        let f = std::fs::File::options().write(true).open(path).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(age_secs)).unwrap();
    }

    fn write_lines(path: &Path, lines: &[Value]) {
        let body: String = lines.iter().map(|l| l.to_string() + "\n").collect();
        std::fs::write(path, body).unwrap();
    }

    #[test]
    fn pretty_model_names() {
        assert_eq!(pretty_model("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(pretty_model("claude-haiku-4-5-20251001"), "Haiku 4.5");
        assert_eq!(pretty_model("claude-fable"), "Fable");
        assert_eq!(pretty_model("claude"), "claude");
        assert_eq!(pretty_model("gpt-5.6-sol"), "Gpt 5.6.sol");
    }

    #[test]
    fn claude_reads_its_own_status_copy_and_the_newest_limits() {
        let dir = tempfile::tempdir().unwrap();
        let future = (now() + 3600.0).floor(); // whole seconds: serde_json does not round-trip every float tail
        write(
            &dir.path().join("conv1.json"),
            &json!({
                "model": {"id": "claude-opus-5-5", "display_name": "Opus 5.5 (1M context)"},
                "effort": {"level": "high"},
                "context_window": {"context_window_size": 1_000_000,
                    "current_usage": {"input_tokens": 10, "cache_creation_input_tokens": 20, "cache_read_input_tokens": 70_000, "output_tokens": 5}},
                "rate_limits": {"seven_day": {"used_percentage": 10, "resets_at": future}}
            }),
            100,
        );
        // Newer copy from another conversation: its limits win (limits are per account).
        write(&dir.path().join("conv2.json"), &json!({"rate_limits": {"seven_day": {"used_percentage": "42.5", "resets_at": future}}}), 1);
        let info = load_with(&session(Agent::Claude, None, Some("conv1")), false, dir.path()).unwrap();
        assert_eq!(info.model.as_deref(), Some("Opus 5.5 (1M context)"));
        assert_eq!(info.effort.as_deref(), Some("high"));
        assert_eq!(info.context_used, Some(70_030));
        assert_eq!(info.context_window, Some(1_000_000));
        assert_eq!(info.limits, vec![Limit::new("주간".into(), 42.5, Some(future))]);
        assert_eq!(
            info.to_json(),
            json!({"limits": [{"label": "주간", "percent": 42.5, "resetsAt": future}], "model": "Opus 5.5 (1M context)",
                   "effort": "high", "contextPercent": 70_030.0 / 1_000_000.0 * 100.0, "contextUsed": 70_030, "contextWindow": 1_000_000})
        );
        let en = load_with(&session(Agent::Claude, None, Some("conv1")), true, dir.path()).unwrap();
        assert_eq!(en.limits[0].label, "Weekly");
    }

    #[test]
    fn claude_falls_back_to_the_transcript_and_a_window_seen_elsewhere() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("t.jsonl");
        write_lines(
            &log,
            &[
                json!({"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 5, "cache_read_input_tokens": 300_000}}}),
                json!({"type": "assistant", "message": {"model": "<synthetic>", "usage": {"input_tokens": 1}}}),
                json!({"type": "user", "message": {"content": "hi"}}),
            ],
        );
        let status = dir.path().join("status");
        std::fs::create_dir(&status).unwrap();
        // No limits anywhere and a model never seen: the window is guessed from the size.
        let s = session(Agent::Claude, Some(log.to_str().unwrap()), Some("missing"));
        let info = load_with(&s, false, &status).unwrap();
        assert_eq!(info.model.as_deref(), Some("Opus 5.5"));
        assert_eq!(info.context_used, Some(300_005));
        assert_eq!(info.context_window, Some(1_000_000));
        assert!(info.limits.is_empty());
        assert!(info.to_json().get("effort").is_none());
        // Another conversation on the same model reported its window.
        write(&status.join("other.json"), &json!({"model": {"id": "claude-opus-5-5"}, "context_window": {"context_window_size": 2_000_000}}), 1);
        assert_eq!(load_with(&s, false, &status).unwrap().context_window, Some(2_000_000));
        // Nothing at all: no usage line.
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(load_with(&session(Agent::Claude, None, None), false, empty.path()), None);
    }

    #[test]
    fn a_limit_past_its_reset_reads_zero() {
        let l = Limit::new("주간".into(), 80.0, Some(1000.0));
        assert_eq!(l.percent_at(999.0), 80.0);
        assert_eq!(l.percent_at(1001.0), 0.0);
        assert_eq!(Limit::new("x".into(), 5.0, None).percent(), 5.0);
    }

    #[test]
    fn codex_rollout_gives_model_context_and_limits() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../Tests/AgentDeckTests/Fixtures/codex-rollout.jsonl");
        // The fixture has token_count events without last_token_usage or rate limits, and no turn_context.
        assert_eq!(codex(fixture.to_str().unwrap(), false), None);

        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("rollout.jsonl");
        write_lines(
            &log,
            &[
                json!({"type": "turn_context", "payload": {"model": "gpt-old", "effort": "low"}}),
                json!({"type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"total_tokens": 1}, "model_context_window": 2}}}),
                json!({"type": "turn_context", "payload": {"model": "gpt-5.6-sol", "collaboration_mode": {"settings": {"reasoning_effort": "xhigh"}}}}),
                json!({"type": "event_msg", "payload": {"type": "token_count",
                    "info": {"last_token_usage": {"total_tokens": 64_000}, "model_context_window": 256_000},
                    "rate_limits": {"primary": {"used_percent": 97.0, "window_minutes": 10080, "resets_at": 4_000_000_000u64},
                                    "secondary": {"used_percent": 12.5, "window_minutes": 300}}}}),
            ],
        );
        let s = session(Agent::Codex, Some(log.to_str().unwrap()), None);
        let info = load_with(&s, false, dir.path()).unwrap();
        assert_eq!(info.model.as_deref(), Some("gpt-5.6-sol"));
        assert_eq!(info.effort.as_deref(), Some("xhigh"));
        assert_eq!((info.context_used, info.context_window), (Some(64_000), Some(256_000)));
        assert_eq!(
            info.limits,
            vec![Limit::new("5시간".into(), 12.5, None), Limit::new("주간".into(), 97.0, Some(4e9))]
        );
        assert_eq!(info.to_json()["contextPercent"], json!(25.0));
        let en = load_with(&s, true, dir.path()).unwrap();
        assert_eq!(en.limits.iter().map(|l| l.label.as_str()).collect::<Vec<_>>(), ["5h", "Weekly"]);
        assert_eq!(window_label(2880.0, false), "2일");
        assert_eq!(window_label(2880.0, true), "2d");
        assert_eq!(window_label(120.0, false), "2시간");
        assert_eq!(window_label(120.0, true), "2h");
        assert_eq!(load_with(&session(Agent::Antigravity, Some(log.to_str().unwrap()), None), false, dir.path()), None);
    }

    #[test]
    fn codex_finds_the_model_at_the_head_when_the_tail_lacks_it() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("rollout.jsonl");
        let filler = json!({"type": "response_item", "payload": {"type": "message", "text": "x".repeat(1000)}});
        let mut lines = vec![json!({"type": "turn_context", "payload": {"model": "gpt-5.6", "reasoning_effort": "medium"}})];
        lines.extend(std::iter::repeat_n(filler, 700)); // pushes turn_context out of the 512 KB tail
        lines.push(json!({"type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"total_tokens": 9}}}}));
        write_lines(&log, &lines);
        let info = codex(log.to_str().unwrap(), false).unwrap();
        assert_eq!(info.model.as_deref(), Some("gpt-5.6"));
        assert_eq!(info.effort.as_deref(), Some("medium"));
        assert_eq!((info.context_used, info.context_window), (Some(9), None));
        assert!(info.to_json().get("contextPercent").is_none());
    }

    /// Prints what the real status line copies and newest Claude transcript give:
    /// `cargo test --lib usage -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn print_real_usage() {
        let dir = status_dir();
        let newest = newest_copies(&dir).into_iter().next().expect("no status copies");
        let id = newest.file_stem().unwrap().to_string_lossy().into_owned();
        let s = session(Agent::Claude, None, Some(&id));
        println!("{}: {}", dir.display(), load(&s, false).map(|u| u.to_json()).unwrap_or(Value::Null));
        let mut rollouts = vec![];
        let mut stack = vec![Path::new(&crate::model::home()).join(".codex/sessions")];
        while let Some(d) = stack.pop() {
            for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else if p.extension().is_some_and(|x| x == "jsonl") {
                    rollouts.push((e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), p));
                }
            }
        }
        if let Some((_, p)) = rollouts.into_iter().max() {
            println!("{}: {}", p.display(), codex(p.to_str().unwrap(), true).map(|u| u.to_json()).unwrap_or(Value::Null));
        }
    }
}
