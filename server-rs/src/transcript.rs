//! The conversation view: a port of `TranscriptRenderer` (Sources/AgentDeck/TranscriptView.swift), the path detection of
//! `FileLinks` (FileLinks.swift) with the home-folder rule of `MobileFiles.resolve` (MobileFiles.swift), and the
//! `items` part of `MobileServer.chat()` (`GET /api/chat`).
//!
//! Roles are Swift's `"\(item.role)"`: `"me"`, `"agent"`, `"tool"`, `"result"`.

use crate::model::{home, AgentAction, Agent};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::sync::{LazyLock, Mutex};

pub const ROLE_ME: &str = "me";
pub const ROLE_AGENT: &str = "agent";
pub const ROLE_TOOL: &str = "tool";
pub const ROLE_RESULT: &str = "result";

/// One entry of a conversation log, in display order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatItem {
    pub id: usize,
    /// `"me"`, `"agent"`, `"tool"` or `"result"` (Swift `ChatItem.Role` case names).
    pub role: String,
    pub text: String,
}

type Entry = (&'static str, String);

/// Parsed entries per log, extended incrementally as the file grows (logs only ever get appended to).
#[derive(Clone)]
struct Cached {
    offset: u64,
    entries: Vec<Entry>,
}

/// How far back the first read goes. Screenshots make single lines over 1 MB, so a small tail can hold no conversation
/// at all: the first read tries `FIRST_WINDOW`, then widens to `WINDOW` when that holds fewer than `ENOUGH` entries.
/// Huge lines are skipped unparsed.
const FIRST_WINDOW: u64 = 4 * 1024 * 1024;
const WINDOW: u64 = 32 * 1024 * 1024;
const ENOUGH: usize = 120;
const HUGE_LINE: usize = 256 * 1024;
const KEEP: usize = 600;

/// Keyed by language too: the Mac's language is app-wide, here it is per request and the placeholders are localized.
static CACHE: LazyLock<Mutex<HashMap<(String, bool), Cached>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// Reads the tail of a Claude, Codex or Antigravity conversation log (Swift `TranscriptRenderer.items`).
pub fn items(path: &str, agent: Agent, en: bool) -> Vec<ChatItem> {
    // Antigravity's log is a SQLite file, not JSON lines.
    if agent == Agent::Antigravity {
        let e = antigravity::entries(path, en);
        return wrap(&e[e.len().saturating_sub(KEEP)..]);
    }
    let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
    let Ok(mut f) = std::fs::File::open(path) else { return vec![] };
    let size = f.seek(SeekFrom::End(0)).unwrap_or(0);
    let key = (path.to_string(), en);
    let c = match cache.get(&key) {
        Some(old) if old.offset <= size => extend(old.clone(), &mut f, size, agent, en, false),
        _ => {
            // first read, or the file was replaced
            let start = |w: u64| Cached { offset: size.saturating_sub(w), entries: vec![] };
            let mut c = extend(start(FIRST_WINDOW), &mut f, size, agent, en, true);
            if c.entries.len() < ENOUGH && size > FIRST_WINDOW {
                c = extend(start(WINDOW), &mut f, size, agent, en, true);
            }
            c
        }
    };
    let out = wrap(&c.entries);
    cache.insert(key, c);
    out
}

/// Parses the complete lines from `c.offset` to `size`; a half-written last line is read again next time.
fn extend(mut c: Cached, f: &mut std::fs::File, size: u64, agent: Agent, en: bool, mid_line: bool) -> Cached {
    if size <= c.offset {
        return c;
    }
    let mut data = Vec::new();
    if f.seek(SeekFrom::Start(c.offset)).is_err() || f.take(size - c.offset).read_to_end(&mut data).is_err() {
        return c;
    }
    let Some(last_nl) = data.iter().rposition(|b| *b == b'\n') else { return c };
    let mut chunks: Vec<&[u8]> = data[..=last_nl].split(|b| *b == b'\n').filter(|ch| !ch.is_empty()).collect();
    if mid_line && c.offset > 0 && !chunks.is_empty() {
        chunks.remove(0); // started mid-line
    }
    let mut parsed: Vec<Value> = Vec::new();
    for chunk in chunks {
        if chunk.len() > HUGE_LINE {
            parsed.push(json!({"type": "huge"})); // an image-heavy tool result; shown as a placeholder
        } else if let Ok(v @ Value::Object(_)) = serde_json::from_slice::<Value>(chunk) {
            parsed.push(v);
        }
    }
    c.entries.extend(if agent == Agent::Claude { claude(&parsed, en) } else { codex(&parsed, en) });
    if c.entries.len() > KEEP {
        c.entries.drain(..c.entries.len() - KEEP);
    }
    c.offset += last_nl as u64 + 1;
    c
}

fn wrap(e: &[Entry]) -> Vec<ChatItem> {
    e.iter().enumerate().map(|(i, (r, t))| ChatItem { id: i, role: r.to_string(), text: t.clone() }).collect()
}

/// The terminal-style view (Swift `TranscriptRenderer.render`).
pub fn render(path: &str, agent: Agent, en: bool, max_blocks: usize) -> String {
    let all = items(path, agent, en);
    all[all.len().saturating_sub(max_blocks)..]
        .iter()
        .map(|i| match i.role.as_str() {
            ROLE_ME => format!("❯ {}", i.text),
            ROLE_RESULT => i.text.clone(),
            _ => format!("⏺ {}", i.text),
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn s<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str)
}

/// `x as? [[String: Any]]`: an array whose elements are all objects (otherwise the Swift cast fails as a whole).
fn dicts(v: Option<&Value>) -> &[Value] {
    match v.and_then(Value::as_array) {
        Some(a) if a.iter().all(Value::is_object) => a,
        _ => &[],
    }
}

fn claude(lines: &[Value], en: bool) -> Vec<Entry> {
    let mut out: Vec<Entry> = Vec::new();
    for line in lines {
        let ty = s(line, "type");
        if ty == Some("huge") {
            out.push((ROLE_RESULT, format!("  ⎿ {}", if en { "(large result, e.g. an image)" } else { "(이미지 등 큰 결과)" })));
            continue;
        }
        // A message typed while the agent is busy is logged at once as a queue "enqueue", and again as a
        // queued_command attachment when the agent picks it up; show the first, skip the repeat below.
        if ty == Some("queue-operation") && s(line, "operation") == Some("enqueue") {
            if let Some(p) = s(line, "content").map(unwrap_paste) {
                if !p.starts_with('<') {
                    out.push((ROLE_ME, p));
                    continue;
                }
            }
        }
        // Messages typed while the agent was busy are stored as queued_command attachments.
        if let Some(a) = line.get("attachment").filter(|a| a.is_object()) {
            if s(a, "type") == Some("queued_command") && a.get("origin").and_then(|o| s(o, "kind")) == Some("human") {
                if let Some(p) = s(a, "prompt").map(unwrap_paste) {
                    if !out.iter().any(|(r, t)| *r == ROLE_ME && *t == p) {
                        out.push((ROLE_ME, p));
                    }
                    continue;
                }
            }
        }
        if line.get("isMeta").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(msg) = line.get("message").filter(|m| m.is_object()) else { continue };
        if let Some(raw) = s(msg, "content") {
            let st = unwrap_paste(raw);
            if ty == Some("user") {
                if !st.starts_with('<') {
                    out.push((ROLE_ME, st));
                } else if let Some(c) = slash_command(&st) {
                    out.push((ROLE_ME, c));
                } else if let Some(c) = tag("bash-input", &st) {
                    out.push((ROLE_ME, format!("! {c}")));
                } else if let Some(o) = tag("bash-stdout", &st) {
                    let all = [o, tag("bash-stderr", &st).unwrap_or_default()]
                        .into_iter()
                        .filter(|x| !x.is_empty())
                        .collect::<Vec<_>>()
                        .join("\n");
                    let none = if en { "(no output)" } else { "(출력 없음)" };
                    out.push((ROLE_RESULT, if all.is_empty() { none.to_string() } else { all }));
                }
            }
            continue;
        }
        for item in dicts(msg.get("content")) {
            match (ty, s(item, "type")) {
                (Some("user"), Some("text")) => {
                    if let Some(t) = s(item, "text").map(unwrap_paste) {
                        if !t.starts_with('<') {
                            out.push((ROLE_ME, t));
                        }
                    }
                }
                (Some("assistant"), Some("text")) => {
                    if let Some(t) = s(item, "text") {
                        out.push((ROLE_AGENT, t.to_string()));
                    }
                }
                (Some("assistant"), Some("tool_use")) => {
                    let input = item.get("input").filter(|i| i.is_object()).cloned().unwrap_or_else(|| json!({}));
                    out.push((ROLE_TOOL, AgentAction::tool(s(item, "name").unwrap_or(""), &input).detail));
                }
                (Some("user"), Some("tool_result")) => out.push((ROLE_RESULT, result(item.get("content"), en))),
                _ => {}
            }
        }
    }
    out
}

static PASTE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<pasted_content[^>]*>\n?|\n?</pasted_content[^>]*>").unwrap());

/// Pasted text is logged as <pasted_content id="…">…</pasted_content id="…">; drop the tags so it reads as typed.
fn unwrap_paste(s: &str) -> String {
    if !s.contains("<pasted_content") {
        return s.to_string();
    }
    PASTE.replace_all(s, "").trim().to_string()
}

/// A slash command the user typed ("/clear", "/model haiku"), logged as <command-name>…<command-args>… tags.
fn slash_command(s: &str) -> Option<String> {
    let name = tag("command-name", s).filter(|n| n.starts_with('/'))?;
    let args = tag("command-args", s).unwrap_or_default();
    Some(if args.is_empty() { name } else { format!("{name} {args}") })
}

/// Text between <t> and </t>; also reads "!" shell-mode records (<bash-input>, <bash-stdout>, <bash-stderr>).
fn tag(t: &str, s: &str) -> Option<String> {
    let open = format!("<{t}>");
    let a = s.find(&open)? + open.len();
    let b = s[a..].find(&format!("</{t}>"))? + a;
    Some(s[a..b].trim().to_string())
}

fn codex(lines: &[Value], en: bool) -> Vec<Entry> {
    let mut out: Vec<Entry> = Vec::new();
    for line in lines.iter().filter(|l| s(l, "type") == Some("response_item")) {
        let Some(p) = line.get("payload").filter(|p| p.is_object()) else { continue };
        match s(p, "type") {
            Some("message") => {
                let texts: Vec<&str> = dicts(p.get("content"))
                    .iter()
                    .filter_map(|c| s(c, "text"))
                    .filter(|t| !t.starts_with('<') && !t.starts_with("# AGENTS.md"))
                    .collect();
                let Some(t) = texts.first() else { continue };
                match s(p, "role") {
                    Some("user") => out.push((ROLE_ME, t.to_string())),
                    Some("assistant") => out.push((ROLE_AGENT, t.to_string())),
                    _ => {}
                }
            }
            Some("function_call") | Some("custom_tool_call") => {
                let args = s(p, "arguments").or_else(|| s(p, "input")).unwrap_or("");
                let input = match serde_json::from_str::<Value>(args) {
                    Ok(v @ Value::Object(_)) => v,
                    _ => json!({ "cmd": args }),
                };
                out.push((ROLE_TOOL, AgentAction::tool(s(p, "name").unwrap_or(""), &input).detail));
            }
            Some("function_call_output") | Some("custom_tool_call_output") => {
                out.push((ROLE_RESULT, result(p.get("output"), en)))
            }
            _ => {}
        }
    }
    out
}

/// Tool output, clipped to a few lines like the CLI does.
fn result(content: Option<&Value>, en: bool) -> String {
    let mut text = String::new();
    match content {
        Some(Value::String(st)) => text = st.clone(),
        Some(Value::Array(a)) if a.iter().all(Value::is_object) => {
            text = a.iter().filter_map(|i| s(i, "text")).collect::<Vec<_>>().join("\n");
            if text.is_empty() && !a.is_empty() {
                text = if en {
                    format!("({} items, e.g. images)", a.len())
                } else {
                    format!("(이미지 등 {}개 항목)", a.len())
                };
            }
        }
        Some(d @ Value::Object(_)) => {
            if let Some(st) = s(d, "output") {
                text = st.to_string();
            }
        }
        _ => {}
    }
    clip(&text, en)
}

/// Tool output text, first six lines.
pub fn clip(text: &str, en: bool) -> String {
    let rows: Vec<&str> = text.split('\n').collect();
    let shown = rows.iter().take(6).map(|r| format!("  ⎿ {r}")).collect::<Vec<_>>().join("\n");
    if rows.len() > 6 {
        let more = if en { format!("+{} lines", rows.len() - 6) } else { format!("+{}줄", rows.len() - 6) };
        format!("{shown}\n  ⎿ … {more}")
    } else {
        shown
    }
}

// MARK: GET /api/chat items

/// The `items` array of `GET /api/chat` (MobileServer.chat): the last 80 entries, tool results dropped, and on every
/// non-tool item the paths in its text that exist inside the home folder (`files`).
pub fn chat_items(transcript_path: Option<&str>, agent: Agent, cwd: &str, en: bool) -> Value {
    chat_items_in(transcript_path, agent, cwd, en, &home())
}

pub fn chat_items_in(transcript_path: Option<&str>, agent: Agent, cwd: &str, en: bool, home: &str) -> Value {
    let all = transcript_path.map(|p| items(p, agent, en)).unwrap_or_default();
    let tail = &all[all.len().saturating_sub(80)..];
    Value::Array(
        tail.iter()
            .filter(|i| i.role != ROLE_RESULT)
            .map(|i| {
                let mut o = Map::new();
                o.insert("role".into(), Value::String(i.role.clone()));
                o.insert("text".into(), Value::String(i.text.clone()));
                // Paths in the text that exist here, so the phone can make them tappable (dirs end in "/").
                if i.role != ROLE_TOOL {
                    let files = file_links_in(&i.text, cwd, home);
                    if !files.is_empty() {
                        o.insert("files".into(), json!(files));
                    }
                }
                Value::Object(o)
            })
            .collect(),
    )
}

// MARK: file links (FileLinks.paths filtered by MobileFiles.resolve)

#[cfg(not(windows))]
const SEP: &str = "/";
#[cfg(windows)]
const SEP: &str = r"[/\\]";

/// `~/a/b`, `/a/b`, `./a`, `a/b.swift`, `README.md`, each optionally followed by `:line[:col]` or `:line-line`.
/// The Swift pattern starts with the lookbehind `(?<![\w/.~-])`, which the regex crate lacks; `LOOKBEHIND` checks the
/// character before each match instead. On Windows `\` also separates and `C:\` / `C:/` may start a path.
static LINK: LazyLock<Regex> = LazyLock::new(|| {
    let drive = if cfg!(windows) { r"[A-Za-z]:[/\\]|" } else { "" };
    Regex::new(&format!(
        r"(?:{drive}~?{SEP}|\.{{1,2}}{SEP})?[\w@가-힣.+-]+(?:{SEP}[\w@가-힣.+-]+)*(?::\d+(?:[:-]\d+)?)?"
    ))
    .unwrap()
});
static LOOKBEHIND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(if cfg!(windows) { r"^[\w/\\.~-]$" } else { r"^[\w/.~-]$" }).unwrap());
static KOREAN_TAIL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[가-힣]+$").unwrap());
static LINE_SUFFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r":\d+([:-]\d+)?$").unwrap());

