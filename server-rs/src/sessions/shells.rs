//! Background shells a Claude Code session left running after its turn (registry status "shell"); port of
//! BackgroundShells.swift without `reap` (the Mac app kills stale wait loops; this server only reads).
//! Claude runs each Bash command as `<shell> -c source ~/.claude/shell-snapshots/… && eval '<command>'`, a child of
//! the claude process. A shell whose whole process tree is wait-loop programs does no work of its own.

use super::procs::{slashed, Procs};
use std::collections::HashMap;

/// Programs a wait loop runs between checks.
pub const WAIT_PROGRAMS: [&str; 8] = ["zsh", "bash", "sh", "sleep", "pgrep", "grep", "cat", "tail"];

#[derive(Clone, Debug, PartialEq)]
pub struct Shell {
    pub pid: u32,
    /// Seconds running.
    pub age: f64,
    pub command: String,
    /// Every process in the shell's tree, deepest last.
    pub tree: Vec<u32>,
    /// Only wait-loop programs run in the tree.
    pub waiting: bool,
}

/// The background shells of one claude process.
pub fn shells(of: u32, procs: &Procs) -> Vec<Shell> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for p in &procs.list {
        children.entry(p.ppid).or_default().push(p.pid);
    }
    fn tree(pid: u32, children: &HashMap<u32, Vec<u32>>, out: &mut Vec<u32>, depth: usize) {
        out.push(pid);
        if depth > 64 {
            return;
        }
        for c in children.get(&pid).into_iter().flatten() {
            tree(*c, children, out, depth + 1);
        }
    }
    children
        .get(&of)
        .into_iter()
        .flatten()
        .filter_map(|pid| procs.get(*pid))
        .filter(|sh| slashed(&sh.command).contains("/.claude/shell-snapshots/"))
        .map(|sh| {
            let mut all = vec![];
            tree(sh.pid, &children, &mut all, 0);
            let waiting = all.iter().all(|p| procs.get(*p).is_some_and(|q| WAIT_PROGRAMS.contains(&q.program().as_str())));
            Shell { pid: sh.pid, age: procs.age(sh.pid), command: sh.command.clone(), tree: all, waiting }
        })
        .collect()
}

/// Whether a session's background shells do real work: None when it has none to look at.
pub fn working(shells: &[Shell]) -> Option<bool> {
    if shells.is_empty() {
        None
    } else {
        Some(shells.iter().any(|s| !s.waiting))
    }
}

/// The user's command inside Claude's wrapper, on one line.
pub fn script(command: &str) -> String {
    let body = command.find("eval '").map(|i| &command[i + 6..]).unwrap_or(command);
    body.replace('\n', " ").chars().take(300).collect()
}

#[cfg(test)]
mod tests {
    use super::super::procs::tests::proc;
    use super::*;

    #[test]
    fn wait_loops_are_not_work() {
        let snap = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh.sh && eval 'until done; do sleep 5; done'";
        let mut list = vec![proc(10, 1, "claude", "claude"), proc(11, 10, "zsh", snap), proc(12, 11, "sleep", "sleep 5")];
        let procs = Procs::from_list(list.clone(), None);
        let sh = shells(10, &procs);
        assert_eq!(sh.len(), 1);
        assert_eq!(sh[0].tree, vec![11, 12]);
        assert_eq!(working(&sh), Some(false));
        assert_eq!(script(&sh[0].command), "until done; do sleep 5; done'");

        list.push(proc(13, 11, "python3", "python3 train.py"));
        assert_eq!(working(&shells(10, &Procs::from_list(list, None))), Some(true));

        // A child that is not a snapshot shell is not a background shell.
        let other = Procs::from_list(vec![proc(10, 1, "claude", "claude"), proc(11, 10, "node", "node mcp.js")], None);
        assert_eq!(working(&shells(10, &other)), None);
    }

    #[test]
    fn windows_paths_match_too() {
        let snap = "C:\\Program Files\\Git\\bin\\bash.exe -c source C:\\Users\\x\\.claude\\shell-snapshots\\s.sh && eval 'sleep 9'";
        let procs = Procs::from_list(vec![proc(10, 1, "claude", "claude"), proc(11, 10, "bash", snap)], None);
        assert_eq!(working(&shells(10, &procs)), Some(false));
    }
}
