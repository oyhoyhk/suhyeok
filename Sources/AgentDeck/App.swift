import AppKit
import AVFoundation
import Speech
import SwiftUI

@main
struct AgentDeckApp: App {
    @StateObject private var store = SessionStore()

    init() {
        // `AgentDeck --snapshot out.png [selectedSessionId]` renders the world offscreen and exits (for checks without touching the screen).
        let args = CommandLine.arguments
        // `AgentDeck --voice-check`: speech recognizer availability and TTS synthesis into memory (no sound).
        if args.contains("--voice-check") {
            let r = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
            print("stt ko-KR available=\(r?.isAvailable ?? false) onDevice=\(r?.supportsOnDeviceRecognition ?? false) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
            for id in ["knight", "fox", "mage"] {
                let (v, pitch) = Speaker.voice(for: id)
                print("voice", id, v?.name ?? "-", "quality=\(v?.quality.rawValue ?? 0)", "pitch=\(pitch)")
            }
            // Spoken summary from the on-device model, if available (2nd arg: a reply file to summarize).
            if let i = args.firstIndex(of: "--voice-check"), i + 1 < args.count,
               let reply = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
                var summary: String?? = .none
                Task { summary = .some(await SpokenSummary.make(Speaker.plain(reply))) }
                while summary == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                print("summary:", (summary ?? nil) ?? "(model unavailable)")
            }
            // Supertonic F1: `--voice-check --install` downloads the model first if it is missing.
            if args.contains("--install"), !NeuralVoice.shared.installed {
                var done = false
                Task.detached { do { try await NeuralVoice.shared.install(); print("supertonic installed") } catch { print("supertonic install failed:", error) }; done = true }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            }
            if NeuralVoice.shared.installed {
                var wav: Data?? = .none
                let started = Date()
                Task.detached { wav = .some(await NeuralVoice.shared.wav("작업을 마쳤습니다. 결과는 정상입니다.")) }
                while wav == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                print("supertonic F1 wav bytes=\((wav ?? nil)?.count ?? 0) secs=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
                let out = NSTemporaryDirectory() + "suhyeok-voice-check.wav"
                try? (wav ?? nil)?.write(to: URL(fileURLWithPath: out))
                print("supertonic sample:", out)
            } else {
                print("supertonic F1 not installed (\(NeuralVoice.dir))")
            }
            let synth = AVSpeechSynthesizer()
            var frames = 0
            let done = DispatchSemaphore(value: 0)
            let u = AVSpeechUtterance(string: Speaker.plain("**작업을 마쳤습니다.** `build.sh`를 실행했고\n```\nok\n```\n결과는 정상입니다."))
            u.voice = Speaker.voice(for: "fox").0
            print("spoken text:", u.speechString.replacingOccurrences(of: "\n", with: " / "))
            synth.write(u) { buf in
                if let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 { frames += Int(pcm.frameLength) } else { done.signal() }
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print("tts frames", frames)
            exit(0)
        }
        // `AgentDeck --snapshot-markdown <file.md> out.png`: render a reply through the markdown viewer offscreen.
        if let i = args.firstIndex(of: "--snapshot-markdown"), i + 2 < args.count,
           let md = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            let host = NSHostingView(rootView: MarkdownView(text: md).padding(14).frame(width: 760)
                .background(Color(red: 0.07, green: 0.10, blue: 0.22)).environment(\.colorScheme, .dark))
            host.frame.size = CGSize(width: 760, height: 1600)
            let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 760, height: 1600), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            host.frame.size = host.fittingSize
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
            }
            exit(0)
        }
        // `open 수혁.app --args --dictate-test <log>`: run dictation for 8 s inside the real app (permission prompts
        // included) and log every step to the file.
        if let i = args.firstIndex(of: "--dictate-test"), i + 1 < args.count {
            UserDefaults.standard.set(args[i + 1], forKey: "dictationLog")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let d = Dictation()
                d.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    Dictation.log("result text=\(d.text) error=\(d.error ?? "-")")
                    d.stop()
                    UserDefaults.standard.removeObject(forKey: "dictationLog")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
        }
        // `AgentDeck --dialogue-audit`: per live session, how many chat items the dialogue would show and how long it took.
        if args.contains("--dialogue-audit") { Snapshot.dialogueAudit() }
        // `AgentDeck --snapshot-sidebar out.png`: the sidebar's session rows, offscreen.
        if let i = args.firstIndex(of: "--snapshot-sidebar"), i + 1 < args.count {
            Snapshot.sidebar(path: args[i + 1])
        }
        // `AgentDeck --snapshot-world out.png [seconds]` renders the live world (walking included) offscreen.
        if let i = args.firstIndex(of: "--snapshot-world"), i + 1 < args.count {
            Snapshot.world(path: args[i + 1], wait: args.dropFirst(i + 2).first.flatMap(Double.init) ?? 3)
        }
        // `AgentDeck --trace-walk <seconds>` runs the world offscreen and logs positions/facing twice a second.
        if let i = args.firstIndex(of: "--trace-walk"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            Snapshot.traceWalk(seconds: secs)
        }
        // `AgentDeck --snapshot-bosses out.png`: every move of each boss's script, side by side.
        if let i = args.firstIndex(of: "--snapshot-bosses"), i + 1 < args.count {
            Snapshot.bosses(path: args[i + 1])
        }
        // `AgentDeck --bench-recent` times the recent-conversation scan (cold, then warm).
        if args.contains("--bench-recent") {
            for run in 1...3 {
                let t = Date()
                let n = RecentSource.load(excluding: []).count
                print(String(format: "run %d: %d conversations in %.0f ms", run, n, Date().timeIntervalSince(t) * 1000))
            }
            exit(0)
        }
        // `AgentDeck --bench-effects <frames>` renders boss and farewell effects offscreen and prints the memory footprint.
        if let i = args.firstIndex(of: "--bench-effects"), i + 1 < args.count, let n = Int(args[i + 1]) {
            Snapshot.benchEffects(frames: n)
        }
        // `AgentDeck --snapshot-poses <characterId> out.png` renders one character's walk/work frames.
        if let i = args.firstIndex(of: "--snapshot-poses"), i + 2 < args.count {
            Snapshot.poses(character: args[i + 1], path: args[i + 2])
        }
        // `AgentDeck --snapshot-hosted <name> out.png` renders the embedded terminal offscreen.
        if let i = args.firstIndex(of: "--snapshot-hosted"), i + 2 < args.count {
            Snapshot.hosted(name: args[i + 1], path: args[i + 2])
        }
        // `AgentDeck --agents`: live agents by the names the app shows (who can be messaged).
        // `AgentDeck --msg <이름>[,<이름>…] "본문"`: types a message into those agents' terminals, signed by the caller.
        if args.contains("--agents") || args.contains("--msg") { Snapshot.mail(args) }
        // `AgentDeck --usage` prints each live session's model, context and rate limits (the dialogue's status line).
        if args.contains("--usage") {
            if let i = args.firstIndex(of: "--usage"), i + 1 < args.count {  // a Codex rollout path
                print(UsageInfo.codex(args[i + 1]).map { String(describing: $0) } ?? "-"); exit(0)
            }
            for s in Snapshot.loadedStorePublic().sessions {
                print(s.agent.rawValue, s.id, "pid=" + (s.pid.map { String($0) } ?? "-"), "parent=" + (s.parentId ?? "-"), UsageInfo.load(s).map { String(describing: $0) } ?? "-")
            }
            exit(0)
        }
        // `AgentDeck --check-update` prints installed vs latest release.
        if args.contains("--check-update") {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let latest = await Updater.latestVersion() ?? "?"
                print("installed \(current) latest \(latest) newer=\(Updater.isNewer(latest, than: current))")
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        // `AgentDeck --ledger`: crystal ledger check (read only). `--snapshot-guild out.png`: the guild page offscreen.
        if args.contains("--ledger") { CrystalBank.report(); exit(0) }
        if let i = args.firstIndex(of: "--snapshot-guild"), i + 1 < args.count { CrystalBank.snapshot(path: args[i + 1]) }
        if let i = args.firstIndex(of: "--snapshot-market"), i + 1 < args.count { CrystalBank.snapshot(path: args[i + 1], market: true) }
        // Talking to a live session from the command line (same paths as the dialogue view):
        //   --send <id> <text>   --press <id> <up|down|enter|escape|1|2|3>   --migrate <id>   --snapshot-dialogue <id> out.png
        // `AgentDeck --snapshot-sidebar out.png`: the workspace window (sidebar + world) offscreen.
        if let i = args.firstIndex(of: "--snapshot-sidebar"), i + 1 < args.count {
            let store = Snapshot.loadedStorePublic()
            // The sidebar List is AppKit-backed and does not cache-render, so draw the same rows in a stack.
            let rows = VStack(alignment: .leading, spacing: 8) {
                ForEach(store.sessions) { s in
                    SessionRow(title: s.name, subtitle: s.agent.rawValue + " · " + s.project, session: s, store: store)
                }
            }
            .padding(12).frame(width: 300, alignment: .leading).background(Color(white: 0.95))
            let host = NSHostingView(rootView: rows.frame(width: 300, height: 800, alignment: .top))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        // `AgentDeck --serve-mobile <seconds>`: run the phone server on 127.0.0.1 (no tunnel) and print the code.
        if let i = args.firstIndex(of: "--serve-mobile"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            let store = Snapshot.loadedStorePublic()
            MobileServer.shared.start(store: store)
            MobileServer.shared.beginPairing()
            print("secret", MobileServer.shared.pairingSecret ?? "")
            fflush(stdout)
            // Test driver: decisions come on stdin ("allow" / "deny" answer the oldest waiting request),
            // standing in for the approval panel without synthetic clicks.
            FileHandle.standardInput.readabilityHandler = { h in
                let line = String(data: h.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in
                    if let req = MobileServer.shared.pending.first(where: { $0.decision == nil }), line == "allow" || line == "deny" {
                        MobileServer.shared.decide(req.id, allow: line == "allow")
                        print("decided", line); fflush(stdout)
                    }
                }
            }
            let end = Date().addingTimeInterval(secs)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                store.refresh()
            }
            exit(0)
        }
        // `AgentDeck --announce-test <reply file> <agent> [request]`: print what the agent would say (no sound).
        if let i = args.firstIndex(of: "--announce-test"), i + 2 < args.count,
           let reply = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            var said: String?? = .none
            let agent = args[i + 2], request = args.dropFirst(i + 3).first
            Task { said = .some(await SpokenSummary.answer(agent: agent, request: request, reply: reply)) }
            while said == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print((said ?? nil) ?? "(nothing)")
            exit(0)
        }
        // `AgentDeck --say-test`: two confirmations and a reply summary, queued; each should finish before the next.
        if args.contains("--say-test") {
            Speaker.shared.say("첫 번째 안내예요.")
            Speaker.shared.announce("작업을 마쳤습니다. 테스트 열두 개가 모두 통과했고 커밋까지 끝냈습니다.", agent: "펠릭스",
                                    request: "테스트 돌리고 커밋해 줘", characterId: nil)
            Speaker.shared.say("세 번째 안내예요.")
            let end = Date().addingTimeInterval(30)
            while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-talk"), i + 1 < args.count {
            TalkModeCapsule.snapshot(path: args[i + 1])
        }
        if let i = args.firstIndex(of: "--wake-test"), i + 1 < args.count {
            WakeWord.test(file: args[i + 1], names: Array(args.dropFirst(i + 2)))
        }
        if args.contains("--reopen-permissions") {
            Snapshot.reopenPermissions()
        }
        // `--ledger-register <code>`: registers this Mac with an admin code (as the guild's server section does),
        // without settling; the app settles on its next start.
        if let i = args.firstIndex(of: "--ledger-register"), i + 1 < args.count {
            Snapshot.ledgerRegister(code: args[i + 1])
        }
        // `--market-upload <pack folder> <price> <description file> [alias]`: the selling tab's upload, for packs
        // made outside the app. Needs server sync on and this Mac registered, like the tab.
        if let i = args.firstIndex(of: "--market-upload"), i + 3 < args.count {
            Snapshot.marketUpload(folder: args[i + 1], price: Int(args[i + 2]) ?? 0, descriptionFile: args[i + 3],
                                  alias: args.dropFirst(i + 4).first ?? "")
        }
        for flag in ["--send", "--press", "--migrate", "--end", "--menu", "--choose", "--live", "--clone", "--summary", "--hunt", "--snapshot-dialogue", "--snapshot-world-dialogue"] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                Snapshot.session(flag: flag, id: args[i + 1], arg: args.dropFirst(i + 2).first)
            }
        }
        // `--parse-menu <screen.txt>`: show what the dialogue's choice card would contain.
        if let i = args.firstIndex(of: "--parse-menu"), i + 1 < args.count,
           let screen = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            if let m = TerminalMenu.parse(screen) {
                print("question:", m.question.map(DialogueView.translate) ?? "-")
                print("context:\n" + (m.context ?? "-"))
                for (k, o) in m.options.enumerated() { print(k == m.selected ? "❯" : " ", k, o.label) }
            } else { print("no menu") }
            exit(0)
        }
        // `--menu-hosted <tmux session> [n]`: parse (and optionally choose in) a menu on 수혁's own tmux server,
        // which also covers sessions that are not in Claude's registry yet (e.g. the folder trust prompt).
        if let i = args.firstIndex(of: "--menu-hosted"), i + 1 < args.count, let tmux = TmuxEngine.tmux {
            let name = args[i + 1]
            let screen = TerminalSource.run(tmux, TmuxEngine.base + ["capture-pane", "-p", "-t", name]) ?? ""
            guard let menu = TerminalMenu.parse(screen) else { print("no menu"); exit(0) }
            for (k, o) in menu.options.enumerated() { print(k == menu.selected ? "❯" : " ", k, o.label, o.detail ?? "") }
            if let n = args.dropFirst(i + 2).first.flatMap(Int.init) {
                let steps = n - menu.selected
                for _ in 0..<abs(steps) {
                    _ = TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, steps > 0 ? "Down" : "Up"]); usleep(60_000)
                }
                _ = TerminalSource.run(tmux, TmuxEngine.base + ["send-keys", "-t", name, "Enter"])
                print("chose", n)
            }
            exit(0)
        }
        // Session engine from the command line:
        //   --new-session <Claude|Codex|Shell> <cwd> [prompt]   --list-sessions   --kill-session <name>
        if let i = args.firstIndex(of: "--new-session"), i + 2 < args.count, args[i + 1] == TmuxEngine.shellTag {
            print(TmuxEngine.createShell(cwd: args[i + 2]) ?? "FAILED")
            exit(0)
        }
        if let i = args.firstIndex(of: "--new-session"), i + 2 < args.count, let agent = Agent(rawValue: args[i + 1]) {
            print(TmuxEngine.create(agent: agent, cwd: args[i + 2], prompt: args.dropFirst(i + 3).first) ?? "FAILED")
            exit(0)
        }
        if args.contains("--list-sessions") {
            for h in TmuxEngine.list() { print(h.name, h.agent?.rawValue ?? TmuxEngine.shellTag, h.cwd, h.title, separator: "\t") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--kill-session"), i + 1 < args.count {
            TmuxEngine.kill(args[i + 1]); exit(0)
        }
        // `AgentDeck --terminal <sessionId> [transcript]` prints what the terminal window would show.
        if let i = args.firstIndex(of: "--terminal"), i + 1 < args.count {
            Snapshot.terminal(id: args[i + 1], transcript: args.dropFirst(i + 2).first == "transcript")
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(path: args[i + 1], select: i + 2 < args.count ? args[i + 2] : nil)
        }
        CommandHover.install()
        AppAppearance.current.apply()
    }

    var body: some Scene {
        WindowGroup("수혁", id: "main") {
            WorkspaceView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("세션 이름 수정…") { store.editingSummary = store.selectedSession }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selectedSession == nil)
            }
            CommandGroup(after: .sidebar) {
                ForEach(1...10, id: \.self) { n in
                    // Order read on the key press: the sidebar sort can change without the store publishing.
                    Button("수혁 세션 \(n)번으로 이동") {
                        let panes = store.hostedAgentPanes()
                        if n <= panes.count { store.selection = panes[n - 1] }
                    }
                    .keyboardShortcut(KeyEquivalent(Swift.Character("\(n % 10)")))  // ⌘0 is the 10th
                }
                Divider()
                // Shown for the menu; the key itself is caught by TerminalPanelKey before the menu sees it.
                Button(store.terminalPanelOpen ? "터미널 패널 닫기" : "터미널 패널 열기") { store.toggleTerminalPanel() }
                    .keyboardShortcut("`")
            }
        }
        Settings { SettingsView().environmentObject(store) }
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var lastRefresh = Date()
    @Published private var assignments: [String: Int] = [:]
    @Published private var names: [String: String] = [:]
    private var spokenNames: [String: String] = [:]
    @Published var selection: Pane = .world
    @Published var hosted: [TmuxEngine.Hosted] = []
    @Published var recent: [RecentConversation] = []
    /// Where each working agent stands; only moves after the new kind of work lasts a while.
    @Published private var stations: [String: AgentAction.Kind] = [:]
    /// Recent kinds of work per session (one sample per refresh); the station follows the majority,
    /// so agents do not shuttle between forge, board and desk every time the tool changes.
    private var workSamples: [String: [(Date, AgentAction.Kind)]] = [:]
    private let stationWindow: TimeInterval = 45
    private var lastRecentLoad = Date.distantPast
    private var assigner = CharacterAssigner()
    private var timer: Timer?
    private var loading = false

    init() {
        refresh()
        // Never leave a public tunnel running after the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MobileTunnel.shared.stop() }
        }
        if UserDefaults.standard.bool(forKey: "mobileEnabled"), !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            Task { @MainActor in MobileServer.shared.start(store: self); MobileTunnel.shared.start() }
        }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { CrystalBank.shared.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func character(for session: AgentSession) -> Character? {
        guard let i = assignments[session.id], Art.roster.indices.contains(i) else { return nil }
        return Art.roster[i]
    }

    func agentName(for session: AgentSession) -> String { names[session.id] ?? String(localized: "모험가") }
    /// The Korean name, for voice features (wake word, spoken replies), which stay Korean in any UI language.
    func spokenName(for session: AgentSession) -> String { spokenNames[session.id] ?? "모험가" }

    /// Messages between agents in the last couple of hours (`AgentDeck --msg`).
    @Published var mail: [AgentMail.Entry] = []

    /// Live agents `s` exchanged messages with, most recent first. Distinct from children: peers, not sessions it started.
    func partners(of s: AgentSession) -> [AgentSession] {
        var order: [String] = []
        for e in mail.reversed() where e.from == s.id || e.to.contains(s.id) {
            for id in [e.from] + e.to where id != s.id && !order.contains(id) { order.append(id) }
        }
        return order.compactMap { id in sessions.first { $0.id == id } }
    }

    func mailRoster() -> [AgentMail.Agent] {
        sessions.map { s in
            AgentMail.Agent(id: s.id, name: agentName(for: s), agent: s.agent.rawValue, pid: s.pid, cwd: s.cwd, activity: s.activity.label)
        }
    }

    func session(hosted name: String) -> AgentSession? { sessions.first { $0.hostedName == name } }
    /// Sessions started from inside `s` (e.g. `claude -p` runs from its scripts), oldest first.
    func children(of s: AgentSession) -> [AgentSession] {
        sessions.filter { $0.parentId == s.id }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    // MARK: hunting

    @Published var hunt: [String: Hunt.Progress] = [:]

    /// Hunting ground for a session, or nil for the camp. Only agents in a turn (or stopped on a question
    /// mid-turn) hunt; the ground is picked by how long their run has lasted. Idle agents go back to the camp,
    /// and their run keeps counting until they have rested an hour.
    func ground(for s: AgentSession) -> Hunt.Tier? {
        guard s.status == .busy || s.status == .waiting else { return nil }
        return (hunt[s.id] ?? Hunt.Progress()).tier() ?? .low
    }

    /// "중급 사냥터 · 연속 6.2시간 · 결정 31 · 마나 1200" for cards (this log's earnings and output tokens).
    func huntLine(for s: AgentSession) -> String {
        let p = hunt[s.id] ?? Hunt.Progress()
        let place = ground(for: s).map { $0.label } ?? String(localized: "대기소")
        let run = p.run().map { String(localized: " · 연속 \(String(format: "%.1f", $0 / 3600))시간") } ?? ""
        return place + run + String(localized: " · 결정 \(p.earned) · 마나 \(p.mana)")
    }

    /// Where every agent stands: its hunting ground's attack spots, or the camp. Shared by the map and the phone.
    func placements() -> [(session: AgentSession, point: CGPoint, tier: Hunt.Tier?)] {
        let byStart: (AgentSession, AgentSession) -> Bool = { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        var groups: [Hunt.Tier?: [AgentSession]] = [:]
        for s in sessions { groups[ground(for: s), default: []].append(s) }
        var out: [(session: AgentSession, point: CGPoint, tier: Hunt.Tier?)] = []
        for (tier, members) in groups {
            let spots = tier.map(World.attackSpots) ?? World.campSpots
            for (i, s) in members.sorted(by: byStart).enumerated() {
                out.append((s, Pathfinder.shared.nearest(World.spot(spots, i)), tier))
            }
        }
        return out
    }

    /// Newest thing the agent did: its last log entry, else the last status change.
    func lastActivity(for s: AgentSession) -> Date? {
        [hunt[s.id]?.last, s.updatedAt].compactMap { $0 }.max()
    }

    /// The crystal ledger balance (see CrystalBank), shown on the map and the phone.
    var totalCrystals: Int { CrystalBank.shared.balance }

    func station(for s: AgentSession) -> AgentAction.Kind? { stations[s.id] }

    /// Raw kind of work right now; writing replies and unknown tools happen at the desk.
    private func workKind(_ s: AgentSession) -> AgentAction.Kind? {
        guard s.activity == .working else { return nil }
        switch s.action?.kind {
        case nil: return s.status == .shell ? .shell : .editing
        case .replying?, .other?: return .editing
        case let k?: return k
        }
    }

    private func updateStations(_ all: [AgentSession]) {
        let now = Date()
        var next: [String: AgentAction.Kind] = [:]
        for s in all {
            guard let kind = workKind(s) else { workSamples[s.id] = nil; continue }
            var samples = (workSamples[s.id] ?? []).filter { now.timeIntervalSince($0.0) < stationWindow }
            samples.append((now, kind))
            workSamples[s.id] = samples
            guard let current = stations[s.id] else { next[s.id] = kind; continue }  // just started: go straight there
            let counts = Dictionary(grouping: samples, by: \.1).mapValues(\.count)
            let leader = counts.max { $0.value < $1.value }!
            // Move only when another kind clearly dominates the window; ties keep the agent where it is.
            next[s.id] = leader.key != current && leader.value > (counts[current] ?? 0) ? leader.key : current
        }
        workSamples = workSamples.filter { next[$0.key] != nil }
        stations = next
    }

    /// Where a session's terminal lives in the main window.
    /// The session open in the detail pane (sidebar selection), if any.
    var selectedSession: AgentSession? {
        switch selection {
        case .hosted(let name): return session(hosted: name)
        case .external(let id): return sessions.first { $0.id == id }
        case .world, .list, .guild, .market: return nil
        }
    }

    func pane(for s: AgentSession) -> Pane { s.hostedName.map(Pane.hosted) ?? .external(s.id) }

    /// Folders seen in live, hosted and recent sessions, for the new-session picker.
    var knownFolders: [String] {
        var seen = Set<String>()
        return (hosted.map(\.cwd) + sessions.map(\.cwd) + recent.map(\.cwd)).filter { seen.insert($0).inserted }
    }

    func start(agent: Agent, cwd: String, prompt: String?, resume: String? = nil) {
        let face = character(resuming: resume)
        Task.detached {
            let name = TmuxEngine.create(agent: agent, cwd: cwd, prompt: prompt, resume: resume, character: face)
            await MainActor.run {
                self.hosted = TmuxEngine.list()
                if let name { self.selection = .hosted(name) }
                self.refresh()
            }
        }
    }

    /// Bottom terminal panel (⌘`). Its shell stays on the tmux server, so closing the panel only hides it.
    @Published var terminalPanelOpen = false

    /// Opens the panel, first starting its shell in the selected session's folder if none is running.
    func toggleTerminalPanel() {
        if terminalPanelOpen { terminalPanelOpen = false; return }
        if !hosted.contains(where: { $0.name == TmuxEngine.panelName }) {
            let cwd: String? = switch selection {
            case .hosted(let n): hosted.first { $0.name == n }?.cwd
            case .external(let id): sessions.first { $0.id == id }?.cwd
            default: nil
            }
            guard TmuxEngine.createShell(cwd: cwd ?? NSHomeDirectory(), name: TmuxEngine.panelName) != nil else { return }
            hosted = TmuxEngine.list()
        }
        terminalPanelOpen = true
    }

    /// A new agent that starts from a copy of this session's conversation; the original keeps running.
    func clone(_ s: AgentSession) {
        guard let id = s.conversationId else { return }
        let flags = Self.permissionFlags(s)
        let face = character(resuming: nil)  // a clone is a new agent with its own face
        Task.detached {
            let name = TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: id, fork: true, extraArgs: flags,
                                         character: face)
            await MainActor.run {
                self.hosted = TmuxEngine.list()
                if let name { self.selection = .hosted(name) }
                self.refresh()
            }
        }
    }

    // MARK: summaries

    /// The user's own one-line summary per conversation, shown instead of the generated title.
    /// Session whose summary sheet is open (set from the right-click menu).
    @Published var editingSummary: AgentSession?
    @Published private(set) var summaries: [String: String] =
        UserDefaults.standard.dictionary(forKey: "summaries") as? [String: String] ?? [:]

    private func summaryKey(_ s: AgentSession) -> String { s.conversationId ?? s.id }

    func summary(for s: AgentSession) -> String? { summaries[summaryKey(s)] }

    func setSummary(_ text: String, for s: AgentSession) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        summaries[summaryKey(s)] = t.isEmpty ? nil : t
        UserDefaults.standard.set(summaries, forKey: "summaries")
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {  // show it now, not at the next refresh
            let original = sessions[i].generatedName ?? sessions[i].name
            sessions[i].generatedName = t.isEmpty ? nil : original
            sessions[i].name = t.isEmpty ? original : t
        }
    }

    /// What to call the session in the UI: the user's summary, else the generated title.

    func resume(_ r: RecentConversation) { start(agent: r.agent, cwd: r.cwd, prompt: nil, resume: r.id) }

    func resume(conversationOf s: AgentSession) {
        guard let id = s.conversationId else { return }
        start(agent: s.agent, cwd: s.cwd, prompt: nil, resume: id)
    }

    struct MigrationResult: Identifiable {
        let id: String
        let name: String
        let message: String
        let ok: Bool
    }

    /// Moves conversations from other terminals into 수혁: close the original (so only one process
    /// writes the conversation), then resume it on 수혁's tmux server with its full history.
    func migrate(_ targets: [AgentSession], closeOriginal: Bool) async -> [MigrationResult] {
        var results: [MigrationResult] = []
        for s in targets {
            let label = agentName(for: s) + " · " + s.name
            guard let conversation = s.conversationId else {
                results.append(.init(id: s.id, name: label, message: String(localized: "대화 ID를 몰라 이어서 열 수 없음"), ok: false)); continue
            }
            var note = ""
            let flags = Self.permissionFlags(s)  // read before the original process is gone
            if closeOriginal {
                note = await Task.detached { Self.closeOriginal(s) }.value
                if !note.isEmpty, let pid = s.pid, Darwin.kill(pid, 0) == 0 {
                    // Still running (e.g. an unsent draft): do not open a second copy of the conversation.
                    results.append(.init(id: s.id, name: label, message: note, ok: false)); continue
                }
            }
            let face = character(resuming: conversation, from: s)
            let name = await Task.detached {
                TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: conversation, extraArgs: flags, character: face)
            }.value
            results.append(.init(id: s.id, name: label,
                                 message: name == nil ? String(localized: "수혁에서 여는 데 실패")
                                    : note.isEmpty ? String(localized: "옮김") : String(localized: "옮김 — \(note)"),
                                 ok: name != nil))
        }
        hosted = TmuxEngine.list()
        refresh()
        return results
    }

    /// Ends a session gracefully: quit command first; hosted sessions also lose their tmux session.
    /// Returns a message when the session could not be ended.
    func end(_ s: AgentSession) async -> String? {
        let note = await Task.detached { Self.closeOriginal(s) }.value
        if let name = s.hostedName {
            kill(name)  // also covers an agent that ignored /exit
            return nil
        }
        refresh()
        return note.isEmpty ? nil : note
    }

    /// Restarts 수혁 sessions whose process does not match the "skip permissions" setting, keeping the conversation:
    /// quit gracefully (skipped when busy or a draft is typed), then resume it with the right flags.
    func reopenForPermissionSetting() async -> [MigrationResult] {
        let want = UserDefaults.standard.object(forKey: "skipPermissions") as? Bool ?? true
        var results: [MigrationResult] = []
        for s in sessions where s.hostedName != nil {
            let has = !Self.permissionFlags(s).isEmpty
            guard has != want, let name = s.hostedName, let conversation = s.conversationId else { continue }
            let label = agentName(for: s) + " · " + s.name
            if s.status == .busy || s.status == .waiting {
                results.append(.init(id: s.id, name: label, message: String(localized: "작업 중이라 건너뜀"), ok: false)); continue
            }
            let note = await Task.detached { Self.closeOriginal(s) }.value
            if let pid = s.pid, Darwin.kill(pid, 0) == 0 {
                results.append(.init(id: s.id, name: label, message: note.isEmpty ? String(localized: "종료되지 않음") : note, ok: false)); continue
            }
            TerminalHost.shared.drop(name)
            TmuxEngine.kill(name)
            // Without extraArgs: TmuxEngine adds the flag from the current setting.
            let face = character(resuming: conversation, from: s)
            let new = await Task.detached {
                TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: conversation, character: face)
            }.value
            results.append(.init(id: s.id, name: label, message: new == nil ? String(localized: "다시 열기 실패") : String(localized: "다시 열림"), ok: new != nil))
        }
        hosted = TmuxEngine.list()
        refresh()
        return results
    }

    /// Permission options the original process was started with, so a migrated session behaves the same.
    nonisolated static func permissionFlags(_ s: AgentSession) -> [String] {
        guard let pid = s.pid,
              let cmd = TerminalSource.run("/bin/ps", ["-o", "command=", "-p", String(pid)]) else { return [] }
        let words = cmd.split(separator: " ").map(String.init)
        var flags: [String] = []
        if words.contains("--dangerously-skip-permissions") { flags.append("--dangerously-skip-permissions") }
        if words.contains("--dangerously-bypass-approvals-and-sandbox") { flags.append("--dangerously-bypass-approvals-and-sandbox") }
        if let i = words.firstIndex(of: "--permission-mode"), i + 1 < words.count { flags += ["--permission-mode", words[i + 1]] }
        return flags
    }

    /// Sends the agent's quit command to its terminal and waits for the process to end.
    /// Refuses when the input box holds unsent text: typing /exit would append to it and submit the draft.
    nonisolated private static func closeOriginal(_ s: AgentSession) -> String {
        guard let pid = s.pid, SessionInput.canSend(s) else {
            return String(localized: "원래 세션을 닫지 못함 — 원래 터미널에서 직접 종료할 것")
        }
        guard case .text(let screen, _) = TerminalSource.read(pid: pid, lines: 40) else {
            return String(localized: "화면을 읽지 못해 종료하지 않음 — 원래 터미널에서 직접 종료할 것")
        }
        if let draft = inputDraft(screen) {
            return String(localized: "입력칸에 보내지 않은 글이 있어 종료하지 않음(\(oneLine(draft, limit: 30))) — 원래 터미널에서 정리 후 다시 시도")
        }
        _ = SessionInput.send(s, text: s.agent == .claude ? "/exit" : "/quit")
        for _ in 0..<30 {
            if Darwin.kill(pid, 0) != 0 { return "" }
            usleep(500_000)
        }
        return String(localized: "원래 세션이 15초 안에 끝나지 않음 — 원래 터미널에서 확인할 것")
    }

    /// Text typed into the agent's input box, if any. The box is the last line starting with "❯";
    /// the grey "Try …" hint of an empty box counts as empty.
    nonisolated static func inputDraft(_ screen: String) -> String? {
        guard let line = screen.split(separator: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })
        else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("Try \"") { return nil }
        return text
    }

    // MARK: characters

    private static let conversationCharactersKey = "conversationCharacters"
    /// Character of each conversation 수혁 started, so resuming it brings back the same face and voice.
    private var conversationCharacters =
        UserDefaults.standard.dictionary(forKey: SessionStore.conversationCharactersKey) as? [String: String] ?? [:]

    /// Characters just given to sessions that are still starting, so back-to-back launches do not draw the same one
    /// before the first session shows up in a refresh.
    private var launching: [Int: Date] = [:]

    /// The character a new 수혁 session gets: the conversation's own when resuming, then the one `s` already shows,
    /// else one no live or starting agent has.
    func character(resuming conversation: String?, from s: AgentSession? = nil) -> Character? {
        let roster = Art.roster
        if let id = conversation.flatMap({ conversationCharacters[$0] }), let c = roster.first(where: { $0.id == id }) { return c }
        if let s, let i = assignments[s.id], roster.indices.contains(i) { return roster[i] }
        launching = launching.filter { Date().timeIntervalSince($0.value) < 60 }
        let open = CrystalBank.shared.unlocked
        let lineup = Lineup.order(roster).filter(open.contains)
        guard let i = Self.pick(lineup: lineup, live: Set(assignments.values), starting: Set(launching.keys)) else { return nil }
        launching[i] = Date()
        return roster[i]
    }

    /// The first in the lineup nobody uses; failing that the first no starting session took; failing that the
    /// first (more agents than characters).
    nonisolated static func pick(lineup: [Int], live: Set<Int>, starting: Set<Int>) -> Int? {
        lineup.first { !live.contains($0) && !starting.contains($0) } ?? lineup.first { !starting.contains($0) } ?? lineup.first
    }

    /// Roster index per session whose character is fixed: chosen at launch (tmux `@character`) or remembered for
    /// its conversation. Newly seen conversations of pinned sessions are remembered here.
    private func pins(_ sessions: [AgentSession], hosted: [TmuxEngine.Hosted]) -> [String: Int] {
        let roster = Art.roster
        var pins: [String: Int] = [:]
        var changed = false
        for s in sessions {
            let launched = s.hostedName.flatMap { n in hosted.first { $0.name == n }?.character }
            guard let id = launched ?? s.conversationId.flatMap({ conversationCharacters[$0] }),
                  let i = roster.firstIndex(where: { $0.id == id }) else { continue }
            pins[s.id] = i
            if let c = s.conversationId, conversationCharacters[c] != id { conversationCharacters[c] = id; changed = true }
        }
        if changed { UserDefaults.standard.set(conversationCharacters, forKey: Self.conversationCharactersKey) }
        return pins
    }

    func kill(_ name: String) {
        TerminalHost.shared.drop(name)
        TmuxEngine.kill(name)
        hosted.removeAll { $0.name == name }
        if selection == .hosted(name) { selection = .world }
        lastRecentLoad = .distantPast  // the ended conversation shows up under recent
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let all = SessionTree.link(ClaudeSource.load() + CodexSource.load()).sorted {
                if $0.activity.sortRank != $1.activity.sortRank { return $0.activity.sortRank < $1.activity.sortRank }
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            let hosted = TmuxEngine.list()
            AgentMail.deliverSpool(all)
            let mail = AgentMail.recent()
            var hunt: [String: Hunt.Progress] = [:]
            for s in all { if let p = s.transcriptPath { hunt[s.id] = HuntClock.progress(path: p) } }
            let reloadRecent = await MainActor.run { Date().timeIntervalSince(self.lastRecentLoad) > 30 }
            let recent = reloadRecent
                ? RecentSource.load(excluding: Set(all.compactMap { $0.conversationId ?? $0.id.replacingOccurrences(of: "codex-", with: "") }))
                : nil
            await MainActor.run {
                // The user's own summaries replace generated titles everywhere the session is shown.
                let all = all.map { s -> AgentSession in
                    var s = s
                    if let mine = self.summaries[s.conversationId ?? s.id] { s.generatedName = s.name; s.name = mine }
                    return s
                }
                self.hosted = hosted
                self.hunt = hunt
                if let recent { self.recent = recent; self.lastRecentLoad = Date() }
                self.sessions = all
                self.updateStations(all)
                self.assignments = self.assigner.update(all, allowed: CrystalBank.shared.unlocked, pinned: self.pins(all, hosted: hosted),
                                                          order: Lineup.order(Art.roster))
                self.names = AgentNames.assign(all, assignments: self.assignments)
                self.spokenNames = L10n.english ? AgentNames.assign(all, assignments: self.assignments, english: false) : self.names
                self.mail = mail
                AgentMail.writeRoster(self.mailRoster())
                self.lastRefresh = Date()
                WakeWord.shared.observe(all)
                Notifier.shared.observe(all, store: self)
                self.loading = false
            }
        }
    }
}

