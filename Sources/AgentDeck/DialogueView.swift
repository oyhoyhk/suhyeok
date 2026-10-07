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
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: items.count) { proxy.scrollTo("end", anchor: .bottom) }
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
                Button("보내기") { submit(s) }.disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 4) {
                ForEach(SessionInput.Key.allCases, id: \.self) { key in
                    Button(key.label) { press(s, key) }.controlSize(.small).disabled(!canSend)
                }
                Spacer()
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
        Task.detached {
            let ok = SessionInput.send(s, text: text)
            await MainActor.run { notice = ok ? nil : "보내지 못함 — 터미널 접근이 거부됨 (cmux는 재시작 후 가능)" }
        }
    }

    private func press(_ s: AgentSession, _ key: SessionInput.Key) {
        showScreen = true  // keys answer menus; show what they act on
        Task.detached { _ = SessionInput.press(s, key) }
    }

    private func poll(_ s: AgentSession) async {
        while !Task.isCancelled {
            let (newItems, newScreen) = await Task.detached { () -> ([ChatItem], String?) in
                let items = s.transcriptPath.map { TranscriptRenderer.items(path: $0, agent: s.agent) } ?? []
                var screen: String?
                if let pid = s.pid, case .text(let t, _) = TerminalSource.read(pid: pid, lines: 30) {
                    screen = t.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
                }
                return (items, screen)
            }.value
            if newItems != items { loaded = newItems }
            screen = newScreen
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
