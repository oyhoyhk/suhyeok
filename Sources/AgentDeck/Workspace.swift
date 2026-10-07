import AppKit
import SQLite3
import SwiftUI

/// What the main window shows.
enum Pane: Hashable {
    case world, list
    case hosted(String)    // tmux session on 수혁's server: full interactive terminal
    case external(String)  // AgentSession.id running in another terminal: read-only view
}

/// A past conversation that can be resumed inside 수혁.
struct RecentConversation: Identifiable, Hashable {
    let id: String  // Claude session id or Codex thread id
    let agent: Agent
    let cwd: String
    let title: String
    let updated: Date
}

enum RecentSource {
    static func load(excluding live: Set<String>, days: Double = 7, limit: Int = 30) -> [RecentConversation] {
        let since = Date().addingTimeInterval(-days * 86400)
        return (claude(since: since) + codex(since: since))
            .filter { !live.contains($0.id) }
            .sorted { $0.updated > $1.updated }
            .prefix(limit).map { $0 }
    }

    private static func claude(since: Date) -> [RecentConversation] {
        let fm = FileManager.default
        let root = ClaudeSource.projectsDir
        var files: [(String, Date)] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for f in (try? fm.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? [] where f.hasSuffix(".jsonl") {
                let path = "\(root)/\(dir)/\(f)"
                if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > since {
                    files.append((path, m))
                }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(60).compactMap { path, modified in
            var title: String?, cwd: String?
            for line in JSONLTail.lines(path: path, maxBytes: 256 * 1024).reversed() {
                if title == nil, line["type"] as? String == "ai-title" { title = line["aiTitle"] as? String }
                if cwd == nil { cwd = line["cwd"] as? String }
                if title != nil, cwd != nil { break }
            }
            // Headless runs (claude -p) have no title and are not worth resuming by hand.
            guard let title, let cwd else { return nil }
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return RecentConversation(id: id, agent: .claude, cwd: cwd, title: title, updated: modified)
        }
    }

    private static func codex(since: Date) -> [RecentConversation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(CodexSource.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, cwd, title, updated_at_ms FROM threads
            WHERE archived = 0 AND source != 'exec' AND updated_at_ms > ? ORDER BY updated_at_ms DESC LIMIT 30
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        var out: [RecentConversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let title = col(2)
            out.append(RecentConversation(id: col(0), agent: .codex, cwd: col(1),
                                          title: title.isEmpty ? "Codex 대화" : oneLine(title, limit: 60),
                                          updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000)))
        }
        return out
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var updater = Updater.shared
    @State private var showNew = false
    @State private var showMigrate = false
    @State private var confirmUpdate = false
    @State private var ending: AgentSession?
    @State private var migrating: AgentSession?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Section {
                    Label("월드", systemImage: "map").tag(Pane.world)
                    Label("목록", systemImage: "list.bullet.rectangle").tag(Pane.list)
                }
                Section("수혁 세션") {
                    if store.hosted.isEmpty {
                        Text("＋ 버튼으로 새 세션 시작").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.hosted) { h in
                        SessionRow(title: store.session(hosted: h.name).map { $0.name } ?? h.title,
                                   subtitle: h.agent.rawValue + " · " + (h.cwd as NSString).lastPathComponent,
                                   session: store.session(hosted: h.name), store: store)
                            .tag(Pane.hosted(h.name))
                            .contextMenu {
                                if let s = store.session(hosted: h.name) {
                                    AgentMenu(store: store, session: s, ending: $ending, migrating: $migrating)
                                } else {
                                    Button("세션 종료", role: .destructive) { store.kill(h.name) }
                                }
                            }
                    }
                }
                Section {
                    ForEach(store.sessions.filter { $0.hostedName == nil }) { s in
                        SessionRow(title: s.name, subtitle: s.agent.rawValue + " · " + s.project, session: s, store: store)
                            .tag(Pane.external(s.id))
                            .contextMenu { AgentMenu(store: store, session: s, ending: $ending, migrating: $migrating) }
                    }
                } header: {
                    HStack {
                        Text("다른 터미널")
                        Spacer()
                        Button("수혁으로 옮기기…") { showMigrate = true }.buttonStyle(.borderless).font(.caption)
                    }
                }
                Section("최근 대화") {
                    ForEach(store.recent.prefix(15)) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).lineLimit(1)
                                Text("\(r.agent.rawValue) · \((r.cwd as NSString).lastPathComponent) · \(duration(since: r.updated)) 전")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("이어서") { store.resume(r) }.controlSize(.small)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { showNew = true } label: { Label("새 세션", systemImage: "plus") }
                        .keyboardShortcut("n")
                }
            }
            .safeAreaInset(edge: .bottom) { updateBanner }
        } detail: {
            switch store.selection {
            case .world: WorldView(store: store)
            case .list: BoardView(store: store)
            case .hosted(let name): HostedSessionView(store: store, name: name)
            case .external(let id): ExternalSessionView(store: store, id: id)
            }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet(store: store) }
        .sheet(isPresented: $showMigrate) { MigrationSheet(store: store) }
        .endSessionDialog(store: store, ending: $ending, migrating: $migrating)
        .onAppear { updater.start() }
        .confirmationDialog("수혁을 업데이트할까요?", isPresented: $confirmUpdate) {
            Button("업데이트 후 다시 열기") { updater.upgrade() }
        } message: {
            Text(updater.viaBrew
                 ? "brew로 새 버전을 설치하고 앱을 다시 엶. 실행 중인 에이전트 세션은 tmux에 있어 끊기지 않음."
                 : "brew로 설치한 앱이 아니라서 GitHub 릴리스 페이지를 엶.")
        }
    }

    /// Sidebar footer: shows only when a newer release exists or an upgrade is running.
    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .available(let v):
            Button { confirmUpdate = true } label: {
                Label("업데이트 \(v) 설치 (현재 \(updater.current))", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).padding(10)
        case .upgrading:
            HStack { ProgressView().controlSize(.small); Text("업데이트 중… 끝나면 다시 열림").font(.caption) }.padding(10)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).padding(10)
        case .idle:
            EmptyView()
        }
    }
}

