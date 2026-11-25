//! Authenticated routes (contract/README.md "인증 필요"), the same paths and answers as MobileServer.route.
//! Reads come from the store; actions go to the agents through this server's terminals (src/pty) with the
//! keystroke rules of src/menu.rs. Anything that types or waits runs in spawn_blocking.

use super::http::json_reply;
use super::App;
use axum::body::Body;
use axum::http::{HeaderMap, Response};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use suhyeok::menu::{self, Key, Term};
use suhyeok::model::{home, now, Agent, AgentSession};
use suhyeok::pty::{launch, Launch};

const RESEND_WINDOW: f64 = 5.0;

fn msg(en: bool, ko: &str, english: &str) -> String {
    if en { english } else { ko }.to_string()
}

/// The session `id` names, copied out of the store.
fn session(app: &App, id: Option<&Value>) -> Option<AgentSession> {
    let id = id?.as_str()?;
    app.store.lock().unwrap().sessions.iter().find(|s| s.id == id).cloned()
}

/// The terminal a hosted session runs in, as `menu::Term` (Claude gets its pid for the panel check).
fn term_for(app: &App, s: &AgentSession) -> Option<suhyeok::pty::HostedTerm> {
    let claude = if s.agent == Agent::Claude { s.pid } else { None };
    app.host.term(s.hosted_name.as_deref()?, claude)
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    tokio::task::spawn_blocking(f).await.ok()
}

