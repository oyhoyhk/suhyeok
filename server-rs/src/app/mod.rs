//! The running server: configuration, pairing state and the session store behind the HTTP routes.

pub mod api;
pub mod auth;
pub mod events;
pub mod http;
pub mod network;
pub mod sidebar;
pub mod store;

use auth::Auth;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use store::Store;
use suhyeok::model::now;
use suhyeok::pty::restore::Restore;
use suhyeok::pty::{Host, HostOptions};

pub struct Config {
    pub port: u16,
    /// English labels (the Mac follows its UI language).
    pub en: bool,
    /// Bundled art: field images, sprites, bosses, fonts, walkmap.json, roster.json.
    pub art_dir: PathBuf,
    /// Devices, character assignments and other state kept across runs.
    pub data_dir: PathBuf,
    /// Hosts besides 127.0.0.1/localhost that may address this server (a tunnel host, a LAN address), "host:port".
    pub extra_hosts: Vec<String>,
    /// Reopen the conversations a restart closed (SessionRestore "모두 다시 열기"), at start.
    pub restore: bool,
}

pub struct App {
    pub config: Config,
    pub auth: Mutex<Auth>,
    pub store: Mutex<Store>,
    /// The terminals this server hosts (tmux on the Mac): agents and shells live as long as this process.
    pub host: Host,
    /// Open conversations, written as they change, so a restart can reopen them.
    pub restore: Mutex<Restore>,
    /// Last send per "session \0 text" (MobileServer.lastSends): a double send within 5 s is answered ok, not typed twice.
    pub last_sends: Mutex<HashMap<String, f64>>,
    /// LAN listener and Cloudflare tunnel (phase 4).
    pub net: Mutex<Net>,
    /// Called with a new pairing request id (the CLI prints it; the desktop app shows an approval prompt).
    pub pair_hook: Box<dyn Fn(&str) + Send + Sync>,
}

impl App {
    pub fn new(config: Config, pair_hook: Box<dyn Fn(&str) + Send + Sync>) -> App {
        let auth = Auth::load(config.data_dir.join("devices.json"), now());
        let store = Store::new(&config);
        let restore = Restore::open(suhyeok::pty::restore::default_path(&config.data_dir));
        App {
            config,
            auth: Mutex::new(auth),
            store: Mutex::new(store),
            host: Host::new(HostOptions::default()),
            restore: Mutex::new(restore),
            last_sends: Mutex::new(HashMap::new()),
            net: Mutex::new(Net::default()),
            pair_hook,
        }
    }

    /// One refresh: sessions, then the restore record (its entries need the terminals' sessions).
    pub fn refresh(&self) {
        let mut store = self.store.lock().unwrap();
        store.refresh(&self.host);
        self.restore.lock().unwrap().record(&store.terms, &store.sessions);
    }

    /// Reopens everything the last restart closed, with each conversation's character.
    pub fn reopen_closed(&self) -> usize {
        let roster: Vec<_> = self.store.lock().unwrap().party.roster().to_vec();
        let names = self.restore.lock().unwrap().reopen_closed(
            &self.host,
            |id| roster.iter().find(|c| c.id == id).cloned(),
            true,
            true,
            self.config.en,
        );
        names.into_iter().flatten().count()
    }

    pub fn authorized(&self, cookie: Option<&str>) -> bool {
        self.auth.lock().unwrap().authorized(cookie, now())
    }

    pub fn extra_hosts(&self) -> Vec<String> {
        let mut out: Vec<String> = self.config.extra_hosts.iter().map(|h| h.to_lowercase()).collect();
        if let Some(h) = self.net.lock().unwrap().tunnel.as_ref().and_then(|t| t.host()) {
            out.push(h);
        }
        out
    }

    /// The LAN listener's port: the next one, so it never collides with the 127.0.0.1 listener (Linux refuses
    /// 0.0.0.0:<port> while 127.0.0.1:<port> listens).
    pub fn lan_port(&self) -> u16 {
        self.config.port + 1
    }

