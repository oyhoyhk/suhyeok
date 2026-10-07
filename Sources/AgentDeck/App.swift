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
            for id in ["knight", "fox", "mage"] { print("voice", id, Speaker.voice(for: id)?.name ?? "-") }
            let synth = AVSpeechSynthesizer()
            var frames = 0
            let done = DispatchSemaphore(value: 0)
            let u = AVSpeechUtterance(string: Speaker.plain("**작업을 마쳤습니다.** `build.sh`를 실행했고\n```\nok\n```\n결과는 정상입니다."))
            u.voice = Speaker.voice(for: "fox")
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
        // `AgentDeck --snapshot-poses <characterId> out.png` renders one character's walk/work frames.
        if let i = args.firstIndex(of: "--snapshot-poses"), i + 2 < args.count {
            Snapshot.poses(character: args[i + 1], path: args[i + 2])
        }
        // `AgentDeck --snapshot-hosted <name> out.png` renders the embedded terminal offscreen.
        if let i = args.firstIndex(of: "--snapshot-hosted"), i + 2 < args.count {
            Snapshot.hosted(name: args[i + 1], path: args[i + 2])
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
        // Talking to a live session from the command line (same paths as the dialogue view):
        //   --send <id> <text>   --press <id> <up|down|enter|escape|1|2|3>   --migrate <id>   --snapshot-dialogue <id> out.png
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
        //   --new-session <Claude|Codex> <cwd> [prompt]   --list-sessions   --kill-session <name>
        if let i = args.firstIndex(of: "--new-session"), i + 2 < args.count, let agent = Agent(rawValue: args[i + 1]) {
            print(TmuxEngine.create(agent: agent, cwd: args[i + 2], prompt: args.dropFirst(i + 3).first) ?? "FAILED")
            exit(0)
        }
        if args.contains("--list-sessions") {
            for h in TmuxEngine.list() { print(h.name, h.agent.rawValue, h.cwd, h.title, separator: "\t") }
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
    }

    var body: some Scene {
        WindowGroup("수혁", id: "main") {
            WorkspaceView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        Settings { SettingsView() }
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
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func character(for session: AgentSession) -> Character? {
        guard let i = assignments[session.id], Art.roster.indices.contains(i) else { return nil }
        return Art.roster[i]
    }

    func agentName(for session: AgentSession) -> String { names[session.id] ?? "모험가" }

    func session(hosted name: String) -> AgentSession? { sessions.first { $0.hostedName == name } }

    // MARK: hunting

    @Published var hunt: [String: Hunt.Progress] = [:]

    /// Hunting ground for a session, or nil for the camp. Working agents always hunt (a fresh run starts low).
    func ground(for s: AgentSession) -> Hunt.Tier? {
        let p = hunt[s.id] ?? Hunt.Progress()
        if let t = p.tier() { return t }
        return s.status == .busy ? .low : nil
    }

    /// "중급 사냥터 · 연속 6.2시간 · 결정 31" for cards.
    func huntLine(for s: AgentSession) -> String {
        let p = hunt[s.id] ?? Hunt.Progress()
        let place = ground(for: s).map { $0.label } ?? "대기소"
        let run = p.run().map { String(format: " · 연속 %.1f시간", $0 / 3600) } ?? ""
        return "\(place)\(run) · 결정 \(p.crystals)"
    }

    var totalCrystals: Int { sessions.reduce(0) { $0 + (hunt[$1.id]?.crystals ?? 0) } }

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
    func pane(for s: AgentSession) -> Pane { s.hostedName.map(Pane.hosted) ?? .external(s.id) }

    /// Folders seen in live, hosted and recent sessions, for the new-session picker.
    var knownFolders: [String] {
        var seen = Set<String>()
        return (hosted.map(\.cwd) + sessions.map(\.cwd) + recent.map(\.cwd)).filter { seen.insert($0).inserted }
    }

    func start(agent: Agent, cwd: String, prompt: String?, resume: String? = nil) {
        Task.detached {
            let name = TmuxEngine.create(agent: agent, cwd: cwd, prompt: prompt, resume: resume)
            await MainActor.run {
                self.hosted = TmuxEngine.list()
                if let name { self.selection = .hosted(name) }
                self.refresh()
            }
        }
    }

    /// A new agent that starts from a copy of this session's conversation; the original keeps running.
    func clone(_ s: AgentSession) {
        guard let id = s.conversationId else { return }
        let flags = Self.permissionFlags(s)
        Task.detached {
            let name = TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: id, fork: true, extraArgs: flags)
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
                results.append(.init(id: s.id, name: label, message: "대화 ID를 몰라 이어서 열 수 없음", ok: false)); continue
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
            let name = await Task.detached {
                TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: conversation, extraArgs: flags)
            }.value
            results.append(.init(id: s.id, name: label,
                                 message: name == nil ? "수혁에서 여는 데 실패" : (note.isEmpty ? "옮김" : "옮김 — " + note),
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
            return "원래 세션을 닫지 못함 — 원래 터미널에서 직접 종료할 것"
        }
        guard case .text(let screen, _) = TerminalSource.read(pid: pid, lines: 40) else {
            return "화면을 읽지 못해 종료하지 않음 — 원래 터미널에서 직접 종료할 것"
        }
        if let draft = inputDraft(screen) {
            return "입력칸에 보내지 않은 글이 있어 종료하지 않음(\(oneLine(draft, limit: 30))) — 원래 터미널에서 정리 후 다시 시도"
        }
        _ = SessionInput.send(s, text: s.agent == .claude ? "/exit" : "/quit")
        for _ in 0..<30 {
            if Darwin.kill(pid, 0) != 0 { return "" }
            usleep(500_000)
        }
        return "원래 세션이 15초 안에 끝나지 않음 — 원래 터미널에서 확인할 것"
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
            let all = (ClaudeSource.load() + CodexSource.load()).sorted {
                if $0.activity.sortRank != $1.activity.sortRank { return $0.activity.sortRank < $1.activity.sortRank }
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            let hosted = TmuxEngine.list()
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
                self.assignments = self.assigner.update(all)
                self.names = AgentNames.assign(all)
                self.lastRefresh = Date()
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
        ForEach(store.sessions.filter { $0.activity == .working }) { s in
            Button("\(store.agentName(for: s)) — \(s.action?.detail ?? s.name)") {
                store.selection = store.pane(for: s)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
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
}

/// Offscreen checks that never touch the user's screen.
@MainActor
enum Snapshot {
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
            print("clones:", TmuxEngine.list().filter { $0.title.hasSuffix("(클론)") }.map(\.name))
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
