import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Offscreen checks that never touch the user's screen.
@MainActor
enum Snapshot {
    static func loadedStorePublic() -> SessionStore { loadedStore() }

    static func mail(_ args: [String]) {
        // The running app rewrites the roster on every refresh; only without it does the CLI read sessions itself.
        let fresh = ((try? FileManager.default.attributesOfItem(atPath: AgentMail.rosterPath)[.modificationDate]) as? Date)
            .map { -$0.timeIntervalSinceNow < 120 } ?? false
        let agents = fresh ? AgentMail.roster().filter { a in a.pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false }  // EPERM: alive, but a sandbox (Codex) may not signal it
            : loadedStore().mailRoster()
        let me = AgentMail.sender(in: agents)
        if args.contains("--agents") {
            for a in agents {
                print(a.name, a.agent, a.activity, a.id, (a.cwd as NSString).lastPathComponent,
                      a.id == me?.id ? "(나)" : "", separator: "\t")
            }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--msg"), i + 2 < args.count else {
            print("usage: AgentDeck --msg <이름>[,<이름>…] \"본문\""); exit(2)
        }
        let (to, missing) = AgentMail.resolve(args[i + 1], in: agents.filter { $0.id != me?.id })
        guard missing.isEmpty, !to.isEmpty else {
            print("모르는 이름: \(missing.joined(separator: ", ")) — 보낼 수 있는 에이전트: \(agents.map(\.name).joined(separator: ", "))"); exit(1)
        }
        let from = me ?? AgentMail.Agent(id: "user", name: "사용자", agent: "user", pid: nil, cwd: "", activity: "")
        let request = AgentMail.Request(from: from, to: to, text: args[i + 2], exe: Bundle.main.executablePath ?? args[0])
        // Typing needs only the pid: SessionInput finds the hosting terminal from the process environment.
        let sessions = to.map { a in
            AgentSession(id: a.id, agent: Agent(rawValue: a.agent) ?? .claude, name: a.name, cwd: a.cwd, status: .unknown,
                         startedAt: nil, updatedAt: nil, lastUser: nil, lastAssistant: nil, estimated: false, pid: a.pid)
        }
        // Typed directly when this process may reach the terminals; from a sandbox (Codex) the tmux socket is off limits,
        // so whoever failed goes through the running app.
        var (out, failed) = AgentMail.deliver(request, sessions: sessions)
        if !failed.isEmpty, fresh {
            var relay = request
            relay.pending = failed
            out = AgentMail.spoolAndWait(relay) ?? "보내지 못함: 수혁 앱이 응답하지 않음"
            if out.hasPrefix("보냄"), failed.count < to.count { out = "보냄 → \(to.map(\.name).joined(separator: ", "))" }
        }
        print(out)
        exit(out.hasPrefix("보냄") ? 0 : 1)
    }

    private static func loadedStore() -> SessionStore {
        let store = SessionStore()
        // Let the first background refresh land.
        let deadline = Date().addingTimeInterval(30)
        while store.sessions.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return store
    }

