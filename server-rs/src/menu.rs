//! Reading menus and replies off an agent's terminal screen, and the keystrokes that answer them.
//! A port of Sources/AgentDeck/SessionInput.swift (`SessionInput`, `TerminalMenu`, `LiveReply`), HostedMenu.swift,
//! the screen-reading parts of TerminalSource.swift and `DialogueView.translate`.
//!
//! On the Mac every side effect goes through tmux (`capture-pane`, `paste-buffer`, `send-keys`). Here it goes
//! through [`Term`], which the PTY host implements for each terminal it hosts. `SessionInput.canSend` is
//! "the server has a `Term` for this session" (a terminal it hosts), so it has no function here.

use crate::model::Agent;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

/// Lines of scrollback read above the visible screen when looking for a menu or a live reply
/// (Swift `TerminalSource.read(pid:lines: 60)` = `tmux capture-pane -p -J -S -60`).
pub const SCREEN_SCROLLBACK: usize = 60;

/// Everything [`send`], [`choose`], [`answer`] … do to a terminal. tmux equivalents in brackets.
pub trait Term {
    /// The visible screen plus up to `scrollback` lines of history above it, rows joined with "\n"
    /// [`capture-pane -p -J -S -<scrollback>`; scrollback 0 = `capture-pane -p`, the visible screen only].
    /// Soft-wrapped rows should come back as one line (tmux `-J`); trailing spaces may be kept or trimmed.
    /// None when the terminal cannot be read.
    fn screen(&self, scrollback: usize) -> Option<String>;
    /// Pastes `text` as one paste, line breaks included, without pressing Enter
    /// [`load-buffer` + `paste-buffer -p -d`]. The bytes to write are [`paste_bytes`].
    fn paste(&self, text: &str) -> bool;
    /// Types one line of text literally, no Enter [`send-keys -l`]. Callers never pass line breaks.
    fn type_text(&self, text: &str) -> bool;
    /// Presses one key [`send-keys <Key::tmux()>`]. The bytes to write are [`Key::bytes`].
    fn press(&self, key: Key) -> bool;
    /// Claude Code shows a panel (/status, /config …) right now: its registry entry says `waitingFor: "dialog open"`
    /// without `needs` (`crate::sessions::claude::panel_open(home, pid)`). Only asked for Claude sessions.
    fn panel_open(&self) -> bool {
        false
    }
    /// Waits between steps. Tests override it to record the waits instead of sleeping.
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d)
    }
}

/// The keys the phone and the Mac can press (contract `/api/key` takes `tmux()` names, case-insensitively).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Up,
    Down,
    Left,
    Right,
    Tab,
    Enter,
    Escape,
    One,
    Two,
    Three,
}

impl Key {
    pub const ALL: [Key; 10] =
        [Key::Up, Key::Down, Key::Left, Key::Right, Key::Tab, Key::Enter, Key::Escape, Key::One, Key::Two, Key::Three];

    /// Button label on the Mac.
    pub fn label(self) -> &'static str {
        match self {
            Key::Up => "↑",
            Key::Down => "↓",
            Key::Left => "←",
            Key::Right => "→",
            Key::Tab => "Tab",
            Key::Enter => "⏎",
            Key::Escape => "Esc",
            Key::One => "1",
            Key::Two => "2",
            Key::Three => "3",
        }
    }

    /// tmux key name.
    pub fn tmux(self) -> &'static str {
        match self {
            Key::Up => "Up",
            Key::Down => "Down",
            Key::Left => "Left",
            Key::Right => "Right",
            Key::Tab => "Tab",
            Key::Enter => "Enter",
            Key::Escape => "Escape",
            Key::One => "1",
            Key::Two => "2",
            Key::Three => "3",
        }
    }

    /// The key for a tmux name, ignoring case (`/api/key`).
    pub fn from_name(name: &str) -> Option<Key> {
        Key::ALL.into_iter().find(|k| k.tmux().eq_ignore_ascii_case(name))
    }

    /// What a PTY host writes for the key: what tmux writes to a pane in normal cursor mode.
    /// Enter is CR, as a terminal sends it. When the program has turned on application cursor keys (DECCKM,
    /// `vt100::Screen::application_cursor()`), tmux sends the arrows as SS3 instead ("\x1bOA" …); Claude Code,
    /// Codex and Antigravity read both forms.
    pub fn bytes(self) -> &'static [u8] {
        match self {
            Key::Up => b"\x1b[A",
            Key::Down => b"\x1b[B",
            Key::Right => b"\x1b[C",
            Key::Left => b"\x1b[D",
            Key::Tab => b"\t",
            Key::Enter => b"\r",
            Key::Escape => b"\x1b",
            Key::One => b"1",
            Key::Two => b"2",
            Key::Three => b"3",
        }
    }
}

/// What `tmux paste-buffer -p` writes to a pane: line feeds become CR (its default separator), and the text is
/// wrapped in bracketed-paste markers when the program asked for them (DECSET 2004,
/// `vt100::Screen::bracketed_paste()`). Bracketed paste keeps line breaks inside one message instead of submitting
/// each line.
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() + 12);
    if bracketed {
        out.extend_from_slice(b"\x1b[200~");
    }
    out.extend_from_slice(text.replace('\n', "\r").as_bytes());
    if bracketed {
        out.extend_from_slice(b"\x1b[201~");
    }
    out
}

// ---------------------------------------------------------------------------------------------------------------
// SessionInput: typing into an agent's terminal

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// Sends a whole message and presses Enter. Returns false when the terminal refused it.
pub fn send(term: &dyn Term, agent: Agent, text: &str) -> bool {
    close_panel(term, agent);
    // Bracketed paste keeps line breaks inside one message instead of submitting each line.
    if !term.paste(text) {
        return false;
    }
    // Let the TUI take the paste before Enter; a long paste takes it longer.
    term.sleep(Duration::from_micros((150_000 + text.len() as u64 * 200).min(800_000)));
    if !term.press(Key::Enter) {
        return false;
    }
    // An Enter that lands while the TUI is still busy with the paste (or picks a slash-command suggestion)
    // leaves the message in the input box, and the next message gets glued onto it. Press again until it is gone.
    for attempt in 1..=3u64 {
        term.sleep(ms(250 * attempt));
        match term.screen(0) {
            Some(screen) if still_typed(text, &screen) => {
                term.press(Key::Enter);
            }
            _ => break,
        }
    }
    true
}

