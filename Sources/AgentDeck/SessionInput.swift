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

/// A selection menu the agent's TUI is showing (permission prompts, questions, trust checks).
struct TerminalMenu: Equatable {
    struct Option: Equatable { let label: String; let detail: String? }
    let options: [Option]
    let selected: Int

    /// Finds the menu just above a footer hint like "Enter to confirm · Esc to cancel".
    /// The highlighted option starts with "❯" at some column; the others start two columns further in,
    /// and deeper-indented lines are descriptions of the option above them.
    static func parse(_ screen: String) -> TerminalMenu? {
        let lines = screen.components(separatedBy: "\n")
        guard let footer = lines.lastIndex(where: {
            $0.contains("Enter to confirm") || $0.contains("Enter to select") || $0.contains("Esc to cancel")
        }) else { return nil }
        // The highlighted line closest above the footer.
        guard let sel = lines[..<footer].lastIndex(where: { l in indentOf(l).map { lineTail(l, $0).hasPrefix("❯") } ?? false }),
              footer - sel < 40, let col = indentOf(lines[sel]) else { return nil }
        func optionText(_ i: Int) -> String? {
            let l = lines[i]
            guard let ind = indentOf(l) else { return nil }
            if i == sel { return String(lineTail(l, ind).dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces) }
            return ind == col + 2 ? lineTail(l, ind) : nil
        }
        // Grow the block both ways from the highlighted line.
        var first = sel
        var i = sel - 1
        while i >= 0 {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { i -= 1; continue }
            guard let ind = indentOf(l), ind >= col + 2 else { break }
            if optionText(i) != nil { first = i }
            i -= 1
        }
        var options: [Option] = []
        var selected = 0
        for j in first..<footer {
            if let t = optionText(j) {
                if j == sel { selected = options.count }
                options.append(Option(label: clean(t), detail: nil))
            } else if let ind = indentOf(lines[j]), ind > col + 2, let last = options.last {
                let d = lineTail(lines[j], ind)
                options[options.count - 1] = Option(label: last.label, detail: [last.detail, d].compactMap { $0 }.joined(separator: " "))
            }
        }
        return options.count >= 2 ? TerminalMenu(options: options, selected: selected) : nil
    }

    private static func indentOf(_ l: String) -> Int? {
        let n = l.prefix { $0 == " " }.count
        return n < l.count ? n : nil
    }
    private static func lineTail(_ l: String, _ n: Int) -> String { String(l.dropFirst(n)).trimmingCharacters(in: .whitespaces) }
    /// "2. Yes, and don't ask again" -> "Yes, and don't ask again"
    private static func clean(_ s: String) -> String {
        if let r = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) { return String(s[r.upperBound...]) }
        return s
    }
}

extension SessionInput {
    /// Moves the highlight from `menu.selected` to `index` with arrow keys, then confirms.
    static func choose(_ s: AgentSession, menu: TerminalMenu, index: Int) -> Bool {
        let steps = index - menu.selected
        for _ in 0..<abs(steps) {
            guard press(s, steps > 0 ? .down : .up) else { return false }
            usleep(60_000)
        }
        usleep(80_000)
        return press(s, .enter)
    }
}


/// What the agent is writing right now, scraped from the terminal screen of a Claude Code session.
struct LiveReply: Equatable {
    let text: String
    let status: String?  // spinner line, e.g. "Cogitating… (12s · ↑ 300 tokens)"
    /// The current turn exactly as the terminal shows it: from the latest prompt down to the input box.
    var raw: String = ""

    static func turn(_ screen: String) -> String {
        var lines = screen.components(separatedBy: "\n")
        if let box = lines.indices.last(where: { i in
            i > 0 && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("❯")
                && lines[i - 1].trimmingCharacters(in: .whitespaces).hasPrefix("─")
        }) { lines = Array(lines[..<(box - 1)]) }
        // Start at the user's latest prompt echo ("❯ …" at the left edge) if it is on screen.
        if let start = lines.lastIndex(where: { $0.hasPrefix("❯ ") }) { lines = Array(lines[start...]) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        // Trim the right padding Claude Code adds to fill the terminal width.
        return lines.map { l in String(l.reversed().drop(while: { $0 == " " }).reversed()) }.suffix(60).joined(separator: "\n")
    }

    static let spinners: Set<Swift.Character> = ["✻", "✶", "✳", "✢", "✽", "·", "*", "⏺"]

    static func parse(_ screen: String, alreadyLogged: String?) -> LiveReply? {
        var lines = screen.components(separatedBy: "\n")
        // Cut the input box: the last line starting with "❯" that sits right under a ──── border.
        if let box = lines.indices.last(where: { i in
            i > 0 && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("❯")
                && lines[i - 1].trimmingCharacters(in: .whitespaces).hasPrefix("─")
        }) { lines = Array(lines[..<(box - 1)]) }
        // Below the reply Claude Code prints a spinner line ("· Transmuting… (2m 3s · ↓ 7.7k tokens)"),
        // sometimes a "⎿ Tip" hint and right-aligned notices ("✔ Update installed"). Take the spinner as status
        // and cut everything from it down.
        var status: String?
        let tailStart = max(0, lines.count - 8)
        if let i = lines[tailStart...].lastIndex(where: { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let first = t.first, first != "⏺", first != "⎿", first != "✔" else { return false }
            return spinners.contains(first) && t.contains("…")
        }) {
            status = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
            lines = Array(lines[..<i])
        }
        while let l = lines.last?.trimmingCharacters(in: .whitespaces),
              l.isEmpty || l.hasPrefix("⎿  Tip") || l.hasPrefix("✔") {
            lines.removeLast()
        }
        // The newest "⏺ " block that is text (not a tool call like "⏺ Bash(…)").
        guard let start = lines.lastIndex(where: { $0.hasPrefix("⏺ ") }) else {
            return status.map { LiveReply(text: "", status: $0) }
        }
        let head = String(lines[start].dropFirst(2))
        // Tool calls are "⏺ Bash(…)" or, in compact view, "⏺ <description>" followed by "⎿" output lines.
        let nextLine = lines[(start + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let isTool = head.range(of: #"^[A-Za-z_]+\("#, options: .regularExpression) != nil
            || (nextLine?.trimmingCharacters(in: .whitespaces).hasPrefix("⎿") ?? false)
        var body = [head] + lines[(start + 1)...]
            .filter { !$0.contains("ctrl+enter to send") && !$0.contains("esc to interrupt") }  // UI hints, not reply text
            .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        let text = body.joined(separator: "\n")
        // Already in the log as a finished message: nothing live to add.
        if isTool || (alreadyLogged.map { norm($0).hasPrefix(norm(text).prefix(60)) } ?? false) {
            return status.map { LiveReply(text: "", status: $0) }
        }
        return LiveReply(text: text, status: status)
    }

    private static func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }
}
