import Foundation

/// Types into the terminal that hosts an agent, as if the user typed there.
/// The host is found the same way as for reading: tmux (incl. 수혁's own server) → Orca → cmux.
enum SessionInput {
    enum Key: CaseIterable {
        case up, down, left, right, tab, enter, escape, one, two, three

        var label: String {
            switch self {
            case .up: return "↑"
            case .down: return "↓"
            case .left: return "←"
            case .right: return "→"
            case .tab: return "Tab"
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
            case .left: return "Left"
            case .right: return "Right"
            case .tab: return "Tab"
            case .enter: return "Enter"
            case .escape: return "Escape"
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            }
        }

        /// Raw bytes for hosts that only take text (Orca writes `--text` to the pty as is); nil = Enter, sent as `--enter`.
        var bytes: String? {
            switch self {
            case .up: return "\u{1b}[A"
            case .down: return "\u{1b}[B"
            case .left: return "\u{1b}[D"
            case .right: return "\u{1b}[C"
            case .tab: return "\t"
            case .enter: return nil
            case .escape: return "\u{1b}"
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            }
        }

        var cmux: String {
            switch self {
            case .up: return "up"
            case .down: return "down"
            case .left: return "left"
            case .right: return "right"
            case .tab: return "tab"
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
            // Let the TUI take the paste before Enter; a long paste takes it longer.
            usleep(useconds_t(min(150_000 + text.utf8.count * 200, 800_000)))
            guard TerminalSource.run(tmux, base + ["send-keys", "-t", pane, "Enter"]) != nil else { return false }
            // An Enter that lands while the TUI is still busy with the paste (or picks a slash-command suggestion)
            // leaves the message in the input box, and the next message gets glued onto it. Press again until it is gone.
            for attempt in 1...3 {
                usleep(useconds_t(250_000 * attempt))
                guard let screen = TerminalSource.run(tmux, base + ["capture-pane", "-p", "-t", pane]),
                      stillTyped(text, in: screen) else { break }
                _ = TerminalSource.run(tmux, base + ["send-keys", "-t", pane, "Enter"])
            }
            return true
        case .orca(let handle):
            // Orca types the text; flatten lines so only the final Enter submits.
            return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--text=" + oneLineInput(text), "--enter"]) != nil
        case .cmux(let w, let f):
            // cmux turns \n into Enter, so send one line and press Enter separately.
            let line = oneLineInput(text).replacingOccurrences(of: "\\", with: "\\\\")
            guard TerminalSource.run(cmux, ["send", "--workspace", w, "--surface", f, "--", line]) != nil else { return false }
            usleep(150_000)
            return TerminalSource.run(cmux, ["send-key", "--workspace", w, "--surface", f, "enter"]) != nil
        }
    }

    /// Types text without pressing Enter (e.g. into a menu's "Type something" row).
    static func type(_ s: AgentSession, text: String) -> Bool {
        guard let t = target(s) else { return false }
        let line = oneLineInput(text)
        switch t {
        case .tmux(let socket, let pane):
            guard let tmux = TmuxEngine.tmux else { return false }
            return TerminalSource.run(tmux, ["-S", socket, "send-keys", "-t", pane, "-l", line]) != nil
        case .orca(let handle):
            return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--text=" + line]) != nil
        case .cmux(let w, let f):
            return TerminalSource.run(cmux, ["send", "--workspace", w, "--surface", f, "--",
                                             line.replacingOccurrences(of: "\\", with: "\\\\")]) != nil
        }
    }

    static func press(_ s: AgentSession, _ key: Key) -> Bool {
        guard let t = target(s) else { return false }
        switch t {
        case .tmux(let socket, let pane):
            guard let tmux = TmuxEngine.tmux else { return false }
            return TerminalSource.run(tmux, ["-S", socket, "send-keys", "-t", pane, key.tmux]) != nil
        case .orca(let handle):
            // Orca's CLI takes text and Enter only, but writes the text to the pty unchanged, so keys go as escape bytes.
            guard let b = key.bytes else {
                return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--enter"]) != nil
            }
            return TerminalSource.run(orca, ["terminal", "send", "--terminal", handle, "--text=" + b]) != nil
        case .cmux(let w, let f):
            return TerminalSource.run(cmux, ["send-key", "--workspace", w, "--surface", f, key.cmux]) != nil
        }
    }

