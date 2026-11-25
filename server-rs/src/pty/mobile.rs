//! The terminal tab of the phone and the /desk page (MobileTerminal.swift): the hosted terminals (agents, plain
//! shells, the bottom panel), read as screens with their colors and typed into. JSON shapes match the Mac's
//! `GET /api/terminals`, `GET /api/term` and `POST /api/term-input`.

use super::host::{Host, Hosted};
use super::launch::{PANEL_NAME, SHELL_TAG};
use serde_json::{json, Value};

/// Keys the phone may press, as tmux names them. Ctrl+letter ("C-c") is allowed on top of these.
pub const KEYS: [&str; 14] =
    ["Enter", "Tab", "BTab", "Escape", "BSpace", "DC", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown"];

/// What tmux `send-keys <key>` writes to a pane for the keys above (xterm encodings; arrows, Home and End as SS3
/// when the program turned on application cursor keys). None for a key the phone may not press.
pub fn key_bytes(key: &str, app_cursor: bool) -> Option<Vec<u8>> {
    if let [b'C', b'-', c] = key.as_bytes() {
        return c.is_ascii_lowercase().then(|| vec![c - b'a' + 1]);
    }
    let cursor = |k: u8| if app_cursor { vec![0x1b, b'O', k] } else { vec![0x1b, b'[', k] };
    Some(match key {
        "Enter" => b"\r".to_vec(),
        "Tab" => b"\t".to_vec(),
        "BTab" => b"\x1b[Z".to_vec(),
        "Escape" => b"\x1b".to_vec(),
        "BSpace" => b"\x7f".to_vec(),
        "DC" => b"\x1b[3~".to_vec(),
        "Up" => cursor(b'A'),
        "Down" => cursor(b'B'),
        "Right" => cursor(b'C'),
        "Left" => cursor(b'D'),
        "Home" => cursor(b'H'),
        "End" => cursor(b'F'),
        "PageUp" => b"\x1b[5~".to_vec(),
        "PageDown" => b"\x1b[6~".to_vec(),
        _ => return None,
    })
}

/// `/api/terminals` rows: every terminal, oldest first. `who` gives the agent's display name and character id for
/// a terminal whose agent session is known (SessionStore.agentName / character); ("", None) otherwise, and the
/// character pinned at launch fills in.
pub fn terminals(host: &Host, who: impl Fn(&Hosted) -> (String, Option<String>)) -> Vec<Value> {
    host.list()
        .into_iter()
        .map(|h| {
            let (agent_name, character) = who(&h);
            json!({
                "name": h.name,
                "title": h.title,
                "cwd": h.cwd,
                "kind": h.agent.map(|a| a.raw()).unwrap_or(SHELL_TAG),
                "panel": h.name == PANEL_NAME,
                "agentName": agent_name,
                "character": character.or_else(|| h.character.clone()).unwrap_or_default(),
                "created": h.created,
            })
        })
        .collect()
}

/// `/api/term` body: `history` lines of scrollback (0-2000) above the visible screen, colors as SGR escapes,
/// size, cursor and alternate screen. None when there is no such terminal (`404 {"error":"gone"}`).
pub fn screen(host: &Host, name: &str, history: i64) -> Option<Value> {
    host.screen(name, history.clamp(0, 2000) as usize).map(|s| s.to_json())
}

/// Types `text` as it is (no Enter; tmux `send-keys -l`).
pub fn type_text(host: &Host, name: &str, text: &str) -> bool {
    !text.is_empty() && host.write_bytes(name, text.as_bytes())
}

/// Presses one of `KEYS` or Ctrl+letter.
pub fn press(host: &Host, name: &str, key: &str) -> bool {
    let ctrl = key.len() == 3 && key.starts_with("C-") && key.as_bytes()[2].is_ascii_lowercase();
    if !KEYS.contains(&key) && !ctrl {
        return false;
    }
    let Some((_, app)) = host.modes(name) else { return false };
    key_bytes(key, app).is_some_and(|b| host.write_bytes(name, &b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_encodings() {
        assert_eq!(key_bytes("Up", false).unwrap(), b"\x1b[A");
        assert_eq!(key_bytes("Up", true).unwrap(), b"\x1bOA");
        assert_eq!(key_bytes("C-c", false).unwrap(), [3]);
        assert_eq!(key_bytes("BSpace", false).unwrap(), [0x7f]);
        assert_eq!(key_bytes("C-C", false), None);
        assert_eq!(key_bytes("F1", false), None);
        for k in KEYS {
            assert!(key_bytes(k, false).is_some(), "{k}");
        }
    }
}