/// What `GET /api/chat` puts under an item's `files`: each path written in `text` that exists on disk and lies inside the
/// home folder, as written → the absolute path it points to; folders end in "/" (`\` on Windows).
pub fn file_links(text: &str, cwd: &str) -> BTreeMap<String, String> {
    file_links_in(text, cwd, &home())
}

pub fn file_links_in(text: &str, cwd: &str, home: &str) -> BTreeMap<String, String> {
    paths(text, cwd, home).into_iter().filter(|(_, v)| resolve_in_home(v, home).is_some()).collect()
}

/// Swift `FileLinks.paths(in:cwd:)`: the linked paths in `text`, as written, to what they point to.
pub fn paths(text: &str, cwd: &str, home: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if !(text.contains('/') || text.contains('.') || (cfg!(windows) && text.contains('\\'))) {
        return out;
    }
    let mut pos = 0;
    while let Some(m) = LINK.find_at(text, pos) {
        // Emulated lookbehind: a match glued to a word or path character is no match at this start; retry one further.
        if let Some(prev) = text[..m.start()].chars().next_back() {
            if LOOKBEHIND.is_match(prev.encode_utf8(&mut [0; 4])) {
                pos = m.start() + text[m.start()..].chars().next().map_or(1, char::len_utf8);
                continue;
            }
        }
        pos = m.end();
        let mut token = m.as_str().trim_end_matches('.').to_string(); // sentence end
        let mut hit = target(&token, cwd, home);
        if hit.is_none() {
            // a Korean particle stuck to the path: "README.md와"
            token = KOREAN_TAIL.replace(&token, "").into_owned();
            hit = target(&token, cwd, home);
        }
        if let Some((full, dir)) = hit {
            out.insert(token, if dir { format!("{full}{}", std::path::MAIN_SEPARATOR) } else { full });
        }
    }
    out
}

