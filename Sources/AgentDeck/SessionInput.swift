import Foundation

/// Types into the terminal that hosts an agent, as if the user typed there.
/// The host is found the same way as for reading: tmux (incl. 수혁's own server) → Orca → cmux.
enum SessionInput {
    enum Key: CaseIterable {
        case up, down, enter, escape, one, two, three

        var label: String {
            switch self {
            case .up: return "↑"
            case .down: return "↓"
            case .enter: return "⏎"
            case .escape: return "Esc"
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            }
        }

        var tmux: String {
            switch self {
            case .up: return "Up"
            case .down: return "Down"
            case .enter: return "Enter"
            case .escape: return "Escape"
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            }
        }

        var cmux: String {
            switch self {
            case .up: return "up"
            case .down: return "down"
            case .enter: return "enter"
            case .escape: return "escape"
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            }
        }
    }

    private enum Target {
        case tmux(socket: String, pane: String)
        case orca(handle: String)
        case cmux(workspace: String, surface: String)
    }

    private static func target(_ s: AgentSession) -> Target? {
        guard let pid = s.pid else { return nil }
        let env = ProcessEnv.of(pid)
        if let t = env["TMUX"], let pane = env["TMUX_PANE"] {
            return .tmux(socket: String(t.split(separator: ",").first ?? ""), pane: pane)
        }
        if let h = env["ORCA_TERMINAL_HANDLE"] { return .orca(handle: h) }
        if let w = env["CMUX_WORKSPACE_ID"], let f = env["CMUX_SURFACE_ID"] { return .cmux(workspace: w, surface: f) }
        return nil
    }

    static func canSend(_ s: AgentSession) -> Bool { target(s) != nil }

    /// Sends a whole message and presses Enter. Returns false when the host refused it.
    static func send(_ s: AgentSession, text: String) -> Bool {
        guard let t = target(s) else { return false }
        switch t {
        case .tmux(let socket, let pane):
            guard let tmux = TmuxEngine.tmux else { return false }
            // Bracketed paste keeps line breaks inside one message instead of submitting each line.
            let base = ["-S", socket]
            guard runInput(tmux, base + ["load-buffer", "-b", "suhyeok-input", "-"], input: text),
                  TerminalSource.run(tmux, base + ["paste-buffer", "-p", "-d", "-b", "suhyeok-input", "-t", pane]) != nil
            else { return false }
            usleep(150_000)  // let the TUI take the paste before Enter
            return TerminalSource.run(tmux, base + ["send-keys", "-t", pane, "Enter"]) != nil
        case .orca(let handle):
            // Orca types the text; flatten lines so only the final Enter submits.
            return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--text", oneLineInput(text), "--enter"]) != nil
        case .cmux(let w, let f):
            // cmux turns \n into Enter, so send one line and press Enter separately.
            let line = oneLineInput(text).replacingOccurrences(of: "\\", with: "\\\\")
            guard TerminalSource.run(cmux, ["send", "--workspace", w, "--surface", f, "--", line]) != nil else { return false }
            usleep(150_000)
            return TerminalSource.run(cmux, ["send-key", "--workspace", w, "--surface", f, "enter"]) != nil
        }
    }

    static func press(_ s: AgentSession, _ key: Key) -> Bool {
        guard let t = target(s) else { return false }
        switch t {
        case .tmux(let socket, let pane):
            guard let tmux = TmuxEngine.tmux else { return false }
            return TerminalSource.run(tmux, ["-S", socket, "send-keys", "-t", pane, key.tmux]) != nil
        case .orca(let handle):
            guard key == .enter else { return false }  // Orca's CLI only exposes text + Enter
            return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--text", "", "--enter"]) != nil
        case .cmux(let w, let f):
            return TerminalSource.run(cmux, ["send-key", "--workspace", w, "--surface", f, key.cmux]) != nil
        }
    }

    private static let orca = "/Applications/Orca.app/Contents/Resources/bin/orca"
    private static let cmux = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    private static func oneLineInput(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func runInput(_ path: String, _ args: [String], input: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
