import Foundation

/// Messages agents send each other through 수혁 (`AgentDeck --msg <이름> "본문"`). The text is typed into the
/// recipient's terminal like any instruction, under a header that names the sender and how to answer.
enum AgentMail {
    struct Entry: Codable, Equatable {
        let at: Date
        let from: String
        let fromName: String
        let to: [String]
        let toNames: [String]
        let text: String
    }

    /// Live agents as the app names them, so a CLI call resolves "레오" the same way the sidebar shows it.
    struct Agent: Codable, Equatable {
        let id: String
        let name: String
        let agent: String
        let pid: Int32?
        let cwd: String
        let activity: String
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Suhyeok"
    static let logPath = dir + "/messages.jsonl"
    static let rosterPath = dir + "/agents.json"
    /// How long an exchange keeps two agents shown as talking.
    static let window: TimeInterval = 2 * 3600

    static let marker = "[수혁 메시지 · "

    // MARK: format

    /// "[수혁 메시지 · 시엘(claude-3209) → 레오, 바람 · 답장: '<exe>' --msg 시엘,바람 \"…\"]\n본문"
    static func compose(from: Agent, to: [Agent], recipient: Agent, text: String, exe: String) -> String {
        let replyTo = ([from.name] + to.filter { $0.id != recipient.id }.map(\.name)).joined(separator: ",")
        return marker + "\(from.name)(\(from.id)) → \(to.map(\.name).joined(separator: ", ")) · "
            + "답장: '\(exe)' --msg \(replyTo) \"…\"]\n" + text
    }

    struct Received: Equatable {
        let fromName: String
        let fromId: String
        let toNames: [String]
        let body: String
    }

    static func parse(_ text: String) -> Received? {
        guard text.hasPrefix(marker),
              let m = text.range(of: #"^\[수혁 메시지 · (.+?)\(([^()]+)\) → (.+?) · 답장: [^\n]*\]\s*"#, options: .regularExpression)
        else { return nil }
        let head = String(text[m])
        let parts = head.dropFirst(marker.count)
        guard let open = parts.firstIndex(of: "("), let close = parts[open...].firstIndex(of: ")"),
              let arrow = parts.range(of: " → "), let tail = parts.range(of: " · 답장: ") else { return nil }
        return Received(fromName: String(parts[..<open]),
                        fromId: String(parts[parts.index(after: open)..<close]),
                        toNames: parts[arrow.upperBound..<tail.lowerBound].components(separatedBy: ", "),
                        body: String(text[m.upperBound...]))
    }

    // MARK: log

    static func log(_ e: Entry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard var line = try? enc.encode(e) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = FileHandle(forWritingAtPath: logPath) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: logPath))
        }
    }

    static func recent(within: TimeInterval = window) -> [Entry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let since = Date().addingTimeInterval(-within)
        guard let h = FileHandle(forReadingAtPath: logPath) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 256 * 1024 ? size - 256 * 1024 : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(Entry.self, from: Data($0)) }
            .filter { $0.at > since }
    }

    // MARK: spool

    /// A sandboxed agent (Codex runs its shell in one) can neither reach another terminal nor write the app's folder,
    /// but /tmp stays writable: the CLI leaves the message here and the running app, outside the sandbox, types it.
    static let spool = "/tmp/suhyeok-mail"

    struct Request: Codable {
        let from: Agent
        let to: [Agent]
        let text: String
        let exe: String
        /// Recipients still to type into; nil = all of `to`.
        var pending: [Agent]? = nil
    }

    /// Writes the request and waits for the app's answer ("보냄 → …" or the failure), nil when nobody picked it up.
    static func spoolAndWait(_ r: Request, timeout: TimeInterval = 12) -> String? {
        try? FileManager.default.createDirectory(atPath: spool, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let req = spool + "/\(id).json", done = spool + "/\(id).done"
        guard let d = try? JSONEncoder().encode(r), (try? d.write(to: URL(fileURLWithPath: req + ".tmp"))) != nil,
              rename(req + ".tmp", req) == 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let out = try? String(contentsOfFile: done, encoding: .utf8) { unlink(done); return out }
            usleep(200_000)
        }
        unlink(req)
        return nil
    }

    /// App side: types every waiting request into its recipients' terminals and leaves the outcome for the CLI.
    static func deliverSpool(_ sessions: [AgentSession]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: spool) else { return }
        for name in names where name.hasSuffix(".json") {
            let path = spool + "/" + name
            guard let d = fm.contents(atPath: path), let r = try? JSONDecoder().decode(Request.self, from: d) else { continue }
            unlink(path)
            let out = deliver(r, sessions: sessions, only: r.pending).out
            try? out.write(toFile: spool + "/" + name.replacingOccurrences(of: ".json", with: ".done"), atomically: true, encoding: .utf8)
        }
    }

    /// Types the message into each recipient in `only` (default: all) and logs it; returns what the CLI prints
    /// and who could not be reached.
    @discardableResult
    static func deliver(_ r: Request, sessions: [AgentSession], only: [Agent]? = nil) -> (out: String, failed: [Agent]) {
        let targets = only ?? r.to
        var failed: [Agent] = []
        for a in targets {
            guard let s = sessions.first(where: { $0.id == a.id }),
                  SessionInput.send(s, text: compose(from: r.from, to: r.to, recipient: a, text: r.text, exe: r.exe))
            else { failed.append(a); continue }
        }
        // The log may be unwritable from a sandbox; the app logs what it relays.
        if failed.count < targets.count {
            let sent = targets.filter { a in !failed.contains { $0.id == a.id } }
            log(Entry(at: Date(), from: r.from.id, fromName: r.from.name, to: sent.map(\.id), toNames: sent.map(\.name), text: r.text))
        }
        return (failed.isEmpty ? "보냄 → \(targets.map(\.name).joined(separator: ", "))"
                : "보내지 못함: \(failed.map(\.name).joined(separator: ", ")) (터미널 입력을 받을 수 없는 세션)", failed)
    }

    // MARK: roster

    static func writeRoster(_ agents: [Agent]) {
        guard let d = try? JSONEncoder().encode(agents), d != FileManager.default.contents(atPath: rosterPath) else { return }
        try? d.write(to: URL(fileURLWithPath: rosterPath))
    }

    static func roster() -> [Agent] {
        guard let d = FileManager.default.contents(atPath: rosterPath) else { return [] }
        return (try? JSONDecoder().decode([Agent].self, from: d)) ?? []
    }

    /// The agent whose process runs this one: walk up from our parent until a listed agent's pid.
    static func sender(in agents: [Agent]) -> Agent? {
        let byPid = Dictionary(agents.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var p = getppid()
        for _ in 0..<32 where p > 1 {
            if let a = byPid[p] { return a }
            p = SessionTree.parentPid(p)
        }
        return nil
    }

    /// "레오", "레오,바람" or session ids; names as the app shows them.
    static func resolve(_ list: String, in agents: [Agent]) -> (found: [Agent], missing: [String]) {
        var found: [Agent] = [], missing: [String] = []
        for key in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !key.isEmpty {
            if let a = agents.first(where: { $0.name == key || $0.id == key }) { found.append(a) } else { missing.append(key) }
        }
        return (found, missing)
    }
}
