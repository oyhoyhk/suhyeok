// 수혁 for Windows: a window onto the 수혁 server on the owner's Mac (MobileServer's /desk page).
// The local page (ui/index.html) only takes the pairing link and remembers the server; everything after that is
// the Mac's own page, so it gets no access to Tauri's IPC (no capabilities are granted to remote origins).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{Manager, Url};

/// Where the app's own files are served from (differs per platform in Tauri 2).
fn local(path: &str) -> Url {
    let base = if cfg!(windows) { "http://tauri.localhost/" } else { "tauri://localhost/" };
    Url::parse(base).unwrap().join(path).unwrap()
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let reload = MenuItemBuilder::with_id("reload", "다시 연결").accelerator("F5").build(app)?;
            let setup = MenuItemBuilder::with_id("setup", "연결 주소 바꾸기").build(app)?;
            let file = SubmenuBuilder::new(app, "수혁")
                .item(&reload)
                .item(&setup)
                .separator()
                .quit()
                .build()?;
            let edit = SubmenuBuilder::new(app, "편집")
                .undo()
                .redo()
                .separator()
                .cut()
                .copy()
                .paste()
                .select_all()
                .build()?;
            app.set_menu(MenuBuilder::new(app).item(&file).item(&edit).build()?)?;
            Ok(())
        })
        .on_menu_event(|app, event| {
            let Some(window) = app.get_webview_window("main") else { return };
            // Both go through the local page: it opens the saved server again, or shows the setup form.
            let target = match event.id().as_ref() {
                "reload" => local("index.html"),
                "setup" => local("index.html?setup=1"),
                _ => return,
            };
            let _ = window.navigate(target);
        })
        .run(tauri::generate_context!())
        .expect("error while running 수혁");
}
