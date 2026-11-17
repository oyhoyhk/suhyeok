//! One snapshot of the process table, read through sysinfo so it works on Windows, Linux and macOS.
//! Replaces the Mac-only calls in SessionTree.swift (sysctl, proc_pidinfo, proc_listallpids) and the `ps` table
//! BackgroundShells.swift parses. Tests build a `Procs` by hand with `Procs::from_list`.

use std::collections::HashMap;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Proc {
    pub pid: u32,
    /// 0 when the parent is unknown.
    pub ppid: u32,
    /// Executable name, without ".exe" (Swift `proc_name`).
    pub name: String,
    /// Arguments joined by spaces (`ps -o command=`).
    pub command: String,
    /// Start time, Unix seconds.
    pub start: f64,
    pub cwd: Option<String>,
}

impl Proc {
    /// The program a process runs (Swift `BackgroundShells.Proc.program`). Swift takes the first word of the `ps`
    /// command line, which breaks on paths with spaces ("C:\Program Files\…"); the executable name is used here and
    /// the first word only when the name is unknown.
    pub fn program(&self) -> String {
        if !self.name.is_empty() {
            return self.name.clone();
        }
        let first = self.command.split(' ').find(|w| !w.is_empty()).unwrap_or("");
        strip_exe(last_component(first)).to_string()
    }
}

pub struct Procs {
    pub list: Vec<Proc>,
    by_pid: HashMap<u32, usize>,
    /// pid -> paths of the files it holds open, read for the `codex` and `agy` processes only. None where the OS gives
    /// no portable way to list another process's open files (Windows): callers fall back to matching by folder.
    pub open_files: Option<HashMap<u32, Vec<String>>>,
    /// When the snapshot was taken, Unix seconds (process ages are measured from it).
    pub taken: f64,
}

impl Procs {
    pub fn from_list(list: Vec<Proc>, open_files: Option<HashMap<u32, Vec<String>>>) -> Procs {
        let by_pid = list.iter().enumerate().map(|(i, p)| (p.pid, i)).collect();
        Procs { list, by_pid, open_files, taken: crate::model::now() }
    }

