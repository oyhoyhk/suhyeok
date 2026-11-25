//! The 수혁 server on this computer (contract/README.md "주인 경로"): find it on 127.0.0.1:<port>, start the bundled
//! one when nothing answers, and call the owner API with the token the server keeps in `<data dir>/owner-token`.
//! The server is started detached: it holds the sessions, so it keeps running when the window or the app closes.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Local {
    pub port: u16,
    pub data_dir: PathBuf,
}

/// What answers on the port.
#[derive(Debug, PartialEq)]
pub enum Probe {
    /// suhyeok-server that accepts our owner token.
    Ours,
    /// Nothing listening.
    Down,
    /// suhyeok-server started with another data folder (our token is not its owner token).
    OtherSuhyeok,
    /// Some other program (for example the Mac app's own server).
    Foreign,
}

/// The bundled server binary and art folder.
pub struct Bundle {
    pub server: PathBuf,
    pub art: PathBuf,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(3)).build()
}

impl Local {
    pub fn origin(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// The owner token, once the server has created it.
    pub fn token(&self) -> Option<String> {
        let t = fs::read_to_string(self.data_dir.join("owner-token")).ok()?;
        let t = t.trim().to_string();
        (!t.is_empty()).then_some(t)
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, ureq::Error> {
        let req = agent()
            .request(method, &format!("{}{path}", self.origin()))
            .set("X-Suhyeok-Owner", &self.token().unwrap_or_default());
        let resp = match body {
            Some(b) => req.send_json(b)?,
            None => req.call()?,
        };
        Ok(resp.into_json().unwrap_or(Value::Null))
    }

    pub fn get(&self, path: &str) -> Result<Value, String> {
        self.call("GET", path, None).map_err(|e| e.to_string())
    }

    pub fn post(&self, path: &str, body: Value) -> Result<Value, String> {
        self.call("POST", path, Some(body)).map_err(|e| e.to_string())
    }

    pub fn probe(&self) -> Probe {
        match self.call("GET", "/api/owner/info", None) {
            Ok(v) if v.get("server").and_then(Value::as_str) == Some("suhyeok-server") => Probe::Ours,
            Ok(_) => Probe::Foreign,
            Err(ureq::Error::Status(403, resp)) => {
                let v: Value = resp.into_json().unwrap_or(Value::Null);
                if v.get("error").and_then(Value::as_str) == Some("owner") {
                    Probe::OtherSuhyeok
                } else {
                    Probe::Foreign
                }
            }
            Err(ureq::Error::Status(..)) => Probe::Foreign,
            Err(ureq::Error::Transport(t)) if t.kind() == ureq::ErrorKind::ConnectionFailed => Probe::Down,
            Err(ureq::Error::Transport(_)) => Probe::Foreign,
        }
    }

    /// `POST /pair/owner` with the owner token: a new owner device; returns its `sh` cookie as the server set it.
    pub fn pair_owner(&self) -> Result<tauri::webview::Cookie<'static>, String> {
        let token = self.token().ok_or("no owner token")?;
        let resp = agent()
            .post(&format!("{}/pair/owner", self.origin()))
            .send_json(serde_json::json!({ "token": token }))
            .map_err(|e| e.to_string())?;
        let header = resp.header("set-cookie").ok_or("no cookie")?.to_string();
        tauri::webview::Cookie::parse(header).map_err(|e| e.to_string())
    }

    /// True when the `sh` cookie the webview holds is an owner device of this server (so the window can go straight
    /// to /desk instead of pairing as owner again, which would add another device).
    pub fn owner_cookie_valid(&self, cookie: &str) -> bool {
        agent()
            .get(&format!("{}/api/owner/info", self.origin()))
            .set("Cookie", &format!("sh={cookie}"))
            .call()
            .is_ok()
    }

    /// Makes sure our server answers: starts the bundled one when the port is free. Err is a message for the user.
    pub fn ensure(&self, bundle: &Bundle, en: bool) -> Result<(), String> {
        let tr = |ko: &str, e: &str| if en { e.to_string() } else { ko.to_string() };
        match self.probe() {
            Probe::Ours => return Ok(()),
            Probe::Down => {}
            Probe::OtherSuhyeok => {
                return Err(if en {
                    format!("Another 수혁 server (started with a different data folder) is running on 127.0.0.1:{}. Stop it, then try again.", self.port)
                } else {
                    format!("127.0.0.1:{}에서 다른 데이터 폴더로 실행된 수혁 서버가 돌고 있음. 그 서버를 끄고 다시 시도", self.port)
                })
            }
            Probe::Foreign => {
                return Err(if en {
                    format!("127.0.0.1:{} is in use by a program that is not the 수혁 server. Quit that program, then try again.", self.port)
                } else {
                    format!("127.0.0.1:{}를 수혁 서버가 아닌 다른 프로그램이 쓰고 있음. 그 프로그램을 끄고 다시 시도", self.port)
                })
            }
        }
        if !bundle.server.exists() {
            return Err(tr("수혁 서버 파일이 없음: ", "The 수혁 server file is missing: ") + &bundle.server.to_string_lossy());
        }
        fs::create_dir_all(&self.data_dir).map_err(|e| e.to_string())?;
        let log_path = self.data_dir.join("server.log");
        let log = fs::File::create(&log_path).map_err(|e| e.to_string())?;
        let mut cmd = Command::new(&bundle.server);
        cmd.arg("--port")
            .arg(self.port.to_string())
            .arg("--art")
            .arg(&bundle.art)
            .arg("--data")
            .arg(&self.data_dir)
            .current_dir(&self.data_dir)
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log);
        if en {
            cmd.arg("--en");
        }
        detach(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| tr("수혁 서버를 시작하지 못함: ", "Could not start the 수혁 server: ") + &e.to_string())?;
        eprintln!("[suhyeok] started server pid {} on port {}", child.id(), self.port);

        let started = Instant::now();
        let result = loop {
            if let Ok(Some(status)) = child.try_wait() {
                let tail = fs::read_to_string(&log_path).unwrap_or_default();
                let tail: String = tail.lines().rev().take(5).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
                break Err(format!("{} ({status})\n{tail}", tr("수혁 서버가 바로 종료됨", "The 수혁 server exited right away")));
            }
            if self.probe() == Probe::Ours {
                break Ok(());
            }
            if started.elapsed() > Duration::from_secs(20) {
                break Err(tr("수혁 서버가 20초 안에 응답하지 않음", "The 수혁 server did not answer within 20 seconds"));
            }
            std::thread::sleep(Duration::from_millis(200));
        };
        // Reap it when it ends (tray "서버 종료") so no zombie is left while the app runs; this does not tie its life
        // to ours.
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        result
    }
}

