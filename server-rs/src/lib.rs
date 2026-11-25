//! 수혁 server for Windows and Linux (docs/plans/2026-11-17-001-feat-cross-platform-server-plan.md).
//! Each module ports one part of the Mac app (Sources/AgentDeck); the HTTP layer follows contract/README.md.

pub mod characters;
pub mod hunt;
pub mod menu;
pub mod model;
pub mod pty;
pub mod sessions;
pub mod transcript;
pub mod usage;
pub mod world;