    /// The live process table of this machine.
    pub fn snapshot() -> Procs {
        use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
        let mut sys = System::new();
        sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().without_tasks().with_cmd(UpdateKind::Always).with_cwd(UpdateKind::Always),
        );
        let mut list: Vec<Proc> = sys
            .processes()
            .values()
            .map(|p| {
                let cmd: Vec<String> = p.cmd().iter().map(|a| a.to_string_lossy().into_owned()).collect();
                let name = p.name().to_string_lossy().into_owned();
                Proc {
                    pid: p.pid().as_u32(),
                    ppid: p.parent().map(|q| q.as_u32()).unwrap_or(0),
                    command: if cmd.is_empty() { name.clone() } else { cmd.join(" ") },
                    name: strip_exe(&name).to_string(),
                    start: p.start_time() as f64,
                    cwd: p.cwd().map(|c| c.to_string_lossy().into_owned()).filter(|c| !c.is_empty()),
                }
            })
            .collect();
        list.sort_by_key(|p| p.pid);
        let mut procs = Procs::from_list(list, None);
        let watched: Vec<u32> = procs.pids_named("codex").into_iter().chain(procs.pids_named("agy")).collect();
        procs.open_files = open_files(&watched);
        procs
    }

    pub fn get(&self, pid: u32) -> Option<&Proc> {
        self.by_pid.get(&pid).map(|i| &self.list[*i])
    }

    /// Swift `kill(pid, 0) == 0`.
    pub fn exists(&self, pid: u32) -> bool {
        self.by_pid.contains_key(&pid)
    }

    pub fn parent_pid(&self, pid: u32) -> u32 {
        self.get(pid).map(|p| p.ppid).unwrap_or(0)
    }

    pub fn cwd(&self, pid: u32) -> Option<String> {
        self.get(pid).and_then(|p| p.cwd.clone())
    }

    pub fn start(&self, pid: u32) -> Option<f64> {
        self.get(pid).map(|p| p.start).filter(|s| *s > 0.0)
    }

    pub fn age(&self, pid: u32) -> f64 {
        self.get(pid).map(|p| (self.taken - p.start).max(0.0)).unwrap_or(0.0)
    }

    pub fn pids_named(&self, name: &str) -> Vec<u32> {
        self.list.iter().filter(|p| p.pid > 0 && p.name == name).map(|p| p.pid).collect()
    }

    /// `pid` is `ancestor` or runs under it (SessionTree.descends).
    pub fn descends(&self, pid: u32, ancestor: u32) -> bool {
        let mut p = pid;
        for _ in 0..32 {
            if p <= 1 {
                break;
            }
            if p == ancestor {
                return true;
            }
            p = self.parent_pid(p);
        }
        false
    }

    /// No parent left, or the parent is the init process (launchd / init / systemd).
    fn orphan(&self, pid: u32) -> bool {
        let parent = self.parent_pid(pid);
        parent <= 1 || !self.exists(parent)
    }

    /// The Codex app-server daemon runs under launchd/init (directly or under its own `codex` supervisor), not a shell.
    pub fn is_codex_daemon(&self, pid: u32) -> bool {
        if self.orphan(pid) {
            return true;
        }
        let parent = self.parent_pid(pid);
        self.get(parent).is_some_and(|p| p.name == "codex") && self.orphan(parent)
    }

    /// Rollout file -> pid of the `codex` process writing it (SessionTree.codexRollouts). Empty without open-file data.
    pub fn codex_rollouts(&self) -> HashMap<String, u32> {
        let mut out = HashMap::new();
        let Some(open) = &self.open_files else { return out };
        for pid in self.pids_named("codex") {
            if self.is_codex_daemon(pid) {
                continue;
            }
            for path in open.get(&pid).into_iter().flatten() {
                if path.ends_with(".jsonl") && slashed(path).contains("/.codex/sessions/") {
                    out.insert(path.clone(), pid);
                }
            }
        }
        out
    }

    /// Conversation id -> pid of the `agy` process holding presence/<id>.lock (SessionTree.antigravityLocks).
    pub fn antigravity_locks(&self) -> HashMap<String, u32> {
        let mut out = HashMap::new();
        let Some(open) = &self.open_files else { return out };
        for pid in self.pids_named("agy") {
            for path in open.get(&pid).into_iter().flatten() {
                if path.ends_with(".lock") && slashed(path).contains("/.gemini/antigravity-cli/presence/") {
                    let file = last_component(path);
                    out.insert(file.trim_end_matches(".lock").to_string(), pid);
                }
            }
        }
        out
    }

    /// Interactive Codex: the newest `codex` process in `cwd` started before the thread (SessionTree.codexProcess).
    pub fn codex_process(&self, cwd: &str, started_at: f64, excluding: &std::collections::HashSet<u32>) -> Option<u32> {
        self.pids_named("codex")
            .into_iter()
            .filter(|p| !excluding.contains(p) && !self.is_codex_daemon(*p) && self.cwd(*p).as_deref() == Some(cwd))
            .filter_map(|p| self.start(p).map(|s| (p, s)))
            .filter(|(_, s)| *s <= started_at + 5.0)
            .fold(None, |best: Option<(u32, f64)>, (p, s)| match best {
                Some((_, b)) if b >= s => best,
                _ => Some((p, s)),
            })
            .map(|(p, _)| p)
    }
}

pub(crate) fn strip_exe(name: &str) -> &str {
    if name.len() > 4 && name[name.len() - 4..].eq_ignore_ascii_case(".exe") {
        &name[..name.len() - 4]
    } else {
        name
    }
}

