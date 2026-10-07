import Foundation

/// Reads the live terminal screen hosting an agent process.
/// The host is detected from variables in the agent's environment; each host has its own read command.
/// Terminals without a read API (plain Ghostty, xterm, Warp, editor terminals) fall back to the transcript view.
enum TerminalSource {
    enum Result { case text(String, host: String), unsupported, denied(host: String, hint: String) }

    private struct Host {
        let name: String
        let tool: String
        let args: [String]
        let deniedHint: String
    }

    private static var cache: [Int32: Host?] = [:]
    private static let lock = NSLock()

    static func read(pid: Int32, lines: Int = 400) -> Result {
        guard let host = host(pid: pid, lines: lines) else { return .unsupported }
        guard let out = run(host.tool, host.args), !out.isEmpty else {
            return .denied(host: host.name, hint: host.deniedHint)
        }
        return .text(out, host: host.name)
    }

    /// Picks the most specific host: a tmux pane inside cmux is better read through tmux.
    private static func host(pid: Int32, lines: Int) -> Host? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        let env = ProcessEnv.of(pid)
        var found: Host?
        if let tmux = env["TMUX"], let pane = env["TMUX_PANE"], let bin = which("tmux") {
            let socket = String(tmux.split(separator: ",").first ?? "")
            found = Host(name: "tmux", tool: bin,
                         args: ["-S", socket, "capture-pane", "-p", "-J", "-t", pane, "-S", "-\(lines)"],
                         deniedHint: "tmux 서버(\(socket))에 접근하지 못함")
        } else if let handle = env["ORCA_TERMINAL_HANDLE"] {
            let bin = "/Applications/Orca.app/Contents/Resources/bin/orca"
            found = Host(name: "Orca", tool: bin,
                         args: ["terminal", "read", "--terminal", handle, "--limit", String(lines)],
                         deniedHint: "Orca 런타임에 연결하지 못함 (Orca 실행 여부 확인: orca status)")
        } else if let ws = env["CMUX_WORKSPACE_ID"], let sf = env["CMUX_SURFACE_ID"] {
            let bin = "/Applications/cmux.app/Contents/Resources/bin/cmux"
            found = Host(name: "cmux", tool: bin,
                         args: ["read-screen", "--workspace", ws, "--surface", sf, "--scrollback", "--lines", String(lines)],
                         deniedHint: "cmux 소켓 접근 거부됨 — settings.json의 automation.socketControlMode를 password로 두고 cmux를 한 번 재시작해야 함")
        }
        if let f = found, !FileManager.default.isExecutableFile(atPath: f.tool) { found = nil }
        cache[pid] = found
        return found
    }

    /// GUI apps launched from Finder have a minimal PATH, so look in the usual install places.
    private static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Environment variables of another process (via `ps eww`), cached since they never change.
enum ProcessEnv {
    private static var cache: [Int32: [String: String]] = [:]
    private static let lock = NSLock()

    static func of(_ pid: Int32) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let env = cache[pid] { return env }
        guard let out = TerminalSource.run("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]) else { return [:] }
        var vars: [String: String] = [:]
        for token in out.split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                vars[String(kv[0])] = String(kv[1])
            }
        }
        cache[pid] = vars
        return vars
    }
}
