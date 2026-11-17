//! The terminals this server hosts (TmuxEngine.swift's tmux server, in-process): each one a PTY (ConPTY on Windows,
//! a Unix PTY elsewhere) with a reader thread feeding a vt100 parser, a writer thread taking input, and a waiter
//! that drops the terminal from the list when its process ends. Terminals live as long as the server process.

use super::launch::{self, Launch, SESSION_ENV};
use super::screen::{Replies, Screen};
use crate::model::Agent;
use crate::sessions::procs::Procs;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::num::NonZeroU16;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, Weak};
use std::time::Duration;

/// How terminals are started. `Default` is what the server uses: the user's shell, tmux's detached size 200x50.
#[derive(Clone, Debug)]
pub struct HostOptions {
    /// Shell for plain terminals, and the login shell agents run under on Unix. None = `launch::default_shell()`.
    pub shell: Option<String>,
    /// Extra environment for every terminal, applied last (e.g. a PATH that has the agent CLIs).
    pub env: Vec<(String, String)>,
    /// Size of a new terminal (TmuxEngine: `new-session -x 200 -y 50`).
    pub cols: u16,
    pub rows: u16,
    /// Lines of scrollback kept per terminal. tmux keeps 50000 (`history-limit`); the phone reads at most 2000.
    pub scrollback: usize,
}

impl Default for HostOptions {
    fn default() -> HostOptions {
        HostOptions { shell: None, env: vec![], cols: 200, rows: 50, scrollback: 5000 }
    }
}

/// Per-session markers a server started from inside a terminal or a Claude Code session would pass on. With them a new
/// Claude thinks it is a child session (no transcript, no ~/.claude/sessions entry, so 수혁 never sees it) or talks to
/// the parent's messaging socket. User settings (CLAUDE_CODE_ENABLE_TELEMETRY, ANTHROPIC_*, …) are kept.
pub const INHERITED_MARKERS: [&str; 15] = [
    "TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
];

/// A hosted terminal as the sidebar and `/api/terminals` see it (TmuxEngine.Hosted).
#[derive(Clone, Debug, PartialEq)]
pub struct Hosted {
    /// e.g. "sh-3fa9c1", or `launch::PANEL_NAME`.
    pub name: String,
    /// None: a plain shell (사이드바 "터미널"), no agent and no character.
    pub agent: Option<Agent>,
    pub cwd: String,
    pub title: String,
    /// Unix seconds.
    pub created: f64,
    /// Roster id of the character chosen when 수혁 started it.
    pub character: Option<String>,
    /// The process the terminal started (on Unix the login shell the agent runs under; tmux `pane_pid`).
    pub pid: Option<u32>,
}

struct Term {
    info: Hosted,
    /// Tells this terminal apart from a later one with the same name.
    gen: u64,
    parser: Arc<Mutex<vt100::Parser<Replies>>>,
    /// Input goes through the writer thread, so a program that stops reading never blocks a caller.
    input: mpsc::Sender<Vec<u8>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
}

struct Shared {
    opts: HostOptions,
    terms: Mutex<BTreeMap<String, Arc<Term>>>,
    changes: AtomicU64,
    next_gen: AtomicU64,
}

/// Owns the hosted terminals. Cheap to clone; every clone sees the same terminals. Dropping the last clone ends them.
#[derive(Clone)]
pub struct Host {
    shared: Arc<Shared>,
}

impl Default for Host {
    fn default() -> Host {
        Host::new(HostOptions::default())
    }
}

impl Host {
    pub fn new(opts: HostOptions) -> Host {
        Host {
            shared: Arc::new(Shared {
                opts,
                terms: Mutex::new(BTreeMap::new()),
                changes: AtomicU64::new(0),
                next_gen: AtomicU64::new(1),
            }),
        }
    }

    pub fn shell(&self) -> String {
        self.shared.opts.shell.clone().unwrap_or_else(launch::default_shell)
    }