/// A message typed while a Claude Code panel (/status, /config …) is open goes into the panel and is lost,
/// so close it first. Menus (permission, question, model picker) are left for the user to answer.
pub fn close_panel(term: &dyn Term, agent: Agent) {
    if agent != Agent::Claude || !term.panel_open() {
        return;
    }
    match term.screen(SCREEN_SCROLLBACK) {
        Some(screen) if TerminalMenu::parse(&screen).is_none() => {}
        _ => return,
    }
    // /config takes the first Esc to leave its search box. Press again only while the registry still shows
    // the panel: a second Esc on the empty prompt would open the rewind menu.
    for _ in 0..3 {
        if !term.press(Key::Escape) {
            return;
        }
        for _ in 0..6 {
            term.sleep(ms(100));
            if !term.panel_open() {
                term.sleep(ms(100));
                return;
            }
        }
    }
}

/// Types text without pressing Enter (e.g. into a menu's "Type something" row); line breaks become spaces.
pub fn type_text(term: &dyn Term, text: &str) -> bool {
    term.type_text(&one_line_input(text))
}

/// Presses one key.
pub fn press(term: &dyn Term, key: Key) -> bool {
    term.press(key)
}

/// Moves the highlight from `menu.selected` to `index` with arrow keys, then confirms.
pub fn choose(term: &dyn Term, menu: &TerminalMenu, index: usize) -> bool {
    if !move_to(term, menu, index) {
        return false;
    }
    term.press(Key::Enter)
}

/// Answers a free-text row: moves the highlight onto it and types. A single-select question also needs Enter;
/// a checkbox row is ticked by the typing itself.
pub fn answer(term: &dyn Term, menu: &TerminalMenu, index: usize, text: &str) -> bool {
    if !move_to(term, menu, index) || !type_text(term, text) {
        return false;
    }
    if menu.is_multi_select() {
        return true;
    }
    term.sleep(ms(150));
    term.press(Key::Enter)
}

fn move_to(term: &dyn Term, menu: &TerminalMenu, index: usize) -> bool {
    let steps = index as isize - menu.selected as isize;
    for _ in 0..steps.unsigned_abs() {
        if !term.press(if steps > 0 { Key::Down } else { Key::Up }) {
            return false;
        }
        term.sleep(ms(60));
    }
    term.sleep(ms(80));
    true
}

/// `POST /api/choose`: picks option `index` of the menu on screen now; `text` answers a "Type something" row
/// (trimmed; such a row needs text). False when no menu shows or it has no such option.
pub fn choose_on_screen(term: &dyn Term, index: usize, text: &str) -> bool {
    let Some(menu) = term.screen(SCREEN_SCROLLBACK).and_then(|s| TerminalMenu::parse(&s)) else { return false };
    if index >= menu.options.len() {
        return false;
    }
    if menu.is_free_text(index) {
        let text = text.trim();
        return !text.is_empty() && answer(term, &menu, index, text);
    }
    choose(term, &menu, index)
}

/// What sits in the agent's input box: Claude Code draws it between the last two rules ("❯ …"),
/// Codex shows a "›" line near the bottom. None when the screen shows neither.
pub fn draft(screen: &str) -> Option<String> {
    let lines: Vec<&str> = screen.split('\n').collect();
    let rules: Vec<usize> = (0..lines.len())
        .filter(|&i| {
            let t = trim_ws(lines[i]);
            t.chars().count() >= 10 && t.chars().all(|c| c == '─')
        })
        .collect();
    if rules.len() >= 2 {
        let (top, bottom) = (rules[rules.len() - 2], rules[rules.len() - 1]);
        let joined = lines[top + 1..bottom].join("\n");
        let b = joined.trim();
        return Some(if b.starts_with('❯') || b.starts_with('>') { drop_first(b) } else { b }.to_string());
    }
    let tail = &lines[lines.len().saturating_sub(8)..];
    tail.iter().rev().find(|l| trim_ws(l).starts_with('›')).map(|l| drop_first(trim_ws(l)).to_string())
}

/// Whether `text` is still waiting in the input box: its last characters (spaces and line wraps ignored), or a
/// collapsed "[Pasted text …]" placeholder.
pub fn still_typed(text: &str, screen: &str) -> bool {
    let Some(b) = draft(screen) else { return false };
    let squeeze = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    let all: Vec<char> = squeeze(text).chars().collect();
    let tail: String = all[all.len().saturating_sub(12)..].iter().collect();
    let in_box = squeeze(&b);
    !tail.is_empty() && in_box.contains(&tail) || in_box.contains("[Pastedtext")
}