fn target(token: &str, cwd: &str, home: &str) -> Option<(String, bool)> {
    let path = LINE_SUFFIX.replace(token, "");
    if !(path.contains('/') || path.contains('.') || (cfg!(windows) && path.contains('\\'))) {
        return None;
    }
    let mut full = expand_tilde(&path, home);
    if !is_absolute(&full) {
        if cwd.is_empty() {
            return None;
        }
        full = Path::new(cwd).join(full);
    }
    let full = standardize(&full);
    let meta = std::fs::metadata(&full).ok()?;
    Some((full.to_string_lossy().into_owned(), meta.is_dir()))
}

/// Swift `MobileFiles.resolve`: `path` (absolute or `~/…`) with symlinks resolved, when it lies inside the home folder.
pub fn resolve_in_home(path: &str, home: &str) -> Option<String> {
    if path.is_empty() {
        return None;
    }
    let full = standardize(&expand_tilde(path, home));
    if !is_absolute(&full) {
        return None;
    }
    let real = std::fs::canonicalize(&full).unwrap_or(full);
    let root = std::fs::canonicalize(home).unwrap_or_else(|_| PathBuf::from(home));
    real.starts_with(&root).then(|| real.to_string_lossy().into_owned())
}

fn is_absolute(p: &Path) -> bool {
    if cfg!(windows) {
        p.is_absolute()
    } else {
        p.to_string_lossy().starts_with('/')
    }
}

