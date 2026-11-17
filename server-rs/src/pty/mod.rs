//! Terminals this server hosts, in place of the Mac's own tmux server (`tmux -L suhyeok`, TmuxEngine.swift).
//!
//! On the Mac every agent and plain shell 수혁 starts runs on its tmux server, so it outlives the app. On Windows and
//! Linux the server process hosts them itself in PTYs (ConPTY / Unix PTY): [`Host`] starts them, lists them, reads
//! their screens through a vt100 parser, types into them and ends them. They live as long as the server; after a
//! restart [`restore::Restore`] reopens the conversations they had open with the agent's resume flag.
//!
//! - [`launch`]: command lines, titles and names (TmuxEngine.create / createShell, Agent helpers, Persona)
//! - [`host`]: the PTYs ([`Host`], [`Hosted`], [`HostedTerm`] for `menu::Term`)
//! - [`screen`]: screen reads, plain (`capture-pane -p -J`) and colored (`-e`)
//! - [`mobile`]: `/api/terminals`, `/api/term`, `/api/term-input` (MobileTerminal.swift)
//! - [`restore`]: the open-sessions record (SessionRestore.swift)

pub mod host;
pub mod launch;
pub mod mobile;
pub mod restore;
pub mod screen;

pub use host::{owner_in, Host, HostOptions, Hosted, HostedTerm};
pub use launch::{Launch, PANEL_NAME, SESSION_ENV, SHELL_TAG};
pub use screen::Screen;

#[cfg(all(test, unix))]
mod tests;