struct SessionRow: View {
    let title: String
    let subtitle: String
    let session: AgentSession?
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session?.activity.color ?? .secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let s = session { Text(store.agentName(for: s)).bold() }
                    Text(title).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// [대화 | 터미널] switch shared by session pages; starts from the Settings default.
struct ModePicker: View {
    @Binding var mode: OpenMode?
    @AppStorage(OpenMode.storageKey) private var defaultMode = OpenMode.dialogue.rawValue

    var body: some View {
        Picker("", selection: Binding(get: { mode ?? OpenMode(rawValue: defaultMode) ?? .dialogue }, set: { mode = $0 })) {
            ForEach(OpenMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize()
    }

    static func effective(_ mode: OpenMode?) -> OpenMode {
        mode ?? OpenMode(rawValue: UserDefaults.standard.string(forKey: OpenMode.storageKey) ?? "") ?? .dialogue
    }
}

struct HostedSessionView: View {
    @ObservedObject var store: SessionStore
    let name: String
    @State private var confirmKill = false
    @State private var mode: OpenMode?

    var body: some View {
        let h = store.hosted.first { $0.name == name }
        let s = store.session(hosted: name)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(s?.activity.color ?? .secondary).frame(width: 8, height: 8)
                if let s { Text(store.agentName(for: s)).font(.headline) }
                Text(s?.name ?? h?.title ?? name).lineLimit(1)
                if let a = s?.action, s?.activity == .working {
                    Label(a.detail, systemImage: a.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if s != nil { ModePicker(mode: $mode) }
                Text((h?.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(role: .destructive) { confirmKill = true } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless).help("세션 종료")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if h == nil {
                Text("종료된 세션").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let s, ModePicker.effective(mode) == .dialogue {
                DialogueView(store: store, sessionId: s.id, onTerminal: { mode = .terminal }).padding(10)
            } else {
                // Codex sessions and agents still starting have no registry entry yet: terminal only.
                EmbeddedTerminal(name: name).id(name)
            }
        }
        .confirmationDialog("이 세션을 종료할까요?", isPresented: $confirmKill) {
            Button("종료", role: .destructive) { store.kill(name) }
        } message: {
            Text("에이전트 프로세스가 끝남. 대화 기록은 남아 '최근 대화'에서 이어서 열 수 있음.")
        }
    }
}

struct ExternalSessionView: View {
    @ObservedObject var store: SessionStore
    let id: String
    @State private var confirmMove = false
    @State private var mode: OpenMode?

    var body: some View {
        if let s = store.sessions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(s.activity.color).frame(width: 8, height: 8)
                    Text(store.agentName(for: s)).font(.headline)
                    Text(s.name).lineLimit(1)
                    Spacer()
                    ModePicker(mode: $mode)
                    if s.conversationId != nil {
                        Button("수혁으로 옮기기") { confirmMove = true }
                    }
                }
                Text(SessionInput.canSend(s) ? "다른 터미널에서 실행 중인 세션 — 지시는 그 터미널로 전달됨"
                                             : "다른 터미널에서 실행 중인 세션 — 이 터미널은 입력을 받을 수 없어 보기만 가능")
                    .font(.caption).foregroundStyle(.secondary)
                if ModePicker.effective(mode) == .dialogue {
                    DialogueView(store: store, sessionId: s.id, onTerminal: { mode = .terminal })
                } else {
                    TerminalPanel(session: s)
                }
            }
            .padding(12)
            .sheet(isPresented: $confirmMove) { MigrationSheet(store: store, only: s.id) }
        } else {
            Text("종료된 세션").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NewSessionSheet: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var agent: Agent = .claude
    @State private var cwd = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 세션").font(.title2.bold())
            Picker("에이전트", selection: $agent) {
                Text("Claude Code").tag(Agent.claude)
                Text("Codex").tag(Agent.codex)
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("작업 폴더", text: $cwd).font(.body.monospaced())
                Menu("최근") {
                    ForEach(store.knownFolders, id: \.self) { f in
                        Button(f.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { cwd = f }
                    }
                }
                .fixedSize()
                Button("선택…") { pickFolder() }
            }
            Toggle("권한 확인 없이 실행", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "skipPermissions") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "skipPermissions") }))
                .font(.caption)
            Text("첫 지시 (비워 두면 빈 세션으로 시작)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("시작") {
                    store.start(agent: agent, cwd: cwd, prompt: prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!folderExists)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var folderExists: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &dir) && dir.boolValue
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: cwd)
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }
}