/// `~` or `~/rest` → home (NSString.expandingTildeInPath, current user only).
fn expand_tilde(p: &str, home: &str) -> PathBuf {
    if p == "~" {
        return PathBuf::from(home);
    }
    match p.strip_prefix("~/").or_else(|| if cfg!(windows) { p.strip_prefix("~\\") } else { None }) {
        Some(rest) => Path::new(home).join(rest),
        None => PathBuf::from(p),
    }
}

/// NSString.standardizingPath, lexically: drops empty and "." components and a trailing separator, and folds ".."
/// into its parent in absolute paths (relative paths keep a leading "..").
fn standardize(p: &Path) -> PathBuf {
    let mut out: Vec<Component> = Vec::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => match out.last() {
                Some(Component::Normal(_)) => {
                    out.pop();
                }
                Some(Component::RootDir) | Some(Component::Prefix(_)) => {}
                _ => out.push(c),
            },
            _ => out.push(c),
        }
    }
    out.iter().collect()
}

// MARK: Antigravity (port of the transcript half of AntigravitySource.swift)

mod antigravity {
    use super::{clip, Entry, ROLE_AGENT, ROLE_ME, ROLE_RESULT, ROLE_TOOL};
    use crate::model::AgentAction;
    use serde_json::{json, Value};
    use std::collections::HashMap;
    use std::sync::{LazyLock, Mutex};
    use std::time::SystemTime;

