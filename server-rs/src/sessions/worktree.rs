//! Project name for a working folder (port of Worktree.project(of:)). Checkouts 수혁 makes live at
//! `~/.suhyeok/worktrees/<repo>/<name>` and belong to their repo, not to their own folder name.

use std::path::PathBuf;

/// `~/.suhyeok/worktrees` (Swift `Worktree.root`).
pub fn root() -> PathBuf {
    PathBuf::from(crate::model::home()).join(".suhyeok").join("worktrees")
}

pub fn project(cwd: &str) -> String {
    project_in(cwd, &root().to_string_lossy())
}

/// `project` with the worktree root given (tests).
pub fn project_in(cwd: &str, root: &str) -> String {
    let root = root.trim_end_matches(['/', '\\']);
    if let Some(rest) = cwd.strip_prefix(root).and_then(|r| r.strip_prefix(['/', '\\'])) {
        if let Some(repo) = rest.split(['/', '\\']).find(|p| !p.is_empty()) {
            return repo.to_string();
        }
    }
    last_path_component(cwd)
}

/// NSString.lastPathComponent: trailing separators ignored, "/" stays "/", "" stays "".
fn last_path_component(path: &str) -> String {
    let trimmed = path.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        return path.chars().next().map(String::from).unwrap_or_default();
    }
    trimmed.rsplit(['/', '\\']).next().unwrap_or(trimmed).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_checkout_belongs_to_its_repo() {
        let root = "/Users/a/.suhyeok/worktrees";
        assert_eq!(project_in("/Users/a/.suhyeok/worktrees/agent-deck/login-bug", root), "agent-deck");
        assert_eq!(project_in("/Users/a/.suhyeok/worktrees/agent-deck/login-bug/src", root), "agent-deck");
        assert_eq!(project_in("/Users/a/.suhyeok/worktreesX/foo", root), "foo");
    }

    #[test]
    fn plain_folder_is_its_last_component() {
        let root = "/r";
        assert_eq!(project_in("/Users/a/project/poe1-re", root), "poe1-re");
        assert_eq!(project_in("/Users/a/project/", root), "project");
        assert_eq!(project_in("/", root), "/");
        assert_eq!(project_in("", root), "");
        assert_eq!(project_in("C:\\Users\\a\\proj", "C:\\Users\\a\\.suhyeok\\worktrees"), "proj");
        assert_eq!(project_in("C:\\Users\\a\\.suhyeok\\worktrees\\repo\\x", "C:\\Users\\a\\.suhyeok\\worktrees"), "repo");
    }

    #[test]
    fn default_root_is_under_home() {
        let cwd = root().join("repo").join("branch");
        assert_eq!(project(&cwd.to_string_lossy()), "repo");
    }
}
