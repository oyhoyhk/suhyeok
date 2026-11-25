// 수혁 desktop (Windows, Linux; builds on macOS for testing): runs the 수혁 server on this computer and opens it or
// another computer's 수혁 in one window.
//
// - "이 컴퓨터": the bundled suhyeok-server on 127.0.0.1:<port> (started detached when nothing answers there), opened
//   through its /owner page with the owner token from <data dir>/owner-token.
// - Other computers: origins added from a pairing link, kept in <app data dir>/servers.json.
// Pages the servers serve are remote origins: they get no IPC (only the app's own ui/index.html may call commands;
// Tauri rejects custom commands from remote origins and no capability grants plugin commands to any page).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod server;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use server::{Bundle, Local};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuEvent, MenuItemBuilder, PredefinedMenuItem, Submenu, SubmenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as _};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind, MessageDialogResult};

/// Korean UI when the OS language is Korean, English otherwise.
fn en() -> bool {
    static EN: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *EN.get_or_init(|| !sys_locale::get_locale().unwrap_or_default().to_lowercase().starts_with("ko"))
}

fn tr(ko: &str, en_text: &str) -> String {
    if en() { en_text } else { ko }.to_string()
}

/// Where the app's own files are served from (differs per platform in Tauri 2).
fn local_page(path: &str) -> Url {
    let base = if cfg!(windows) { "http://tauri.localhost/" } else { "tauri://localhost/" };
    Url::parse(base).unwrap().join(path).unwrap()
}

/// The app's page with a message (view=starting|error|add|devices).
fn page(view: &str, msg: Option<&str>) -> Url {
    let mut u = local_page("index.html");
    u.query_pairs_mut().append_pair("view", view);
    if let Some(m) = msg {
        u.query_pairs_mut().append_pair("msg", m);
    }
    u
}

/// Saved servers. `current` None = this computer.
#[derive(Default, Serialize, Deserialize)]
struct Servers {
    remotes: Vec<String>,
    current: Option<String>,
}

struct State {
    local: Local,
    bundle: Bundle,
    list: Mutex<Servers>,
    list_file: PathBuf,
    server_menu: Mutex<Option<Submenu<tauri::Wry>>>,
}

impl State {
    fn save(&self) {
        let list = self.list.lock().unwrap();
        if let Some(dir) = self.list_file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&self.list_file, serde_json::to_string_pretty(&*list).unwrap_or_default());
    }
}

fn main_window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("main")
}