    type Stamp = [Option<SystemTime>; 2];
    static CACHE: LazyLock<Mutex<HashMap<(String, bool), (Stamp, Vec<Entry>)>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));

    /// The conversation as chat entries, oldest first. Parsed again only when the database or its WAL changed.
    pub fn entries(path: &str, en: bool) -> Vec<Entry> {
        let m = |p: String| std::fs::metadata(p).and_then(|m| m.modified()).ok();
        let stamp: Stamp = [m(path.to_string()), m(format!("{path}-wal"))];
        let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        let key = (path.to_string(), en);
        if let Some((s, e)) = cache.get(&key) {
            if *s == stamp {
                return e.clone();
            }
        }
        let out = parse(path, en);
        cache.insert(key, (stamp, out.clone()));
        out
    }

    fn parse(path: &str, en: bool) -> Vec<Entry> {
        let mut out: Vec<Entry> = Vec::new();
        for (ty, payload) in steps(path, 2000) {
            match ty {
                14 => {
                    if let Some(t) = strings(&payload, &[19, 2]).into_iter().next() {
                        out.push((ROLE_ME, t));
                    }
                }
                15 => {
                    for t in strings(&payload, &[20, 1]).into_iter().filter(|t| !t.is_empty()) {
                        out.push((ROLE_AGENT, t));
                    }
                    for call in messages(&payload, &[20, 7]) {
                        out.push((ROLE_TOOL, action(call).detail));
                    }
                }
                _ => {
                    // Tool results (run_command, read_file, …) share this field.
                    if let Some(t) = strings(&payload, &[140, 2, 1]).into_iter().next() {
                        out.push((ROLE_RESULT, clip(&t, en)));
                    }
                }
            }
        }
        out
    }

    /// A tool call: name in field 2, JSON arguments in field 3.
    fn action(call: &[u8]) -> AgentAction {
        let args = strings(call, &[3]).into_iter().next().unwrap_or_default();
        let input = match serde_json::from_str::<Value>(&args) {
            Ok(v @ Value::Object(_)) => v,
            _ => json!({ "cmd": args }),
        };
        AgentAction::tool(&strings(call, &[2]).into_iter().next().unwrap_or_default(), &input)
    }

    fn steps(path: &str, limit: u32) -> Vec<(i64, Vec<u8>)> {
        use rusqlite::{Connection, OpenFlags};
        if !std::path::Path::new(path).exists() {
            return vec![];
        }
        // WAL databases. agy removes -wal and -shm once idle, and a read-only connection cannot open a WAL database
        // without -shm; with no -wal the main file holds everything, so read it as immutable then.
        let wal = std::path::Path::new(&format!("{path}-wal")).exists();
        let mut p = path.replace('\\', "/");
        if !p.starts_with('/') {
            p.insert(0, '/');
        }
        let p = p.replace('%', "%25").replace('?', "%3f").replace('#', "%23");
        let uri = format!("file://{p}{}", if wal { "?mode=ro" } else { "?immutable=1" });
        let Ok(db) = Connection::open_with_flags(&uri, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI)
        else {
            return vec![];
        };
        let _ = db.busy_timeout(std::time::Duration::from_millis(200)); // the CLI writes these files while it runs
        let sql = format!("SELECT step_type, step_payload FROM steps ORDER BY idx ASC LIMIT {limit}");
        let Ok(mut stmt) = db.prepare(&sql) else { return vec![] };
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, i64>(0).unwrap_or(0), r.get::<_, Option<Vec<u8>>>(1).ok().flatten().unwrap_or_default()))
        });
        match rows {
            Ok(rows) => rows.filter_map(Result::ok).collect(),
            Err(_) => vec![],
        }
    }

    // Just enough protobuf to pull length-delimited fields out by number, following a path of nested messages.

    pub fn messages<'a>(b: &'a [u8], path: &[u64]) -> Vec<&'a [u8]> {
        path.iter().fold(vec![b], |level, n| level.into_iter().flat_map(|m| fields(m, *n)).collect())
    }

    pub fn strings(b: &[u8], path: &[u64]) -> Vec<String> {
        messages(b, path).into_iter().filter_map(|m| String::from_utf8(m.to_vec()).ok()).collect()
    }

    /// The length-delimited fields numbered `number` at the top level of `b`; stops at the first malformed byte.
    fn fields(b: &[u8], number: u64) -> Vec<&[u8]> {
        let mut out = Vec::new();
        let mut i = 0usize;
        while i < b.len() {
            let Some(key) = varint(b, &mut i) else { break };
            match key & 7 {
                0 => {
                    if varint(b, &mut i).is_none() {
                        return out;
                    }
                }
                1 => i = i.saturating_add(8),
                5 => i = i.saturating_add(4),
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
        let (mut r, mut shift) = (0u64, 0u64);
        while *i < b.len() && shift < 64 {
            let c = b[*i];
            *i += 1;
            r |= u64::from(c & 0x7f) << shift;
            if c < 0x80 {
                return Some(r);
            }
            shift += 7;
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn fixture(name: &str) -> String {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/AgentDeckTests/Fixtures")
            .join(name)
            .to_string_lossy()
            .into_owned()
    }

    fn write_log(lines: &[&str]) -> tempfile::NamedTempFile {
        let mut f = tempfile::Builder::new().suffix(".jsonl").tempfile().unwrap();
        f.write_all((lines.join("\n") + "\n").as_bytes()).unwrap();
        f
    }

    fn pairs(items: &[ChatItem]) -> Vec<(String, String)> {
        items.iter().map(|i| (i.role.clone(), i.text.clone())).collect()
    }

    fn p(r: &str, t: &str) -> (String, String) {
        (r.to_string(), t.to_string())
    }

    /// TranscriptTests.testShellModeCommandAndOutputAreShown
    #[test]
    fn shell_mode_command_and_output_are_shown() {
        let f = write_log(&[
            r#"{"type":"user","message":{"role":"user","content":"<bash-input>tsh status</bash-input>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<bash-stdout>logged in</bash-stdout><bash-stderr>warn</bash-stderr>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<bash-input>true</bash-input>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<bash-stdout></bash-stdout><bash-stderr></bash-stderr>"}}"#,
        ]);
        let got = pairs(&items(f.path().to_str().unwrap(), Agent::Claude, false));
        assert_eq!(
            got,
            vec![p("me", "! tsh status"), p("result", "logged in\nwarn"), p("me", "! true"), p("result", "(출력 없음)")]
        );
        assert_eq!(items(f.path().to_str().unwrap(), Agent::Claude, true)[3].text, "(no output)");
    }

    /// TranscriptTests.testPastedContentIsUnwrapped
    #[test]
    fn pasted_content_is_unwrapped() {
        let f = write_log(&[
            r#"{"type":"user","message":{"role":"user","content":"\n\n<pasted_content id=\"dc3d\">\nbutler status x\n| a | b |\n</pasted_content id=\"dc3d\">"}}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"이거 봐\n\n<pasted_content id=\"a1\">\nlog line\n</pasted_content id=\"a1\">"}]}}"#,
        ]);
        let got = pairs(&items(f.path().to_str().unwrap(), Agent::Claude, false));
        assert_eq!(got, vec![p("me", "butler status x\n| a | b |"), p("me", "이거 봐\n\nlog line")]);
    }

    #[test]
    fn claude_fixture() {
        let got = pairs(&items(&fixture("claude-session.jsonl"), Agent::Claude, false));
        assert_eq!(
            got,
            vec![
                p("me", "please git commit -m 'x' for me"),
                p("tool", "Bash · git add a && git commit -m \"feat: a\""),
                p("result", "  ⎿ [main 1234567] feat: a"),
                p("agent", "done"),
                p("tool", "Bash · git -C repo commit -m wip"),
                p("result", "  ⎿ nothing to commit"),
                p("tool", "Bash · git log --grep='git commit'"),
                p("result", "  ⎿ "),
            ]
        );
    }

    #[test]
    fn codex_fixture_has_no_chat_and_rollout_items_render() {
        assert!(items(&fixture("codex-rollout.jsonl"), Agent::Codex, false).is_empty());
        let f = write_log(&[
            r##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"},{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"##,
            r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>"},{"type":"input_text","text":"fix the bug"}]}}"#,
            r#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cargo test\"}"}}"#,
            r#"{"type":"response_item","payload":{"type":"function_call_output","output":"1\n2\n3\n4\n5\n6\n7\n8"}}"#,
            r#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch"}}"#,
            r#"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":{"output":"Done"}}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fixed"}]}}"#,
            r#"{"type":"event_msg","payload":{"type":"agent_message","message":"ignored"}}"#,
        ]);
        let got = pairs(&items(f.path().to_str().unwrap(), Agent::Codex, true));
        assert_eq!(
            got,
            vec![
                p("me", "fix the bug"),
                p("tool", "exec_command · cargo test"),
                p("result", "  ⎿ 1\n  ⎿ 2\n  ⎿ 3\n  ⎿ 4\n  ⎿ 5\n  ⎿ 6\n  ⎿ … +2 lines"),
                p("tool", "apply_patch · *** Begin Patch"),
                p("result", "  ⎿ Done"),
                p("agent", "fixed"),
            ]
        );
    }

    #[test]
    fn queue_slash_meta_images_and_huge_lines() {
        let huge = format!(r#"{{"type":"user","message":{{"content":"{}"}}}}"#, "x".repeat(HUGE_LINE + 1));
        let f = write_log(&[
            r#"{"type":"queue-operation","operation":"enqueue","content":"also do this"}"#,
            r#"{"type":"user","attachment":{"type":"queued_command","origin":{"kind":"human"},"prompt":"also do this"}}"#,
            r#"{"type":"user","attachment":{"type":"queued_command","origin":{"kind":"human"},"prompt":"second"}}"#,
            r#"{"type":"user","message":{"content":"<command-name>/model</command-name><command-args>haiku</command-args>"}}"#,
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name><command-args></command-args>"}}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"meta text"}}"#,
            r#"{"type":"user","message":{"content":"<system-reminder>skip</system-reminder>"}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image"},{"type":"image"}]}]}}"#,
            &huge,
        ]);
        let got = pairs(&items(f.path().to_str().unwrap(), Agent::Claude, false));
        assert_eq!(
            got,
            vec![
                p("me", "also do this"),
                p("me", "second"),
                p("me", "/model haiku"),
                p("me", "/clear"),
                p("result", "  ⎿ (이미지 등 2개 항목)"),
                p("result", "  ⎿ (이미지 등 큰 결과)"),
            ]
        );
    }

    #[test]
    fn appended_lines_extend_the_cached_tail() {
        let mut f = write_log(&[r#"{"type":"user","message":{"content":"one"}}"#]);
        let path = f.path().to_str().unwrap().to_string();
        assert_eq!(items(&path, Agent::Claude, false).len(), 1);
        // A half-written line is not read until its newline arrives.
        f.write_all(br#"{"type":"user","message":{"content":"two"}}"#).unwrap();
        assert_eq!(items(&path, Agent::Claude, false).len(), 1);
        f.write_all(b"\n").unwrap();
        let got = items(&path, Agent::Claude, false);
        assert_eq!(pairs(&got), vec![p("me", "one"), p("me", "two")]);
        assert_eq!(got[1].id, 1);
    }

    // AntigravityTests: a conversation database shaped like agy 1.4.12's, built from scratch.
    fn field(number: u64, body: &[u8]) -> Vec<u8> {
        let mut out = varint(number << 3 | 2);
        out.extend(varint(body.len() as u64));
        out.extend_from_slice(body);
        out
    }
    fn varint(mut n: u64) -> Vec<u8> {
        let mut out = vec![];
        loop {
            out.push((n & 0x7f) as u8 | if n > 0x7f { 0x80 } else { 0 });
            n >>= 7;
            if n == 0 {
                return out;
            }
        }
    }
    fn make_db(steps: &[(i64, Vec<u8>)]) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("agy.db").to_string_lossy().into_owned();
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute("CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, step_payload blob)", []).unwrap();
        for (i, (t, b)) in steps.iter().enumerate() {
            db.execute("INSERT INTO steps VALUES (?1, ?2, ?3)", rusqlite::params![i as i64, t, b]).unwrap();
        }
        (dir, path)
    }

    #[test]
    fn antigravity_steps_become_chat_entries() {
        let mut me = vec![0x08, 14];
        me.extend(field(19, &field(2, "이 폴더 파일 목록".as_bytes())));
        let mut call = field(2, b"run_command");
        call.extend(field(3, br#"{"CommandLine":"ls","toolSummary":"List files"}"#));
        let mut step = field(3, "thinking…".as_bytes());
        step.extend(field(7, &call));
        let conv = vec![
            (14, me),
            (15, field(20, &step)),
            (132, field(140, &field(2, &field(1, b"a.txt\nb.txt")))),
            (15, field(20, &field(1, "파일 두 개: a.txt, b.txt".as_bytes()))),
        ];
        let (_dir, path) = make_db(&conv);
        let got = pairs(&items(&path, Agent::Antigravity, false));
        assert_eq!(
            got,
            vec![
                p("me", "이 폴더 파일 목록"),
                p("tool", "run_command · List files"),
                p("result", "  ⎿ a.txt\n  ⎿ b.txt"),
                p("agent", "파일 두 개: a.txt, b.txt"),
            ]
        );
        let (_dir2, bad) = make_db(&[(14, vec![0x9a, 0x01, 0xff, 0xff])]); // field 19 claiming more bytes than there are
        assert!(items(&bad, Agent::Antigravity, false).is_empty());
    }

    // MobileFilesTests

    struct Home {
        _dir: tempfile::TempDir,
        home: String,
    }

    fn make_home() -> Home {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home").to_string_lossy().into_owned();
        std::fs::create_dir_all(format!("{home}/proj/out")).unwrap();
        std::fs::write(format!("{home}/proj/old.txt"), "old").unwrap();
        std::fs::write(format!("{home}/proj/out/demo.mp4"), "video").unwrap();
        std::fs::create_dir_all(format!("{home}x")).unwrap();
        std::fs::write(format!("{home}x/a"), "a").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc", format!("{home}/proj/escape")).unwrap();
        Home { _dir: dir, home }
    }

    #[test]
    fn only_paths_inside_home_resolve() {
        let h = make_home();
        let home = &h.home;
        let real = std::fs::canonicalize(home).unwrap().to_string_lossy().into_owned();
        let sep = std::path::MAIN_SEPARATOR;
        let expect = format!("{real}{sep}proj{sep}old.txt");
        assert_eq!(resolve_in_home(&format!("{home}/proj/old.txt"), home), Some(expect.clone()));
        assert_eq!(resolve_in_home(&format!("{home}/proj/../proj/old.txt"), home), Some(expect));
        assert_eq!(resolve_in_home("/etc/hosts", home), None);
        assert_eq!(resolve_in_home(&format!("{home}/../etc"), home), None);
        #[cfg(unix)]
        assert_eq!(resolve_in_home(&format!("{home}/proj/escape/hosts"), home), None, "a symlink out of home");
        assert_eq!(resolve_in_home(&format!("{home}x/a"), home), None, "a sibling folder sharing the prefix");
        assert_eq!(resolve_in_home("relative/path", home), None);
        assert_eq!(resolve_in_home("", home), None);
    }

    #[test]
    fn chat_paths_map_tokens_to_files_and_folders() {
        let h = make_home();
        let home = &h.home;
        let text = format!("결과물은 `out/demo.mp4`에 있고, 폴더 {home}/proj/out 와 없는 파일 nothing/here.mp4 는 링크 안 됨.");
        let paths = file_links_in(&text, &format!("{home}/proj"), home);
        assert_eq!(paths.get("out/demo.mp4"), Some(&format!("{home}/proj/out/demo.mp4")));
        assert_eq!(paths.get(&format!("{home}/proj/out")), Some(&format!("{home}/proj/out/")));
        assert_eq!(paths.get("nothing/here.mp4"), None);
        assert_eq!(paths.len(), 2);
    }

    #[test]
    fn chat_paths_keep_a_line_range() {
        let h = make_home();
        let home = &h.home;
        let paths = file_links_in("고친 곳: `out/demo.mp4:71-75`, old.txt:3:7", &format!("{home}/proj"), home);
        assert_eq!(paths.get("out/demo.mp4:71-75"), Some(&format!("{home}/proj/out/demo.mp4")));
        assert_eq!(paths.get("old.txt:3:7"), Some(&format!("{home}/proj/old.txt")));
    }

    #[test]
    fn file_link_edge_cases() {
        let h = make_home();
        let home = &h.home;
        let cwd = format!("{home}/proj");
        // A Korean particle glued on, a sentence-ending period, "~/", "./", "..", and a path outside home.
        let text = "old.txt와 ./out/demo.mp4. ~/proj/old.txt ../proj/out 그리고 /etc/hosts 및 a/b";
        let got = file_links_in(text, &cwd, home);
        let want: BTreeMap<String, String> = [
            ("old.txt", format!("{home}/proj/old.txt")),
            ("./out/demo.mp4", format!("{home}/proj/out/demo.mp4")),
            ("~/proj/old.txt", format!("{home}/proj/old.txt")),
            ("../proj/out", format!("{home}/proj/out/")),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        assert_eq!(got, want);
        // Unfiltered, /etc/hosts exists and is linked; the home filter is what drops it.
        assert!(paths(text, &cwd, home).contains_key("/etc/hosts"));
        // Swift's lookbehind: no match may start right after a word or path character, so "~old.txt" is not "old.txt".
        assert!(file_links_in("zz~old.txt", &cwd, home).is_empty());
        assert!(file_links_in("zz~ old.txt", &cwd, home).contains_key("old.txt"));
        // No cwd, no relative links.
        assert!(file_links_in("old.txt", "", home).is_empty());
        assert!(file_links_in("no paths here", &cwd, home).is_empty());
    }

    #[test]
    fn chat_items_drop_results_and_link_files_except_on_tools() {
        let h = make_home();
        let home = &h.home;
        let f = write_log(&[
            r#"{"type":"user","message":{"content":"look at old.txt"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"description":"old.txt"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"old"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"It says old (out/demo.mp4 too)."}]}}"#,
        ]);
        let v = chat_items_in(Some(f.path().to_str().unwrap()), Agent::Claude, &format!("{home}/proj"), false, home);
        let want = json!([
            {"role": "me", "text": "look at old.txt", "files": {"old.txt": format!("{home}/proj/old.txt")}},
            {"role": "tool", "text": "Read · old.txt"},
            {"role": "agent", "text": "It says old (out/demo.mp4 too).", "files": {"out/demo.mp4": format!("{home}/proj/out/demo.mp4")}},
        ]);
        assert_eq!(v, want);
        assert_eq!(chat_items_in(None, Agent::Claude, "/", false, home), json!([]));
    }

    /// Prints the newest items of a real Claude transcript: `cargo test --lib transcript -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn print_real_transcript() {
        let root = Path::new(&home()).join(".claude/projects");
        let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
        for d in std::fs::read_dir(&root).into_iter().flatten().flatten() {
            for f in std::fs::read_dir(d.path()).into_iter().flatten().flatten() {
                let p = f.path();
                if p.extension().is_some_and(|e| e == "jsonl") {
                    let t = f.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
                    if newest.as_ref().is_none_or(|n| t > n.0) {
                        newest = Some((t, p));
                    }
                }
            }
        }
        let (_, path) = newest.expect("no transcript");
        let path = path.to_string_lossy().into_owned();
        let all = items(&path, Agent::Claude, false);
        println!("{path}: {} items", all.len());
        for i in &all[all.len().saturating_sub(12)..] {
            println!("[{}] {}", i.role, one(&i.text));
        }
        let chat = chat_items(Some(&path), Agent::Claude, "/Users/owen/project/agent-deck", false);
        let with_files: Vec<_> = chat.as_array().unwrap().iter().filter(|o| o.get("files").is_some()).collect();
        println!("chat items: {}, with files: {}", chat.as_array().unwrap().len(), with_files.len());
        for o in with_files.iter().rev().take(3) {
            println!("files: {}", o["files"]);
        }
    }

    fn one(s: &str) -> String {
        crate::model::one_line(s, 140)
    }
}
