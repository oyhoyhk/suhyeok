import Foundation

/// Runs agent sessions on a dedicated tmux server (`tmux -L suhyeok`), so they outlive the app
/// and can still be attached from any other terminal: `tmux -L suhyeok attach -t <name>`.
enum TmuxEngine {
    static let socketName = "suhyeok"
    /// `@agent` of a plain shell session.
    static let shellTag = "Shell"

    struct Hosted: Identifiable, Hashable {
        let name: String     // tmux session name, e.g. sh-3fa9c1
        let agent: Agent?    // nil: a plain shell (사이드바 "터미널"), no agent and no character
        let cwd: String
        let title: String
        let created: Date
        /// Roster id of the character chosen when 수혁 started it (nil for sessions from older versions).
        var character: String? = nil
        var id: String { name }
    }

    static var tmux: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Server flags: own socket, own config, force UTF-8 (Korean text).
    static var base: [String] { ["-L", socketName, "-f", configPath, "-u"] }

    static let configPath: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Suhyeok")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tmux.conf").path
        // The app draws its own chrome; tmux stays invisible. No prefix key, so Claude Code's ctrl+b keeps working.
        let conf = """
            set -g status off
            set -g prefix None
            unbind C-b
            set -g mouse on
            set -g history-limit 50000
            set -g escape-time 10
            set -g default-terminal "tmux-256color"
            set -ga terminal-overrides ",xterm-256color:Tc"
            set -g allow-rename off
            """
        try? conf.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }()

    /// The socket path an agent sees in $TMUX when it runs on this server.
    static func isOurs(tmuxEnv: String) -> Bool {
        (tmuxEnv.split(separator: ",").first ?? "").hasSuffix("/\(socketName)")
    }

    /// Starts an agent in a new detached session and returns its name. `character` is pinned to the session and,
    /// when the voice setting is on, its voice is appended to the agent's system prompt.
    static func create(agent: Agent, cwd: String, prompt: String?, resume: String? = nil, fork: Bool = false,
                       extraArgs: [String] = [], character: Character? = nil) -> String? {
        let name = "sh-" + String(UUID().uuidString.lowercased().prefix(6))
        var cmd: [String]
        switch agent {
        case .claude:
            // --fork-session: start a new conversation that begins with a copy of the resumed one.
            cmd = ["claude"] + (resume.map { ["--resume", $0] + (fork ? ["--fork-session"] : []) } ?? [])
        case .codex:
            cmd = ["codex"] + (resume.map { [fork ? "fork" : "resume", $0] } ?? [])
        }
        if let c = character, Persona.enabled, let voice = Persona.instructions(for: c) {
            let flag = agent == .claude ? ["--append-system-prompt", voice] : ["-c", "developer_instructions=" + tomlString(voice)]
            cmd.insert(contentsOf: flag, at: 1)
        }
        // Skip permission prompts by default (Settings ⌘, can turn it off); flags already carried over from a
        // migrated or cloned session are not added twice.
        if UserDefaults.standard.object(forKey: "skipPermissions") as? Bool ?? true {
            let flag = agent == .claude ? "--dangerously-skip-permissions" : "--dangerously-bypass-approvals-and-sandbox"
            if !extraArgs.contains(flag) { cmd.append(flag) }
        }
        cmd += extraArgs
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { cmd.append(p) }
        // Login + interactive zsh so PATH matches the user's terminals; keep a shell after the agent exits.
        let inner = cmd.map(quote).joined(separator: " ")
            + "; echo; echo " + quote(String(localized: "[에이전트 종료됨 — exit 로 창 닫기]")) + "; exec zsh -l"
        let shell = "exec /bin/zsh -lic " + quote(inner)
        let title = fork ? titleFor(prompt: prompt, cwd: cwd, resume: nil) + String(localized: " (클론)") : titleFor(prompt: prompt, cwd: cwd, resume: resume)
        return newSession(name, cwd: cwd, command: shell, meta: [("@agent", agent.rawValue), ("@title", title),
                                                                  ("@character", character?.id ?? "")])
    }

    /// The one shell behind the bottom terminal panel (⌘`), shared by every pane.
    static let panelName = "suhyeok-panel"

    /// Starts a login zsh in `cwd` with no agent, for running commands by hand. Returns its session name.
    static func createShell(cwd: String, name: String? = nil) -> String? {
        let name = name ?? "sh-" + String(UUID().uuidString.lowercased().prefix(6))
        return newSession(name, cwd: cwd, command: "exec /bin/zsh -l",
                          meta: [("@agent", shellTag), ("@title", (cwd as NSString).lastPathComponent), ("@character", "")])
    }

    private static func newSession(_ name: String, cwd: String, command: String, meta: [(String, String)]) -> String? {
        guard let tmux else { return nil }
        var env = ProcessInfo.processInfo.environment["LANG"] == nil ? ["-e", "LANG=ko_KR.UTF-8"] : []
        env += ["-e", "SUHYEOK_SESSION=\(name)"]
        let args = base + ["new-session", "-d", "-s", name, "-c", cwd, "-x", "200", "-y", "50"] + env + [command]
        guard TerminalSource.run(tmux, args) != nil else { return nil }
        // Metadata lives on the session itself, so the list survives app restarts.
        for (k, v) in [("@cwd", cwd)] + meta {
            _ = TerminalSource.run(tmux, base + ["set-option", "-t", name, k, v])
        }
        return name
    }

    static func list() -> [Hosted] {
        guard let tmux,
              let out = TerminalSource.run(tmux, base + ["list-sessions", "-F",
                  "#{session_name}\t#{@agent}\t#{@cwd}\t#{@title}\t#{session_created}\t#{@character}"])
        else { return [] }  // no server yet = no sessions
        return out.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { return nil }
            return Hosted(name: f[0], agent: f[1] == shellTag ? nil : Agent(rawValue: f[1]) ?? .claude, cwd: f[2],
                          title: f[3].isEmpty ? f[0] : f[3],
                          created: Date(timeIntervalSince1970: Double(f[4]) ?? 0),
                          character: f[5].isEmpty ? nil : f[5])
        }.sorted { $0.created < $1.created }
    }

    static func kill(_ name: String) {
        guard let tmux else { return }
        _ = TerminalSource.run(tmux, base + ["kill-session", "-t", name])
    }

    /// tmux session that owns a pane, e.g. "%3" -> "sh-3fa9c1".
    static func session(ofPane pane: String) -> String? {
        guard let tmux,
              let out = TerminalSource.run(tmux, base + ["display-message", "-p", "-t", pane, "#{session_name}"])
        else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func titleFor(prompt: String?, cwd: String, resume: String?) -> String {
        if let p = prompt, !p.isEmpty { return oneLine(p, limit: 40) }
        let folder = (cwd as NSString).lastPathComponent
        return resume == nil ? folder : String(localized: "\(folder) (이어서)")
    }

    /// A TOML basic string, for Codex `-c key=value` overrides.
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// POSIX single-quote escaping.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
