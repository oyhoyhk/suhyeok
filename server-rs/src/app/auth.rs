//! Pairing and device tokens: the same rules as MobileServer.swift (contract/README.md "페어링").
//! A 60 s single-use secret creates a request the owner allows or denies; the token is handed over once as the
//! `sh` cookie and only its SHA-256 is kept. Tokens expire 7 days after last use or 30 days after pairing.

use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;

pub const MAX_AGE: u64 = 30 * 86400;
const SECRET_TTL: f64 = 60.0;
const PENDING_TTL: f64 = 120.0;
const FAIL_WINDOW: f64 = 600.0;
const FAIL_LIMIT: usize = 5;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Device {
    pub hash: String,
    pub name: String,
    pub issued: f64,
    #[serde(rename = "lastUsed")]
    pub last_used: f64,
    /// Paired through the owner token (the desktop app on this machine), not through a link the owner approved.
    #[serde(default)]
    pub owner: bool,
}

impl Device {
    fn expired(&self, now: f64) -> bool {
        now - self.last_used > 7.0 * 86400.0 || now - self.issued > 30.0 * 86400.0
    }
}

#[derive(Clone, Debug)]
pub struct PendingPair {
    pub id: String,
    pub device: String,
    pub client: String,
    pub created: f64,
    /// None = waiting for the owner.
    pub decision: Option<bool>,
    pub token: Option<String>,
}

pub enum PairStatus {
    Waiting,
    Allowed(String),
    Denied,
    Expired,
    Unknown,
}

pub struct Auth {
    file: PathBuf,
    /// Secret only this machine's user can read (`<data dir>/owner-token`): the desktop app proves it is the owner
    /// with it, to open its own window without pairing and to answer other devices' requests.
    pub owner_token: String,
    pub devices: Vec<Device>,
    pub secret: Option<(String, f64)>,
    pub pending: Vec<PendingPair>,
    failed: HashMap<String, Vec<f64>>,
}

/// `<dir>/owner-token`, created on first use and readable by this user only (Unix 0600; on Windows the per-user
/// app-data folder already is).
fn owner_token(dir: &std::path::Path) -> String {
    let path = dir.join("owner-token");
    if let Ok(t) = std::fs::read_to_string(&path) {
        let t = t.trim().to_string();
        if t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit()) {
            return t;
        }
    }
    let t = random_hex(32);
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(&path, &t);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    t
}

pub fn random_hex(bytes: usize) -> String {
    let mut b = vec![0u8; bytes];
    rand::rng().fill_bytes(&mut b);
    hex::encode(b)
}

