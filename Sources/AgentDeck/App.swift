import AppKit
import SwiftUI

@main
struct AgentDeckApp: App {
    @StateObject private var store = SessionStore()

    init() {
        // `AgentDeck --snapshot out.png [selectedSessionId]` renders the world offscreen and exits (for checks without touching the screen).
        let args = CommandLine.arguments
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
        for flag in ["--send", "--press", "--migrate", "--snapshot-dialogue", "--snapshot-world-dialogue"] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                Snapshot.session(flag: flag, id: args[i + 1], arg: args.dropFirst(i + 2).first)
            }
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
    private var pendingStations: [String: (kind: AgentAction.Kind, since: Date)] = [:]
    private let stationDwell: TimeInterval = 3
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
            guard let kind = workKind(s) else { pendingStations[s.id] = nil; continue }
            guard let current = stations[s.id] else { next[s.id] = kind; continue }  // just started: go straight there
            if kind == current { pendingStations[s.id] = nil; next[s.id] = current; continue }
            let pending = pendingStations[s.id]
            if pending?.kind == kind, now.timeIntervalSince(pending!.since) >= stationDwell {
                next[s.id] = kind
                pendingStations[s.id] = nil
            } else {
                if pending?.kind != kind { pendingStations[s.id] = (kind, now) }
                next[s.id] = current
            }
        }
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
            if closeOriginal {
                note = await Task.detached { Self.closeOriginal(s) }.value
            }
            let name = await Task.detached { TmuxEngine.create(agent: s.agent, cwd: s.cwd, prompt: nil, resume: conversation) }.value
            results.append(.init(id: s.id, name: label,
                                 message: name == nil ? "수혁에서 여는 데 실패" : (note.isEmpty ? "옮김" : "옮김 — " + note),
                                 ok: name != nil))
        }
        hosted = TmuxEngine.list()
        refresh()
        return results
    }

    /// Sends the agent's quit command to its terminal and waits for the process to end.
    nonisolated private static func closeOriginal(_ s: AgentSession) -> String {
        guard let pid = s.pid, SessionInput.canSend(s) else {
            return "원래 세션을 닫지 못함 — 원래 터미널에서 직접 종료할 것"
        }
        _ = SessionInput.press(s, .escape)  // leave any open menu or half-typed input first
        _ = SessionInput.send(s, text: s.agent == .claude ? "/exit" : "/quit")
        for _ in 0..<30 {
            if Darwin.kill(pid, 0) != 0 { return "" }
            usleep(500_000)
        }
        return "원래 세션이 15초 안에 끝나지 않음 — 원래 터미널에서 확인할 것"
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
            let reloadRecent = await MainActor.run { Date().timeIntervalSince(self.lastRecentLoad) > 30 }
            let recent = reloadRecent
                ? RecentSource.load(excluding: Set(all.compactMap { $0.conversationId ?? $0.id.replacingOccurrences(of: "codex-", with: "") }))
                : nil
            await MainActor.run {
                self.hosted = hosted
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
        let deadline = Date().addingTimeInterval(5)
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
