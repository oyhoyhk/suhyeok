//! Sidebar order: port of SidebarSort.ordered (SidebarSort.swift). Rows are agents in 수혁's own terminals
//! (phase 2) or in other terminals; sorted by folder, last activity, creation, name or status.

use std::cmp::Ordering;
use suhyeok::model::{AgentSession, SessionStatus};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sort {
    Folder,
    LastActivity,
    Created,
    Name,
    Status,
}

impl Sort {
    pub const ALL: [Sort; 5] = [Sort::Folder, Sort::LastActivity, Sort::Created, Sort::Name, Sort::Status];
    pub fn key(self) -> &'static str {
        match self {
            Sort::Folder => "folder",
            Sort::LastActivity => "lastActivity",
            Sort::Created => "created",
            Sort::Name => "name",
            Sort::Status => "status",
        }
    }
    pub fn from_key(k: &str) -> Option<Sort> {
        Sort::ALL.into_iter().find(|s| s.key() == k)
    }
    pub fn label(self, en: bool) -> &'static str {
        match (self, en) {
            (Sort::Folder, false) => "폴더별",
            (Sort::LastActivity, false) => "마지막 응답 순",
            (Sort::Created, false) => "생성 순",
            (Sort::Name, false) => "이름 순",
            (Sort::Status, false) => "상태 순",
            (Sort::Folder, true) => "By folder",
            (Sort::LastActivity, true) => "Last reply",
            (Sort::Created, true) => "Created",
            (Sort::Name, true) => "Name",
            (Sort::Status, true) => "Status",
        }
    }
}

/// One sidebar row.
pub struct Row<'a> {
    pub key: String,
    pub title: String,
    pub subtitle: String,
    pub term: Option<String>,
    pub session: Option<&'a AgentSession>,
    pub cwd: String,
    pub created: Option<f64>,
}

/// Finder-style comparison (localizedStandardCompare): case-insensitive, digit runs compared as numbers.
pub fn natural(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let mut n = String::new();
                while let Some(c) = x.peek().copied().filter(char::is_ascii_digit) {
                    n.push(c);
                    x.next();
                }
                let mut m = String::new();
                while let Some(d) = y.peek().copied().filter(char::is_ascii_digit) {
                    m.push(d);
                    y.next();
                }
                let (n, m) = (n.trim_start_matches('0'), m.trim_start_matches('0'));
                let o = n.len().cmp(&m.len()).then_with(|| n.cmp(m));
                if o != Ordering::Equal {
                    return o;
                }
            }
            (Some(c), Some(d)) => {
                let o = c.to_lowercase().cmp(d.to_lowercase());
                if o != Ordering::Equal {
                    return o;
                }
                x.next();
                y.next();
            }
        }
    }
}

/// Rows in the chosen order; `Folder` groups under project names (folders in order, newest activity first inside),
/// other orders come back as one group with no folder name.
pub fn ordered<'a>(
    mut rows: Vec<Row<'a>>,
    sort: Sort,
    ascending: bool,
    last_activity: &dyn Fn(&AgentSession) -> Option<f64>,
    name_of: &dyn Fn(&AgentSession) -> String,
    now: f64,
) -> Vec<(Option<String>, Vec<Row<'a>>)> {
    let last = |r: &Row| r.session.and_then(|s| last_activity(s)).or(r.created).unwrap_or(f64::MIN);
    let name = |r: &Row| r.session.map(|s| name_of(s)).unwrap_or_else(|| r.title.clone());
    // Needs you first: stopped on a question, then working, waiting, resting.
    let rank = |r: &Row| match r.session {
        None => 9,
        Some(s) if s.status == SessionStatus::Waiting => 0,
        Some(s) => s.activity_at(now).sort_rank() + 1,
    };
    let dir = |o: Ordering| if ascending { o } else { o.reverse() };
    let newest_first = |a: &Row, b: &Row| last(b).partial_cmp(&last(a)).unwrap_or(Ordering::Equal);
    match sort {
        Sort::Folder => {
            let mut groups: Vec<(String, Vec<Row>)> = vec![];
            for r in rows {
                let p = suhyeok::sessions::worktree::project(&r.cwd);
                match groups.iter_mut().find(|(k, _)| *k == p) {
                    Some((_, v)) => v.push(r),
                    None => groups.push((p, vec![r])),
                }
            }
            groups.sort_by(|a, b| dir(natural(&a.0, &b.0)));
            groups
                .into_iter()
                .map(|(k, mut v)| {
                    v.sort_by(newest_first);
                    (Some(k), v)
                })
                .collect()
        }
        Sort::LastActivity => {
            rows.sort_by(|a, b| {
                let o = last(a).partial_cmp(&last(b)).unwrap_or(Ordering::Equal);
                if o == Ordering::Equal { name(a).cmp(&name(b)) } else { dir(o) }
            });
            vec![(None, rows)]
        }
        Sort::Created => {
            rows.sort_by(|a, b| {
                let (ca, cb) = (a.created.unwrap_or(f64::MIN), b.created.unwrap_or(f64::MIN));
                let o = ca.partial_cmp(&cb).unwrap_or(Ordering::Equal);
                if o == Ordering::Equal { newest_first(a, b) } else { dir(o) }
            });
            vec![(None, rows)]
        }
        Sort::Name => {
            rows.sort_by(|a, b| {
                let o = natural(&name(a), &name(b));
                if o == Ordering::Equal { newest_first(a, b) } else { dir(o) }
            });
            vec![(None, rows)]
        }
        Sort::Status => {
            rows.sort_by(|a, b| {
                let o = rank(a).cmp(&rank(b));
                if o == Ordering::Equal { newest_first(a, b) } else { dir(o) }
            });
            vec![(None, rows)]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use suhyeok::model::Agent;

    #[test]
    fn natural_order_is_numeric_and_case_insensitive() {
        assert_eq!(natural("file2", "file10"), Ordering::Less);
        assert_eq!(natural("Apple", "banana"), Ordering::Less);
        assert_eq!(natural("a", "A"), Ordering::Equal);
    }

    #[test]
    fn status_sort_puts_questions_first() {
        let mk = |id: &str, st: SessionStatus, upd: f64| {
            let mut s = AgentSession::new(id.into(), Agent::Claude, id.into(), format!("/p/{id}"), st);
            s.updated_at = Some(upd);
            s
        };
        let (a, b, c) = (mk("a", SessionStatus::Idle, 0.0), mk("b", SessionStatus::Waiting, 0.0), mk("c", SessionStatus::Busy, 0.0));
        let rows = [&a, &b, &c]
            .into_iter()
            .map(|s| Row { key: s.id.clone(), title: s.name.clone(), subtitle: String::new(), term: None, session: Some(s), cwd: s.cwd.clone(), created: None })
            .collect();
        let out = ordered(rows, Sort::Status, true, &|s| s.updated_at, &|s| s.name.clone(), 10_000.0);
        let keys: Vec<_> = out[0].1.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(keys, ["b", "c", "a"]);
    }
}