    /// What sits in the agent's input box: Claude Code draws it between the last two rules ("❯ …"),
    /// Codex shows a "›" line near the bottom. nil when the screen shows neither.
    static func draft(_ screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        let rules = lines.indices.filter { i in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.count >= 10 && t.allSatisfy { $0 == "─" }
        }
        if rules.count >= 2, let top = rules.dropLast().last, let bottom = rules.last {
            let box = lines[(top + 1)..<bottom].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return box.hasPrefix("❯") || box.hasPrefix(">") ? String(box.dropFirst()) : box
        }
        if let line = lines.suffix(8).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }) {
            return String(line.trimmingCharacters(in: .whitespaces).dropFirst())
        }
        return nil
    }

    /// Whether `text` is still waiting in the input box: its last characters (spaces and line wraps ignored), or a
    /// collapsed "[Pasted text …]" placeholder.
    static func stillTyped(_ text: String, in screen: String) -> Bool {
        guard let box = draft(screen) else { return false }
        let squeeze = { (s: String) in String(s.filter { !$0.isWhitespace }) }
        let tail = String(squeeze(text).suffix(12)), inBox = squeeze(box)
        return !tail.isEmpty && inBox.contains(tail) || inBox.contains("[Pastedtext")
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
    /// What is being asked, read from the screen above the options: the question line
    /// ("Do you want to proceed?") and the context block (tool, command, file) under the last border.
    var question: String? = nil
    var context: String? = nil

    /// Finds the menu just above a footer hint like "Enter to confirm · Esc to cancel".
    /// The highlighted option starts with "❯" at some column; the others start two columns further in,
    /// and deeper-indented lines are descriptions of the option above them.
    static func parse(_ screen: String) -> TerminalMenu? {
        let lines = screen.components(separatedBy: "\n")
        // The review step of a multi-question/multi-select AskUserQuestion has no footer: end at the last line.
        // Claude Code: "Enter to confirm · Esc to cancel"; Codex: "enter select · esc back", "esc to cancel".
        let hint = lines.lastIndex(where: { l in
            let h = l.lowercased()
            return h.contains("enter to confirm") || h.contains("enter to select") || h.contains("esc to cancel")
                || h.contains("enter select") || h.contains("esc back")
        })
        let review = lines.contains { $0.contains("Ready to submit your answers?") }
            ? lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0 + 1 } : nil
        guard let footer = hint ?? review else { return nil }
        // The highlighted line closest above the footer ("❯" in Claude Code, "›" in Codex).
        guard let sel = lines[..<footer].lastIndex(where: { l in
                  indentOf(l).map { lineTail(l, $0).hasPrefix("❯") || lineTail(l, $0).hasPrefix("›") } ?? false }),
              footer - sel < 40, let col = indentOf(lines[sel]) else { return nil }
        let numbered = String(lineTail(lines[sel], col).dropFirst()).trimmingCharacters(in: .whitespaces)
            .range(of: #"^\d+\."#, options: .regularExpression) != nil
        func optionText(_ i: Int) -> String? {
            let l = lines[i]
            guard let ind = indentOf(l) else { return nil }
            if i == sel { return String(lineTail(l, ind).dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces) }
            // Multi-select lists end with a "Submit" row ("Next" when more questions follow), indented like the
            // option labels, not the numbers.
            if ["Submit", "Next"].contains(lineTail(l, ind)) { return lineTail(l, ind) }
            guard ind == col + 2 else { return nil }
            // Codex draws its menu at the left edge, level with the text above it: when the options are numbered,
            // only numbered lines are options.
            return !numbered || lineTail(l, ind).range(of: #"^\d+\."#, options: .regularExpression) != nil ? lineTail(l, ind) : nil
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
                // AskUserQuestion with previews draws a box to the right of the options; its rows are not descriptions.
                if d.hasPrefix("┌") || d.hasPrefix("│") || d.hasPrefix("└") || d.hasPrefix("Notes: press n") { continue }
                options[options.count - 1] = Option(label: last.label, detail: [last.detail, d].compactMap { $0 }.joined(separator: " "))
            }
        }
        guard options.count >= 2 else { return nil }
        // Context: lines between the box's top border (───) and the first option, minus tips and separators.
        let top = lines[..<first].lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("──") } ?? max(0, first - 30)
        var ctx = lines[(top + 1)..<first].map { l -> String in
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("│") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t
        }.filter { t in
            !t.isEmpty && !t.hasPrefix("╌") && !t.hasPrefix("──") && !t.hasPrefix("Tip:") && !t.hasPrefix("⎿  Tip")
        }
        var question: String?
        if let q = ctx.last, q.hasSuffix("?") { question = q; ctx.removeLast() }
        return TerminalMenu(options: options, selected: selected, question: question,
                            context: ctx.isEmpty ? nil : ctx.suffix(14).joined(separator: "\n"))
    }

    /// AskUserQuestion's free-text row: "Type something." (single) or "[ ] Type something" (multi-select).
    func isFreeText(_ i: Int) -> Bool {
        options[i].label.range(of: #"^(\[.\] )?Type something\.?$"#, options: .regularExpression) != nil
    }
    /// Checkbox rows: typing into the free-text row ticks it, no Enter needed.
    var isMultiSelect: Bool { options.contains { $0.label.hasPrefix("[ ] ") || $0.label.hasPrefix("[✔] ") } }

    private static func indentOf(_ l: String) -> Int? {
        let n = l.prefix { $0 == " " }.count
        return n < l.count ? n : nil
    }
    private static func lineTail(_ l: String, _ n: Int) -> String { String(l.dropFirst(n)).trimmingCharacters(in: .whitespaces) }
    /// "2. Yes, and don't ask again" -> "Yes, and don't ask again"; a preview box to the right of the label is dropped.
    private static func clean(_ s: String) -> String {
        var s = s
        if let r = s.range(of: #"\s{2,}[┌│└].*$"#, options: .regularExpression) { s.removeSubrange(r) }
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

    /// Answers a free-text row: moves the highlight onto it and types. A single-select question also needs Enter;
    /// a checkbox row is ticked by the typing itself.
    static func answer(_ s: AgentSession, menu: TerminalMenu, index: Int, text: String) -> Bool {
        let steps = index - menu.selected
        for _ in 0..<abs(steps) {
            guard press(s, steps > 0 ? .down : .up) else { return false }
            usleep(60_000)
        }
        usleep(80_000)
        guard type(s, text: text) else { return false }
        if menu.isMultiSelect { return true }
        usleep(150_000)
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