/// The text after the last '/' or '\'.
pub(crate) fn last_component(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Windows paths with forward slashes, so one substring test covers both.
pub(crate) fn slashed(path: &str) -> String {
    path.replace('\\', "/")
}

#[cfg(target_os = "linux")]
fn open_files(pids: &[u32]) -> Option<HashMap<u32, Vec<String>>> {
    let mut out = HashMap::new();
    for pid in pids {
        let paths = std::fs::read_dir(format!("/proc/{pid}/fd"))
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .filter_map(|e| std::fs::read_link(e.path()).ok())
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        out.insert(*pid, paths);
    }
    Some(out)
}

/// macOS (test machine only): `lsof` in place of proc_pidinfo, which needs libc bindings this crate does not have.
#[cfg(target_os = "macos")]
fn open_files(pids: &[u32]) -> Option<HashMap<u32, Vec<String>>> {
    let mut out: HashMap<u32, Vec<String>> = pids.iter().map(|p| (*p, vec![])).collect();
    if pids.is_empty() {
        return Some(out);
    }
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let Ok(o) = std::process::Command::new("/usr/sbin/lsof").args(["-b", "-w", "-n", "-P", "-Fn", "-p", &list]).output()
    else {
        return Some(out);
    };
    let mut current = 0u32;
    for line in String::from_utf8_lossy(&o.stdout).lines() {
        if let Some(p) = line.strip_prefix('p') {
            current = p.parse().unwrap_or(0);
        } else if let Some(n) = line.strip_prefix('n') {
            out.entry(current).or_default().push(n.to_string());
        }
    }
    Some(out)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn open_files(_pids: &[u32]) -> Option<HashMap<u32, Vec<String>>> {
    None
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn proc(pid: u32, ppid: u32, name: &str, command: &str) -> Proc {
        Proc { pid, ppid, name: name.into(), command: command.into(), start: 1000.0, cwd: None }
    }

    #[test]
    fn program_is_the_first_words_last_component() {
        assert_eq!(proc(1, 0, "", "/bin/zsh -c sleep 1").program(), "zsh");
        assert_eq!(proc(1, 0, "", "C:\\Git\\bin\\bash.exe -c x").program(), "bash");
        assert_eq!(proc(1, 0, "bash", "C:\\Program Files\\Git\\bin\\bash.exe -c x").program(), "bash");
    }

    #[test]
    fn daemon_and_rollouts() {
        let mut list = vec![
            proc(1, 0, "launchd", "launchd"),
            proc(50, 1, "zsh", "-zsh"),
            proc(100, 50, "codex", "codex"),         // interactive, under a shell
            proc(200, 1, "codex", "codex app-server"), // daemon
            proc(300, 200, "codex", "codex worker"),   // under the daemon supervisor
        ];
        list[2].cwd = Some("/w".into());
        let open = HashMap::from([
            (100, vec!["/h/.codex/sessions/2026/a.jsonl".to_string(), "/h/other.jsonl".into()]),
            (200, vec!["/h/.codex/sessions/2026/b.jsonl".to_string()]),
            (300, vec!["/h/.codex/sessions/2026/c.jsonl".to_string()]),
        ]);
        let procs = Procs::from_list(list, Some(open));
        assert!(!procs.is_codex_daemon(100));
        assert!(procs.is_codex_daemon(200));
        assert!(procs.is_codex_daemon(300));
        let r = procs.codex_rollouts();
        assert_eq!(r.len(), 1);
        assert_eq!(r.get("/h/.codex/sessions/2026/a.jsonl"), Some(&100));
        assert_eq!(procs.codex_process("/w", 1003.0, &Default::default()), Some(100));
        assert_eq!(procs.codex_process("/w", 990.0, &Default::default()), None); // started after the thread
        assert!(procs.descends(100, 50));
        assert!(!procs.descends(50, 100));
    }

    #[test]
    fn real_snapshot_contains_this_process() {
        let procs = Procs::snapshot();
        assert!(procs.exists(std::process::id()));
    }
}