/// Swift `split(whereSeparator: \.isNewline).joined(separator: " ")`.
fn one_line_input(s: &str) -> String {
    s.split(|c: char| matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------------------------------------------
// TerminalMenu

/// A selection menu the agent's TUI is showing (permission prompts, questions, trust checks).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalMenu {
    pub options: Vec<MenuOption>,
    pub selected: usize,
    /// What is being asked, read from the screen above the options: the question line
    /// ("Do you want to proceed?") and the context block (tool, command, file) under the last border.
    pub question: Option<String>,
    pub context: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuOption {
    pub label: String,
    pub detail: Option<String>,
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("valid regex"))
}
static NUMBERED: OnceLock<Regex> = OnceLock::new();
static FREE_TEXT: OnceLock<Regex> = OnceLock::new();
static PREVIEW_BOX: OnceLock<Regex> = OnceLock::new();
static NUMBER_PREFIX: OnceLock<Regex> = OnceLock::new();
static TOOL_HEAD: OnceLock<Regex> = OnceLock::new();

fn numbered(s: &str) -> bool {
    re(&NUMBERED, r"^\d+\.").is_match(s)
}

impl TerminalMenu {
    /// Finds the menu just above a footer hint like "Enter to confirm · Esc to cancel".
    /// The highlighted option starts with "❯" at some column; the others start two columns further in,
    /// and deeper-indented lines are descriptions of the option above them.
    pub fn parse(screen: &str) -> Option<TerminalMenu> {
        let lines: Vec<&str> = screen.split('\n').collect();
        let blank = |i: usize| trim_ws(lines[i]).is_empty();
        // The review step of a multi-question/multi-select AskUserQuestion has no footer: end at the last line.
        // Claude Code: "Enter to confirm · Esc to cancel"; Codex: "enter select · esc back", "esc to cancel",
        // "enter continue · esc use session · ⌃c quit" (0.162's working-directory question on resume).
        let hint = lines.iter().rposition(|l| {
            let h = l.to_lowercase();
            ["enter to confirm", "enter to select", "esc to cancel", "enter select", "esc back", "enter continue", "↑/↓ navigate"]
                .iter()
                .any(|k| h.contains(k))
        });
        let review = if lines.iter().any(|l| l.contains("Ready to submit your answers?")) {
            (0..lines.len()).rposition(|i| !blank(i)).map(|i| i + 1)
        } else {
            None
        };
        let mut footer = hint.or(review)?;
        // Antigravity CLI: "↑/↓ Navigate · enter Confirm" right under the options, "esc to cancel" below that. Its
        // highlight is ">", the same as its input box and sent prompts, so ">" counts only above this footer.
        // The slash-command popup ("… · tab Complete") is autocomplete, not a question.
        let lo = footer.saturating_sub(2);
        let navigate = (lo..=footer.min(lines.len() - 1)).rev().find(|&i| lines[i].contains("↑/↓ Navigate"));
        if let Some(n) = navigate {
            if lines[n].contains("tab Complete") {
                return None;
            }
            footer = n;
        }
        // The highlighted line closest above the footer ("❯" in Claude Code, "›" in Codex, ">" in Antigravity).
        let sel = (0..footer).rev().find(|&i| {
            indent_of(lines[i]).is_some_and(|ind| {
                let t = line_tail(lines[i], ind);
                t.starts_with('❯') || t.starts_with('›') || navigate.is_some() && t.starts_with('>')
            })
        })?;
        if footer - sel >= 40 {
            return None;
        }
        let col = indent_of(lines[sel])?;
        let is_numbered = numbered(trim_ws(drop_first(line_tail(lines[sel], col))));
        let option_text = |i: usize| -> Option<String> {
            let l = lines[i];
            let ind = indent_of(l)?;
            let tail = line_tail(l, ind);
            if i == sel {
                return Some(trim_ws(drop_first(tail)).to_string());
            }
            // Multi-select lists end with a "Submit" row ("Next" when more questions follow), indented like the
            // option labels, not the numbers.
            if tail == "Submit" || tail == "Next" {
                return Some(tail.to_string());
            }
            if ind != col + 2 {
                return None;
            }
            // Codex draws its menu at the left edge, level with the text above it: when the options are numbered,
            // only numbered lines are options.
            (!is_numbered || numbered(tail)).then(|| tail.to_string())
        };
        // Grow the block both ways from the highlighted line.
        let mut first = sel;
        for i in (0..sel).rev() {
            if blank(i) {
                continue;
            }
            match indent_of(lines[i]) {
                Some(ind) if ind >= col + 2 => {}
                _ => break,
            }
            if option_text(i).is_some() {
                first = i;
            }
        }
        let mut options: Vec<MenuOption> = vec![];
        let mut selected = 0;
        for j in first..footer {
            if let Some(t) = option_text(j) {
                if j == sel {
                    selected = options.len();
                }
                options.push(MenuOption { label: clean(&t), detail: None });
            } else if let (Some(ind), Some(last)) = (indent_of(lines[j]), options.last_mut()) {
                if ind <= col + 2 {
                    continue;
                }
                let d = line_tail(lines[j], ind);
                // AskUserQuestion with previews draws a box to the right of the options; its rows are not descriptions.
                if d.starts_with('┌') || d.starts_with('│') || d.starts_with('└') || d.starts_with("Notes: press n") {
                    continue;
                }
                last.detail = Some(match last.detail.take() {
                    Some(prev) => format!("{prev} {d}"),
                    None => d.to_string(),
                });
            }
        }
        if options.len() < 2 {
            return None;
        }
        // Context: lines between the box's top border (───) and the first option, minus tips and separators.
        // Codex 0.166 draws no border: its block starts after two or more blank lines that set it off from the
        // transcript (the blank lines right above the options do not count).
        let mut gap: Option<usize> = None;
        let mut row = first as isize - 1;
        while row >= 0 && blank(row as usize) {
            row -= 1;
        }
        let floor = (first as isize - 30).max(0);
        while row > floor {
            if blank(row as usize) && blank(row as usize - 1) {
                gap = Some(row as usize);
                break;
            }
            row -= 1;
        }
        let top = (0..first)
            .rev()
            .find(|&i| trim_ws(lines[i]).starts_with("──"))
            .or(gap)
            .unwrap_or(first.saturating_sub(30));
        let mut ctx: Vec<String> = lines[(top + 1).min(first)..first]
            .iter()
            .map(|l| {
                let t = trim_ws(l);
                match t.strip_prefix('│') {
                    Some(rest) => trim_ws(rest),
                    None => t,
                }
            })
            .filter(|t| {
                !t.is_empty()
                    && !t.starts_with('╌')
                    && !t.starts_with("──")
                    && !t.starts_with("Tip:")
                    && !t.starts_with("⎿  Tip")
            })
            .map(str::to_string)
            .collect();
        let mut question = None;
        if ctx.last().is_some_and(|q| q.ends_with('?')) {
            question = ctx.pop();
        } else if gap.is_some() && ctx.first().is_some_and(|q| q.ends_with('?')) {
            // Codex asks first and lists the details under it ("Would you like to run the following command?").
            question = Some(ctx.remove(0));
        }
        let context = (!ctx.is_empty()).then(|| ctx[ctx.len().saturating_sub(14)..].join("\n"));
        Some(TerminalMenu { options, selected, question, context })
    }

    /// AskUserQuestion's free-text row: "Type something." (single) or "[ ] Type something" (multi-select).
    pub fn is_free_text(&self, i: usize) -> bool {
        self.options.get(i).is_some_and(|o| re(&FREE_TEXT, r"^(\[.\] )?Type something\.?$").is_match(&o.label))
    }

    /// Checkbox rows: typing into the free-text row ticks it, no Enter needed.
    pub fn is_multi_select(&self) -> bool {
        self.options.iter().any(|o| o.label.starts_with("[ ] ") || o.label.starts_with("[✔] "))
    }
}

/// Columns of leading spaces; None for a line that is empty or all spaces.
fn indent_of(l: &str) -> Option<usize> {
    let n = l.bytes().take_while(|b| *b == b' ').count();
    (n < l.len()).then_some(n)
}

fn line_tail(l: &str, n: usize) -> &str {
    trim_ws(&l[n..])
}

/// "2. Yes, and don't ask again" -> "Yes, and don't ask again"; a preview box to the right of the label is dropped.
fn clean(s: &str) -> String {
    let s = match re(&PREVIEW_BOX, r"\s{2,}[┌│└].*$").find(s) {
        Some(m) => &s[..m.start()],
        None => s,
    };
    match re(&NUMBER_PREFIX, r"^\d+\.\s+").find(s) {
        Some(m) => s[m.end()..].to_string(),
        None => s.to_string(),
    }
}

/// Swift `CharacterSet.whitespaces`: tab and the space separators (Zs), not line breaks.
fn is_ws(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_ws)
}