pub fn sha256_hex(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

/// Constant-time comparison for secrets.
fn equal(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn device_name(user_agent: &str, en: bool) -> String {
    for (k, n) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Macintosh", "Mac"), ("Windows", "Windows"), ("Linux", "Linux")] {
        if user_agent.contains(k) {
            return n.into();
        }
    }
    if en { "Browser" } else { "브라우저" }.into()
}

impl Auth {
    /// Devices persist in `<data dir>/devices.json`.
    pub fn load(file: PathBuf, now: f64) -> Auth {
        let devices: Vec<Device> = std::fs::read(&file)
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default();
        let owner_token = file.parent().map(owner_token).unwrap_or_else(|| random_hex(32));
        let mut a = Auth { file, owner_token, devices, secret: None, pending: vec![], failed: HashMap::new() };
        a.devices.retain(|d| !d.expired(now));
        a
    }

    fn save(&mut self, now: f64) {
        self.devices.retain(|d| !d.expired(now));
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(&self.devices) {
            let _ = std::fs::write(&self.file, json);
        }
    }

    /// The owner token checked in constant time.
    pub fn is_owner_token(&self, given: &str) -> bool {
        equal(given, &self.owner_token)
    }

    /// A device for the owner's own window: issued without a pairing request. Returns the cookie token.
    pub fn issue_owner(&mut self, name: &str, now: f64) -> String {
        // One owner window per machine: a new one replaces the older owner devices instead of piling up.
        self.devices.retain(|d| !d.owner);
        let token = random_hex(32);
        self.devices.push(Device { hash: sha256_hex(&token), name: name.into(), issued: now, last_used: now, owner: true });
        self.save(now);
        token
    }

    /// The `sh` cookie belongs to an owner device.
    pub fn owner_cookie(&self, cookie_header: Option<&str>) -> bool {
        let Some(token) = cookie_header.and_then(|c| c.split(';').map(str::trim).find_map(|kv| kv.strip_prefix("sh="))) else {
            return false;
        };
        let h = sha256_hex(token);
        self.devices.iter().any(|d| d.owner && d.hash == h)
    }

    pub fn forget(&mut self, hash: &str, now: f64) -> bool {
        let before = self.devices.len();
        self.devices.retain(|d| d.hash != hash);
        self.save(now);
        self.devices.len() != before
    }

    /// A fresh 128-bit secret for 60 seconds; starting again also lifts any lockout.
    pub fn begin_pairing(&mut self, now: f64) -> String {
        let s = random_hex(16);
        self.secret = Some((s.clone(), now + SECRET_TTL));
        self.failed.clear();
        s
    }

    /// Step 1: the secret from the link. Ok(pending id) or Err((status, message)).
    pub fn pair(&mut self, given: Option<&str>, client: &str, device: String, now: f64, en: bool) -> Result<String, (u16, String)> {
        let fails = self.failed.entry(client.to_string()).or_default();
        fails.retain(|t| now - t < FAIL_WINDOW);
        if fails.len() >= FAIL_LIMIT {
            return Err((429, if en {
                "Try again later — pressing 'Start pairing' on the server lifts this right away"
            } else {
                "잠시 후 다시 시도 — 서버에서 '연결 시작'을 다시 누르면 바로 풀림"
            }.into()));
        }
        let ok = match (given, &self.secret) {
            (Some(g), Some((s, until))) => now < *until && equal(g, s),
            _ => false,
        };
        if !ok {
            fails.push(now);
            return Err((403, if en {
                "Pairing link expired — press 'Start pairing' on the server and copy the link again"
            } else {
                "연결 링크가 만료됨 — 서버에서 '연결 시작'을 누르고 링크를 다시 받기"
            }.into()));
        }
        self.secret = None; // single use
        self.pending.retain(|p| now - p.created <= PENDING_TTL);
        let id = random_hex(16);
        self.pending.push(PendingPair { id: id.clone(), device, client: client.into(), created: now, decision: None, token: None });
        Ok(id)
    }

    /// The owner's answer to a waiting request.
    pub fn decide(&mut self, id: &str, allow: bool, now: f64) -> bool {
        let Some(i) = self.pending.iter().position(|p| p.id == id && p.decision.is_none()) else { return false };
        self.pending[i].decision = Some(allow);
        if allow {
            let token = random_hex(32);
            self.pending[i].token = Some(token.clone());
            let name = self.pending[i].device.clone();
            self.devices.push(Device { hash: sha256_hex(&token), name, issued: now, last_used: now, owner: false });
            self.save(now);
        }
        true
    }

    pub fn oldest_waiting(&self, now: f64) -> Option<String> {
        self.pending.iter().find(|p| p.decision.is_none() && now - p.created < PENDING_TTL).map(|p| p.id.clone())
    }

    /// Step 2: the client polls; the token is handed over once.
    pub fn status(&mut self, id: &str, now: f64) -> PairStatus {
        let Some(i) = self.pending.iter().position(|p| p.id == id) else { return PairStatus::Unknown };
        if now - self.pending[i].created > PENDING_TTL {
            self.pending.remove(i);
            return PairStatus::Expired;
        }
        match self.pending[i].decision {
            None => PairStatus::Waiting,
            Some(false) => {
                self.pending.remove(i);
                PairStatus::Denied
            }
            Some(true) => {
                let p = self.pending.remove(i);
                PairStatus::Allowed(p.token.unwrap_or_default())
            }
        }
    }

    /// Checks the `sh` cookie; touches lastUsed at most once an hour.
    pub fn authorized(&mut self, cookie_header: Option<&str>, now: f64) -> bool {
        let Some(token) = cookie_header.and_then(|c| {
            c.split(';').map(str::trim).find_map(|kv| kv.strip_prefix("sh=")).map(str::to_string)
        }) else {
            return false;
        };
        let h = sha256_hex(&token);
        let Some(i) = self.devices.iter().position(|d| d.hash == h) else { return false };
        if self.devices[i].expired(now) {
            self.devices.remove(i);
            self.save(now);
            return false;
        }
        if now - self.devices[i].last_used > 3600.0 {
            self.devices[i].last_used = now;
            self.save(now);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auth() -> (tempfile::TempDir, Auth) {
        let dir = tempfile::tempdir().unwrap();
        let a = Auth::load(dir.path().join("devices.json"), 1000.0);
        (dir, a)
    }

    #[test]
    fn pairing_round_trip_issues_a_token_once() {
        let (_d, mut a) = auth();
        let s = a.begin_pairing(1000.0);
        let id = a.pair(Some(&s), "local", "Windows".into(), 1001.0, false).unwrap();
        assert!(a.pair(Some(&s), "local", "x".into(), 1002.0, false).is_err(), "secret is single use");
        assert!(matches!(a.status(&id, 1003.0), PairStatus::Waiting));
        assert!(a.decide(&id, true, 1004.0));
        let PairStatus::Allowed(token) = a.status(&id, 1005.0) else { panic!() };
        assert!(matches!(a.status(&id, 1006.0), PairStatus::Unknown), "handed over once");
        assert!(a.authorized(Some(&format!("a=b; sh={token}")), 1007.0));
        assert!(!a.authorized(Some("sh=nope"), 1007.0));
        // Persisted and reloaded.
        let b = Auth::load(a.file.clone(), 1008.0);
        assert_eq!(b.devices.len(), 1);
    }

    #[test]
    fn owner_token_is_stable_and_issues_owner_devices() {
        let (_d, mut a) = auth();
        let t = a.owner_token.clone();
        assert_eq!(t.len(), 64);
        assert!(a.is_owner_token(&t) && !a.is_owner_token("x"));
        assert_eq!(Auth::load(a.file.clone(), 1000.0).owner_token, t, "same token after a restart");
        let first = a.issue_owner("이 PC", 1000.0);
        let cookie = a.issue_owner("이 PC", 1000.0);
        assert!(!a.authorized(Some(&format!("sh={first}")), 1000.0), "a new owner window replaces the old one");
        assert_eq!(a.devices.iter().filter(|d| d.owner).count(), 1);
        assert!(a.owner_cookie(Some(&format!("sh={cookie}"))));
        assert!(a.authorized(Some(&format!("sh={cookie}")), 1001.0));
        let s = a.begin_pairing(1000.0);
        let id = a.pair(Some(&s), "c", "Android".into(), 1000.0, false).unwrap();
        a.decide(&id, true, 1000.0);
        let PairStatus::Allowed(other) = a.status(&id, 1000.0) else { panic!() };
        assert!(!a.owner_cookie(Some(&format!("sh={other}"))), "approved devices are not owners");
        let h = sha256_hex(&other);
        assert!(a.forget(&h, 1002.0));
        assert!(!a.authorized(Some(&format!("sh={other}")), 1003.0));
    }

    #[test]
    fn expiry_and_lockout() {
        let (_d, mut a) = auth();
        let s = a.begin_pairing(1000.0);
        assert!(a.pair(Some(&s), "c", "x".into(), 1061.0, false).is_err(), "secret lives 60 s");
        for _ in 0..4 {
            let _ = a.pair(Some("0"), "c", "x".into(), 1062.0, false);
        }
        let e = a.pair(Some("0"), "c", "x".into(), 1063.0, false).unwrap_err();
        assert_eq!(e.0, 429);
        let s = a.begin_pairing(1064.0); // lifts the lockout
        let id = a.pair(Some(&s), "c", "x".into(), 1065.0, false).unwrap();
        assert!(matches!(a.status(&id, 1065.0 + 121.0), PairStatus::Expired));
        a.devices.push(Device { hash: sha256_hex("t"), name: "n".into(), issued: 0.0, last_used: 0.0, owner: false });
        assert!(!a.authorized(Some("sh=t"), 8.0 * 86400.0), "idle 7 days");
    }
}