/// Pick sessions running in other terminals (cmux, Orca, tmux…) and continue them inside 수혁.
struct MigrationSheet: View {
    @ObservedObject var store: SessionStore
    var only: String? = nil  // preselect a single session
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var closeOriginal = true
    @State private var running = false
    @State private var results: [SessionStore.MigrationResult] = []

    private var candidates: [AgentSession] { store.sessions.filter { $0.hostedName == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수혁으로 옮기기").font(.title2.bold())
            Text("대화 기록 전체를 이어받아 수혁 안에서 계속함. 작업 중인 세션은 끊기지 않게 제외됨.")
                .font(.caption).foregroundStyle(.secondary)
            if results.isEmpty {
                List(candidates) { s in
                    let busy = s.activity == .working
                    Toggle(isOn: Binding(get: { picked.contains(s.id) },
                                         set: { if $0 { picked.insert(s.id) } else { picked.remove(s.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(store.agentName(for: s)) · \(s.name)").lineLimit(1)
                            Text("\(s.agent.rawValue) · \(s.project) · \(host(s))\(busy ? " · 작업 중이라 제외" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(busy || s.conversationId == nil)
                }
                .frame(minHeight: 240)
                Toggle("원래 세션 종료 (/exit 전송 후 종료 확인) — 같은 대화를 두 곳에서 쓰지 않도록 권장", isOn: $closeOriginal)
            } else {
                List(results) { r in
                    Label(r.name + " — " + r.message, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? Color.primary : Color.orange)
                }
                .frame(minHeight: 240)
            }
            HStack {
                if running { ProgressView().controlSize(.small); Text("옮기는 중…").font(.caption) }
                Spacer()
                Button(results.isEmpty ? "취소" : "닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                if results.isEmpty {
                    Button("옮기기 (\(picked.count))") { run() }
                        .keyboardShortcut(.defaultAction).disabled(picked.isEmpty || running)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let movable = candidates.filter { $0.activity != .working && $0.conversationId != nil }.map(\.id)
            picked = Set(only.map { [$0] } ?? movable).intersection(movable)
        }
    }

    private func host(_ s: AgentSession) -> String {
        guard let pid = s.pid else { return "터미널 정보 없음" }
        let env = ProcessEnv.of(pid)
        if env["TMUX"] != nil { return "tmux" }
        if env["ORCA_TERMINAL_HANDLE"] != nil { return "Orca" }
        if env["CMUX_SURFACE_ID"] != nil { return "cmux" }
        return "기타 터미널"
    }

    private func run() {
        running = true
        let targets = candidates.filter { picked.contains($0.id) }
        Task {
            results = await store.migrate(targets, closeOriginal: closeOriginal)
            running = false
        }
    }
}


/// Right-click menu for an agent, used on the world map and in the sidebar.
struct AgentMenu: View {
    @ObservedObject var store: SessionStore
    let session: AgentSession
    var openDialogue: (() -> Void)? = nil
    @Binding var ending: AgentSession?
    @Binding var migrating: AgentSession?

    var body: some View {
        if let openDialogue { Button("대화하기", action: openDialogue) }
        Button("터미널 보기") { store.selection = store.pane(for: session) }
        Divider()
        Button("클론으로 새 에이전트 만들기") { store.clone(session) }
            .disabled(session.conversationId == nil)
        Button("진행 요약 수정…") { store.editingSummary = session }
        if session.hostedName == nil, session.conversationId != nil {
            Button("수혁으로 옮기기…") { migrating = session }
        }
        Divider()
        Button("세션 종료…", role: .destructive) { ending = session }
            .disabled(session.hostedName == nil && !SessionInput.canSend(session))
    }
}

extension View {
    /// Confirmation + result for ending a session from a context menu.
    func endSessionDialog(store: SessionStore, ending: Binding<AgentSession?>, migrating: Binding<AgentSession?>) -> some View {
        modifier(EndSessionDialog(store: store, ending: ending, migrating: migrating))
    }
}

struct EndSessionDialog: ViewModifier {
    @ObservedObject var store: SessionStore
    @Binding var ending: AgentSession?
    @Binding var migrating: AgentSession?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("\(ending.map { store.agentName(for: $0) } ?? "")의 세션을 종료할까요?",
                                isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                                presenting: ending) { s in
                Button("종료", role: .destructive) {
                    Task { failure = await store.end(s) }
                }
            } message: { s in
                Text("\(s.name)\n에이전트에 \(s.agent == .claude ? "/exit" : "/quit")를 보내 정상 종료함. 대화 기록은 남아 '최근 대화'에서 이어서 열 수 있음.")
            }
            .alert("세션을 끝내지 못함", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("확인") { failure = nil }
            } message: { Text(failure ?? "") }
            .sheet(item: $migrating) { s in MigrationSheet(store: store, only: s.id) }
            .sheet(item: $store.editingSummary) { s in SummarySheet(store: store, session: s) }
    }
}


/// Edit the one-line progress summary shown for an agent (hover card, status card, sidebar, dialogue).
struct SummarySheet: View {
    @ObservedObject var store: SessionStore
    let session: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(store.agentName(for: session))의 진행 요약").font(.title3.bold())
            if let g = session.generatedName ?? Optional(session.name) {
                Text("자동 제목: \(g)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("예: 결함 시각화 2차 — 리뷰 반영 중", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("자동 제목으로 되돌리기") { text = ""; save() }
                    .disabled(store.summary(for: session) == nil)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { text = store.summary(for: session) ?? "" }
    }

    private func save() {
        store.setSummary(text, for: session)
        dismiss()
    }
}