    /// Starts an agent in a new terminal and returns its name (TmuxEngine.create). None when the name in
    /// `l.name` is taken or the program could not be started.
    pub fn create_agent(&self, l: &Launch) -> Option<String> {
        let argv = launch::agent_args(l);
        #[cfg(unix)]
        let argv = launch::unix_wrapper(&self.shell(), &argv, l.en);
        #[cfg(windows)]
        let argv = {
            // No login shell to find the CLI: look it up on the PATH the child gets (npm puts claude.cmd there).
            let path = self.child_env("PATH").unwrap_or_default();
            let pathext = self.child_env("PATHEXT").unwrap_or_default();
            let mut full = launch::windows_argv(&argv[0], &path, &pathext)?;
            full.extend(argv[1..].iter().cloned());
            full
        };
        let character = l.character.as_ref().map(|c| c.id.clone());
        self.spawn(l.name.as_deref(), argv, &l.cwd, Some(l.agent), launch::title(l), character)
    }

    /// Starts the user's shell in `cwd` with no agent (TmuxEngine.createShell). `name`: e.g. `launch::PANEL_NAME`;
    /// None when that name is taken.
    pub fn create_shell(&self, cwd: &str, name: Option<&str>) -> Option<String> {
        let argv = launch::shell_argv(&self.shell());
        self.spawn(name, argv, cwd, None, launch::shell_title(cwd), None)
    }

    /// Every terminal, oldest first.
    pub fn list(&self) -> Vec<Hosted> {
        let mut out: Vec<Hosted> = self.shared.terms.lock().unwrap().values().map(|t| t.info.clone()).collect();
        out.sort_by(|a, b| a.created.total_cmp(&b.created).then_with(|| a.name.cmp(&b.name)));
        out
    }

    pub fn get(&self, name: &str) -> Option<Hosted> {
        self.term_arc(name).map(|t| t.info.clone())
    }

    pub fn exists(&self, name: &str) -> bool {
        self.shared.terms.lock().unwrap().contains_key(name)
    }

    /// Bumped whenever a terminal starts, is killed or ends: callers re-read `list()` (and rewrite the restore
    /// record) when it moved.
    pub fn changes(&self) -> u64 {
        self.shared.changes.load(Ordering::SeqCst)
    }

    /// Ends the terminal and everything running in it (tmux kill-session: hangup, then a hard kill after a second
    /// for what ignored it). False when there is no such terminal.
    pub fn kill(&self, name: &str) -> bool {
        let Some(term) = self.shared.terms.lock().unwrap().remove(name) else { return false };
        self.shared.changes.fetch_add(1, Ordering::SeqCst);
        end(&term);
        true
    }

    /// The terminal's scrollback (up to `history` lines) and visible screen.
    pub fn screen(&self, name: &str, history: usize) -> Option<Screen> {
        let t = self.term_arc(name)?;
        let mut p = t.parser.lock().unwrap();
        Some(Screen::capture(&mut p, history))
    }

    /// `screen(..).text()`: plain text, wrapped rows joined (`capture-pane -p -J -S -<history>`).
    pub fn text(&self, name: &str, history: usize) -> Option<String> {
        self.screen(name, history).map(|s| s.text())
    }

    /// Queues bytes for the terminal's input, as typed. False when there is no such terminal.
    pub fn write_bytes(&self, name: &str, bytes: &[u8]) -> bool {
        match self.term_arc(name) {
            Some(t) => bytes.is_empty() || t.input.send(bytes.to_vec()).is_ok(),
            None => false,
        }
    }

    /// Pastes text as one paste (`tmux paste-buffer -p`): in bracketed-paste markers when the program asked for
    /// them, line feeds sent as CR.
    pub fn paste(&self, name: &str, text: &str) -> bool {
        let Some((bracketed, _)) = self.modes(name) else { return false };
        self.write_bytes(name, &crate::menu::paste_bytes(text, bracketed))
    }

