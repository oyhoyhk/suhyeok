//! HTTP layer: the routes and security rules of MobileServer.swift (contract/README.md), on axum.
//! One fallback handler matches method + path like the Swift `route`, so the two stay easy to compare.

use super::auth::{device_name, PairStatus, MAX_AGE};
use super::App;
use axum::body::{to_bytes, Body, Bytes};
use axum::extract::{Request, State};
use axum::http::{header, HeaderMap, HeaderValue, Method, Response, StatusCode};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use suhyeok::model::now;

/// The shared desktop page; `{{LANG}}` becomes ko/en (see DesktopPage.swift).
pub const DESK_HTML: &str = include_str!("../../../web/desk.html");

const MAX_BODY: usize = 64 * 1024;
pub const MAX_UPLOAD: usize = 25 * 1024 * 1024;
const CSP: &str = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; form-action 'self'";

pub fn router(app: Arc<App>) -> axum::Router {
    axum::Router::new().fallback(handle).with_state(app)
}

fn reply(status: u16, content_type: &str, body: impl Into<Body>, extra: &[(&str, String)]) -> Response<Body> {
    let mut r = Response::new(body.into());
    *r.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let h = r.headers_mut();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_str(content_type).unwrap());
    let has_cache = extra.iter().any(|(k, _)| k.eq_ignore_ascii_case("cache-control"));
    if !has_cache {
        h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    h.insert("x-content-type-options", HeaderValue::from_static("nosniff"));
    h.insert(header::REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    h.insert(header::CONNECTION, HeaderValue::from_static("close"));
    h.insert("x-frame-options", HeaderValue::from_static("DENY"));
    h.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP));
    for (k, v) in extra {
        if let (Ok(k), Ok(v)) = (header::HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v)) {
            h.insert(k, v);
        }
    }
    r
}

pub fn json_reply(v: Value, status: u16) -> Response<Body> {
    reply(status, "application/json; charset=utf-8", v.to_string(), &[])
}

fn hdr<'a>(h: &'a HeaderMap, k: &str) -> Option<&'a str> {
    h.get(k).and_then(|v| v.to_str().ok())
}

/// 127.0.0.1/localhost on our port, or a host the owner opened (tunnel, LAN address). Blocks DNS rebinding.
fn allowed_host(app: &App, h: &HeaderMap) -> bool {
    hdr(h, "host").is_some_and(|host| app.host_allowed(host))
}

/// The pairing cookie: Secure only over https (the tunnel). Plain http — this machine's 127.0.0.1 and the LAN
/// listener — gets it without Secure, because WebKit (macOS WKWebView, Linux WebKitGTK, Safari) drops a Secure cookie
/// on http even for 127.0.0.1. On the LAN prefer Tailscale (encrypted) over an open Wi-Fi.
fn cookie(app: &App, h: &HeaderMap, token: &str) -> String {
    let host = hdr(h, "host").unwrap_or("").to_lowercase();
    let https = hdr(h, "x-forwarded-proto") == Some("https") || app.extra_hosts().iter().any(|x| *x == host);
    let secure = if https { " Secure;" } else { "" };
    format!("sh={token}; Path=/; Max-Age={MAX_AGE}; HttpOnly;{secure} SameSite=Strict")
}

/// Addressed as this machine (127.0.0.1 / localhost on our port): the owner routes never answer through a tunnel or LAN.
fn local_host(app: &App, h: &HeaderMap) -> bool {
    let port = app.config.port;
    hdr(h, "host").map(str::to_lowercase).is_some_and(|x| x == format!("127.0.0.1:{port}") || x == format!("localhost:{port}"))
}

/// The page the desktop app opens for its own window: `/owner#<owner token>` pairs this window as the owner
/// (same-origin POST, the token never goes in a URL the server sees) and goes on to the desk page.
const OWNER_HTML: &str = r#"<!doctype html><meta charset="utf-8"><title>수혁</title><body style="background:#232129">
<script>
const t = location.hash.slice(1);
history.replaceState(null, "", "/owner");
fetch("/pair/owner", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({token: t})})
  .then(r => { location.replace(r.ok ? "/desk" : "/desk#owner-failed"); });