    static func run(path: String, select: String?) {
        let store = loadedStore()
        let view = WorldView(store: store, initialSelection: select ?? store.sessions.first?.id)
            .frame(width: 1400, height: 820).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    static func ledgerRegister(code: String) {
        let sync = CrystalBank.shared.sync
        Task {
            do {
                try await sync.register(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                print("registered")
                exit(0)
            } catch {
                print("FAILED", CrystalBank.describe(error)); exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func marketUpload(folder: String, price: Int, descriptionFile: String, alias: String) {
        let bank = CrystalBank.shared
        guard let market = bank.market, bank.canTrade else {
            print("market unavailable: turn on server sync and register this Mac first"); exit(1)
        }
        guard let description = try? String(contentsOfFile: descriptionFile, encoding: .utf8) else {
            print("cannot read \(descriptionFile)"); exit(1)
        }
        Task {
            do {
                let id = try await market.upload(folder: URL(fileURLWithPath: folder), price: price, alias: alias,
                                                 description: description.trimmingCharacters(in: .whitespacesAndNewlines)) { done, total in
                    print("uploaded \(done)/\(total)")
                }
                let status = (try? await market.mine())?.listings.first { $0.id == id }?.status ?? "?"
                print("listing \(id) \(status)")
                exit(0)
            } catch {
                print("FAILED", CrystalBank.describe(error)); exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func dialogueAudit() {
        let store = loadedStore()
        let until = Date().addingTimeInterval(40)
        while store.sessions.isEmpty, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        for s in store.sessions {
            let t0 = Date()
            let items = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) } ?? []
            let size = s.transcriptPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? -1
            let roles = Dictionary(grouping: items, by: { "\($0.role)" }).mapValues(\.count)
            print(String(format: "%-14@ %-8@ %5.2fs %6dKB items=%4d %@ path=%@", s.id as NSString, store.agentName(for: s) as NSString,
                         Date().timeIntervalSince(t0), size / 1024, items.count, "\(roles)" as NSString,
                         (s.transcriptPath.map { ($0 as NSString).lastPathComponent } ?? "NONE") as NSString))
        }
        exit(0)
    }

    static func sidebar(path: String) {
        let store = loadedStore()
        let until = Date().addingTimeInterval(40)
        while store.sessions.isEmpty, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(store.sessions.filter { $0.parentId == nil }.prefix(12)) { s in
                SessionRow(title: s.name, subtitle: s.agent.rawValue + " · " + s.project, session: s, store: store)
                ForEach(store.children(of: s)) { c in ChildSessionRow(session: c, store: store) }
            }
        }
        .padding(14).frame(width: 300, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: host.fittingSize),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    static func world(path: String, wait: Double) {
        let store = loadedStore()
        let host = NSHostingView(rootView: WorldView(store: store).frame(width: 1400, height: 820))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1400, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        if ProcessInfo.processInfo.environment["SUHYEOK_DEBUG"] != nil {
            FileHandle.standardError.write("snapshot at \(Date().timeIntervalSinceReferenceDate)\n".data(using: .utf8)!)
        }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    static func traceWalk(seconds: Double) {
        let store = loadedStore()
        var last: TimeInterval = 0
        let start = Date().timeIntervalSinceReferenceDate
        Walker.trace = { pos, facing, now in
            guard now - last >= 0.5 else { return }
            last = now
            let row = pos.keys.sorted().map { id in
                let p = pos[id]!
                return "\(id.suffix(5)):\(String(format: "%.3f,%.3f", p.x, p.y)):\(facing[id]?.rawValue.prefix(1) ?? "-")"
            }
            print(String(format: "%5.1f ", now - start) + row.joined(separator: " "))
        }
        let host = NSHostingView(rootView: WorldView(store: store).frame(width: 1400, height: 820))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1400, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        exit(0)
    }

    static func reopenPermissions() {
        let store = loadedStore()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            for r in await store.reopenForPermissionSetting() { print(r.ok ? "ok  " : "skip", r.name, "—", r.message) }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(0)
    }

    static func bosses(path: String) {
        let cell = CGSize(width: 230, height: 230)
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(Hunt.Tier.allCases, id: \.self) { tier in
                // Time at 60% into each step of the script (minus the per-tier offset in BossPattern.state).
                let steps = BossPattern.script(tier)
                let starts = steps.indices.map { i in steps[..<i].reduce(0) { $0 + $1.length } }
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                        let t = 300 * steps.reduce(0) { $0 + $1.length } + starts[i] + st.length * 0.6 - Double(tier.rawValue) * 3.7
                        ZStack(alignment: .topLeading) {
                            Color(red: 0.25, green: 0.2, blue: 0.15)
                            BossView(tier: tier, time: t, size: CGSize(width: 80, height: 90), attackers: [],
                                     center: CGPoint(x: cell.width / 2, y: cell.height * 0.55))
                            Text("\(st.move)").font(.caption.bold()).foregroundStyle(.white).padding(4)
                        }
                        .frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
        .padding(8).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    /// Memory growth check for per-frame effects: SF Symbols drawn at a new point size every frame used to pile up in the glyph cache.
    static func benchEffects(frames: Int) {
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return Double(info.phys_footprint) / 1_048_576
        }
        let cell = CGSize(width: 400, height: 300)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame.size = cell
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: cell),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        let start = Date()
        print(String(format: "start footprint=%.0fMB", footprintMB()))
        for f in 0..<frames {
            let t = Double(f) * 0.1
            let zoom = 1 + Double(f % 37) / 50  // pinch zoom changes the drawn size too
            host.rootView = AnyView(ZStack(alignment: .topLeading) {
                ForEach(Hunt.Tier.allCases, id: \.self) { tier in
                    BossView(tier: tier, time: t, size: CGSize(width: 80 * zoom, height: 90 * zoom), attackers: [],
                             center: CGPoint(x: 70 + Double(tier.rawValue) * 130, y: 160))
                }
                DepartureView(departure: Departure(id: "bench", character: nil, point: .zero, start: 0),
                              time: (t.truncatingRemainder(dividingBy: 1.5)), height: 60 * zoom)
                    .position(x: 200, y: 250)
            }.frame(width: cell.width, height: cell.height))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (f + 1) % max(1, frames / 4) == 0 { print(String(format: "frame %d footprint=%.0fMB", f + 1, footprintMB())) }
        }
        print(String(format: "%d frames in %.1fs", frames, Date().timeIntervalSince(start)))
        if let s = ProcessInfo.processInfo.environment["BENCH_HOLD"].flatMap(Double.init) { Thread.sleep(forTimeInterval: s) }
        exit(0)
    }

    static func poses(character id: String, path: String) {
        guard let c = Art.roster.first(where: { $0.id == id }) else { print("unknown character"); exit(1) }
        func session(_ status: SessionStatus) -> AgentSession {
            AgentSession(id: "pose", agent: .claude, name: "pose", cwd: "/tmp", status: status, startedAt: Date(),
                         updatedAt: Date(), lastUser: nil, lastAssistant: nil, estimated: false)
        }
        // Attack frames at 0.0/0.2/0.45/0.55/0.75 s show ready, wind-up, strike, impact, follow-through.
        let cases: [(String, Bool, Facing, Avatar.Pose, Double)] = [
            ("↓ 걷기", true, .down, .camp, 0.0), ("← 걷기", true, .left, .camp, 0.13), ("→ 걷기", true, .right, .camp, 0.26),
            ("↑ 걷기", true, .up, .camp, 0.39), ("공격 준비", false, .down, .attack(faceRight: false), 0.0),
            ("공격 ①", false, .down, .attack(faceRight: false), 0.25), ("공격 ②", false, .down, .attack(faceRight: false), 0.45),
            ("공격 ③", false, .down, .attack(faceRight: false), 0.55), ("공격 ④", false, .down, .attack(faceRight: false), 0.75),
            ("→ 공격", false, .down, .attack(faceRight: true), 0.55),
        ]
        let view = HStack(alignment: .bottom, spacing: 24) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, k in
                VStack {
                    Avatar(session: session(.busy), character: c, pose: k.3, agentName: k.0, time: 120 + k.4 - Double(abs("pose".hashValue % 100)) / 15,
                           height: 110, selected: false, walking: k.1, facing: k.2)
                }
            }
        }
        .padding(30).background(Color(red: 0.45, green: 0.3, blue: 0.18))
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    static func hosted(name: String, path: String) {
        let term = TerminalHost.shared.view(for: name)
        // Never ordered front: the window exists only so the view gets a backing store.
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = term
        term.frame = window.contentView!.bounds
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        if let rep = term.bitmapImageRepForCachingDisplay(in: term.bounds) {
            term.cacheDisplay(in: term.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        TerminalHost.shared.drop(name)
        exit(0)
    }

    /// A window that is never shown, so `view` lays out and draws for `writePNG` without appearing on screen.
    static func offscreen(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return window
    }

    /// Takes the window, not the view, so it stays alive until the picture is taken.
    static func writePNG(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func session(flag: String, id: String, arg: String?) {
        let store = loadedStore()
        guard let s = store.sessions.first(where: { $0.id == id }) else {
            print("no session \(id); live: \(store.sessions.map(\.id).joined(separator: " "))"); exit(1)
        }
        switch flag {
        case "--send":
            print(SessionInput.send(s, text: arg ?? "") ? "sent" : "FAILED")
        case "--press":
            let key = SessionInput.Key.allCases.first { $0.tmux.lowercased() == arg?.lowercased() }
            print(key.map { SessionInput.press(s, $0) ? "pressed" : "FAILED" } ?? "unknown key")
        case "--menu", "--choose":
            guard let pid = s.pid, case .text(let screen, _) = TerminalSource.read(pid: pid, lines: 40),
                  let menu = TerminalMenu.parse(screen) else { print("no menu"); break }
            for (i, o) in menu.options.enumerated() { print(i == menu.selected ? "❯" : " ", i, o.label, o.detail ?? "") }
            if flag == "--choose", let n = arg.flatMap(Int.init) {
                print(SessionInput.choose(s, menu: menu, index: n) ? "chose \(n)" : "FAILED")
            }
        case "--live":
            // Print the live reply parse twice a second for N seconds.
            let secs = arg.flatMap(Double.init) ?? 20
            let end = Date().addingTimeInterval(secs)
            var last = ""
            while Date() < end {
                if let pid = s.pid, case .text(let t, _) = TerminalSource.read(pid: pid, lines: 60) {
                    let logged = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) }?.last { $0.role == .agent }?.text
                    let l = LiveReply.parse(t, alreadyLogged: logged)
                    let line = "status=\(l?.status ?? "-") text=\(l.map { String($0.text.suffix(60)) } ?? "-")"
                    if line != last { print(String(format: "%.1f", secs - end.timeIntervalSinceNow), line.replacingOccurrences(of: "\n", with: "⏎")); last = line }
                }
                usleep(500_000)
            }
        case "--hunt":
            let t0 = Date()
            let p = s.transcriptPath.map { HuntClock.progress(path: $0) } ?? Hunt.Progress()
            let run = p.run().map { String(format: "%.1fh", $0 / 3600) } ?? "resting"
            print("run \(run) tier \(p.tier()?.label ?? "대기소") active \(Int(p.activeSeconds / 60))m crystals \(p.crystals) (\(String(format: "%.2f", Date().timeIntervalSince(t0)))s)")
        case "--clone":
            store.clone(s)
            let deadline = Date().addingTimeInterval(5)
            let before = Set(TmuxEngine.list().map(\.name))
            while Date() < deadline, Set(TmuxEngine.list().map(\.name)).subtracting(before).isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            print("clones:", TmuxEngine.list().filter { $0.title.hasSuffix(String(localized: " (클론)")) }.map(\.name))
        case "--summary":
            store.setSummary(arg ?? "", for: s)
            print("summary:", store.summary(for: s) ?? "(cleared)")
        case "--end":
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                print(await store.end(s) ?? "ended")
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        case "--migrate":
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                for r in await store.migrate([s], closeOriginal: true) { print(r.ok ? "ok" : "FAILED", r.name, "—", r.message) }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        case "--clear":
            // arg = out path: the dialogue drawn while /clear is still on its way (the spinner over the old log).
            let host = NSHostingView(rootView: DialogueView(store: store, sessionId: s.id, onClose: {}, onTerminal: {})
                .frame(width: 1100, height: 640))
            let window = offscreen(host, size: CGSize(width: 1100, height: 640))
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let t0 = Date(), done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let ok = await store.startOver(s)
                let now = store.sessions.first { $0.id == s.id }?.conversationId ?? "-"
                print(ok ? "sent" : "FAILED", s.conversationId ?? "-", "→", now, String(format: "%.1fs", Date().timeIntervalSince(t0)))
                done.signal()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let arg { writePNG(window, to: arg) }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        case "--snapshot-world-dialogue":
            // arg = out path; the panel size comes from the dialogueLarge default.
            let host = NSHostingView(rootView: WorldView(store: store, initialSelection: nil, initialDialogue: s.id)
                .frame(width: 1400, height: 820))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1400, height: 820),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg ?? "world.png"))
            }
        case "--snapshot-dialogue":
            let items = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) } ?? []
            // A real (never shown) window, so scroll views and text fields draw like in the app.
            let host = NSHostingView(rootView: DialogueView(store: store, sessionId: s.id, onClose: {}, onTerminal: {}, preload: items)
                .frame(width: 1100, height: 640))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1100, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            // SUHYEOK_TEST_PASTEBOARD=<name>: press ⌘V in the input twice — a long text, then an image — from that pasteboard.
            if let name = ProcessInfo.processInfo.environment["SUHYEOK_TEST_PASTEBOARD"] {
                func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
                let pb = NSPasteboard(name: .init(name))
                if let field = fields(host).first(where: \.isEditable) {
                    window.makeFirstResponder(field)
                    let long = (1...40).map { "line \($0) of a long pasted log" }.joined(separator: "\n")
                    let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
                    for content in [long as NSPasteboardWriting, img] {
                        pb.clearContents(); pb.writeObjects([content])
                        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "v",
                                                 charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
                        NSApp.sendEvent(e)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    }
                    print("field:", field.stringValue)
                    pb.releaseGlobally()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
            // SUHYEOK_TEST_DROP=<file>: list views that accept drops, then drop that file on the middle of the dialogue.
            if let file = ProcessInfo.processInfo.environment["SUHYEOK_TEST_DROP"] {
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                for v in all(host) where !v.registeredDraggedTypes.isEmpty {
                    print("drop view:", type(of: v), v.frame, v.registeredDraggedTypes.map(\.rawValue).prefix(6))
                }
                let pb = NSPasteboard(name: .init("suhyeok-test-drop"))
                pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: file) as NSURL])
                func editable(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(editable) }
                var point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
                // SUHYEOK_TEST_DROP_AT=field: focus the input (as when the dialogue opens) and drop right on it.
                if ProcessInfo.processInfo.environment["SUHYEOK_TEST_DROP_AT"] == "field", let f = editable(host).first(where: \.isEditable) {
                    window.makeFirstResponder(f)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    let r = f.convert(f.bounds, to: nil)
                    point = NSPoint(x: r.midX, y: r.midY)
                    for v in all(host) where !v.registeredDraggedTypes.isEmpty {
                        print("after focus:", type(of: v), v.convert(v.bounds, to: nil), v.registeredDraggedTypes.count)
                    }
                }
                let drag = TestDrag(pasteboard: pb, location: point, window: window)
                if let target = all(host).last(where: { !$0.registeredDraggedTypes.isEmpty && $0.convert($0.bounds, to: nil).contains(point) }) {
                    print("target:", type(of: target))
                    print("entered:", target.draggingEntered(drag), "updated:", target.draggingUpdated(drag))
                    print("perform:", target.performDragOperation(drag))
                } else { print("no drop target under", point) }
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
                print("field:", fields(host).first(where: \.isEditable)?.stringValue ?? "-")
                pb.releaseGlobally()
            }
            // SUHYEOK_SNAPSHOT_SCROLL=top: scroll the conversation up first (shows the "맨 아래로" button).
            if ProcessInfo.processInfo.environment["SUHYEOK_SNAPSHOT_SCROLL"] == "top" {
                func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
                if let chat = scrollViews(host).max(by: { $0.frame.height < $1.frame.height }) {
                    chat.contentView.scroll(to: .zero)
                    chat.reflectScrolledClipView(chat.contentView)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(1))
            }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg ?? "dialogue.png"))
            }
        default: break
        }
        exit(0)
    }

    static func terminal(id: String, transcript: Bool) {
        let store = loadedStore()
        guard let s = store.sessions.first(where: { $0.id == id }) else {
            print("no session \(id); live: \(store.sessions.map(\.id).joined(separator: " "))")
            exit(1)
        }
        let (text, source) = TerminalPanel.load(s, transcript ? .transcript : .auto)
        print("[source] \(source) [hosted] \(s.hostedName ?? "-")")
        print(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n"))
        exit(0)
    }
}


/// A drag that never happened on screen, for checking drop handling offscreen.
final class TestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingLocation = location; draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