fn drop_first(s: &str) -> &str {
    let mut c = s.chars();
    c.next();
    c.as_str()
}

/// Strips the right padding (spaces only) Claude Code adds to fill the terminal width.
fn trim_right_spaces(l: &str) -> &str {
    l.trim_end_matches(' ')
}

// ---------------------------------------------------------------------------------------------------------------
// HostedMenu: menus on hosted terminals whose agent has no session yet (e.g. the folder trust check)

/// The menu the hosted terminal shows now, if any (visible screen only, like `capture-pane -p`).
pub fn hosted_menu(term: &dyn Term) -> Option<TerminalMenu> {
    TerminalMenu::parse(&term.screen(0)?)
}

/// `POST /api/choose-hosted`: picks option `index` of the menu the terminal shows now (moves the highlight, then Enter).
pub fn hosted_choose(term: &dyn Term, index: usize) -> bool {
    match hosted_menu(term) {
        Some(menu) if index < menu.options.len() => choose(term, &menu, index),
        _ => false,
    }
}

// ---------------------------------------------------------------------------------------------------------------
// LiveReply and screen views

/// What the agent is writing right now, scraped from the terminal screen of a Claude Code session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveReply {
    pub text: String,
    /// Spinner line, e.g. "Cogitating… (12s · ↑ 300 tokens)".
    pub status: Option<String>,
    /// The current turn exactly as the terminal shows it: from the latest prompt down to the input box.
    pub raw: String,
}

const SPINNERS: [char; 8] = ['✻', '✶', '✳', '✢', '✽', '·', '*', '⏺'];

/// Drops the input box: everything from the ──── border above the last line starting with "❯".
fn cut_input_box(lines: &mut Vec<&str>) {
    if let Some(b) = (1..lines.len())
        .rev()
        .find(|&i| trim_ws(lines[i]).starts_with('❯') && trim_ws(lines[i - 1]).starts_with('─'))
    {
        lines.truncate(b - 1);
    }
}

impl LiveReply {
    /// The current turn as the terminal shows it (contract `live`): from the user's latest prompt echo down to
    /// the input box, right padding trimmed, at most 60 lines.
    pub fn turn(screen: &str) -> String {
        let mut lines: Vec<&str> = screen.split('\n').collect();
        cut_input_box(&mut lines);
        // Start at the user's latest prompt echo ("❯ …" at the left edge) if it is on screen.
        if let Some(start) = lines.iter().rposition(|l| l.starts_with("❯ ")) {
            lines.drain(..start);
        }
        while lines.last().is_some_and(|l| trim_ws(l).is_empty()) {
            lines.pop();
        }
        while lines.first().is_some_and(|l| trim_ws(l).is_empty()) {
            lines.remove(0);
        }
        let lines: Vec<&str> = lines.into_iter().map(trim_right_spaces).collect();
        lines[lines.len().saturating_sub(60)..].join("\n")
    }

    /// The reply being written (newest "⏺ " text block) and the spinner status. None when there is neither.
    /// `already_logged`: the newest finished message in the log; a reply that starts like it is not live.
    pub fn parse(screen: &str, already_logged: Option<&str>) -> Option<LiveReply> {
        let mut lines: Vec<&str> = screen.split('\n').collect();
        cut_input_box(&mut lines);
        // Below the reply Claude Code prints a spinner line ("· Transmuting… (2m 3s · ↓ 7.7k tokens)"),
        // sometimes a "⎿ Tip" hint and right-aligned notices ("✔ Update installed"). Take the spinner as status
        // and cut everything from it down.
        let mut status: Option<String> = None;
        let tail_start = lines.len().saturating_sub(8);
        if let Some(i) = (tail_start..lines.len()).rev().find(|&i| {
            let t = trim_ws(lines[i]);
            match t.chars().next() {
                Some(f) if f != '⏺' && f != '⎿' && f != '✔' => SPINNERS.contains(&f) && t.contains('…'),
                _ => false,
            }
        }) {
            status = Some(trim_ws(drop_first(trim_ws(lines[i]))).to_string());
            lines.truncate(i);
        }
        while let Some(l) = lines.last().map(|l| trim_ws(l)) {
            if l.is_empty() || l.starts_with("⎿  Tip") || l.starts_with('✔') {
                lines.pop();
            } else {
                break;
            }
        }
        let status_only = |status: Option<String>| status.map(|s| LiveReply { text: String::new(), status: Some(s), raw: String::new() });
        // The newest "⏺ " block that is text (not a tool call like "⏺ Bash(…)").
        let Some(start) = lines.iter().rposition(|l| l.starts_with("⏺ ")) else { return status_only(status) };
        let head = drop_first(drop_first(lines[start]));
        // Tool calls are "⏺ Bash(…)" or, in compact view, "⏺ <description>" followed by "⎿" output lines.
        let next_line = lines[start + 1..].iter().find(|l| !trim_ws(l).is_empty());
        let is_tool = re(&TOOL_HEAD, r"^[A-Za-z_]+\(").is_match(head)
            || next_line.is_some_and(|l| trim_ws(l).starts_with('⎿'));
        let mut body: Vec<&str> = vec![head];
        body.extend(
            lines[start + 1..]
                .iter()
                .filter(|l| !l.contains("ctrl+enter to send") && !l.contains("esc to interrupt")) // UI hints, not reply text
                .map(|l| l.strip_prefix("  ").unwrap_or(l)),
        );
        while body.last().is_some_and(|l| trim_ws(l).is_empty()) {
            body.pop();
        }
        let text = body.join("\n");
        // Already in the log as a finished message: nothing live to add.
        let norm = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
        let logged = already_logged.is_some_and(|l| {
            let prefix: String = norm(&text).chars().take(60).collect();
            norm(l).starts_with(&prefix)
        });
        if is_tool || logged {
            return status_only(status);
        }
        Some(LiveReply { text, status, raw: String::new() })
    }
}