pub async fn route(
    app: &Arc<App>,
    method: &str,
    path: &str,
    q: &HashMap<String, String>,
    _h: &HeaderMap,
    bytes: &[u8],
    body: &Value,
) -> Response<Body> {
    let en = app.config.en;
    match (method, path) {
        ("GET", "/api/state") => json_reply(app.store.lock().unwrap().state_json(), 200),
        ("GET", "/api/chat") => {
            let Some(s) = session(app, q.get("id").map(|v| json!(v)).as_ref()) else {
                return json_reply(json!({"error": "gone"}), 404);
            };
            let term = term_for(app, &s);
            let screen = q.get("screen").map(String::as_str) == Some("1");
            let v = blocking(move || super::store::Store::chat_json(&s, term.as_ref().map(|t| t as &dyn Term), screen, en)).await;
            json_reply(v.unwrap_or(json!({})), 200)
        }
        ("GET", "/api/events") => {
            let store = app.store.lock().unwrap();
            let e = &store.events;
            let after = q.get("after").and_then(|v| v.parse::<u64>().ok());
            let fresh = e.since(after, q.get("boot").map(String::as_str));
            json_reply(
                json!({"boot": e.boot, "seq": e.seq, "events": fresh.iter().map(|x| json!({
                    "seq": x.seq, "id": x.session, "name": x.name, "title": x.title, "kind": x.kind, "text": x.text, "at": x.at,
                })).collect::<Vec<_>>()}),
                200,
            )
        }
        ("GET", "/api/sidebar") => {
            let store = app.store.lock().unwrap();
            json_reply(store.sidebar_json(q.get("sort").map(String::as_str), q.get("asc").map(String::as_str) == Some("1")), 200)
        }
        ("GET", "/api/folders") => json_reply(json!({"home": home(), "folders": app.store.lock().unwrap().known_folders()}), 200),
        ("GET", "/api/files") => {
            if q.contains_key("dir") {
                return json_reply(json!({"error": "gone"}), 404);
            }
            json_reply(json!({"home": home(), "folders": []}), 200)
        }
        ("GET", "/app/android.json") | ("GET", "/app/android.apk") => json_reply(json!({"error": "none"}), 404),

        // Terminal tab (MobileTerminal): this server's terminals, their screens, typing and keys, a new shell.
        ("GET", "/api/terminals") => {
            let store = app.store.lock().unwrap();
            let list = suhyeok::pty::mobile::terminals(&app.host, |h| {
                let s = store.sessions.iter().find(|s| s.hosted_name.as_deref() == Some(h.name.as_str()));
                let name = s.map(|s| store.agent_name(s)).unwrap_or_default();
                let character = s.and_then(|s| store.party.character(s)).map(|c| c.id.clone()).or_else(|| h.character.clone());
                (name, character)
            });
            json_reply(json!({"terminals": list}), 200)
        }
        ("GET", "/api/term") => {
            let name = q.get("name").cloned().unwrap_or_default();
            let history = q.get("history").and_then(|v| v.parse::<i64>().ok()).unwrap_or(300);
            match suhyeok::pty::mobile::screen(&app.host, &name, history) {
                Some(v) => json_reply(v, 200),
                None => json_reply(json!({"error": "gone"}), 404),
            }
        }
        ("POST", "/api/term-input") => {
            let Some(name) = body.get("name").and_then(Value::as_str).map(str::to_string) else {
                return json_reply(json!({"ok": false}), 400);
            };
            let host = app.host.clone();
            let (text, key) = (body.get("text").and_then(Value::as_str).map(str::to_string), body.get("key").and_then(Value::as_str).map(str::to_string));
            let ok = blocking(move || match (text, key) {
                (Some(t), _) => suhyeok::pty::mobile::type_text(&host, &name, &t),
                (None, Some(k)) => suhyeok::pty::mobile::press(&host, &name, &k),
                _ => false,
            })
            .await
            .unwrap_or(false);
            json_reply(json!({"ok": ok}), 200)
        }
        ("POST", "/api/term-new") => {
            let host = app.host.clone();
            match blocking(move || host.create_shell(&home(), None)).await.flatten() {
                Some(name) => json_reply(json!({"ok": true, "name": name}), 200),
                None => json_reply(json!({"ok": false}), 200),
            }
        }

        ("POST", "/api/send") => {
            let (Some(s), Some(text)) = (session(app, body.get("id")), body.get("text").and_then(Value::as_str).map(str::to_string)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            if text.is_empty() {
                return json_reply(json!({"ok": false}), 400);
            }
            let key = format!("{}\0{}", s.id, text);
            {
                let mut sends = app.last_sends.lock().unwrap();
                let t = now();
                sends.retain(|_, at| t - *at < RESEND_WINDOW);
                if sends.contains_key(&key) {
                    return json_reply(json!({"ok": true}), 200);
                }
                sends.insert(key.clone(), t); // set before typing: a copy arriving mid-send is caught too
            }
            let Some(term) = term_for(app, &s) else {
                app.last_sends.lock().unwrap().remove(&key);
                return json_reply(json!({"ok": false}), 200);
            };
            let agent = s.agent;
            let ok = blocking(move || menu::send(&term, agent, &text)).await.unwrap_or(false);
            let mut sends = app.last_sends.lock().unwrap();
            if ok {
                sends.insert(key, now()); // the window runs from the end of the send
            } else {
                sends.remove(&key); // a failed send may be retried
            }
            json_reply(json!({"ok": ok}), 200)
        }
        ("POST", "/api/key") => {
            let (Some(s), Some(key)) = (session(app, body.get("id")), body.get("key").and_then(Value::as_str).and_then(Key::from_name)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            let Some(term) = term_for(app, &s) else { return json_reply(json!({"ok": false}), 200) };
            let ok = blocking(move || menu::press(&term, key)).await.unwrap_or(false);
            json_reply(json!({"ok": ok}), 200)
        }
        ("POST", "/api/choose") => {
            let (Some(s), Some(i)) = (session(app, body.get("id")), body.get("index").and_then(Value::as_u64)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            let text = body.get("text").and_then(Value::as_str).unwrap_or("").trim().to_string();
            let Some(term) = term_for(app, &s) else { return json_reply(json!({"ok": false}), 200) };
            let ok = blocking(move || menu::choose_on_screen(&term, i as usize, &text)).await.unwrap_or(false);
            json_reply(json!({"ok": ok}), 200)
        }
        ("POST", "/api/choose-hosted") => {
            let (Some(name), Some(i)) = (body.get("name").and_then(Value::as_str), body.get("index").and_then(Value::as_u64)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            if !app.host.get(name).is_some_and(|h| h.agent.is_some()) {
                return json_reply(json!({"ok": false}), 400);
            }
            let Some(term) = app.host.term(name, None) else { return json_reply(json!({"ok": false}), 400) };
            let ok = blocking(move || menu::hosted_choose(&term, i as usize)).await.unwrap_or(false);
            json_reply(json!({"ok": ok}), 200)
        }
        ("POST", "/api/upload") => {
            let name = q.get("name").cloned().unwrap_or_default();
            match save_upload(&app.config.data_dir, bytes, &name) {
                Some(path) => json_reply(json!({"ok": true, "path": path}), 200),
                None => json_reply(json!({"ok": false}), 400),
            }
        }

        // New session (NewSessionSheet) and "이어서" on a recent conversation.
        ("POST", "/api/new") => {
            let agent = body.get("agent").and_then(Value::as_str).and_then(Agent::from_raw);
            let cwd = body.get("cwd").and_then(Value::as_str).unwrap_or("");
            let (Some(agent), true) = (agent, std::path::Path::new(cwd).is_dir()) else {
                return json_reply(json!({"ok": false, "message": msg(en, "작업 폴더가 없음", "No such folder")}), 200);
            };
            let mut l = Launch::new(agent, cwd);
            l.prompt = body.get("prompt").and_then(Value::as_str).map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
            json_reply(json!({"ok": start(app, l, None, None).await}), 200)
        }
        ("POST", "/api/resume") => {
            let Some(id) = body.get("id").and_then(Value::as_str) else { return json_reply(json!({"ok": false}), 400) };
            let r = app.store.lock().unwrap().recent.iter().find(|r| r.id == id).cloned();
            let Some(r) = r else { return json_reply(json!({"ok": false}), 200) };
            let mut l = Launch::new(r.agent, &r.cwd);
            l.resume = Some(r.id.clone());
            json_reply(json!({"ok": start(app, l, Some(r.id.clone()), None).await}), 200)
        }

        // The long-press / right-click menu (AgentMenu).
        ("POST", "/api/action") => {
            let (Some(s), Some(action)) = (session(app, body.get("id")), body.get("action").and_then(Value::as_str)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            action_route(app, s, action, body, en).await
        }
        _ => json_reply(json!({"error": "not found"}), 404),
    }
}

/// Starts an agent terminal with its character (SessionStore.start / character(resuming:)), then refreshes.
async fn start(app: &Arc<App>, mut l: Launch, conversation: Option<String>, from: Option<AgentSession>) -> bool {
    l.en = app.config.en;
    l.character = app.store.lock().unwrap().party.character_for_launch(conversation.as_deref(), from.as_ref(), now());
    let a = app.clone();
    blocking(move || {
        let name = a.host.create_agent(&l);
        if name.is_some() {
            a.refresh();
        }
        name.is_some()
    })
    .await
    .unwrap_or(false)
}

async fn action_route(app: &Arc<App>, s: AgentSession, action: &str, body: &Value, en: bool) -> Response<Body> {
    match action {
        "clone" => {
            let Some(conv) = s.conversation_id.clone() else {
                return json_reply(json!({"ok": false, "message": msg(en, "이어 열 대화가 없음", "No conversation to continue")}), 200);
            };
            if !s.agent.can_fork() {
                return json_reply(json!({"ok": false, "message": msg(en, "Antigravity는 클론을 지원하지 않음", "Antigravity cannot clone")}), 200);
            }
            let mut l = Launch::new(s.agent, &s.cwd);
            l.resume = Some(conv);
            l.fork = true;
            let ok = start(app, l, None, Some(s)).await;
            json_reply(json!({"ok": ok, "message": msg(en, "클론을 만드는 중", "Making a clone")}), 200)
        }
        "rename" => {
            let text = body.get("text").and_then(Value::as_str).unwrap_or("").trim().to_string();
            if let Some(conv) = &s.conversation_id {
                let mut store = app.store.lock().unwrap();
                if text.is_empty() {
                    store.summaries.remove(conv);
                } else {
                    store.summaries.insert(conv.clone(), text);
                }
            }
            let a = app.clone();
            blocking(move || a.refresh()).await;
            json_reply(json!({"ok": true}), 200)
        }
        "clear" => {
            if s.agent != Agent::Claude {
                return json_reply(json!({"ok": false, "message": msg(en, "Claude 세션만 가능", "Claude sessions only")}), 200);
            }
            let Some(term) = term_for(app, &s) else { return json_reply(json!({"ok": false}), 200) };
            let ok = blocking(move || menu::send(&term, Agent::Claude, "/clear")).await.unwrap_or(false);
            json_reply(json!({"ok": ok}), 200)
        }
        "end" => {
            let Some(name) = s.hosted_name.clone().filter(|n| app.host.exists(n)) else {
                return json_reply(json!({"ok": false, "message": msg(en, "이 서버의 터미널이 아님", "Not in this server's terminals")}), 200);
            };
            let Some(term) = term_for(app, &s) else { return json_reply(json!({"ok": false}), 200) };
            let (host, agent) = (app.host.clone(), s.agent);
            blocking(move || {
                menu::send(&term, agent, launch::quit_command(agent));
                std::thread::sleep(std::time::Duration::from_millis(1500));
                host.kill(&name)
            })
            .await;
            let a = app.clone();
            blocking(move || a.refresh()).await;
            json_reply(json!({"ok": true, "message": msg(en, "종료함", "Ended")}), 200)
        }
        "migrate" => {
            // Another terminal cannot be typed into from here: the conversation is opened in a new terminal and the
            // original keeps running (the Mac's fallback when the original terminal takes no input).
            let Some(conv) = s.conversation_id.clone().filter(|_| s.hosted_name.is_none()) else {
                return json_reply(json!({"ok": false, "message": msg(en, "옮길 수 없는 세션", "This session cannot be moved")}), 200);
            };
            let mut l = Launch::new(s.agent, &s.cwd);
            l.resume = Some(conv.clone());
            let ok = start(app, l, Some(conv), Some(s)).await;
            json_reply(
                json!({"ok": ok, "message": msg(en, "수혁에서 이어서 열었음 — 원래 터미널의 세션은 직접 종료하기", "Opened in 수혁 — end the original terminal's session yourself")}),
                200,
            )
        }
        _ => json_reply(json!({"ok": false}), 400),
    }
}

/// A file from the phone or PC, kept in a temporary folder (Attachments.savePhone); the client puts the path in its
/// message.
fn save_upload(data_dir: &std::path::Path, bytes: &[u8], name: &str) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    let dir = std::env::temp_dir().join("suhyeok-uploads");
    std::fs::create_dir_all(&dir).ok()?;
    let _ = data_dir;
    let clean: String = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| !c.is_control() && !matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|'))
        .collect();
    let clean = if clean.is_empty() || clean.starts_with('.') { "upload.bin".to_string() } else { clean };
    let path = dir.join(format!("{}-{}", suhyeok::model::now() as u64, clean));
    std::fs::write(&path, bytes).ok()?;
    Some(path.to_string_lossy().into_owned())
}
