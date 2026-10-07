import SwiftUI

/// How a session opens by default; set in Settings (⌘,).
enum OpenMode: String, CaseIterable {
    case dialogue, terminal
    var label: String { self == .dialogue ? "대화창" : "터미널" }
    static let storageKey = "openMode"
}

struct SettingsView: View {
    @AppStorage(OpenMode.storageKey) private var openMode = OpenMode.dialogue.rawValue

    var body: some View {
        Form {
            Picker("세션 여는 방식", selection: $openMode) {
                ForEach(OpenMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            Text("대화창: 에이전트와 RPG 대화하듯 질문·답을 주고받음. 권한 확인 같은 메뉴는 아래 빠른 키로 답함.\n터미널: 에이전트 TUI를 그대로 조작.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// RPG-style conversation with one agent: portrait, alternating messages, an input line and quick keys.
struct DialogueView: View {
    @ObservedObject var store: SessionStore
    let sessionId: String
    var onClose: (() -> Void)? = nil
    var onTerminal: (() -> Void)? = nil
    /// Items to show before the first poll (offscreen snapshots render a single frame).
    var preload: [ChatItem] = []
    /// Side-panel size; nil when the view fills a page and has no size switch.
    var large: Bool? = nil
    var onToggleSize: (() -> Void)? = nil
    /// PIP mode: dragging the header moves the window.
    var onHeaderDrag: ((CGSize) -> Void)? = nil
    var onHeaderDragEnd: ((CGSize) -> Void)? = nil

    @State private var loaded: [ChatItem]?
    private var items: [ChatItem] { loaded ?? preload }
    @State private var draft = ""
    @State private var screen: String?
    @State private var menu: TerminalMenu?
    /// Sent from here but not yet in the log; shown right away so the message never seems lost.
    @State private var pending: [Pending] = []
    @StateObject private var dictation = Dictation()
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage("readReplies") private var readReplies = false
    @State private var lastSpokenCount: Int?
    @State private var live: LiveReply?
    @State private var showScreen = false
    @State private var notice: String?
    @FocusState private var focused: Bool

    private var session: AgentSession? { store.sessions.first { $0.id == sessionId } }

    var body: some View {
        if let s = session {
            HStack(alignment: .top, spacing: 0) {
                if large != false { portrait(s) }  // small panel: the avatar moves into the header
                VStack(spacing: 0) {
                    header(s)
                    conversation(s)
                    if showScreen { screenPreview }
                    inputBar(s)
                }
            }
            .background(Color(red: 0.07, green: 0.10, blue: 0.22))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.68, blue: 0.25), lineWidth: 3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
            .task(id: sessionId) { await poll(s) }
            .onChange(of: dictation.text) { _, t in if dictation.listening || !t.isEmpty { draft = t } }
            .onAppear { focused = true }
        } else {
            Text("종료된 세션").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: pieces

    private func portrait(_ s: AgentSession) -> some View {
        VStack(spacing: 8) {
            if let c = store.character(for: s), let img = Art.image("portraits/\(c.id)") ?? Art.image("sprites/\(c.id)") {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(store.agentName(for: s)).font(.title3.bold()).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            HStack(spacing: 5) {
                Circle().fill(s.activity.color).frame(width: 8, height: 8)
                Text(s.activity.label).font(.caption)
            }
            if let a = s.action, s.activity == .working {
                Text(a.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(width: large == true ? 150 : 190)
        .padding(14)
        .background(Color.black.opacity(0.25))
    }

    private func header(_ s: AgentSession) -> some View {
        HStack {
            if large == false {
                if let c = store.character(for: s), let img = Art.image("sprites/\(c.id)") {
                    Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit).frame(height: 30)
                }
                Text(store.agentName(for: s)).font(.headline).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                Circle().fill(s.activity.color).frame(width: 7, height: 7)
            }
            Text(s.name).font(.headline).lineLimit(1)
            if large != false { Text(s.project).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Spacer()
            if let large, let onToggleSize {
                Button(action: onToggleSize) {
                    Image(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless).help(large ? "작게 보기" : "크게 보기 (화면 절반)")
            }
            if let onTerminal { Button("터미널로", action: onTerminal).controlSize(.small) }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onHeaderDrag?($0.translation) }
            .onEnded { onHeaderDragEnd?($0.translation) })
        .onHover { inside in
            guard onHeaderDrag != nil else { return }
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private func conversation(_ s: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items.suffix(200)) { item in bubble(item, s) }
                    ForEach(pending) { p in pendingBubble(p) }
                    if let live { liveBubble(live, s) }
                    if let menu { menuCard(menu, s) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            // Open at the newest message and stay there as new ones arrive.
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: sessionId) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: live) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: pending.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: menu) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear {
                // Once more after layout settles; the first call can land before the bubbles are measured.
                proxy.scrollTo("end", anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func bubble(_ item: ChatItem, _ s: AgentSession) -> some View {
        switch item.role {
        case .me:
            HStack {
                Spacer(minLength: 60)
                Text(item.text).textSelection(.enabled)
                    .padding(10)
                    .background(Color(red: 0.55, green: 0.42, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        case .agent:
            VStack(alignment: .leading, spacing: 3) {
                Text(store.agentName(for: s)).font(.caption.bold()).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                Text(markdown(item.text)).textSelection(.enabled)
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.trailing, 60)
        case .tool:
            Label(item.text, systemImage: "hammer").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .result:
            EmptyView()  // outputs stay in the terminal view; the chat shows only what was done
        }
    }

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var failed = false
    }

    private func pendingBubble(_ p: Pending) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 3) {
                Text(p.text).textSelection(.enabled)
                    .padding(10)
                    .background(Color(red: 0.55, green: 0.42, blue: 0.12).opacity(p.failed ? 0.35 : 0.6),
                                in: RoundedRectangle(cornerRadius: 10))
                Text(p.failed ? "전달 실패" : "전달 중…").font(.caption2)
                    .foregroundStyle(p.failed ? Color.orange : Color.secondary)
            }
        }
    }

    /// The reply as it is being written, read from the terminal screen (the log only gets finished messages).
    @ViewBuilder private func liveBubble(_ l: LiveReply, _ s: AgentSession) -> some View {
        if !l.raw.isEmpty { liveTerminal(l, s) } else { liveText(l, s) }
    }

    /// While the agent works: the turn exactly as its terminal shows it (tool calls, output, text being written).
    private func liveTerminal(_ l: LiveReply, _ s: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(store.agentName(for: s)).font(.caption.bold()).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                ProgressView().controlSize(.mini)
                Text(l.status ?? "작업 중").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(l.raw)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
        }
    }

    private func liveText(_ l: LiveReply, _ s: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(store.agentName(for: s)).font(.caption.bold()).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                if let st = l.status {
                    ProgressView().controlSize(.mini)
                    Text(st).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !l.text.isEmpty {
                (Text(markdown(l.text)) + Text(" ▍").foregroundColor(Color(red: 1, green: 0.85, blue: 0.4)))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .padding(.trailing, 60)
    }

    /// The agent is asking to pick one option (permission prompt, question): clickable choices.
    private func menuCard(_ m: TerminalMenu, _ s: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("선택해 주세요", systemImage: "list.bullet.circle.fill").font(.caption.bold())
                .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            ForEach(Array(m.options.enumerated()), id: \.offset) { i, o in
                Button {
                    menu = nil
                    Task.detached { _ = SessionInput.choose(s, menu: m, index: i) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(o.label)").fontWeight(i == m.selected ? .semibold : .regular)
                        if let d = o.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.white.opacity(i == m.selected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!SessionInput.canSend(s))
            }
            Button("취소 (Esc)") { menu = nil; Task.detached { _ = SessionInput.press(s, .escape) } }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(10)
        .background(Color(red: 0.2, green: 0.16, blue: 0.05).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.85, green: 0.68, blue: 0.25), lineWidth: 1.5))
        .padding(.trailing, 40)
    }

    private var screenPreview: some View {
        ScrollView {
            Text(screen ?? "화면을 읽을 수 없는 터미널")
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 150)
        .background(Color.black.opacity(0.5))
    }

    private func inputBar(_ s: AgentSession) -> some View {
        let canSend = SessionInput.canSend(s)
        return VStack(alignment: .leading, spacing: 6) {
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if let e = dictation.error { Text(e).font(.caption).foregroundStyle(.orange) }
            if dictation.listening {
                Label("듣는 중… 말을 마치면 마이크를 다시 눌러 멈춤", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canSend ? "\(store.agentName(for: s))에게 지시하기 (Enter로 보내기)" : "이 터미널은 입력을 보낼 수 없음 — 보기만 가능",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .focused($focused)
                    .disabled(!canSend)
                    .onSubmit { submit(s) }
                Button { dictation.toggle() } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.listening ? Color.red : Color.primary)
                }
                .help(dictation.listening ? "받아쓰기 멈춤" : "말로 지시하기 (⌘D)")
                .keyboardShortcut("d")
                .disabled(!canSend)
                Button("보내기") { submit(s) }.disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 4) {
                ForEach(SessionInput.Key.allCases, id: \.self) { key in
                    Button(key.label) { press(s, key) }.controlSize(.small).disabled(!canSend)
                }
                Spacer()
                Toggle(isOn: $readReplies) { Label("답변 읽어 주기", systemImage: readReplies ? "speaker.wave.2.fill" : "speaker.slash") }
                    .toggleStyle(.button).controlSize(.small)
                if speaker.speaking { Button("그만 읽기") { speaker.stop() }.controlSize(.small) }
                Toggle("화면 보기", isOn: $showScreen).toggleStyle(.button).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.2))
    }

    // MARK: actions

    private func submit(_ s: AgentSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let p = Pending(text: text)
        pending.append(p)
        let blockedByMenu = menu != nil
        Task.detached {
            let ok = SessionInput.send(s, text: text)
            await MainActor.run {
                if !ok, let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
                notice = !ok ? "보내지 못함 — 터미널 접근이 거부됨 (cmux는 재시작 후 가능)"
                    : blockedByMenu ? "에이전트가 선택을 기다리는 중이라 메시지가 메뉴 뒤에 대기함 — 위 선택지를 먼저 고를 것" : nil
            }
        }
    }

    private func press(_ s: AgentSession, _ key: SessionInput.Key) {
        showScreen = true  // keys answer menus; show what they act on
        Task.detached { _ = SessionInput.press(s, key) }
    }

    private func poll(_ s: AgentSession) async {
        while !Task.isCancelled {
            let busy = store.sessions.first { $0.id == sessionId }?.status == .busy
            let lastAgent = items.last { $0.role == .agent }?.text
            let (newItems, newScreen, newMenu, newLive) = await Task.detached {
                () -> ([ChatItem], String?, TerminalMenu?, LiveReply?) in
                let items = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) } ?? []
                guard let pid = s.pid, case .text(let t, _) = TerminalSource.read(pid: pid, lines: 60) else {
                    return (items, nil, nil, nil)
                }
                let menu = TerminalMenu.parse(t)
                let lastLogged = items.last { $0.role == .agent }?.text ?? lastAgent
                var live = busy && menu == nil ? LiveReply.parse(t, alreadyLogged: lastLogged) : nil
                if busy && menu == nil {
                    live = live ?? LiveReply(text: "", status: nil)
                    live?.raw = LiveReply.turn(t)
                }
                let tail = t.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
                return (items, tail, menu, live)
            }.value
            if newItems != items {
                // Speak the newest agent reply once it is finished (in the log), not replies already there on open.
                let agentCount = newItems.filter { $0.role == .agent }.count
                if readReplies, let last = lastSpokenCount, agentCount > last,
                   let reply = newItems.last(where: { $0.role == .agent }) {
                    Speaker.shared.speak(reply.text, characterId: store.character(for: s)?.id)
                }
                lastSpokenCount = agentCount
                loaded = newItems
            } else if lastSpokenCount == nil {
                lastSpokenCount = newItems.filter { $0.role == .agent }.count
            }
            // A pending message is done once the log has it (as a prompt or a queued command).
            let mine = Set(newItems.filter { $0.role == .me }.suffix(30).map { $0.text.filter { !$0.isWhitespace } })
            pending.removeAll { !$0.failed && mine.contains($0.text.filter { !$0.isWhitespace }) }
            screen = newScreen
            if newMenu != menu { menu = newMenu }
            if newLive != live { live = newLive }
            // Fast while something is happening, so the reply appears as it is typed.
            try? await Task.sleep(for: .seconds(busy || newMenu != nil ? 0.5 : 1.5))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