/// The terminal view `/api/chat?screen=1` sends: right padding trimmed, trailing empty lines dropped, last 40 lines.
pub fn screen_view(screen: &str) -> String {
    let mut lines: Vec<&str> = screen.split('\n').map(trim_right_spaces).collect();
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    lines[lines.len().saturating_sub(40)..].join("\n")
}

/// A menu question as the phone shows it (`menuQuestion`, `prompts[].question`): in Korean, known Claude Code
/// questions get a translation in front ("이대로 진행할까요? — Do you want to proceed?"). `en`: English UI, unchanged.
pub fn translate(question: &str, en: bool) -> String {
    if en {
        return question.to_string();
    }
    const KNOWN: [(&str, &str); 4] = [
        ("Do you want to proceed?", "이대로 진행할까요?"),
        ("Do you want to make this edit", "이 파일을 수정할까요?"),
        ("Do you want to create", "이 파일을 만들까요?"),
        ("Do you want to allow", "허용할까요?"),
    ];
    for (en_q, ko) in KNOWN {
        if question.starts_with(en_q) {
            return format!("{ko} — {question}");
        }
    }
    question.to_string()
}

// ---------------------------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn rule() -> String {
        "─".repeat(40)
    }

    fn fixture(name: &str) -> String {
        let path = format!("{}/../Tests/AgentDeckTests/Fixtures/screens/{name}.txt", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    /// A Swift multi-line literal whose closing `"""` sat 8 columns in: strip that indentation.
    fn swift_literal(s: &str) -> String {
        s.trim_start_matches('\n')
            .trim_end_matches(|c| c == ' ' || c == '\n')
            .split('\n')
            .map(|l| if l.len() >= 8 && l[..8].trim().is_empty() { &l[8..] } else { l.trim_start_matches(' ') })
            .collect::<Vec<_>>()
            .join("\n")
            .replace("{rule}", &rule())
    }

    fn labels(m: &TerminalMenu) -> Vec<&str> {
        m.options.iter().map(|o| o.label.as_str()).collect()
    }

    // --- SessionInputTests.swift

    fn claude_box(b: &str) -> String {
        let r = rule();
        format!("⏺ 이전 답변\n\n{r}\n❯ {b}\n{r}\n   ◆ Opus 5.5 │ ~/project\n  ⏵⏵ bypass permissions on")
    }

    #[test]
    fn menu_message_left_in_claude_input_box_is_detected() {
        let text = "길드 결정 메뉴에서 각 캐릭터에 호버하면 정보를 보여줘";
        assert!(still_typed(text, &claude_box(text)));
        // Wrapped across lines in the box.
        assert!(still_typed(text, &claude_box("길드 결정 메뉴에서 각 캐릭터에 호버하면\n  정보를 보여줘")));
        assert!(still_typed(text, &claude_box("[Pasted text #1 +12 lines]")));
    }

    #[test]
    fn menu_submitted_message_is_not_detected() {
        let text = "운영서버 배포해줘";
        let r = rule();
        // Submitted: echoed above the box, box empty.
        let screen = format!("> {text}\n\n✢ Swirling…\n{r}\n❯ \n{r}\n  ⏵⏵ bypass permissions on");
        assert!(!still_typed(text, &screen));
        assert!(!still_typed(text, "zsh: plain shell\n$ "));
    }

    #[test]
    fn menu_codex_prompt_line() {
        let text = "테스트 돌려줘";
        assert!(still_typed(text, "• 작업 완료\n\n› 테스트 돌려줘\n\n  ⏎ send   ⌃J newline"));
        assert!(!still_typed(text, "› 테스트 돌려줘\n\n• 작업 중\n\n› Ask Codex to do anything\n  ⏎ send"));
    }

    /// AskUserQuestion with previews draws the focused option's preview in a box to the right of the options
    /// (captured from Claude Code v2.1.296): the box is not part of the labels or their descriptions.
    #[test]
    fn menu_with_preview_pane() {
        let screen = swift_literal(
            r#"
         ☐ Format

        이 지적, 어떻게 볼까요?

        ❯ 1. 한 번에 3개 (추천)           ┌──────────────────────────────────────────┐
          2. 지금처럼 2단계 질문          │ ┌ demo ┐                                 │
                                          │ ( ) 맞는 지적 · 계속 알려줘              │
                                          │ → 근거(file:line 등)                     │
                                          └──────────────────────────────────────────┘

                                          Notes: press n to add notes

        {rule}
          Chat about this

        Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
        "#,
        );
        let m = TerminalMenu::parse(&screen).expect("menu");
        assert_eq!(
            m.options,
            vec![
                MenuOption { label: "한 번에 3개 (추천)".into(), detail: None },
                MenuOption { label: "지금처럼 2단계 질문".into(), detail: None },
            ]
        );
        assert_eq!(m.selected, 0);
        assert_eq!(m.question.as_deref(), Some("이 지적, 어떻게 볼까요?"));
    }

    /// A multi-select question followed by more questions ends with "Next", not "Submit" (Claude Code v2.1.300).
    #[test]
    fn menu_multi_select_with_more_questions_keeps_next_row() {
        let screen = swift_literal(
            r#"
        {rule}
        ←  ☐ Fruits  ☐ Color  ✔ Submit  →

        Which fruits do you like?

        ❯ 1. [ ] Apple
                 Crisp and slightly tart
          2. [ ] Banana
                 Soft and sweet
          3. [ ] Cherry
                 Small and juicy
          4. [ ] Type something
             Next
        {rule}
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        "#,
        );
        let m = TerminalMenu::parse(&screen).expect("menu");
        assert_eq!(labels(&m), ["[ ] Apple", "[ ] Banana", "[ ] Cherry", "[ ] Type something", "Next", "Chat about this"]);
        assert_eq!(m.options[0].detail.as_deref(), Some("Crisp and slightly tart"));
        assert_eq!(m.selected, 0);
        assert_eq!(m.question.as_deref(), Some("Which fruits do you like?"));
        assert!(m.is_multi_select());
        assert!(m.is_free_text(3));
        assert!(!m.is_free_text(0));
    }

    // --- ScreenFixtureTests.swift

    #[test]
    fn menu_fixture_claude_folder_trust() {
        let m = TerminalMenu::parse(&fixture("claude-trust")).expect("menu");
        assert_eq!(labels(&m), ["No, exit", "Yes, I trust this folder"]);
        assert_eq!(m.selected, 0); // 2.1.312 highlights "No, exit"
    }

    #[test]
    fn menu_fixture_claude_permission() {
        let m = TerminalMenu::parse(&fixture("claude-permission")).expect("menu");
        assert_eq!(m.question.as_deref(), Some("Do you want to proceed?"));
        assert_eq!(
            labels(&m),
            [
                "Yes",
                "Yes, and always allow access to",
                "Yes, and switch to auto mode · auto mode handles these prompts for you",
                "No"
            ]
        );
        assert!(m.options[1].detail.as_deref().unwrap_or("").ends_with("from this project")); // the wrapped rest of the label
        assert!(m.context.as_deref().unwrap_or("").contains("rm now.txt"));
        assert!(!m.context.as_deref().unwrap_or("Tip:").contains("Tip:"));
    }

    #[test]
    fn menu_fixture_codex_folder_trust() {
        let m = TerminalMenu::parse(&fixture("codex-trust")).expect("menu");
        assert_eq!(labels(&m), ["Trust and continue", "Back to Agent Command Center"]);
    }

    #[test]
    fn menu_fixture_codex_resume_directory_question() {
        let m = TerminalMenu::parse(&fixture("codex-resume-cwd-menu")).expect("menu");
        assert_eq!(
            labels(&m),
            [
                "Use session directory (/tmp/other-session/",
                "Use current directory (/tmp/",
                "Always use session directory",
                "Always use current directory"
            ]
        );
        assert_eq!(m.selected, 0);
    }

    /// Codex 0.166.0 opens straight on the input box and draws its approval prompt without a border.
    #[test]
    fn menu_fixture_codex166_approval() {
        let m = TerminalMenu::parse(&fixture("codex166-approval")).expect("menu");
        assert_eq!(m.question.as_deref(), Some("Would you like to run the following command?"));
        assert_eq!(
            labels(&m),
            [
                "Yes, proceed (y)",
                "Yes, and don't ask again for commands that start with `date > now.txt` (p)",
                "No, and tell Codex what to do differently (esc)"
            ]
        );
        let ctx = m.context.expect("context");
        assert_eq!(ctx.split('\n').last(), Some("$ date > now.txt"));
        assert!(!ctx.contains("/init")); // the welcome text above the transcript is not context
    }

    #[test]
    fn menu_fixture_codex166_screens_without_menu() {
        for name in ["codex166-idle", "codex166-typed", "codex166-replied"] {
            assert_eq!(TerminalMenu::parse(&fixture(name)), None, "{name}");
        }
        assert!(still_typed("이 폴더의 파일 목록을 알려줘", &fixture("codex166-typed")));
        assert!(!still_typed("Run exactly this shell command: date > now.txt", &fixture("codex166-replied")));
    }

    /// Antigravity CLI 1.4.12 highlights with ">", like its input box and the prompts it echoes.
    #[test]
    fn menu_fixture_antigravity_folder_trust() {
        let m = TerminalMenu::parse(&fixture("agy-trust")).expect("menu");
        assert_eq!(labels(&m), ["Yes, I trust this folder", "No, exit"]);
        assert_eq!(m.selected, 0);
    }

    #[test]
    fn menu_fixture_antigravity_permission() {
        let m = TerminalMenu::parse(&fixture("agy-permission")).expect("menu");
        assert_eq!(m.question.as_deref(), Some("Run this command?"));
        assert_eq!(m.options.len(), 4);
        assert_eq!(m.options[0].label, "Yes, run command");
        assert_eq!(m.options[3].label, "No, cancel");
        assert!(m.context.as_deref().unwrap_or("").contains("date > now.txt"));
    }

    #[test]
    fn menu_fixture_antigravity_screens_without_menu() {
        for name in ["agy-idle", "agy-typed", "agy-working", "agy-replied", "agy-slash"] {
            assert_eq!(TerminalMenu::parse(&fixture(name)), None, "{name}");
        }
    }

    #[test]
    fn menu_fixture_unsent_text_in_antigravity_input_box() {
        assert!(still_typed("이 폴더의 파일 목록을 알려줘", &fixture("agy-typed")));
        assert!(!still_typed("이 폴더의 파일 목록을 알려줘", &fixture("agy-idle")));
        assert!(!still_typed("Run the shell command: date > now.txt", &fixture("agy-replied")));
    }

    #[test]
    fn menu_fixture_no_menu_when_idle_working_or_done() {
        for name in ["claude-idle", "claude-typed", "claude-working", "claude-replied", "codex-idle"] {
            assert_eq!(TerminalMenu::parse(&fixture(name)), None, "{name}");
        }
    }

    #[test]
    fn menu_fixture_unsent_text_in_claude_input_box() {
        assert!(still_typed("이 저장소의 파일 목록을 알려줘", &fixture("claude-typed")));
        assert!(!still_typed("이 저장소의 파일 목록을 알려줘", &fixture("claude-idle")));
        // Sent and answered: the prompt is in the scrollback, the box is empty.
        let sent = "Run exactly this shell command with the Bash tool: date > now.txt";
        assert!(!still_typed(sent, &fixture("claude-replied")));
    }

    #[test]
    fn menu_fixture_working_spinner_is_the_live_status() {
        let live = LiveReply::parse(&fixture("claude-working"), None).expect("live");
        assert!(live.status.as_deref().unwrap_or("").starts_with("Cascading"));
    }

    /// Panels (2.1.314) are not menus, so a message sent into one closes it first instead of waiting behind it.
    #[test]
    fn menu_fixture_panels_are_not_menus() {
        assert_eq!(TerminalMenu::parse(&fixture("claude-status-panel")), None);
        assert_eq!(TerminalMenu::parse(&fixture("claude-config-panel")), None);
        // The model picker is also "dialog open" in the registry, but it is a menu: left for the user to answer.
        assert_eq!(TerminalMenu::parse(&fixture("claude-model-menu")).map(|m| m.selected), Some(1));
    }

    // --- Pure helpers

    #[test]
    fn menu_keys_by_tmux_name() {
        assert_eq!(Key::from_name("escape"), Some(Key::Escape));
        assert_eq!(Key::from_name("ENTER"), Some(Key::Enter));
        assert_eq!(Key::from_name("2"), Some(Key::Two));
        assert_eq!(Key::from_name("C-c"), None);
        assert_eq!(Key::Up.bytes(), b"\x1b[A");
        assert_eq!(Key::Enter.bytes(), b"\r");
    }

    #[test]
    fn menu_paste_bytes_like_tmux_paste_buffer() {
        assert_eq!(paste_bytes("a\nb", true), b"\x1b[200~a\rb\x1b[201~".to_vec());
        assert_eq!(paste_bytes("a\nb", false), b"a\rb".to_vec());
    }

    #[test]
    fn menu_translate_known_questions() {
        assert_eq!(translate("Do you want to proceed?", false), "이대로 진행할까요? — Do you want to proceed?");
        assert_eq!(translate("Do you want to create now.txt?", false), "이 파일을 만들까요? — Do you want to create now.txt?");
        assert_eq!(translate("Do you want to proceed?", true), "Do you want to proceed?");
        assert_eq!(translate("Run this command?", false), "Run this command?");
    }

    #[test]
    fn menu_live_turn_starts_at_prompt_and_stops_at_box() {
        let r = rule();
        let screen = format!("old\n❯ 질문   \n\n⏺ 답변 중   \n\n{r}\n❯ \n{r}\n  status");
        assert_eq!(LiveReply::turn(&screen), "❯ 질문\n\n⏺ 답변 중");
        let live = LiveReply::parse(&format!("⏺ Hello\n  world\n\n✻ Thinking… (3s)\n{r}\n❯ \n{r}"), None).unwrap();
        assert_eq!(live.text, "Hello\nworld");
        assert_eq!(live.status.as_deref(), Some("Thinking… (3s)"));
        // A tool call is not live text, and neither is a message already in the log.
        assert_eq!(LiveReply::parse("⏺ Bash(ls)\n  ⎿  a", None), None);
        assert_eq!(LiveReply::parse("⏺ Hello\n  world", Some("Hello world!")), None);
    }

    #[test]
    fn menu_screen_view_trims() {
        assert_eq!(screen_view("a   \nb \n\n\n"), "a\nb");
    }

    // --- Keystrokes against a fake terminal (Swift's tmux calls → trait calls)

    #[derive(Debug, PartialEq, Eq, Clone)]
    enum Ev {
        Screen(usize),
        Paste(String),
        Type(String),
        Key(Key),
        Sleep(u64), // ms
        Panel,
    }

    #[derive(Default)]
    struct Fake {
        log: RefCell<Vec<Ev>>,
        /// Screens returned by successive `screen` calls; the last one repeats.
        screens: RefCell<Vec<String>>,
        /// Answers to successive `panel_open` calls; false when used up.
        panel: RefCell<Vec<bool>>,
    }

    impl Fake {
        fn with_screens(screens: &[&str]) -> Fake {
            Fake { screens: RefCell::new(screens.iter().map(|s| s.to_string()).collect()), ..Default::default() }
        }
        fn events(&self) -> Vec<Ev> {
            self.log.borrow().clone()
        }
        fn keys(&self) -> Vec<Ev> {
            self.events().into_iter().filter(|e| matches!(e, Ev::Key(_) | Ev::Type(_) | Ev::Paste(_))).collect()
        }
    }

    impl Term for Fake {
        fn screen(&self, scrollback: usize) -> Option<String> {
            self.log.borrow_mut().push(Ev::Screen(scrollback));
            let mut s = self.screens.borrow_mut();
            if s.len() > 1 {
                Some(s.remove(0))
            } else {
                s.first().cloned()
            }
        }
        fn paste(&self, text: &str) -> bool {
            self.log.borrow_mut().push(Ev::Paste(text.into()));
            true
        }
        fn type_text(&self, text: &str) -> bool {
            self.log.borrow_mut().push(Ev::Type(text.into()));
            true
        }
        fn press(&self, key: Key) -> bool {
            self.log.borrow_mut().push(Ev::Key(key));
            true
        }
        fn panel_open(&self) -> bool {
            self.log.borrow_mut().push(Ev::Panel);
            let mut p = self.panel.borrow_mut();
            if p.is_empty() {
                false
            } else {
                p.remove(0)
            }
        }
        fn sleep(&self, d: Duration) {
            self.log.borrow_mut().push(Ev::Sleep(d.as_millis() as u64));
        }
    }

    #[test]
    fn menu_send_pastes_presses_enter_and_checks_the_box() {
        let empty = claude_box("");
        let t = Fake::with_screens(&[&empty]);
        assert!(send(&t, Agent::Codex, "줄 하나\n줄 둘"));
        // 18 UTF-8 bytes: 150 ms + 18 × 0.2 ms.
        assert_eq!(
            t.events(),
            vec![
                Ev::Paste("줄 하나\n줄 둘".into()),
                Ev::Sleep(153),
                Ev::Key(Key::Enter),
                Ev::Sleep(250),
                Ev::Screen(0),
            ]
        );
    }

    #[test]
    fn menu_send_presses_enter_again_while_the_text_stays_in_the_box() {
        let text = "운영서버 배포해줘";
        let (stuck, empty) = (claude_box(text), claude_box(""));
        let t = Fake::with_screens(&[&stuck, &stuck, &empty]);
        assert!(send(&t, Agent::Claude, text));
        assert_eq!(
            t.events(),
            vec![
                Ev::Panel,
                Ev::Paste(text.into()),
                Ev::Sleep(155),
                Ev::Key(Key::Enter),
                Ev::Sleep(250),
                Ev::Screen(0),
                Ev::Key(Key::Enter),
                Ev::Sleep(500),
                Ev::Screen(0),
                Ev::Key(Key::Enter),
                Ev::Sleep(750),
                Ev::Screen(0),
            ]
        );
        // A long paste waits at most 800 ms before Enter.
        let t = Fake::with_screens(&[&empty]);
        send(&t, Agent::Codex, &"x".repeat(10_000));
        assert_eq!(t.events()[1], Ev::Sleep(800));
    }

    #[test]
    fn menu_send_closes_a_claude_panel_first() {
        let t = Fake::with_screens(&[&fixture("claude-status-panel"), &claude_box("")]);
        // Open at the check, still open after the first poll, closed after the second.
        *t.panel.borrow_mut() = vec![true, true, false];
        assert!(send(&t, Agent::Claude, "hi"));
        assert_eq!(
            t.events()[..8],
            [
                Ev::Panel,
                Ev::Screen(SCREEN_SCROLLBACK),
                Ev::Key(Key::Escape),
                Ev::Sleep(100),
                Ev::Panel,
                Ev::Sleep(100),
                Ev::Panel,
                Ev::Sleep(100),
            ]
        );
        assert_eq!(t.events()[8], Ev::Paste("hi".into()));
        // A menu on screen (the model picker is also "dialog open") is left alone.
        let t = Fake::with_screens(&[&fixture("claude-model-menu"), &claude_box("")]);
        *t.panel.borrow_mut() = vec![true];
        send(&t, Agent::Claude, "hi");
        assert!(!t.events().contains(&Ev::Key(Key::Escape)));
    }

    #[test]
    fn menu_choose_moves_then_confirms() {
        let m = TerminalMenu::parse(&fixture("claude-permission")).unwrap();
        let t = Fake::default();
        assert!(choose(&t, &m, 2));
        assert_eq!(
            t.events(),
            vec![
                Ev::Key(Key::Down),
                Ev::Sleep(60),
                Ev::Key(Key::Down),
                Ev::Sleep(60),
                Ev::Sleep(80),
                Ev::Key(Key::Enter)
            ]
        );
        let m = TerminalMenu::parse(&fixture("claude-model-menu")).unwrap();
        let t = Fake::default();
        choose(&t, &m, 0);
        assert_eq!(t.keys(), vec![Ev::Key(Key::Up), Ev::Key(Key::Enter)]);
    }

    #[test]
    fn menu_answer_types_into_the_free_text_row() {
        let single = TerminalMenu {
            options: vec![
                MenuOption { label: "A".into(), detail: None },
                MenuOption { label: "Type something.".into(), detail: None },
            ],
            selected: 0,
            question: None,
            context: None,
        };
        let t = Fake::default();
        assert!(answer(&t, &single, 1, "둘째\n줄"));
        assert_eq!(
            t.events(),
            vec![
                Ev::Key(Key::Down),
                Ev::Sleep(60),
                Ev::Sleep(80),
                Ev::Type("둘째 줄".into()),
                Ev::Sleep(150),
                Ev::Key(Key::Enter)
            ]
        );
        // A checkbox row is ticked by typing: no Enter.
        let mut multi = single.clone();
        multi.options[1].label = "[ ] Type something".into();
        let t = Fake::default();
        answer(&t, &multi, 1, "x");
        assert_eq!(t.keys(), vec![Ev::Key(Key::Down), Ev::Type("x".into())]);
    }

    #[test]
    fn menu_choose_on_screen_reads_the_menu_first() {
        let screen = swift_literal(
            r#"
        Which?

        ❯ 1. Apple
          2. Type something.

        Enter to select · Esc to cancel
        "#,
        );
        let t = Fake::with_screens(&[&screen]);
        assert!(!choose_on_screen(&t, 1, "  ")); // a free-text row needs text
        assert!(!choose_on_screen(&t, 5, ""));
        assert!(choose_on_screen(&t, 1, " 바나나 "));
        assert_eq!(t.keys(), vec![Ev::Key(Key::Down), Ev::Type("바나나".into()), Ev::Key(Key::Enter)]);
        assert_eq!(t.events()[0], Ev::Screen(SCREEN_SCROLLBACK));
        let t = Fake::with_screens(&[&fixture("claude-idle")]);
        assert!(!choose_on_screen(&t, 0, ""));
        assert!(t.keys().is_empty());
    }

    #[test]
    fn menu_hosted_trust_menu_is_read_from_the_visible_screen() {
        let t = Fake::with_screens(&[&fixture("claude-trust")]);
        assert_eq!(hosted_menu(&t).map(|m| m.options.len()), Some(2));
        assert!(hosted_choose(&t, 1));
        assert!(!hosted_choose(&t, 2));
        assert_eq!(t.keys(), vec![Ev::Key(Key::Down), Ev::Key(Key::Enter)]);
        assert!(t.events().iter().all(|e| !matches!(e, Ev::Screen(n) if *n != 0)));
    }
}
