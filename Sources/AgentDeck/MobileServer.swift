import CryptoKit
import Foundation
import Network

/// Small HTTP server for the phone page. Listens on 127.0.0.1 only; the outside world reaches it through
/// a Cloudflare quick tunnel (MobileTunnel). Every API call needs a session token obtained by pairing with
/// the 6-digit code shown on the Mac, because these endpoints can type into agent terminals.
@MainActor
final class MobileServer: ObservableObject {
    static let shared = MobileServer()
    static let port: UInt16 = 4380

    @Published private(set) var running = false
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairedDevices = 0

    private var listener: NWListener?
    private weak var store: SessionStore?
    private var codeIssued = Date.distantPast
    private var failedPairs: [Date] = []
    /// Hashes of issued session tokens (the tokens themselves only live on the phones).
    private var tokens: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mobileTokens") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mobileTokens"); pairedDevices = newValue.count }
    }

    func start(store: SessionStore) {
        guard listener == nil else { return }
        self.store = store
        pairedDevices = tokens.count
        newCode()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.serve(c) } }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in self?.running = { if case .ready = st { return true } else { return false } }() }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    func newCode() {
        pairingCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        codeIssued = Date()
    }

    func forgetDevices() { tokens = [] }

    // MARK: HTTP

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    let (status, type, body, extra) = await self.route(req)
                    self.respond(c, status: status, type: type, body: body, headers: extra)
                } else if done || err != nil || buf.count > 1 << 20 {
                    c.cancel()
                } else {
                    self.receive(c, buffer: buf)
                }
            }
        }
    }

    private static func parse(_ d: Data) -> Request? {
        guard let headEnd = d.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: d[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[headEnd.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(first[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for kv in target[target.index(after: q)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if p.count == 2 { query[p[0]] = p[1] }
            }
        }
        return Request(method: String(first[0]), path: path, query: query, headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ c: NWConnection, status: Int, type: String, body: Data, headers: [String: String]) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func json(_ o: Any, _ status: Int = 200) -> (Int, String, Data, [String: String]) {
        (status, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), [:])
    }

    private static func hash(_ t: String) -> String { SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func authorized(_ r: Request) -> Bool {
        // Local screenshot checks only (`--serve-mobile` with SUHYEOK_MOBILE_NOAUTH); the app itself never sets it.
        if ProcessInfo.processInfo.environment["SUHYEOK_MOBILE_NOAUTH"] != nil,
           CommandLine.arguments.contains("--serve-mobile") { return true }
        let cookie = r.headers["cookie"] ?? ""
        guard let t = cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("sh=") })?.dropFirst(3) else { return false }
        return tokens.contains(Self.hash(String(t)))
    }

    private func route(_ r: Request) async -> (Int, String, Data, [String: String]) {
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return (200, "text/html; charset=utf-8", Data(MobilePage.html.utf8), [:])
        case ("POST", "/pair"):
            return pair(r)
        default: break
        }
        // Static art does not need auth (it is the same art shipped in the public app).
        if r.method == "GET", r.path.hasPrefix("/art/"), let data = asset(String(r.path.dropFirst(5))) {
            return (200, r.path.hasSuffix(".png") ? "image/png" : "image/jpeg", data, ["Cache-Control": "max-age=86400"])
        }
        guard authorized(r) else { return json(["error": "pair"], 401) }
        guard let store else { return json(["error": "starting"], 503) }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        func session(_ id: String?) -> AgentSession? { store.sessions.first { $0.id == id } }
        switch (r.method, r.path) {
        case ("GET", "/api/state"):
            return json(state(store))
        case ("GET", "/api/chat"):
            guard let s = session(r.query["id"]) else { return json(["error": "gone"], 404) }
            return json(await Self.chat(s))
        case ("POST", "/api/send"):
            guard let s = session(body["id"] as? String), let text = body["text"] as? String, !text.isEmpty else { return json(["ok": false], 400) }
            let ok = await Task.detached { SessionInput.send(s, text: text) }.value
            return json(["ok": ok])
        case ("POST", "/api/choose"):
            guard let s = session(body["id"] as? String), let i = body["index"] as? Int else { return json(["ok": false], 400) }
            let ok = await Task.detached { () -> Bool in
                guard let pid = s.pid, case .text(let t, _) = TerminalSource.read(pid: pid, lines: 60),
                      let menu = TerminalMenu.parse(t), menu.options.indices.contains(i) else { return false }
                return SessionInput.choose(s, menu: menu, index: i)
            }.value
            return json(["ok": ok])
        case ("POST", "/api/key"):
            guard let s = session(body["id"] as? String), let k = body["key"] as? String,
                  let key = SessionInput.Key.allCases.first(where: { $0.tmux.lowercased() == k.lowercased() }) else { return json(["ok": false], 400) }
            let ok = await Task.detached { SessionInput.press(s, key) }.value
            return json(["ok": ok])
        default:
            return json(["error": "not found"], 404)
        }
    }

    /// Code is valid for 10 minutes, one use; after 5 wrong tries in 10 minutes pairing locks for the rest of it.
    private func pair(_ r: Request) -> (Int, String, Data, [String: String]) {
        failedPairs.removeAll { Date().timeIntervalSince($0) > 600 }
        guard failedPairs.count < 5 else { return json(["error": "잠시 후 다시 시도 (10분)"], 429) }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        guard let code = body["code"] as? String, code == pairingCode, Date().timeIntervalSince(codeIssued) < 600 else {
            failedPairs.append(Date())
            return json(["error": "코드가 맞지 않거나 만료됨 — Mac의 수혁 설정에서 새 코드를 확인"], 403)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokens.insert(Self.hash(token))
        newCode()  // single use
        let cookie = "sh=\(token); Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Strict"
        let (s, t, d, _) = json(["ok": true])
        return (s, t, d, ["Set-Cookie": cookie])
    }

    private func asset(_ path: String) -> Data? {
        guard !path.contains(".."), let dir = Art.dir else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(path))
    }

    private func state(_ store: SessionStore) -> [String: Any] {
        let agents: [[String: Any]] = store.placements().map { p in
            let s = p.session
            return [
                "id": s.id, "name": store.agentName(for: s), "title": s.name, "project": s.project,
                "agent": s.agent.rawValue, "status": s.status.rawValue, "activity": s.activity.label,
                "character": store.character(for: s)?.id ?? "", "x": p.point.x, "y": p.point.y,
                "tier": p.tier.map { World.key($0) } ?? NSNull(), "hunt": store.huntLine(for: s),
                "action": s.action?.detail ?? "", "last": store.lastActivity(for: s)?.timeIntervalSince1970 ?? 0,
                "canSend": SessionInput.canSend(s),
            ]
        }
        let bosses: [[String: Any]] = Hunt.Tier.allCases.map { t in
            let r = World.boss(t)
            return ["key": World.key(t), "name": t.boss, "x": r.midX, "y": r.midY, "w": r.width, "h": r.height]
        }
        return ["agents": agents, "bosses": bosses, "crystals": store.totalCrystals,
                "world": ["w": World.size.width, "h": World.size.height], "avatar": World.avatarHeight]
    }

    nonisolated private static func chat(_ s: AgentSession) async -> [String: Any] {
        await Task.detached { () -> [String: Any] in
            let items = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) } ?? []
            var out: [String: Any] = [
                "items": items.suffix(80).filter { $0.role != .result }.map { ["role": "\($0.role)", "text": $0.text] },
            ]
            if let pid = s.pid, case .text(let t, _) = TerminalSource.read(pid: pid, lines: 60) {
                if let m = TerminalMenu.parse(t) {
                    out["menu"] = m.options.map { ["label": $0.label, "detail": $0.detail ?? ""] }
                } else if s.status == .busy {
                    out["live"] = LiveReply.turn(t)
                }
            }
            return out
        }.value
    }
}