    /// Presses a cursor key or any other key given as the bytes it sends in normal mode ("\x1b[A" …); arrows,
    /// Home and End go as SS3 when the program turned on application cursor keys, as tmux does.
    pub fn press_bytes(&self, name: &str, bytes: &[u8]) -> bool {
        let Some((_, app)) = self.modes(name) else { return false };
        self.write_bytes(name, &cursor_key(bytes, app))
    }

    /// (bracketed paste, application cursor keys) as the program has set them.
    pub fn modes(&self, name: &str) -> Option<(bool, bool)> {
        let t = self.term_arc(name)?;
        let p = t.parser.lock().unwrap();
        Some((p.screen().bracketed_paste(), p.screen().application_cursor()))
    }

    /// Resizes the terminal and its screen; the program gets SIGWINCH (Unix) or a ConPTY resize.
    pub fn resize(&self, name: &str, cols: u16, rows: u16) -> bool {
        let (Some(c), Some(r), Some(t)) = (NonZeroU16::new(cols), NonZeroU16::new(rows), self.term_arc(name)) else {
            return false;
        };
        let size = PtySize { rows, cols, pixel_width: 0, pixel_height: 0 };
        if t.master.lock().unwrap().resize(size).is_err() {
            return false;
        }
        t.parser.lock().unwrap().set_size(r, c);
        true
    }

    /// pid of the process the terminal started (tmux `pane_pid`); the agent runs under it.
    pub fn pid(&self, name: &str) -> Option<u32> {
        self.term_arc(name)?.info.pid
    }

    /// The terminal a process runs in: `pid` is a terminal's process or descends from it (SessionTree / TmuxEngine.pane
    /// via $TMUX_PANE on the Mac). Sets `AgentSession::hosted_name` for Claude, Codex and agy processes alike.
    pub fn owner_of(&self, pid: u32, procs: &Procs) -> Option<String> {
        let roots: Vec<(String, u32)> =
            self.list().into_iter().filter_map(|h| h.pid.map(|p| (h.name, p))).collect();
        owner_in(pid, procs, &roots)
    }

    /// The terminal as `menu::Term`, for sending messages and answering menus. `claude_pid`: the Claude process
    /// running in it, so a /status-like panel can be closed before typing (None for other agents).
    pub fn term(&self, name: &str, claude_pid: Option<u32>) -> Option<HostedTerm> {
        self.exists(name).then(|| HostedTerm { host: self.clone(), name: name.to_string(), claude_pid })
    }

    fn term_arc(&self, name: &str) -> Option<Arc<Term>> {
        self.shared.terms.lock().unwrap().get(name).cloned()
    }

    /// An environment variable as a new terminal sees it (the options' env over the inherited one; on Windows
    /// portable-pty re-reads PATH from the registry).
    #[allow(dead_code)]
    fn child_env(&self, key: &str) -> Option<String> {
        if let Some((_, v)) = self.shared.opts.env.iter().rev().find(|(k, _)| k.eq_ignore_ascii_case(key)) {
            return Some(v.clone());
        }
        CommandBuilder::new("probe").get_env(key).map(|v| v.to_string_lossy().into_owned())
    }

