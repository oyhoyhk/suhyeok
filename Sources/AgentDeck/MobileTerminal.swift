import Foundation

/// The phone's terminal tab: sessions on 수혁's own tmux server (agents, plain shells, the bottom panel), read as
/// screens with their colors and typed into. Terminals outside that server (cmux, Orca, …) are not reachable here.
enum MobileTerminal {
    /// Keys the phone may press, as tmux names them. Ctrl+letter ("C-c") is allowed on top of these.
    static let keys: Set<String> = ["Enter", "Tab", "BTab", "Escape", "BSpace", "DC", "Up", "Down", "Left", "Right",
                                    "Home", "End", "PageUp", "PageDown"]

    /// Every session on the server, oldest first, with the agent's name and character when it runs one.
    @MainActor
    static func list(_ store: SessionStore) async -> [[String: Any]] {
        let hosted = await Task.detached { TmuxEngine.list() }.value
        return hosted.map { h in
            let s = store.session(hosted: h.name)
            return [
                "name": h.name, "title": h.title, "cwd": h.cwd, "kind": h.agent?.rawValue ?? TmuxEngine.shellTag,
                "panel": h.name == TmuxEngine.panelName,
                "agentName": s.map { store.agentName(for: $0) } ?? "",
                "character": s.flatMap { store.character(for: $0)?.id } ?? h.character ?? "",
                "created": h.created.timeIntervalSince1970,
            ]
        }
    }

    /// Only names the server lists: the phone cannot aim tmux at anything else.
    static func exists(_ name: String) -> Bool { TmuxEngine.list().contains { $0.name == name } }

    /// The pane as text with its colors (ANSI escapes), `history` lines of scrollback above the visible screen,
    /// and where the cursor is within the visible screen (the last `height` lines).
    static func screen(_ name: String, history: Int) -> [String: Any]? {
        guard let tmux = TmuxEngine.tmux, exists(name),
              let info = TerminalSource.run(tmux, TmuxEngine.base + ["display-message", "-p", "-t", name,
                  "#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}\t#{alternate_on}"]),
              let text = TerminalSource.run(tmux, TmuxEngine.base + ["capture-pane", "-p", "-e", "-t", name,
                  "-S", "-\(max(0, min(history, 2000)))"])
        else { return nil }
        let f = info.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map { Int($0) ?? 0 }
        guard f.count == 5 else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return ["lines": lines, "width": f[0], "height": f[1], "cx": f[2], "cy": f[3], "alternate": f[4] == 1]
    }

    /// Types `text` as it is (no Enter).
    static func type(_ name: String, text: String) -> Bool {
        guard let tmux = TmuxEngine.tmux, !text.isEmpty, exists(name) else { return false }
        return TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, "-l", "--", text]) != nil
    }

    static func press(_ name: String, key: String) -> Bool {
        let ctrl = key.count == 3 && key.hasPrefix("C-") && key.last!.isASCII && key.last!.isLowercase
        guard keys.contains(key) || ctrl, let tmux = TmuxEngine.tmux, exists(name) else { return false }
        return TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, key]) != nil
    }
}
