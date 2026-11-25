//! suhyeok-server: the 수혁 server for Windows and Linux (contract/README.md).
//!
//! Options:
//!   --port <n>        listen port on 127.0.0.1 (default 4380, or SUHYEOK_PORT)
//!   --art <dir>       bundled art folder (default: next to the executable, else the repo's art/out)
//!   --data <dir>      devices and state (default: the OS data folder / Suhyeok)
//!   --en              English labels
//!   --pair            start pairing now: prints "secret <32hex>"; "allow" / "deny" on stdin answer the oldest request
//!   --no-restore      do not reopen the conversations a restart closed
//!   --seconds <n>     stop after n seconds (tests)

mod app;

use app::{default_art_dir, default_data_dir, App, Config};
use std::io::BufRead;
use std::sync::Arc;
use std::time::Duration;
use suhyeok::model::now;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let port = arg(&args, "--port")
        .or_else(|| std::env::var("SUHYEOK_PORT").ok())
        .and_then(|p| p.parse().ok())
        .unwrap_or(4380u16);
    let config = Config {
        port,
        en: args.iter().any(|a| a == "--en"),
        art_dir: arg(&args, "--art").map(Into::into).unwrap_or_else(default_art_dir),
        data_dir: arg(&args, "--data").map(Into::into).unwrap_or_else(default_data_dir),
        extra_hosts: vec![],
        restore: !args.iter().any(|a| a == "--no-restore"),
    };
    let app = Arc::new(App::new(
        config,
        Box::new(|id| {
            println!("pair-request {id}");
        }),
    ));

    if args.iter().any(|a| a == "--pair") {
        let secret = app.auth.lock().unwrap().begin_pairing(now());
        println!("secret {secret}");
        let a = app.clone();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines().map_while(Result::ok) {
                let line = line.trim().to_string();
                if line != "allow" && line != "deny" {
                    continue;
                }
                let mut auth = a.auth.lock().unwrap();
                if let Some(id) = auth.oldest_waiting(now()) {
                    auth.decide(&id, line == "allow", now());
                    println!("decided {line}");
                }
            }
        });
    }

    let listener = match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot listen on 127.0.0.1:{port}: {e}");
            std::process::exit(1);
        }
    };
    println!("listening http://127.0.0.1:{port}");

    // First look right away, then every 3 seconds (SessionStore's timer). The first one reads every hunt log and can
    // take a while, so the port is open before it; the API answers with what it has until then.
    {
        let a = app.clone();
        tokio::spawn(async move {
            let mut first = true;
            loop {
                let b = a.clone();
                let started = std::time::Instant::now();
                tokio::task::spawn_blocking(move || b.refresh()).await.ok();
                if first {
                    println!("first refresh {:.1}s", started.elapsed().as_secs_f64());
                    first = false;
                    if a.config.restore {
                        let c = a.clone();
                        let n = tokio::task::spawn_blocking(move || c.reopen_closed()).await.unwrap_or(0);
                        if n > 0 {
                            println!("reopened {n} conversation(s)");
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        });
    }
    // The owner's saved choice: LAN listener and tunnel (phase 4).
    let saved = app::network::Settings::load(&app.config.data_dir);
    if saved.lan || saved.tunnel {
        app.set_network(saved);
    }
    let server = axum::serve(listener, app::http::router(app.clone()));
    match arg(&args, "--seconds").and_then(|s| s.parse::<u64>().ok()) {
        Some(secs) => {
            let _ = tokio::time::timeout(Duration::from_secs(secs), server).await;
        }
        None => {
            let _ = server.await;
        }
    }
}