    fn spawn(
        &self,
        name: Option<&str>,
        argv: Vec<String>,
        cwd: &str,
        agent: Option<Agent>,
        title: String,
        character: Option<String>,
    ) -> Option<String> {
        let name = match name {
            Some(n) if self.exists(n) => return None,
            Some(n) => n.to_string(),
            None => (0..16).map(|_| launch::new_name()).find(|n| !self.exists(n))?,
        };
        let opts = &self.shared.opts;
        let pair = native_pty_system()
            .openpty(PtySize { rows: opts.rows, cols: opts.cols, pixel_width: 0, pixel_height: 0 })
            .ok()?;
        let mut cmd = CommandBuilder::from_argv(argv.iter().map(Into::into).collect());
        cmd.cwd(cwd);
        // Not the server's own terminal: an agent started from it would think it runs inside tmux or Claude Code.
        for k in INHERITED_MARKERS {
            cmd.env_remove(k);
        }
        #[cfg(unix)]
        {
            // tmux runs panes as tmux-256color with true color; the vt100 parser speaks xterm.
            cmd.env("TERM", "xterm-256color");
            cmd.env("COLORTERM", "truecolor");
            if cmd.get_env("LANG").is_none() {
                // Korean text needs a UTF-8 locale (TmuxEngine sets ko_KR.UTF-8; Linux images often have only C.UTF-8).
                cmd.env("LANG", if cfg!(target_os = "macos") { "ko_KR.UTF-8" } else { "C.UTF-8" });
            }
        }
        cmd.env(SESSION_ENV, &name);
        for (k, v) in &opts.env {
            cmd.env(k, v);
        }
        let mut child = pair.slave.spawn_command(cmd).ok()?;
        drop(pair.slave);
        let killer = child.clone_killer();
        let (reader, writer) = match (pair.master.try_clone_reader(), pair.master.take_writer()) {
            (Ok(r), Ok(w)) => (r, w),
            _ => {
                let _ = child.kill();
                return None;
            }
        };
        let nz = |n: u16| NonZeroU16::new(n).unwrap_or(NonZeroU16::MIN);
        let parser =
            Arc::new(Mutex::new(vt100::Parser::new_with_callbacks(nz(opts.rows), nz(opts.cols), opts.scrollback, Replies::default())));
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let gen = self.shared.next_gen.fetch_add(1, Ordering::SeqCst);
        let info = Hosted {
            name: name.clone(),
            agent,
            cwd: cwd.to_string(),
            title,
            created: crate::model::now(),
            character: character.filter(|c| !c.is_empty()),
            pid: child.process_id(),
        };
        let term = Arc::new(Term {
            info,
            gen,
            parser: parser.clone(),
            input: tx.clone(),
            master: Mutex::new(pair.master),
            killer: Mutex::new(killer),
        });
        {
            let mut terms = self.shared.terms.lock().unwrap();
            if terms.contains_key(&name) {
                drop(terms);
                end(&term);
                return None;
            }
            terms.insert(name.clone(), term);
        }
        self.shared.changes.fetch_add(1, Ordering::SeqCst);

        let thread = |what: &str| std::thread::Builder::new().name(format!("pty-{what}-{name}"));
        let _ = thread("write").spawn(move || write_loop(writer, rx));
        let _ = thread("read").spawn(move || read_loop(reader, parser, tx));
        let weak: Weak<Shared> = Arc::downgrade(&self.shared);
        let key = name.clone();
        let _ = thread("wait").spawn(move || {
            let _ = child.wait();
            if let Some(shared) = weak.upgrade() {
                let gone = {
                    let mut terms = shared.terms.lock().unwrap();
                    if terms.get(&key).is_some_and(|t| t.gen == gen) {
                        terms.remove(&key)
                    } else {
                        None
                    }
                };
                if gone.is_some() {
                    shared.changes.fetch_add(1, Ordering::SeqCst);
                }
                // Dropped outside the lock: on Windows this closes the pseudoconsole, which ends the reader.
                drop(gone);
            }
        });
        Some(name)
    }
}

impl Drop for Shared {
    /// Terminals live as long as the server: when it goes, so do they.
    fn drop(&mut self) {
        let terms = std::mem::take(&mut *self.terms.lock().unwrap());
        for t in terms.values() {
            end(t);
        }
    }
}

fn write_loop(mut writer: Box<dyn Write + Send>, rx: mpsc::Receiver<Vec<u8>>) {
    for buf in rx {
        if writer.write_all(&buf).and_then(|_| writer.flush()).is_err() {
            break;
        }
    }
}

fn read_loop(mut reader: Box<dyn Read + Send>, parser: Arc<Mutex<vt100::Parser<Replies>>>, input: mpsc::Sender<Vec<u8>>) {
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let replies = {
            let mut p = parser.lock().unwrap();
            p.process(&buf[..n]);
            std::mem::take(&mut p.callbacks_mut().out)
        };
        if !replies.is_empty() {
            let _ = input.send(replies);
        }
    }
}

