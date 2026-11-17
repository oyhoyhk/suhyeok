//! Live tests: real processes in real PTYs on this machine (macOS here, Linux in the container), run under /bin/sh.
//! A stand-in "login shell" keeps the user's profile out (a login /bin/sh resets PATH on Debian), and a stand-in
//! `claude` on PATH prints its arguments instead of starting Claude Code.

use super::*;
use crate::menu::{Key, Term};
use crate::model::Agent;
use crate::sessions::procs::{Proc, Procs};
use std::path::Path;
use std::time::{Duration, Instant};

fn script(dir: &Path, name: &str, body: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let p = dir.join(name);
    std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p.to_string_lossy().into_owned()
}

/// A Host whose shell is /bin/sh without a login profile, with `dir` first on PATH.
fn host(dir: &Path) -> Host {
    let shell = script(dir, "fakesh", "if [ \"$1\" = -lic ]; then exec /bin/sh -c \"$2\"; fi\nexec /bin/sh");
    let path = format!("{}:{}", dir.display(), std::env::var("PATH").unwrap_or_default());
    Host::new(HostOptions {
        shell: Some(shell),
        env: vec![("PATH".into(), path), ("PS1".into(), "$ ".into()), ("ENV".into(), String::new())],
        ..HostOptions::default()
    })
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    // Generous: the whole suite runs in parallel, and a loaded container can take a while to start a shell.
    let deadline = Instant::now() + Duration::from_secs(30);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// A new shell, once its prompt is up: shells may drop input typed before that (Linux dash, zsh with a heavy
/// profile), so tests that type wait for it as a person would.
fn ready_shell(h: &Host, cwd: &str) -> String {
    let name = h.create_shell(cwd, None).unwrap();
    wait_for("prompt", || prompts(h, &name) > 0);
    name
}

/// Prompt lines: "$" on Linux dash, "sh-3.2$" on macOS /bin/sh. Counted by their start, so a prompt line that later
/// shows "^C" or a command still counts.
fn prompts(h: &Host, name: &str) -> usize {
    lines(h, name).iter().filter(|l| l.starts_with('$') || (l.starts_with("sh-") && l.contains('$'))).count()
}

fn lines(h: &Host, name: &str) -> Vec<String> {
    h.screen(name, 300).map(|s| s.lines()).unwrap_or_default()
}

fn wait_line(h: &Host, name: &str, line: &str) {
    wait_for(&format!("line {line:?} in {name}"), || lines(h, name).iter().any(|l| l.trim() == line));
}

fn alive(pid: u32) -> bool {
    use sysinfo::{Pid, ProcessStatus, ProcessesToUpdate, System};
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::Some(&[Pid::from_u32(pid)]), true);
    sys.process(Pid::from_u32(pid)).is_some_and(|p| !matches!(p.status(), ProcessStatus::Zombie | ProcessStatus::Dead))
}

#[test]
fn shell_runs_commands_and_is_listed_and_killed() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let cwd = dir.path().to_string_lossy().into_owned();
    let before = h.changes();
    let name = ready_shell(&h, &cwd);
    assert!(name.starts_with("sh-"));
    assert!(h.changes() > before);
    let listed = h.list();
    assert_eq!(listed.len(), 1);
    assert_eq!((listed[0].agent, listed[0].cwd.as_str()), (None, cwd.as_str()));
    assert_eq!(listed[0].title, launch::shell_title(&cwd));
    let pid = h.pid(&name).unwrap();
    assert!(alive(pid));

    assert!(h.write_bytes(&name, b"echo $((6*7)); echo \"[$SUHYEOK_SESSION]\"; pwd\r"));
    wait_line(&h, &name, "42");
    wait_line(&h, &name, &format!("[{name}]"));
    let real = std::fs::canonicalize(dir.path()).unwrap();
    wait_for("pwd", || lines(&h, &name).iter().any(|l| Path::new(l.trim()) == real || l.trim() == cwd));

    // The panel shell has a fixed name; a second one with that name is refused (tmux: duplicate session).
    assert_eq!(h.create_shell(&cwd, Some(PANEL_NAME)).as_deref(), Some(PANEL_NAME));
    assert_eq!(h.create_shell(&cwd, Some(PANEL_NAME)), None);
    assert_eq!(h.list().len(), 2);

    assert!(h.kill(&name));
    assert!(!h.exists(&name));
    assert!(!h.kill(&name));
    assert!(!h.write_bytes(&name, b"x"));
    assert!(h.screen(&name, 0).is_none());
    wait_for("killed shell to end", || !alive(pid));
    assert_eq!(h.list().iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), [PANEL_NAME]);
}

