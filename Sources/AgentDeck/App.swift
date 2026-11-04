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
        // `AgentDeck --snapshot-changes <folder> out.png` renders the changes panel for that folder offscreen.
        // SUHYEOK_TEST_NOTE=<text>: write that note on the diff line containing SUHYEOK_TEST_NOTE_LINE (default "let limit");
        // SUHYEOK_TEST_NOTE_SAVE=1 also presses Enter to add it.
        if let i = args.firstIndex(of: "--snapshot-changes"), i + 2 < args.count {
            Snapshot.changes(cwd: args[i + 1], path: args[i + 2])
        }
        // `AgentDeck --open-sessions [out.png]`: what is written down for reopening after a restart (live 수혁 agents).
        // `AgentDeck --reopen <conversation>`: reopen that written-down session, as the sidebar offer does.
        if args.contains("--open-sessions") || args.contains("--reopen") { Snapshot.restore(args) }
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
        // `AgentDeck --ledger`: crystal ledger check (read only). `--snapshot-guild out.png [height]`: the guild page offscreen.
        if args.contains("--ledger") { CrystalBank.report(); exit(0) }
        if let i = args.firstIndex(of: "--snapshot-guild"), i + 1 < args.count {
            CrystalBank.snapshot(path: args[i + 1], height: args.dropFirst(i + 2).first.flatMap { Double($0) }.map { CGFloat($0) } ?? 1100)
        }
        if let i = args.firstIndex(of: "--snapshot-market"), i + 1 < args.count { CrystalBank.snapshot(path: args[i + 1], market: true) }
        // Talking to a live session from the command line (same paths as the dialogue view):
        //   --send <id> <text>   --press <id> <up|down|enter|escape|1|2|3>   --migrate <id>   --snapshot-dialogue <id> out.png   --clear <id> [out.png]
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
        // `--market-install <listing id>`: download and install a listing this Mac owns or sells (its own pack).
        if let i = args.firstIndex(of: "--market-install"), i + 1 < args.count { Snapshot.marketInstall(listingId: args[i + 1]) }
        if let i = args.firstIndex(of: "--market-upload"), i + 3 < args.count {
            Snapshot.marketUpload(folder: args[i + 1], price: Int(args[i + 2]) ?? 0, descriptionFile: args[i + 3],
                                  alias: args.dropFirst(i + 4).first ?? "")
        }
        for flag in ["--send", "--press", "--migrate", "--end", "--menu", "--choose", "--live", "--clone", "--clear", "--summary", "--hunt", "--snapshot-dialogue", "--snapshot-world-dialogue"] {
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
        //   --new-session <Claude|Codex|Antigravity|Shell> <cwd> [prompt]   --list-sessions   --kill-session <name>
        if let i = args.firstIndex(of: "--new-session"), i + 2 < args.count, args[i + 1] == TmuxEngine.shellTag {
            print(TmuxEngine.createShell(cwd: args[i + 2]) ?? "FAILED")
            exit(0)
        }
        if let i = args.firstIndex(of: "--new-session"), i + 2 < args.count, let agent = Agent(rawValue: args[i + 1]) {
            print(TmuxEngine.create(agent: agent, cwd: args[i + 2], prompt: args.dropFirst(i + 3).first) ?? "FAILED")
            exit(0)
        }
        // `AgentDeck --background-shells`: each live Claude session's background shells and whether they only wait (kills nothing).
        if args.contains("--background-shells") {
            let procs = BackgroundShells.table()
            for s in ClaudeSource.load() where s.pid != nil {
                for sh in BackgroundShells.shells(of: s.pid!, in: procs) {
                    print(s.id, s.status.rawValue, s.activity.label, sh.pid, String(format: "%.1fh", sh.age / 3600),
                          sh.waiting ? "wait-loop" : "work", BackgroundShells.script(sh.command).prefix(80), separator: "\t")
                }
            }
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
        // Only the app itself kills forgotten wait loops; `--…` checks that load sessions must not.
        BackgroundShells.reaping = !args.dropFirst().contains { $0.hasPrefix("--") }
        CommandHover.install()
        AppAppearance.current.apply()
    }

    var body: some Scene {
        Window("수혁", id: "main") {
            WorkspaceView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("세션 이름 수정…") { store.editingSummary = store.selectedSession }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selectedSession == nil)
                Button("대화 새로 시작 (/clear)") {
                    guard let s = store.selectedSession else { return }
                    Task { await store.startOver(s) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedSession?.agent != .claude)
                Button("세션 종료…") { store.ending = store.selectedSession }
                    .keyboardShortcut(.escape, modifiers: .command)
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
        // SUHYEOK_NO_KEYCHAIN=1: launch without reading the ledger key, for when a keychain prompt nobody can answer
        // (Mac locked, user away) would block launch. The ledger stays read-only, so crystals pause until a normal launch.
        let noKeychain = ProcessInfo.processInfo.environment["SUHYEOK_NO_KEYCHAIN"] == "1"
        if noKeychain { CrystalBank.preview = true }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }), !noKeychain { CrystalBank.shared.start() }
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
        guard let id = s.conversationId, s.agent.canFork else { return }
        let flags = Self.permissionFlags(s)
        let face = character(resuming: nil)  // a clone is a new agent with its own face
        working[s.id] = String(localized: "클론 만드는 중…")
        Task.detached {
            let name = TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: id, fork: true, extraArgs: flags,
                                         character: face)
            await MainActor.run {
                self.working[s.id] = nil
                self.hosted = TmuxEngine.list()
                if let name { self.selection = .hosted(name) }
                self.refresh()
            }
        }
    }

    // MARK: reopening after a restart

    /// Sessions that were open when the tmux server last ran and are closed now (after a reboot), offered in the sidebar.
    @Published private(set) var closedSessions: [SessionRestore.Entry] = []
    @Published private(set) var reopening = false
    private var restoreChecked = false
    private var lastRecorded: [SessionRestore.Entry]?

    /// Writes down which conversations 수혁's agents have open. On the first look after launch, an empty tmux
    /// server means the last run's sessions were closed by a restart: offer those instead of forgetting them.
    private func recordOpenSessions(hosted: [TmuxEngine.Hosted], sessions: [AgentSession]) {
        if !restoreChecked {
            restoreChecked = true
            if !hosted.contains(where: { $0.agent != nil }) {
                closedSessions = SessionRestore.load().filter { FileManager.default.fileExists(atPath: $0.cwd) }
            }
        }
        // Already open again somewhere (e.g. from 최근 대화): a second process on the same conversation would fork it.
        let open = Set(sessions.compactMap(\.conversationId))
        if closedSessions.contains(where: { open.contains($0.conversation) }) { closedSessions.removeAll { open.contains($0.conversation) } }
        let entries = SessionRestore.merged(live: SessionRestore.live(hosted: hosted, sessions: sessions), pending: closedSessions)
        guard entries != lastRecorded else { return }
        lastRecorded = entries
        SessionRestore.save(entries)
    }

    /// Opens the closed sessions again, each continuing its conversation with the same character.
    func reopenClosedSessions() async { await reopen(closedSessions) }

    func reopen(_ entries: [SessionRestore.Entry]) async {
        guard !reopening else { return }
        reopening = true
        for e in entries {
            let face = character(resuming: e.conversation)
            let agent = Agent(rawValue: e.agent) ?? .claude
            _ = await Task.detached {
                TmuxEngine.create(agent: agent, cwd: e.cwd, prompt: nil, resume: e.conversation,
                                  extraArgs: SessionRestore.resumeFlags(e), character: face)
            }.value
            closedSessions.removeAll { $0 == e }
            hosted = TmuxEngine.list()
        }
        reopening = false
        refresh()
    }

    func dismissClosedSessions() { closedSessions = [] }

    /// What an action is doing to a session until its result shows (session id → label), for a spinner.
    @Published private(set) var working: [String: String] = [:]

    /// /clear, marked as working until the new conversation shows up. Returns whether it reached the terminal.
    @discardableResult
    func startOver(_ s: AgentSession) async -> Bool {
        working[s.id] = String(localized: "새 대화 준비 중…")
        defer { working[s.id] = nil }
        guard await Task.detached(operation: { SessionInput.send(s, text: "/clear") }).value else { return false }
        // The new conversation id reaches the session file a moment later; stop waiting after ~10 s.
        var tries = 0
        while tries < 20, sessions.first(where: { $0.id == s.id })?.conversationId == s.conversationId {
            tries += 1
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
        return true
    }

    // MARK: summaries

    /// The user's own one-line summary per conversation, shown instead of the generated title.
    /// Session whose summary sheet is open (set from the right-click menu).
    @Published var editingSummary: AgentSession?
    /// Session whose end confirmation is open in the main window (right-click menu or ⌘Esc).
    @Published var ending: AgentSession?
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
            working[s.id] = String(localized: "옮기는 중…")
            defer { working[s.id] = nil }
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
        working[s.id] = String(localized: "종료하는 중…")
        defer { working[s.id] = nil }
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
        _ = SessionInput.send(s, text: s.agent.quitCommand)
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
            let all = SessionTree.link(ClaudeSource.load() + CodexSource.load() + AntigravitySource.load()).sorted {
                if $0.activity.sortRank != $1.activity.sortRank { return $0.activity.sortRank < $1.activity.sortRank }
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            let hosted = TmuxEngine.list()
            BackgroundShells.reap(all)
            AgentMail.deliverSpool(all)
            let mail = AgentMail.recent()
            var hunt: [String: Hunt.Progress] = [:]
            for s in all where s.agent != .antigravity { if let p = s.transcriptPath { hunt[s.id] = HuntClock.progress(path: p) } }
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
                self.recordOpenSessions(hosted: hosted, sessions: all)
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
