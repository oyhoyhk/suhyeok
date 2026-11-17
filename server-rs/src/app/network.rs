//! Reaching this server from other machines (plan phase 4). The server always listens on 127.0.0.1; the owner can
//! also open it to the local network / Tailscale (a second listener on 0.0.0.0) and start a Cloudflare quick tunnel
//! (port of MobileTunnel in MobileServer.swift). The choice is kept in `<data dir>/network.json` and applied at start.
//!
//! Host rule on the LAN listener: a literal IP address (any of this machine's, on our port) or a name the owner added
//! (e.g. a Tailscale MagicDNS name). Names in general are refused, which keeps DNS rebinding out as on the Mac.

use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader};
use std::net::{IpAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Settings {
    #[serde(default)]
    pub lan: bool,
    #[serde(default)]
    pub tunnel: bool,
    /// Extra names the LAN listener answers to ("my-pc.tailnet.ts.net").
    #[serde(default)]
    pub names: Vec<String>,
}

impl Settings {
    pub fn load(data_dir: &Path) -> Settings {
        std::fs::read(file(data_dir)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }
    pub fn save(&self, data_dir: &Path) {
        let _ = std::fs::create_dir_all(data_dir);
        if let Ok(j) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(file(data_dir), j);
        }
    }
}

fn file(data_dir: &Path) -> PathBuf {
    data_dir.join("network.json")
}

/// This machine's address on the network that reaches the internet (no packet is sent: a UDP "connect" only picks
/// the route). Tailscale addresses (100.x) show up when Tailscale is the default route; otherwise add the name.
pub fn primary_ip() -> Option<IpAddr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("8.8.8.8:80").ok()?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

/// A Host header the LAN listener accepts: "<ip>:<port>" for an IP literal, or "<name>:<port>" / "<name>" for a name
/// the owner added.
pub fn lan_host_ok(host: &str, port: u16, names: &[String]) -> bool {
    let host = host.to_lowercase();
    let (name, p) = match host.rsplit_once(':') {
        // "[fe80::1]:4380" and "1.2.3.4:4380"
        Some((n, p)) if !n.ends_with(']') || n.starts_with('[') => (n.trim_start_matches('[').trim_end_matches(']').to_string(), p.parse::<u16>().ok()),
        _ => (host.clone(), None),
    };
    if p.is_some_and(|p| p != port) {
        return false;
    }
    if name.parse::<IpAddr>().is_ok() {
        return p == Some(port);
    }
    names.iter().any(|n| n.eq_ignore_ascii_case(&name))
}

/// A running `cloudflared tunnel --url`; its public address once cloudflared prints it.
pub struct Tunnel {
    child: Child,
    pub url: Arc<Mutex<Option<String>>>,
}

impl Tunnel {
    /// `cloudflared` on PATH (or the usual install places). A named tunnel config in `<data dir>/named-tunnel.yml`
    /// (first ingress `hostname:`) is used when present, giving an address that survives restarts.
    pub fn start(port: u16, data_dir: &Path) -> Result<Tunnel, String> {
        let bin = cloudflared().ok_or("cloudflared not found — install it (winget install Cloudflare.cloudflared / apt / brew)")?;
        let named = std::fs::read_to_string(data_dir.join("named-tunnel.yml")).ok().and_then(|yml| {
            let re = regex::Regex::new(r"hostname:\s*([A-Za-z0-9.-]+)").ok()?;
            re.captures(&yml).map(|c| c[1].to_string())
        });
        let mut cmd = Command::new(bin);
        match &named {
            Some(_) => {
                cmd.args(["tunnel", "--config"]).arg(data_dir.join("named-tunnel.yml")).args(["--no-autoupdate", "run"]);
            }
            None => {
                // An empty config of our own: a user's ~/.cloudflared/config.yml would otherwise apply to the quick tunnel.
                let conf = data_dir.join("cloudflared.yml");
                if !conf.exists() {
                    let _ = std::fs::create_dir_all(data_dir);
                    let _ = std::fs::write(&conf, "# quick tunnel for 수혁\n");
                }
                cmd.args(["tunnel", "--config"]).arg(&conf).args(["--no-autoupdate", "--url", &format!("http://127.0.0.1:{port}")]);
            }
        }
        cmd.stdout(Stdio::null()).stderr(Stdio::piped()).stdin(Stdio::null());
        let mut child = cmd.spawn().map_err(|e| format!("cloudflared did not start: {e}"))?;
        let url = Arc::new(Mutex::new(None));
        if let Some(err) = child.stderr.take() {
            let url = url.clone();
            std::thread::spawn(move || {
                let quick = regex::Regex::new(r"https://[a-z0-9-]+\.trycloudflare\.com").unwrap();
                for line in BufReader::new(err).lines().map_while(Result::ok) {
                    if let Some(h) = &named {
                        if line.contains("Registered tunnel connection") {
                            *url.lock().unwrap() = Some(format!("https://{h}"));
                        }
                    } else if let Some(m) = quick.find(&line) {
                        *url.lock().unwrap() = Some(m.as_str().to_string());
                    }
                }
            });
        }
        Ok(Tunnel { child, url })
    }

    pub fn host(&self) -> Option<String> {
        self.url.lock().unwrap().as_deref().map(|u| u.trim_start_matches("https://").to_lowercase())
    }

    pub fn stop(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn cloudflared() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "cloudflared.exe" } else { "cloudflared" };
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from));
    if let Some(pf) = std::env::var_os("ProgramFiles(x86)").or_else(|| std::env::var_os("ProgramFiles")) {
        dirs.push(PathBuf::from(pf).join("cloudflared"));
    }
    dirs.into_iter().map(|d| d.join(exe)).find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lan_hosts_are_ip_literals_or_added_names() {
        let names = vec!["my-pc.tail1234.ts.net".to_string()];
        assert!(lan_host_ok("192.168.0.12:4380", 4380, &names));
        assert!(lan_host_ok("100.64.1.2:4380", 4380, &names));
        assert!(lan_host_ok("[fe80::1]:4380", 4380, &names));
        assert!(!lan_host_ok("192.168.0.12:9999", 4380, &names), "another port");
        assert!(!lan_host_ok("192.168.0.12", 4380, &names), "an IP without our port");
        assert!(!lan_host_ok("evil.example:4380", 4380, &names), "names are refused (DNS rebinding)");
        assert!(lan_host_ok("MY-PC.tail1234.ts.net:4380", 4380, &names));
        assert!(lan_host_ok("my-pc.tail1234.ts.net", 4380, &names));
    }

    #[test]
    fn settings_round_trip() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(Settings::load(d.path()), Settings::default());
        let s = Settings { lan: true, tunnel: false, names: vec!["a.ts.net".into()] };
        s.save(d.path());
        assert_eq!(Settings::load(d.path()), s);
    }
}