#[test]
fn a_terminal_whose_process_exits_leaves_the_list() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = ready_shell(&h, &dir.path().to_string_lossy());
    let changes = h.changes();
    h.write_bytes(&name, b"exit\r");
    wait_for("exit detection", || !h.exists(&name));
    assert!(h.changes() > changes);
    assert!(h.list().is_empty());
}

#[test]
fn agent_runs_in_the_wrapper_and_a_shell_stays_after_it() {
    let dir = tempfile::tempdir().unwrap();
    script(dir.path(), "claude", "echo \"ARGS:$*\"\necho \"SESSION:$SUHYEOK_SESSION\"");
    let h = host(dir.path());
    let mut l = Launch::new(Agent::Claude, &dir.path().to_string_lossy());
    l.prompt = Some("hi there".into());
    let name = h.create_agent(&l).unwrap();
    wait_line(&h, &name, "ARGS:--dangerously-skip-permissions hi there");
    wait_line(&h, &name, &format!("SESSION:{name}"));
    wait_line(&h, &name, launch::exited_note(false));
    let t = h.get(&name).unwrap();
    assert_eq!((t.agent, t.title.as_str()), (Some(Agent::Claude), "hi there"));
    // The shell that took over is usable, then closes the terminal.
    h.write_bytes(&name, b"echo after\r");
    wait_line(&h, &name, "after");
    h.write_bytes(&name, b"exit\r");
    wait_for("terminal to close", || !h.exists(&name));

    // A fixed name that is taken starts nothing.
    let shell = h.create_shell(&dir.path().to_string_lossy(), None).unwrap();
    l.name = Some(shell.clone());
    assert_eq!(h.create_agent(&l), None);
}

#[test]
fn paste_is_bracketed_only_when_the_program_asks() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let cwd = dir.path().to_string_lossy().into_owned();
    let plain = ready_shell(&h, &cwd);
    let marked = ready_shell(&h, &cwd);
    h.write_bytes(&plain, b"stty -echo; printf 'READY\\n'; cat -v\r");
    h.write_bytes(&marked, b"stty -echo; printf '\\033[?2004hREADY\\n'; cat -v\r");
    wait_line(&h, &plain, "READY");
    wait_line(&h, &marked, "READY");
    assert_eq!(h.modes(&marked), Some((true, false)));

    assert!(h.paste(&plain, "one\ntwo"));
    h.write_bytes(&plain, b"\r");
    wait_line(&h, &plain, "one");
    wait_line(&h, &plain, "two");
    assert!(!lines(&h, &plain).iter().any(|l| l.contains("200~")));

    assert!(h.paste(&marked, "a\nb"));
    h.write_bytes(&marked, b"\r");
    wait_line(&h, &marked, "^[[200~a");
    wait_line(&h, &marked, "b^[[201~");
}

#[test]
fn screen_json_has_history_colors_and_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = ready_shell(&h, &dir.path().to_string_lossy());
    h.write_bytes(&name, b"i=0; while [ $i -lt 120 ]; do echo row$i; i=$((i+1)); done; printf '\\033[31mRED\\033[0m\\n'\r");
    wait_line(&h, &name, "RED");
    let visible = h.screen(&name, 0).unwrap();
    assert_eq!((visible.width, visible.height, visible.rows.len()), (200, 50, 50));
    assert!(!visible.lines().iter().any(|l| l == "row0"));
    let full = h.screen(&name, 300).unwrap();
    assert!(full.lines().iter().any(|l| l == "row0"));

    let j = mobile::screen(&h, &name, 300).unwrap();
    let rows = j["lines"].as_array().unwrap();
    assert_eq!(rows.len(), full.rows.len());
    assert!(rows.len() > 120 && rows.len() <= 300 + 50);
    assert!(rows.iter().any(|r| r.as_str().unwrap().starts_with("\x1b[0;31mRED\x1b[0m")));
    assert_eq!((j["width"].as_u64(), j["height"].as_u64(), j["alternate"].as_bool()), (Some(200), Some(50), Some(false)));
    assert!(j["cy"].as_u64().unwrap() < 50);
    assert!(mobile::screen(&h, "nope", 10).is_none());
}