/// Runs `cloudflared tunnel --url` for a public https URL that forwards to the local server.
@MainActor
final class MobileTunnel: ObservableObject {
    static let shared = MobileTunnel()
    @Published private(set) var url: String?
    @Published private(set) var error: String?
    private var process: Process?

    static var cloudflared: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard process == nil else { return }
        guard let bin = Self.cloudflared else { error = "cloudflared 없음 — 터미널에서 brew install cloudflared"; return }
        error = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // An empty config of our own: a user's ~/.cloudflared/config.yml (named tunnels, catch-all 404 ingress)
        // would otherwise be applied to this quick tunnel and answer every request with 404.
        let conf = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Suhyeok/cloudflared.yml")
        try? FileManager.default.createDirectory(at: conf.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: conf.path) { try? "# quick tunnel for 수혁 mobile\n".write(to: conf, atomically: true, encoding: .utf8) }
        p.arguments = ["tunnel", "--config", conf.path, "--no-autoupdate", "--url", "http://127.0.0.1:\(MobileServer.port)"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            if let r = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                let u = String(text[r])
                Task { @MainActor in MobileTunnel.shared.url = u }
            }
        }
        p.terminationHandler = { _ in Task { @MainActor in MobileTunnel.shared.process = nil; MobileTunnel.shared.url = nil } }
        do { try p.run(); process = p } catch { self.error = "터널을 시작하지 못함: \(error.localizedDescription)" }
    }

    func stop() {
        process?.terminate()
        process = nil
        url = nil
    }
}