/// Menu bar: emblem + number of working agents.
struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let working = store.sessions.filter { $0.activity == .working }.count
        HStack(spacing: 3) {
            if let icon = Self.icon { Image(nsImage: icon) } else { Image(systemName: "flag.fill") }
            if working > 0 { Text("\(working)") }
        }
        // The menu bar label lives as long as the app, so the wake listener hangs off it.
        .onAppear { WakeWord.shared.attach(store); Notifier.shared.attach(store); CopyOnSelect.install() }
    }

    /// Monochrome template derived from the app icon (art/out/menubar.png); macOS tints it for light/dark bars.
    static let icon: NSImage? = {
        guard let img = Art.image("menubar") else { return nil }
        let copy = img.copy() as! NSImage
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        return copy
    }()
}

struct MenuBarContent: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let counts = Activity.allCases.map { a in "\(a.label) \(store.sessions.filter { $0.activity == a }.count)" }
        Text(counts.joined(separator: " · "))
        Divider()
        ForEach(store.sessions.filter { s in
            s.parentId == nil && (s.activity == .working || store.children(of: s).contains { $0.activity == .working })
        }) { s in
            Button("\(store.agentName(for: s)) — \(s.action?.detail ?? s.name)") { open(s) }
            ForEach(store.children(of: s)) { c in
                Button("    ㄴ \(store.agentName(for: c)) — \(c.action?.detail ?? c.name)") { open(c) }
            }
        }
        Divider()
        if case .available(let v) = Updater.shared.state {
            Button("업데이트 \(v) 설치…") {
                Updater.shared.upgrade()
            }
            Divider()
        }
        Button("수혁 열기") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(_ s: AgentSession) {
        store.selection = store.pane(for: s)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

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