#[test]
fn phone_typing_keys_and_terminal_list() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = ready_shell(&h, &dir.path().to_string_lossy());
    assert!(mobile::type_text(&h, &name, "echo typed"));
    assert!(!mobile::type_text(&h, &name, ""));
    assert!(mobile::press(&h, &name, "Enter"));
    wait_line(&h, &name, "typed");
    assert!(!mobile::press(&h, &name, "F1"));
    assert!(!mobile::press(&h, "nope", "Enter"));
    // Linux flushes the terminal's input on ^C: type again only once the shell has answered with a new prompt.
    let before = prompts(&h, &name);
    assert!(mobile::press(&h, &name, "C-c"));
    wait_for("prompt after ^C", || prompts(&h, &name) > before);

    let rows = mobile::terminals(&h, |_| (String::new(), None));
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["name"], name.as_str());
    assert_eq!(rows[0]["kind"], "Shell");
    assert_eq!(rows[0]["panel"], false);
    assert_eq!(rows[0]["character"], "");

    // The same terminal through menu::Term.
    let t = h.term(&name, None).unwrap();
    assert!(t.type_text("echo via-term"));
    assert!(t.press(Key::Enter));
    wait_for("menu::Term screen", || t.screen(0).is_some_and(|s| s.lines().any(|l| l == "via-term")));
    assert!(h.term("nope", None).is_none());
}

#[test]
fn resize_reaches_the_program() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = ready_shell(&h, &dir.path().to_string_lossy());
    assert!(h.resize(&name, 80, 24));
    assert!(!h.resize(&name, 0, 24));
    let s = h.screen(&name, 0).unwrap();
    assert_eq!((s.width, s.height), (80, 24));
    h.write_bytes(&name, b"stty size\r");
    wait_line(&h, &name, "24 80");
}

#[test]
fn owner_of_walks_up_to_the_terminal_process() {
    let p = |pid, ppid| Proc { pid, ppid, ..Proc::default() };
    let procs = Procs::from_list(vec![p(1, 0), p(100, 1), p(101, 100), p(102, 101), p(200, 1)], None);
    let roots = vec![("sh-a".to_string(), 100)];
    assert_eq!(owner_in(102, &procs, &roots).as_deref(), Some("sh-a"));
    assert_eq!(owner_in(100, &procs, &roots).as_deref(), Some("sh-a"));
    assert_eq!(owner_in(200, &procs, &roots), None);
    assert_eq!(owner_in(999, &procs, &roots), None);

    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = h.create_shell(&dir.path().to_string_lossy(), None).unwrap();
    let pid = h.pid(&name).unwrap();
    assert_eq!(h.owner_of(pid, &Procs::snapshot()).as_deref(), Some(name.as_str()));
}

#[test]
fn dropping_the_host_ends_its_terminals() {
    let dir = tempfile::tempdir().unwrap();
    let h = host(dir.path());
    let name = ready_shell(&h, &dir.path().to_string_lossy());
    // A child of the shell that ignores hangup still goes (hard kill a second later).
    h.write_bytes(&name, b"trap '' HUP; sleep 60 & echo started\r");
    wait_line(&h, &name, "started");
    let pid = h.pid(&name).unwrap();
    let snapshot = Procs::snapshot();
    let sleeper = snapshot.list.iter().find(|p| p.name == "sleep" && snapshot.descends(p.pid, pid)).map(|p| p.pid);
    let sleeper = sleeper.expect("background sleep under the shell");
    drop(h);
    wait_for("shell to end", || !alive(pid));
    wait_for("background child to end", || !alive(sleeper));
}