</script>"#;

/// State-changing calls only from our own page: JSON bodies and, when the browser says, same-origin.
fn same_origin(method: &Method, path: &str, h: &HeaderMap) -> bool {
    if method != Method::POST {
        return true;
    }
    let want = if path == "/api/upload" { "application/octet-stream" } else { "application/json" };
    if !hdr(h, "content-type").unwrap_or("").starts_with(want) {
        return false;
    }
    if let Some(site) = hdr(h, "sec-fetch-site") {
        if site != "same-origin" && site != "none" {
            return false;
        }
    }
    if let (Some(origin), Some(host)) = (hdr(h, "origin"), hdr(h, "host")) {
        let oh = origin.split("://").nth(1).unwrap_or("").split(['/', ':']).next().unwrap_or("").to_lowercase();
        let hh = host.split(':').next().unwrap_or("").to_lowercase();
        if oh != hh {
            return false;
        }
    }
    true
}

/// Cloudflare's CF-Connecting-IP through a tunnel; "local" otherwise.
fn client(h: &HeaderMap) -> String {
    let host = hdr(h, "host").unwrap_or("");
    match hdr(h, "cf-connecting-ip") {
        Some(ip) if !host.starts_with("127.0.0.1") => ip.to_string(),
        // The LAN listener: the address it was reached at (the client's own address needs ConnectInfo).
        _ if !host.starts_with("127.0.0.1") && !host.starts_with("localhost") => format!("LAN · {host}"),
        _ => "local".into(),
    }
}

