import Foundation

/// The desktop page served by MobileServer at /desk: Windows 수혁 (a Tauri window around this page) and PC browsers.
/// Laid out like the Mac app (WorkspaceView): the sidebar (sort, 월드·목록·길드·마켓, 수혁 세션, 터미널, 다른 터미널,
/// 최근 대화), the world map with its overlays, the list, the RPG dialogue and the terminal. It runs on the phone's API
/// plus DesktopAPI; what only the Mac can do (voice, guild ledger, market purchases, worktrees, moving sessions) keeps
/// its place on screen and says so when pressed.
///
/// The page itself lives in `web/desk.html`, shared with the Rust server (server-rs) so every 수혁 server serves the
/// same page. build.sh copies it to Resources/web; runs outside the bundle (swift run, tests) read it from the repo.
enum DesktopPage {
    static var html: String {
        template.replacingOccurrences(of: "{{LANG}}", with: L10n.english ? "en" : "ko")
    }

    static let template: String = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Sources/AgentDeck
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/desk.html")
        for url in [Bundle.main.resourceURL?.appendingPathComponent("web/desk.html"), repo].compactMap({ $0 }) {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        return "<!doctype html><title>수혁</title><p>web/desk.html missing from this build</p>"
    }()
}