    /// Whether a Host header may address this server: this machine, a tunnel or extra host, or (LAN on) an IP literal
    /// or added name on the LAN port.
    pub fn host_allowed(&self, host: &str) -> bool {
        let host = host.to_lowercase();
        let port = self.config.port;
        if host == format!("127.0.0.1:{port}") || host == format!("localhost:{port}") || self.extra_hosts().contains(&host) {
            return true;
        }
        let net = self.net.lock().unwrap();
        net.lan.is_some() && network::lan_host_ok(&host, self.lan_port(), &net.settings.names)
    }

    /// Applies `settings`: starts or stops the LAN listener and the tunnel, and saves the choice.
    pub fn set_network(self: &Arc<App>, settings: network::Settings) {
        settings.save(&self.config.data_dir);
        let mut net = self.net.lock().unwrap();
        net.settings = settings.clone();
        if settings.lan && net.lan.is_none() {
            let addr = std::net::SocketAddr::from(([0, 0, 0, 0], self.lan_port()));
            match std::net::TcpListener::bind(addr).and_then(|l| {
                l.set_nonblocking(true)?;
                tokio::net::TcpListener::from_std(l)
            }) {
                Ok(l) => {
                    let router = http::router(self.clone());
                    net.lan = Some(tokio::spawn(async move {
                        let _ = axum::serve(l, router).await;
                    }));
                    net.lan_error = None;
                }
                Err(e) => net.lan_error = Some(e.to_string()),
            }
        } else if !settings.lan {
            if let Some(task) = net.lan.take() {
                task.abort();
            }
        }
        if settings.tunnel && net.tunnel.is_none() {
            match network::Tunnel::start(self.config.port, &self.config.data_dir) {
                Ok(t) => {
                    net.tunnel = Some(t);
                    net.tunnel_error = None;
                }
                Err(e) => net.tunnel_error = Some(e),
            }
        } else if !settings.tunnel {
            if let Some(t) = net.tunnel.take() {
                t.stop();
            }
        }
    }

    /// Where other machines can reach this server now (for pairing links and the owner's settings).
    pub fn addresses(&self) -> Vec<String> {
        let net = self.net.lock().unwrap();
        let mut out = vec![];
        if let Some(u) = net.tunnel.as_ref().and_then(|t| t.url.lock().unwrap().clone()) {
            out.push(u);
        }
        if net.lan.is_some() {
            let port = self.lan_port();
            for n in &net.settings.names {
                out.push(format!("http://{n}:{port}"));
            }
            if let Some(ip) = network::primary_ip() {
                out.push(match ip {
                    std::net::IpAddr::V6(v6) => format!("http://[{v6}]:{port}"),
                    v4 => format!("http://{v4}:{port}"),
                });
            }
        }
        out
    }

    pub fn on_pair_request(&self, id: &str) {
        (self.pair_hook)(id)
    }

    /// Bundled art under the art folder; `..` refused.
    pub fn public_art(&self, rel: &str) -> Option<(Vec<u8>, &'static str)> {
        if rel.contains("..") || rel.contains('\\') {
            return None;
        }
        let data = std::fs::read(self.config.art_dir.join(rel)).ok()?;
        let kind = if rel.ends_with(".png") {
            "image/png"
        } else if rel.ends_with(".woff2") {
            "font/woff2"
        } else {
            "image/jpeg"
        };
        Some((data, kind))
    }
}

/// Default art folder: next to the executable (installed), else the repo's art/out (development).
pub fn default_art_dir() -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let installed = dir.join("art");
            if installed.join("walkmap.json").exists() {
                return installed;
            }
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../art/out")
}

/// `<OS data dir>/Suhyeok` (Windows %APPDATA%, Linux ~/.local/share). On a Mac, where the Swift app owns
/// "Suhyeok", the Rust server (testing, or a Mac without the Swift app) keeps to "Suhyeok-server".
pub fn default_data_dir() -> PathBuf {
    let name = if cfg!(target_os = "macos") { "Suhyeok-server" } else { "Suhyeok" };
    dirs::data_dir().unwrap_or_else(std::env::temp_dir).join(name)
}

/// Phase 4 state: the saved choice and what is running.
#[derive(Default)]
pub struct Net {
    pub settings: network::Settings,
    pub lan: Option<tokio::task::JoinHandle<()>>,
    pub lan_error: Option<String>,
    pub tunnel: Option<network::Tunnel>,
    pub tunnel_error: Option<String>,
}