fn query(uri: &axum::http::Uri) -> HashMap<String, String> {
    uri.query()
        .unwrap_or("")
        .split('&')
        .filter_map(|kv| {
            let mut p = kv.splitn(2, '=');
            let k = p.next()?;
            let v = p.next()?;
            Some((pct_decode(k), pct_decode(v)))
        })
        .collect()
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        // Like Swift removingPercentEncoding: %XX only; '+' stays '+'.
        if b[i] == b'%' && i + 3 <= b.len() {
            if let Ok(v) = u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"), 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

async fn handle(State(app): State<Arc<App>>, req: Request) -> Response<Body> {
    let (parts, body) = req.into_parts();
    let (method, path, h) = (parts.method.clone(), parts.uri.path().to_string(), parts.headers.clone());
    let q = query(&parts.uri);
    if hdr(&h, "transfer-encoding").is_some() {
        return reply(400, "text/plain", "bad request", &[]);
    }
    let limit = if path == "/api/upload" { MAX_UPLOAD } else { MAX_BODY };
    let declared = hdr(&h, "content-length").and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
    if declared > limit {
        // Past the normal size only a paired client may send (an upload); everyone else gets the pairing answer.
        if path == "/api/upload" && !app.authorized(hdr(&h, "cookie")) {
            return json_reply(json!({"error": "pair"}), 401);
        }
        return reply(400, "text/plain", "bad request", &[]);
    }
    let bytes: Bytes = match to_bytes(body, limit).await {
        Ok(b) => b,
        Err(_) => return reply(400, "text/plain", "bad request", &[]),
    };

    if !allowed_host(&app, &h) {
        return json_reply(json!({"error": "host"}), 421);
    }
    if !same_origin(&method, &path, &h) {
        return json_reply(json!({"error": "origin"}), 403);
    }
    let en = app.config.en;
    match (method.as_str(), path.as_str()) {
        // The phone page is not shared yet (MobilePage.swift has 21 localized strings): the desk page serves both.
        ("GET", "/") | ("GET", "/index.html") | ("GET", "/desk") => {
            let page = DESK_HTML.replace("{{LANG}}", if en { "en" } else { "ko" });
            return reply(200, "text/html; charset=utf-8", page, &[]);
        }
        ("GET", "/owner") if local_host(&app, &h) => {
            return reply(200, "text/html; charset=utf-8", OWNER_HTML, &[]);
        }
        ("POST", "/pair/owner") if local_host(&app, &h) => {
            let body: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let given = body.get("token").and_then(Value::as_str).unwrap_or("");
            let mut auth = app.auth.lock().unwrap();
            if !auth.is_owner_token(given) {
                return json_reply(json!({"error": "owner"}), 403);
            }
            let token = auth.issue_owner(if en { "This computer" } else { "이 컴퓨터" }, now());
            return reply(200, "application/json; charset=utf-8", json!({"ok": true}).to_string(), &[("set-cookie", cookie(&app, &h, &token))]);
        }
        ("POST", "/pair") => {
            let body: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let device = device_name(hdr(&h, "user-agent").unwrap_or(""), en);
            let result = app.auth.lock().unwrap().pair(body.get("secret").and_then(Value::as_str), &client(&h), device, now(), en);
            return match result {
                Ok(id) => {
                    app.on_pair_request(&id);
                    json_reply(json!({"pending": id}), 200)
                }
                Err((status, msg)) => json_reply(json!({"error": msg}), status),
            };
        }
        ("GET", "/pair/status") => {
            let id = q.get("id").cloned().unwrap_or_default();
            let st = app.auth.lock().unwrap().status(&id, now());
            return match st {
                PairStatus::Waiting => json_reply(json!({"waiting": true}), 200),
                PairStatus::Allowed(token) => {
                    reply(200, "application/json; charset=utf-8", json!({"ok": true}).to_string(), &[("set-cookie", cookie(&app, &h, &token))])
                }
                PairStatus::Denied => json_reply(json!({"error": if en { "Denied on the server" } else { "서버에서 거부됨" }}), 403),
                PairStatus::Expired => json_reply(json!({"error": if en { "Not allowed within 2 minutes, expired" } else { "서버에서 2분 안에 허용하지 않아 만료됨" }}), 410),
                PairStatus::Unknown => json_reply(json!({"error": if en { "Request not found — pair again" } else { "요청을 찾을 수 없음 — 다시 연결" }}), 404),
            };
        }
        _ => {}
    }
    // Static art needs no pairing (the same art ships in the public app).
    if method == Method::GET {
        if let Some(rel) = path.strip_prefix("/art/") {
            if let Some((data, kind)) = app.public_art(rel) {
                return reply(200, kind, data, &[("cache-control", "max-age=86400".into())]);
            }
        }
    }
    // Owner routes: this machine only, with the owner token (desktop app) or an owner device's cookie.
    if path.starts_with("/api/owner/") {
        let owner = local_host(&app, &h) && {
            let auth = app.auth.lock().unwrap();
            hdr(&h, "x-suhyeok-owner").is_some_and(|t| auth.is_owner_token(t)) || auth.owner_cookie(hdr(&h, "cookie"))
        };
        if !owner {
            return json_reply(json!({"error": "owner"}), 403);
        }
        let body: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
        return owner_route(&app, method.as_str(), &path, &body);
    }
    if !app.authorized(hdr(&h, "cookie")) {
        return json_reply(json!({"error": "pair"}), 401);
    }
    let body: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
    super::api::route(&app, method.as_str(), &path, &q, &h, &bytes, &body).await
}

/// What only the owner may do: answer other devices' pairing requests, start pairing, see and drop devices.
fn owner_route(app: &Arc<App>, method: &str, path: &str, body: &Value) -> Response<Body> {
    let t = now();
    let mut auth = app.auth.lock().unwrap();
    match (method, path) {
        ("GET", "/api/owner/pending") => {
            let list: Vec<Value> = auth
                .pending
                .iter()
                .filter(|p| p.decision.is_none() && t - p.created < 120.0)
                .map(|p| json!({"id": p.id, "device": p.device, "client": p.client, "created": p.created}))
                .collect();
            json_reply(json!({"pending": list}), 200)
        }
        ("POST", "/api/owner/decide") => {
            let (Some(id), Some(allow)) = (body.get("id").and_then(Value::as_str), body.get("allow").and_then(Value::as_bool)) else {
                return json_reply(json!({"ok": false}), 400);
            };
            json_reply(json!({"ok": auth.decide(id, allow, t)}), 200)
        }
        // "연결 시작": a 60 s single-use secret and the links that carry it, one per address this server answers on.
        ("POST", "/api/owner/pair-start") => {
            let secret = auth.begin_pairing(t);
            drop(auth);
            // Other machines' addresses first (tunnel, LAN), this machine's last.
            let mut bases = app.addresses();
            bases.push(format!("http://127.0.0.1:{}", app.config.port));
            let links: Vec<String> = bases.iter().map(|b| format!("{b}/desk#pair={secret}")).collect();
            json_reply(json!({"secret": secret, "expires": t + 60.0, "links": links}), 200)
        }
        ("GET", "/api/owner/devices") => {
            let list: Vec<Value> = auth
                .devices
                .iter()
                .map(|d| json!({"hash": d.hash, "name": d.name, "issued": d.issued, "lastUsed": d.last_used, "owner": d.owner}))
                .collect();
            json_reply(json!({"devices": list}), 200)
        }
        ("POST", "/api/owner/forget") => {
            let Some(hash) = body.get("hash").and_then(Value::as_str) else { return json_reply(json!({"ok": false}), 400) };
            json_reply(json!({"ok": auth.forget(hash, t)}), 200)
        }
        // The desktop app checks that the port is this server, and where it keeps its state.
        ("GET", "/api/owner/info") => json_reply(
            json!({"server": "suhyeok-server", "version": env!("CARGO_PKG_VERSION"), "pid": std::process::id(),
                   "dataDir": app.config.data_dir.to_string_lossy(), "artDir": app.config.art_dir.to_string_lossy()}),
            200,
        ),
        // Tray "서버 종료": ends every terminal, then the process. The restore record still lists the open
        // conversations, so the next start reopens them.
        ("GET", "/api/owner/network") => {
            drop(auth);
            let addresses = app.addresses();
            let net = app.net.lock().unwrap();
            json_reply(
                json!({
                    "lan": {"on": net.lan.is_some(), "port": app.lan_port(), "error": net.lan_error, "names": net.settings.names},
                    "tunnel": {"on": net.tunnel.is_some(), "url": net.tunnel.as_ref().and_then(|t| t.url.lock().unwrap().clone()), "error": net.tunnel_error},
                    "addresses": addresses,
                }),
                200,
            )
        }
        ("POST", "/api/owner/network") => {
            drop(auth);
            let mut s = app.net.lock().unwrap().settings.clone();
            if let Some(v) = body.get("lan").and_then(Value::as_bool) {
                s.lan = v;
            }
            if let Some(v) = body.get("tunnel").and_then(Value::as_bool) {
                s.tunnel = v;
            }
            if let Some(v) = body.get("names").and_then(Value::as_array) {
                s.names = v.iter().filter_map(Value::as_str).map(|n| n.trim().to_lowercase()).filter(|n| !n.is_empty()).collect();
            }
            app.set_network(s);
            json_reply(json!({"ok": true}), 200)
        }
        ("POST", "/api/owner/shutdown") => {
            drop(auth);
            if let Some(t) = app.net.lock().unwrap().tunnel.take() {
                t.stop();
            }
            for h in app.host.list() {
                app.host.kill(&h.name);
            }
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_millis(300));
                std::process::exit(0);
            });
            json_reply(json!({"ok": true}), 200)
        }
        _ => json_reply(json!({"error": "not found"}), 404),
    }
}
