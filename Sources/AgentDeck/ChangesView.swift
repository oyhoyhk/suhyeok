import SwiftUI

/// The session folder's uncommitted changes beside the agent: read the diff, click lines to leave notes,
/// send the notes to the agent as one instruction, and commit the files you pick.
struct ChangesView: View {
    let cwd: String
    let session: AgentSession?
    var onClose: (() -> Void)? = nil

    @State private var snap: GitChanges.Snapshot?
    @State private var error: String?
    @State private var collapsed: Set<String> = []
    /// Files left out of the next commit; anything new is in by default.
    @State private var excluded: Set<String> = []
    @State private var comments: [ReviewComment] = []
    /// The line whose note is being written (an existing note is edited in place).
    @State private var editing: ReviewComment?
    @State private var message = ""
    @State private var notice: (text: String, failed: Bool)?
    @State private var committing = false
    @State private var reloads = 0

    init(cwd: String, session: AgentSession?, onClose: (() -> Void)? = nil, startNote: ReviewComment? = nil) {
        self.cwd = cwd
        self.session = session
        self.onClose = onClose
        _editing = State(initialValue: startNote)
    }

    private var files: [GitChanges.FileDiff] { snap?.files ?? [] }
    private var picked: [String] { files.map(\.path).filter { !excluded.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: "\(cwd)|\(reloads)") { await poll() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("변경사항", systemImage: "plusminus").font(.headline)
            if !files.isEmpty {
                Text("파일 \(files.count)개").font(.caption).foregroundStyle(.secondary)
                Text("+\(files.reduce(0) { $0 + $1.added })").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(files.reduce(0) { $0 + $1.removed })").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
            Spacer()
            Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("다시 읽기")
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("닫기")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let error {
            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        } else if snap == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("변경사항 읽는 중…") }.foregroundStyle(.secondary)
        } else if files.isEmpty {
            Text("마지막 커밋 이후 바뀐 파일 없음").foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files) { f in
                        // One lazy item per file: rows inside share ids only within their own VStack.
                        Section {
                            if !collapsed.contains(f.path) { VStack(alignment: .leading, spacing: 0) { fileBody(f) } }
                        } header: { fileHeader(f) }
                    }
                    if let more = snap?.moreUntracked, more > 0 {
                        Text("추적하지 않는 파일 \(more)개 더 있음 — .gitignore에 빠진 폴더가 없는지 확인할 것")
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
            }
        }
    }

    private func fileHeader(_ f: GitChanges.FileDiff) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { !excluded.contains(f.path) },
                                     set: { if $0 { excluded.remove(f.path) } else { excluded.insert(f.path) } }))
                .toggleStyle(.checkbox).labelsHidden().help("다음 커밋에 넣기")
            Button {
                if collapsed.contains(f.path) { collapsed.remove(f.path) } else { collapsed.insert(f.path) }
            } label: {
                Image(systemName: collapsed.contains(f.path) ? "chevron.right" : "chevron.down").frame(width: 12)
            }
            .buttonStyle(.borderless)
            Text(f.status.rawValue).font(.caption.monospaced().bold()).foregroundStyle(Self.color(f.status))
                .help(Self.label(f.status))
            Text(f.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if f.added > 0 { Text("+\(f.added)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
            if f.removed > 0 { Text("−\(f.removed)").font(.caption.monospacedDigit()).foregroundStyle(.red) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder private func fileBody(_ f: GitChanges.FileDiff) -> some View {
        if f.binary {
            Text("바이너리 파일 — 내용 비교 없음").font(.caption).foregroundStyle(.secondary).padding(10)
        } else if f.hunks.isEmpty {
            Text(f.status == .deleted || f.status == .untracked ? "빈 파일" : "내용 변경 없음 (권한만 바뀜)")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        ForEach(Array(f.hunks.enumerated()), id: \.offset) { _, h in
            Text(h.header).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.08))
            ForEach(Array(h.lines.enumerated()), id: \.offset) { _, line in
                lineRow(f.path, line)
                let id = ReviewComment(path: f.path, line: line, body: "").id
                if editing?.id == id { editor() }
                else if let c = comments.first(where: { $0.id == id }) { note(c) }
            }
        }
        if f.cut > 0 {
            Text("\(f.cut)줄 더 있음 — 너무 길어 생략").font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private func lineRow(_ path: String, _ line: GitChanges.Line) -> some View {
        let (sign, tint): (String, Color) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("−", .red)
        case .context: (" ", .clear)
        }
        return Button {
            let existing = comments.first { $0.id == ReviewComment(path: path, line: line, body: "").id }
            editing = existing ?? ReviewComment(path: path, line: line, body: "")
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
                Text(line.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
                Text(sign).frame(width: 18).foregroundStyle(tint)
                Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.trailing, 8).padding(.vertical, 1)
            .background(tint.opacity(0.13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("클릭해서 이 줄에 코멘트 달기")
    }

    private func editor() -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("이 줄에 대한 요청 (Enter로 추가)", text: Binding(get: { editing?.body ?? "" }, set: { editing?.body = $0 }),
                      axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNote)
            HStack {
                Button("취소") { editing = nil }.keyboardShortcut(.cancelAction)
                Button("추가", action: saveNote).disabled((editing?.body ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8).padding(.leading, 98)
        .background(Color.yellow.opacity(0.08))
    }

    private func note(_ c: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
            Text(c.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { comments.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("코멘트 지우기")
        }
        .font(.callout)
        .padding(8).padding(.leading, 98)
        .background(Color.yellow.opacity(0.12))
        .onTapGesture { editing = c }
    }

    private func saveNote() {
        guard var c = editing else { return }
        c.body = c.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.body.isEmpty else { return }
        if let i = comments.firstIndex(where: { $0.id == c.id }) { comments[i] = c } else { comments.append(c) }
        editing = nil
    }

    private var footer: some View {
        let canSend = session.map(SessionInput.canSend) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Text(notice.text).font(.caption).foregroundStyle(notice.failed ? .red : .secondary)
                    .textSelection(.enabled).lineLimit(8)
            }
            HStack {
                Text("코멘트 \(comments.count)개").font(.caption).foregroundStyle(.secondary)
                if !comments.isEmpty { Button("모두 지우기") { comments = [] }.buttonStyle(.link).font(.caption) }
                Spacer()
                Button("에이전트에게 보내기", action: sendNotes)
                    .disabled(comments.isEmpty || !canSend)
                    .help(canSend ? "코멘트를 한 번에 지시로 보냄" : "이 세션에는 입력을 보낼 수 없음")
            }
            HStack {
                TextField("커밋 메시지", text: $message).textFieldStyle(.roundedBorder).onSubmit(commit)
                Button(committing ? "커밋 중…" : "커밋 (\(picked.count)개 파일)", action: commit)
                    .disabled(committing || picked.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .controlSize(.small)
        .padding(10)
    }

    private func sendNotes() {
        guard let s = session, !comments.isEmpty else { return }
        let text = ReviewComment.message(comments)
        Task {
            let ok = await Task.detached { SessionInput.send(s, text: text) }.value
            if ok { comments = [] }
            notice = ok ? (String(localized: "코멘트를 보냄 — 에이전트가 고치면 diff가 자동으로 바뀜"), false)
                        : (String(localized: "보내지 못함 — 터미널 접근이 거부됨"), true)
        }
    }

    private func commit() {
        guard let root = snap?.root, !picked.isEmpty, !committing else { return }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines), paths = picked
        guard !msg.isEmpty else { return }
        committing = true
        Task {
            let r = await Task.detached { GitChanges.commit(root: root, paths: paths, message: msg) }.value
            committing = false
            switch r {
            case .success(let summary):
                message = ""
                notice = (String(localized: "커밋함: \(summary)"), false)
                reloads += 1
            case .failure(let f):
                notice = (String(localized: "커밋하지 못함 — \(f.message)"), true)
            }
        }
    }

    /// Re-reads every few seconds, so the agent's edits show up as it makes them.
    private func poll() async {
        while !Task.isCancelled {
            let r = await Task.detached { [cwd] in GitChanges.load(cwd: cwd) }.value
            switch r {
            case .success(let s): if s != snap { snap = s }; error = nil
            case .failure(let f): error = f.message
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    static func color(_ s: GitChanges.Status) -> Color {
        switch s {
        case .modified: .orange
        case .added, .untracked: .green
        case .deleted: .red
        }
    }

    static func label(_ s: GitChanges.Status) -> String {
        switch s {
        case .modified: String(localized: "수정됨")
        case .added: String(localized: "새 파일 (스테이지됨)")
        case .untracked: String(localized: "새 파일 (git이 아직 추적하지 않음)")
        case .deleted: String(localized: "삭제됨")
        }
    }
}