fn show_main(app: &AppHandle) {
    if let Some(w) = main_window(app) {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn navigate(app: &AppHandle, url: Url) {
    if let Some(w) = main_window(app) {
        let _ = w.navigate(url);
    }
}

/// "이 컴퓨터": make sure the local server runs, then open it in the main window. Blocking (runs off the main thread).
fn connect_local(app: &AppHandle) {
    let state = app.state::<State>();
    navigate(app, page("starting", None));
    if let Err(msg) = state.local.ensure(&state.bundle, en()) {
        eprintln!("[suhyeok] local server: {msg}");
        if state.list.lock().unwrap().current.is_none() {
            navigate(app, page("error", Some(&msg)));
        }
        return;
    }
    if state.list.lock().unwrap().current.is_some() {
        return; // switched to another server meanwhile
    }
    let origin = state.local.origin();
    let Some(w) = main_window(app) else { return };
    // cookies() rather than cookies_for_url(): the latter finds nothing for 127.0.0.1 in WKWebView. Cookies are not
    // scoped by port, so the server checks that the one found is its owner device.
    let owner_cookie = || {
        w.cookies()
            .ok()
            .and_then(|cs| {
                cs.into_iter()
                    .find(|c| c.name() == "sh" && c.domain().map(|d| d.trim_start_matches('.')) == Some("127.0.0.1"))
                    .map(|c| c.value().to_string())
            })
            .filter(|c| state.local.owner_cookie_valid(c))
    };
    // Already paired as owner: straight to the desk, so no new owner device is added.
    if owner_cookie().is_none() {
        // Pair as owner here and hand the cookie to the webview without `Secure`: WebKit (macOS, and likely
        // WebKitGTK) drops the server's Secure cookie on http://127.0.0.1, so the server's /owner page alone leaves
        // the desk unpaired there.
        if let Ok(mut c) = state.local.pair_owner() {
            c.set_secure(None);
            c.set_domain("127.0.0.1");
            let _ = w.set_cookie(c);
        }
        if owner_cookie().is_none() {
            // The server's own page (works where the Secure cookie is kept, e.g. WebView2).
            match state.local.token() {
                Some(token) => navigate(app, Url::parse(&format!("{origin}/owner#{token}")).unwrap()),
                None => navigate(app, page("error", Some(&tr("서버의 주인 토큰을 읽지 못함", "Could not read the server's owner token")))),
            }
            return;
        }
    }
    navigate(app, Url::parse(&format!("{origin}/desk")).unwrap());
}

/// Opens the current server (this computer or a saved remote).
fn open_current(app: &AppHandle) {
    let current = app.state::<State>().list.lock().unwrap().current.clone();
    match current {
        None => {
            let a = app.clone();
            std::thread::spawn(move || connect_local(&a));
        }
        Some(origin) => {
            if let Ok(u) = Url::parse(&format!("{origin}/desk")) {
                navigate(app, u);
            }
        }
    }
}

fn select(app: &AppHandle, current: Option<String>) {
    let state = app.state::<State>();
    state.list.lock().unwrap().current = current;
    state.save();
    refresh_server_menu(app);
    open_current(app);
}

/// A pairing link from another computer's 수혁 → (origin, page to open). https, or http on this machine.
fn parse_link(link: &str) -> Result<(String, String), String> {
    let bad = || tr("링크 형식이 아님 — 다른 컴퓨터의 수혁에서 받은 연결 링크를 붙여넣기", "Not a link — paste the pairing link from the other computer's 수혁");
    let u = Url::parse(link.trim()).map_err(|_| bad())?;
    let host = u.host_str().unwrap_or("");
    let on_this_machine = host == "127.0.0.1" || host == "localhost";
    if !(u.scheme() == "https" || (u.scheme() == "http" && on_this_machine)) || host.is_empty() {
        return Err(tr("https 주소만 연결할 수 있음", "Only https addresses can be connected"));
    }
    let origin = u.origin().ascii_serialization();
    let pair = u
        .fragment()
        .and_then(|f| f.strip_prefix("pair="))
        .filter(|s| s.len() == 32 && s.chars().all(|c| c.is_ascii_hexdigit()))
        .map(|s| format!("#pair={s}"))
        .unwrap_or_default();
    Ok((origin.clone(), format!("{origin}/desk{pair}")))
}

/// Setup page: remember another server and open it (`open` false = only remember, for the old saved address).
#[tauri::command]
fn add_server(app: AppHandle, link: String, open: bool) -> Result<(), String> {
    let (origin, target) = parse_link(&link)?;
    let state = app.state::<State>();
    if origin == state.local.origin() {
        if open {
            select(&app, None);
        }
        return Ok(());
    }
    {
        let mut list = state.list.lock().unwrap();
        if !list.remotes.contains(&origin) {
            list.remotes.push(origin.clone());
        }
        if open {
            list.current = Some(origin);
        }
    }
    state.save();
    refresh_server_menu(&app);
    if open {
        navigate(&app, Url::parse(&target).map_err(|e| e.to_string())?);
    }
    Ok(())
}

/// Error page "다시 시도".
#[tauri::command]
fn retry_local(app: AppHandle) {
    select(&app, None);
}

#[tauri::command]
fn devices(app: AppHandle) -> Result<Value, String> {
    app.state::<State>().local.get("/api/owner/devices")
}

#[tauri::command]
fn forget_device(app: AppHandle, hash: String) -> Result<Value, String> {
    app.state::<State>().local.post("/api/owner/forget", json!({ "hash": hash }))
}

fn server_label(origin: &str) -> String {
    origin.trim_start_matches("https://").trim_start_matches("http://").to_string()
}

/// "서버" menu: this computer, the saved servers (the current one checked), add, remove.
fn refresh_server_menu(app: &AppHandle) {
    let state = app.state::<State>();
    let Some(sub) = state.server_menu.lock().unwrap().clone() else { return };
    let list = state.list.lock().unwrap();
    while let Ok(Some(_)) = sub.remove_at(0) {}
    let local = CheckMenuItemBuilder::with_id("srv:local", tr("이 컴퓨터", "This computer"))
        .checked(list.current.is_none())
        .build(app);
    if let Ok(i) = local {
        let _ = sub.append(&i);
    }
    for (n, origin) in list.remotes.iter().enumerate() {
        if let Ok(i) = CheckMenuItemBuilder::with_id(format!("srv:{n}"), server_label(origin))
            .checked(list.current.as_deref() == Some(origin.as_str()))
            .build(app)
        {
            let _ = sub.append(&i);
        }
    }
    if let Ok(i) = PredefinedMenuItem::separator(app) {
        let _ = sub.append(&i);
    }
    if let Ok(i) = MenuItemBuilder::with_id("add", tr("다른 서버 추가…", "Add another server…")).build(app) {
        let _ = sub.append(&i);
    }
    if let Ok(i) = MenuItemBuilder::with_id("remove", tr("목록에서 지우기", "Remove from list")).enabled(list.current.is_some()).build(app) {
        let _ = sub.append(&i);
    }
}

fn build_menu(app: &AppHandle) -> tauri::Result<()> {
    let autostart = app.autolaunch().is_enabled().unwrap_or(false);
    let main = SubmenuBuilder::new(app, tr("수혁", "Suhyeok"))
        .item(&MenuItemBuilder::with_id("reload", tr("다시 불러오기", "Reload")).accelerator("F5").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("pair", tr("다른 기기 연결…", "Connect another device…")).build(app)?)
        .item(&MenuItemBuilder::with_id("devices", tr("연결된 기기…", "Connected devices…")).build(app)?)
        .separator()
        .item(&CheckMenuItemBuilder::with_id("autostart", tr("로그인 시 자동 실행", "Start at login")).checked(autostart).build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("hide", tr("창 닫기", "Close window")).accelerator("CmdOrCtrl+W").build(app)?)
        .item(&MenuItemBuilder::with_id("quit", tr("앱 종료 (서버는 계속 실행)", "Quit app (server keeps running)")).accelerator("CmdOrCtrl+Q").build(app)?)
        .build()?;
    let servers = SubmenuBuilder::new(app, tr("서버", "Server")).build()?;
    let edit = SubmenuBuilder::new(app, tr("편집", "Edit")).undo().redo().separator().cut().copy().paste().select_all().build()?;
    app.set_menu(MenuBuilder::new(app).item(&main).item(&servers).item(&edit).build()?)?;
    *app.state::<State>().server_menu.lock().unwrap() = Some(servers);
    refresh_server_menu(app);
    Ok(())
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let menu = MenuBuilder::new(app)
        .item(&MenuItemBuilder::with_id("open", tr("열기", "Open")).build(app)?)
        .item(&MenuItemBuilder::with_id("server-stop", tr("서버 종료 (모든 세션 종료)", "Stop server (ends all sessions)")).build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("quit", tr("앱 종료", "Quit app")).build(app)?)
        .build()?;
    let mut tray = TrayIconBuilder::with_id("tray").tooltip("수혁").menu(&menu).show_menu_on_left_click(false).on_tray_icon_event(|tray, event| {
        if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
            show_main(tray.app_handle());
        }
    });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

fn message(app: &AppHandle, title: &str, text: &str) {
    app.dialog().message(text).title(title).kind(MessageDialogKind::Info).blocking_show();
}

fn local_off(app: &AppHandle) -> bool {
    let state = app.state::<State>();
    if state.local.probe() == server::Probe::Ours {
        return false;
    }
    message(app, "수혁", &tr("이 컴퓨터의 수혁 서버가 꺼져 있음 — 서버 메뉴에서 '이 컴퓨터'를 고르면 다시 켬", "The 수혁 server on this computer is off — choose 'This computer' in the Server menu to start it"));
    true
}

/// "다른 기기 연결…": a 60 s pairing secret; the first link that is not 127.0.0.1 goes to the clipboard.
fn start_pairing(app: &AppHandle) {
    if local_off(app) {
        return;
    }
    let state = app.state::<State>();
    let links: Vec<String> = match state.local.post("/api/owner/pair-start", json!({})) {
        Ok(v) => v.get("links").and_then(Value::as_array).map(|a| a.iter().filter_map(|l| l.as_str().map(String::from)).collect()).unwrap_or_default(),
        Err(e) => {
            message(app, "수혁", &e);
            return;
        }
    };
    let is_local = |l: &&String| l.starts_with("http://127.0.0.1") || l.starts_with("http://localhost");
    let Some(chosen) = links.iter().find(|l| !is_local(l)).or_else(|| links.first()) else { return };
    let copied = app.clipboard().write_text(chosen.clone()).is_ok();
    let mut text = if copied {
        tr("연결 링크를 클립보드에 복사함. 60초 동안 유효.\n다른 기기의 수혁 앱이나 브라우저에 붙여넣은 뒤, 이 컴퓨터에 뜨는 창에서 허용.\n\n", "Copied the pairing link to the clipboard. Valid for 60 seconds.\nPaste it into 수혁 or a browser on the other device, then allow it in the window that appears on this computer.\n\n")
    } else {
        tr("연결 링크 (60초 동안 유효):\n\n", "Pairing links (valid for 60 seconds):\n\n")
    };
    text += &links.join("\n");
    if links.iter().all(|l| is_local(&l)) {
        text += &tr("\n\n이 서버는 아직 이 컴퓨터 안(127.0.0.1)에서만 열려 있음.", "\n\nThis server is still open only inside this computer (127.0.0.1).");
    }
    message(app, &tr("다른 기기 연결", "Connect another device"), &text);
}

fn open_devices(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("devices") {
        let _ = w.navigate(page("devices", None));
        let _ = w.set_focus();
        return;
    }
    let w = WebviewWindowBuilder::new(app, "devices", WebviewUrl::External(page("devices", None)))
        .title(tr("연결된 기기", "Connected devices"))
        .inner_size(520.0, 460.0)
        .build();
    #[cfg(not(target_os = "macos"))]
    if let Ok(w) = &w {
        let _ = w.remove_menu();
    }
    let _ = w;
}

fn stop_server(app: &AppHandle) {
    let ok = app
        .dialog()
        .message(tr(
            "이 컴퓨터의 수혁 서버를 종료할까? 모든 세션(터미널)이 끝남. 열린 대화는 다음에 서버가 켜질 때 다시 열림.",
            "Stop the 수혁 server on this computer? Every session (terminal) ends. Open conversations reopen the next time the server starts.",
        ))
        .title(tr("서버 종료", "Stop server"))
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(tr("종료", "Stop"), tr("취소", "Cancel")))
        .blocking_show();
    if !ok {
        return;
    }
    let state = app.state::<State>();
    match state.local.post("/api/owner/shutdown", json!({})) {
        Ok(_) => {
            if state.list.lock().unwrap().current.is_none() {
                navigate(app, page("error", Some(&tr("서버를 종료함. 다시 켜려면 아래 버튼이나 서버 메뉴의 '이 컴퓨터'.", "The server is stopped. To start it again use the button below or 'This computer' in the Server menu."))));
            }
        }
        Err(e) => message(app, "수혁", &e),
    }
}

fn on_menu(app: &AppHandle, event: MenuEvent) {
    let id = event.id().as_ref().to_string();
    let a = app.clone();
    // Dialogs block, so everything runs off the main thread.
    let run = move |f: fn(&AppHandle)| {
        std::thread::spawn(move || f(&a));
    };
    match id.as_str() {
        "reload" => open_current(app),
        "pair" => run(start_pairing),
        "devices" => open_devices(app),
        "autostart" => {
            let al = app.autolaunch();
            let on = al.is_enabled().unwrap_or(false);
            let _ = if on { al.disable() } else { al.enable() };
            let _ = build_menu(app);
        }
        "hide" => {
            if let Some(w) = app.get_webview_window("devices").filter(|w| w.is_focused().unwrap_or(false)) {
                let _ = w.close();
            } else if let Some(w) = main_window(app) {
                let _ = w.hide();
            }
        }
        "quit" => app.exit(0),
        "open" => show_main(app),
        "server-stop" => run(stop_server),
        "add" => navigate(app, page("add", None)),
        "remove" => {
            let state = app.state::<State>();
            {
                let mut list = state.list.lock().unwrap();
                if let Some(cur) = list.current.take() {
                    list.remotes.retain(|o| *o != cur);
                }
            }
            state.save();
            refresh_server_menu(app);
            open_current(app);
        }
        "srv:local" => select(app, None),
        other => {
            if let Some(n) = other.strip_prefix("srv:").and_then(|n| n.parse::<usize>().ok()) {
                let origin = app.state::<State>().list.lock().unwrap().remotes.get(n).cloned();
                if let Some(o) = origin {
                    select(app, Some(o));
                }
            }
        }
    }
}

/// Other devices' pairing requests: polled every second, each one asked once in a native dialog.
fn watch_approvals(app: AppHandle) {
    std::thread::spawn(move || {
        let mut seen: HashSet<String> = HashSet::new();
        loop {
            std::thread::sleep(Duration::from_secs(1));
            let state = app.state::<State>();
            let Ok(v) = state.local.get("/api/owner/pending") else { continue };
            let pending = v.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
            for p in pending {
                let Some(id) = p.get("id").and_then(Value::as_str).map(String::from) else { continue };
                if !seen.insert(id.clone()) {
                    continue;
                }
                let device = p.get("device").and_then(Value::as_str).unwrap_or("?");
                let client = p.get("client").and_then(Value::as_str).unwrap_or("?");
                let text = if en() {
                    format!("{device} wants to connect to 수혁 on this computer (from: {client})\n\nIf you allow it, this device can see every agent and send them instructions.")
                } else {
                    format!("{device}에서 이 컴퓨터의 수혁에 연결하려고 함 (접속 위치: {client})\n\n허용하면 이 기기가 모든 에이전트를 보고 지시를 보낼 수 있음")
                };
                // 거부 is the first (default) button: the dialog takes keyboard focus, and a Return typed for another
                // window must not let a device in (seen on macOS). Only an explicit 허용 allows; Escape, closing and
                // 닫기 deny.
                let allow_label = tr("허용", "Allow");
                let answer = app
                    .dialog()
                    .message(text)
                    .title(tr("수혁 연결 요청", "수혁 connection request"))
                    .kind(MessageDialogKind::Warning)
                    .buttons(MessageDialogButtons::YesNoCancelCustom(tr("거부", "Deny"), allow_label.clone(), tr("닫기", "Close")))
                    .blocking_show_with_result();
                let allow = answer == MessageDialogResult::Custom(allow_label);
                let r = state.local.post("/api/owner/decide", json!({ "id": id, "allow": allow }));
                eprintln!("[suhyeok] pairing request {id}: allow={allow} -> {r:?}");
            }
        }
    });
}

/// Where this computer's server listens and keeps its state. SUHYEOK_PORT / SUHYEOK_DATA override (tests).
/// Default data folder: the OS data folder / Suhyeok (the server's own default), on macOS Suhyeok-server because the
/// Mac app already uses ~/Library/Application Support/Suhyeok.
fn local_server(app: &AppHandle) -> Local {
    let port = std::env::var("SUHYEOK_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(4380);
    let data_dir = std::env::var_os("SUHYEOK_DATA").map(PathBuf::from).unwrap_or_else(|| {
        let base = app.path().data_dir().unwrap_or_else(|_| std::env::temp_dir());
        base.join(if cfg!(target_os = "macos") { "Suhyeok-server" } else { "Suhyeok" })
    });
    Local { port, data_dir }
}

/// The sidecar sits next to the app's executable (Tauri externalBin), the art in the resource folder.
fn bundled(app: &AppHandle) -> Bundle {
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(PathBuf::from)).unwrap_or_default();
    let bundle = Bundle {
        server: exe_dir.join(format!("suhyeok-server{}", std::env::consts::EXE_SUFFIX)),
        art: app.path().resource_dir().map(|d| d.join("art")).unwrap_or_default(),
    };
    let data = app.path().app_local_data_dir().unwrap_or_else(|_| std::env::temp_dir());
    server::outside_appimage(bundle, &data, &app.package_info().version.to_string())
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .invoke_handler(tauri::generate_handler![add_server, retry_local, devices, forget_device])
        .setup(|app| {
            let handle = app.handle().clone();
            let list_file = app.path().app_data_dir()?.join("servers.json");
            let list: Servers = std::fs::read(&list_file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
            app.manage(State {
                local: local_server(&handle),
                bundle: bundled(&handle),
                list: Mutex::new(list),
                list_file,
                server_menu: Mutex::new(None),
            });
            let hidden = std::env::args().any(|a| a == "--hidden");
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("수혁")
                .inner_size(1280.0, 820.0)
                .min_inner_size(800.0, 560.0)
                .visible(!hidden)
                .on_navigation(|url| {
                    // Logged without the fragment: /owner#<token> carries the owner token.
                    eprintln!("[suhyeok] navigate {}://{}{}{}", url.scheme(), url.host_str().unwrap_or(""), url.port().map(|p| format!(":{p}")).unwrap_or_default(), url.path());
                    true
                })
                .build()?;
            build_menu(&handle)?;
            build_tray(&handle)?;
            open_current(&handle);
            // The local server starts with the app even when another server is open, so pairing requests reach it.
            let h = handle.clone();
            std::thread::spawn(move || {
                let state = h.state::<State>();
                if state.list.lock().unwrap().current.is_some() {
                    if let Err(msg) = state.local.ensure(&state.bundle, en()) {
                        eprintln!("[suhyeok] local server: {msg}");
                    }
                }
            });
            watch_approvals(handle);
            Ok(())
        })
        .on_menu_event(on_menu)
        .on_window_event(|window, event| {
            // Closing the main window hides it: the app stays in the tray to answer pairing requests.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building 수혁");
    app.run(|app, event| match event {
        // No window left open is not a reason to quit (tray); "앱 종료" exits with a code.
        RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
        #[cfg(target_os = "macos")]
        RunEvent::Reopen { .. } => show_main(app),
        _ => {
            let _ = app;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::parse_link;

    #[test]
    fn pairing_links() {
        let secret = "0123456789abcdef0123456789abcdef";
        assert_eq!(
            parse_link(&format!(" https://a.example.com/desk#pair={secret} ")).unwrap(),
            ("https://a.example.com".into(), format!("https://a.example.com/desk#pair={secret}"))
        );
        // A saved address without a secret opens the desk as is.
        assert_eq!(parse_link("https://a.example.com").unwrap().1, "https://a.example.com/desk");
        assert_eq!(parse_link("http://127.0.0.1:4391/desk#pair=zz").unwrap(), ("http://127.0.0.1:4391".into(), "http://127.0.0.1:4391/desk".into()));
        assert!(parse_link("http://192.168.0.2:4380/desk").is_err(), "plain http only on this machine");
        assert!(parse_link("file:///etc/passwd").is_err());
        assert!(parse_link("not a link").is_err());
    }
}