/// Own session / process group: the server outlives the app and gets no signal from the app's terminal.
#[cfg(unix)]
fn detach(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
}

/// A hidden console of its own (CREATE_NO_WINDOW, inherited by the console programs it runs, so none flashes a
/// window) in a new process group, so it is not tied to the app.
#[cfg(windows)]
fn detach(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
}

/// An AppImage is a mount that disappears when the app quits, but the detached server keeps reading its art from
/// disk: run a copy kept in the app's data folder instead (once per version).
pub fn outside_appimage(bundle: Bundle, data_dir: &Path, version: &str) -> Bundle {
    if std::env::var_os("APPIMAGE").is_none() {
        return bundle;
    }
    let dir = data_dir.join("runtime").join(version);
    let copy = Bundle { server: dir.join(bundle.server.file_name().unwrap_or_default()), art: dir.join("art") };
    if dir.join(".complete").exists() {
        return copy;
    }
    let _ = fs::remove_dir_all(&dir);
    let ok = fs::create_dir_all(&dir).is_ok()
        && fs::copy(&bundle.server, &copy.server).is_ok()
        && copy_dir(&bundle.art, &copy.art).is_ok()
        && fs::write(dir.join(".complete"), "").is_ok();
    if ok {
        copy
    } else {
        bundle
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
