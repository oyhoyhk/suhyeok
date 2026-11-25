import Foundation

/// A menu on one of 수혁's own agent terminals before the agent has a session to show it in: the folder trust check
/// on a first start in a folder comes before Claude Code writes its registry entry (and before a Codex thread exists),
/// so the dialogue and the phone's session list cannot see it. Read and answered through tmux directly.
enum HostedMenu {
    /// The menu on the terminal `name` is showing, if any.
    static func read(_ name: String) -> TerminalMenu? {
        guard let tmux = TmuxEngine.tmux,
              let screen = TerminalSource.run(tmux, TmuxEngine.base + ["capture-pane", "-p", "-t", name]) else { return nil }
        return TerminalMenu.parse(screen)
    }

    /// Picks option `index` of the menu the terminal shows now (moves the highlight, then Enter).
    static func choose(_ name: String, index: Int) -> Bool {
        guard let tmux = TmuxEngine.tmux, let menu = read(name), menu.options.indices.contains(index) else { return false }
        let steps = index - menu.selected
        for _ in 0..<abs(steps) {
            guard TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, steps > 0 ? "Down" : "Up"]) != nil
            else { return false }
            usleep(60_000)
        }
        usleep(80_000)
        return TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, "Enter"]) != nil
    }

    /// Agent terminals in `hosted` that have no session yet (`known`: hosted names that have one) and show a menu.
    static func pending(_ hosted: [TmuxEngine.Hosted], known: Set<String>) -> [(TmuxEngine.Hosted, TerminalMenu)] {
        hosted.filter { $0.agent != nil && !known.contains($0.name) }.compactMap { h in read(h.name).map { (h, $0) } }
    }
}