/// Hangs up the terminal's process and everything under it; a second later, kills what is still there.
fn end(t: &Term) {
    let tree = t.info.pid.map(process_tree).unwrap_or_default();
    let _ = t.killer.lock().unwrap().kill();
    signal(&tree, false);
    if !tree.is_empty() {
        let _ = std::thread::Builder::new().name("pty-reap".into()).spawn(move || {
            std::thread::sleep(Duration::from_secs(1));
            signal(&tree, true);
        });
    }
}

/// `root` and its descendants, with start times so a reused pid is never signalled.
fn process_tree(root: u32) -> Vec<(u32, u64)> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    let mut out: Vec<(u32, u64)> = vec![];
    let mut queue = vec![root];
    while let Some(p) = queue.pop() {
        if out.iter().any(|(q, _)| *q == p) {
            continue;
        }
        let Some(proc_) = sys.process(sysinfo::Pid::from_u32(p)) else { continue };
        out.push((p, proc_.start_time()));
        queue.extend(
            sys.processes().values().filter(|c| c.parent().map(|x| x.as_u32()) == Some(p)).map(|c| c.pid().as_u32()),
        );
    }
    out
}

/// Hangup (SIGHUP; Windows has none and terminates) or a hard kill, to the processes still matching.
fn signal(procs: &[(u32, u64)], hard: bool) {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, Signal, System};
    if procs.is_empty() {
        return;
    }
    let pids: Vec<Pid> = procs.iter().map(|(p, _)| Pid::from_u32(*p)).collect();
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&pids), true, ProcessRefreshKind::nothing());
    for (pid, start) in procs {
        if let Some(p) = sys.process(Pid::from_u32(*pid)).filter(|p| p.start_time() == *start) {
            let sig = if hard { Signal::Kill } else { Signal::Hangup };
            if p.kill_with(sig).is_none() {
                p.kill();
            }
        }
    }
}

/// Which terminal (name, process pid) `pid` runs under, walking up its parents.
pub fn owner_in(pid: u32, procs: &Procs, roots: &[(String, u32)]) -> Option<String> {
    let mut p = pid;
    for _ in 0..64 {
        if let Some((name, _)) = roots.iter().find(|(_, r)| *r == p) {
            return Some(name.clone());
        }
        let up = procs.parent_pid(p);
        if up <= 1 || up == p {
            return None;
        }
        p = up;
    }
    None
}

/// tmux sends arrows, Home and End as SS3 ("\x1bOA") in application cursor mode, CSI ("\x1b[A") otherwise.
fn cursor_key(bytes: &[u8], app: bool) -> Vec<u8> {
    match bytes {
        [0x1b, b'[', k @ (b'A' | b'B' | b'C' | b'D' | b'H' | b'F')] if app => vec![0x1b, b'O', *k],
        _ => bytes.to_vec(),
    }
}

/// One hosted terminal seen through `menu::Term` (tmux capture-pane / paste-buffer / send-keys on the Mac).
pub struct HostedTerm {
    host: Host,
    name: String,
    claude_pid: Option<u32>,
}

impl HostedTerm {
    pub fn name(&self) -> &str {
        &self.name
    }
}

impl crate::menu::Term for HostedTerm {
    fn screen(&self, scrollback: usize) -> Option<String> {
        self.host.text(&self.name, scrollback)
    }
    fn paste(&self, text: &str) -> bool {
        self.host.paste(&self.name, text)
    }
    fn type_text(&self, text: &str) -> bool {
        !text.is_empty() && self.host.write_bytes(&self.name, text.as_bytes())
    }
    fn press(&self, key: crate::menu::Key) -> bool {
        self.host.press_bytes(&self.name, key.bytes())
    }
    fn panel_open(&self) -> bool {
        self.claude_pid
            .is_some_and(|pid| crate::sessions::claude::panel_open(std::path::Path::new(&crate::model::home()), pid))
    }
}
