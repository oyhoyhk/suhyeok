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
    @State private var showNew = false

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
                    }
                }
                Section("다른 터미널") {
                    ForEach(store.sessions.filter { $0.hostedName == nil }) { s in
                        SessionRow(title: s.name, subtitle: s.agent.rawValue + " · " + s.project, session: s, store: store)
                            .tag(Pane.external(s.id))
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
        } detail: {
            switch store.selection {
            case .world: WorldView(store: store)
            case .list: BoardView(store: store)
            case .hosted(let name): HostedSessionView(store: store, name: name)
            case .external(let id): ExternalSessionView(store: store, id: id)
            }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet(store: store) }
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

struct HostedSessionView: View {
    @ObservedObject var store: SessionStore
    let name: String
    @State private var confirmKill = false

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
                Text((h?.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(role: .destructive) { confirmKill = true } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless).help("세션 종료")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if h == nil {
                Text("종료된 세션").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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

    var body: some View {
        if let s = store.sessions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(s.activity.color).frame(width: 8, height: 8)
                    Text(store.agentName(for: s)).font(.headline)
                    Text(s.name).lineLimit(1)
                    Spacer()
                    if s.conversationId != nil {
                        Button("수혁에서 이어서 열기") { confirmMove = true }
                    }
                }
                Text("다른 터미널에서 실행 중인 세션 — 여기서는 보기만 가능")
                    .font(.caption).foregroundStyle(.secondary)
                TerminalPanel(session: s)
            }
            .padding(12)
            .confirmationDialog("수혁에서 이 대화를 이어서 열까요?", isPresented: $confirmMove) {
                Button("이어서 열기") { store.resume(conversationOf: s) }
            } message: {
                Text("원래 터미널의 세션은 아직 실행 중임. 같은 대화를 두 곳에서 동시에 쓰면 기록이 꼬일 수 있으니, 연 뒤 원래 탭에서 /exit 로 종료할 것.")
            }
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
