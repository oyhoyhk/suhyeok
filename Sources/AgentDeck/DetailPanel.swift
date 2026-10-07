import SwiftUI

/// Shown while hovering an avatar: who it is and what it is mainly working on.
struct HoverCard: View {
    let session: AgentSession
    let agentName: String
    var huntLine: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(agentName).font(.headline)
                Circle().fill(session.activity.color).frame(width: 7, height: 7)
                Text(session.activity.label).font(.caption).foregroundStyle(.secondary)
            }
            Text(session.name).font(.callout.weight(.semibold)).lineLimit(2)
            Text(session.project).font(.caption.monospaced()).foregroundStyle(projectColor(session.cwd))
            if let huntLine { Label(huntLine, systemImage: "diamond.fill").font(.caption).foregroundStyle(.cyan) }
            if session.activity == .working, let a = session.action {
                Label(a.detail, systemImage: a.symbol).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if let u = session.lastUser {
                Text("지시: " + u).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .allowsHitTesting(false)
    }
}

/// Small status window opened by clicking an avatar.
struct StatusCard: View {
    let session: AgentSession
    let agentName: String
    var huntLine: String? = nil
    let character: Character?
    let close: () -> Void
    let openTerminal: () -> Void
    @AppStorage(OpenMode.storageKey) private var openMode = OpenMode.dialogue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                portrait.frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(agentName).font(.title3.bold())
                    if let c = character { Text(c.name).font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 5) {
                        Circle().fill(session.activity.color).frame(width: 8, height: 8)
                        Text(session.status == .waiting ? "선택 기다리는 중"
                             : session.activity.label + (session.status == .shell ? " · 백그라운드 셸 실행 중" : ""))
                            .font(.caption.bold()).foregroundStyle(session.activity.color)
                        Text(session.agent.rawValue + (session.estimated ? " · 추정" : ""))
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let started = session.startedAt {
                        Text("가동 \(duration(since: started)) · 현재 상태 \(duration(since: session.updatedAt ?? started))째")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Divider()
            Text(session.name).font(.callout.weight(.semibold)).lineLimit(2)
            if session.activity == .working, let a = session.action {
                Label("지금: " + a.detail, systemImage: a.symbol).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let huntLine { Label(huntLine, systemImage: "diamond.fill").font(.caption.weight(.semibold)).foregroundStyle(.cyan) }
            if let u = session.lastUser { line("person.fill", u, 2) }
            if let a = session.lastAssistant { line("sparkle", a, 4) }
            Button {
                openTerminal()
            } label: {
                Label(openMode == OpenMode.dialogue.rawValue ? "대화하기" : "터미널 보기",
                      systemImage: openMode == OpenMode.dialogue.rawValue ? "bubble.left.and.bubble.right.fill" : "terminal")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(session.pid == nil && session.transcriptPath == nil)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.activity.color.opacity(0.6), lineWidth: 1.5))
        .shadow(radius: 8)
    }

    @ViewBuilder private var portrait: some View {
        if let c = character, let img = Art.image("portraits/\(c.id)") ?? Art.image("sprites/\(c.id)") {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(session.activity.color.opacity(0.3))
                .overlay(Text(String(agentName.prefix(1))).font(.title.bold()))
        }
    }

    private func line(_ icon: String, _ text: String, _ limit: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary).frame(width: 12).padding(.top, 3)
            Text(text).font(.callout).lineLimit(limit).textSelection(.enabled)
        }
    }
}

func duration(since date: Date) -> String {
    let s = max(0, Int(-date.timeIntervalSinceNow))
    if s < 60 { return "\(s)초" }
    if s < 3600 { return "\(s / 60)분" }
    if s < 86400 { return "\(s / 3600)시간 \(s % 3600 / 60)분" }
    return "\(s / 86400)일"
}

/// Live terminal screen when the host terminal can be read, otherwise (or on request) the conversation log.
struct TerminalPanel: View {
    let session: AgentSession
    @State private var mode: Mode = .auto
    @State private var text: String?
    @State private var source = ""

    enum Mode: Hashable { case auto, transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $mode) {
                    Text("터미널").tag(Mode.auto)
                    Text("대화 기록").tag(Mode.transcript)
                }
                .pickerStyle(.segmented).fixedSize()
                Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text ?? "불러오는 중…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(white: 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8))
                .task(id: TaskKey(id: session.id, mode: mode)) {
                    while !Task.isCancelled {
                        let (screen, from) = await Task.detached { [session, mode] in TerminalPanel.load(session, mode) }.value
                        let changed = screen != text
                        text = screen
                        source = from
                        if changed { proxy.scrollTo("bottom", anchor: .bottom) }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }
    }

    private struct TaskKey: Hashable { let id: String; let mode: Mode }

    nonisolated static func load(_ s: AgentSession, _ mode: Mode) -> (String, String) {
        var note = ""
        if mode == .auto, let pid = s.pid {
            switch TerminalSource.read(pid: pid) {
            case .text(let t, let host): return (t, "\(host) 터미널 화면")
            case .denied(let host, let hint): note = "\(host) 화면을 읽지 못해 대화 기록 표시 — \(hint)"
            case .unsupported: note = "화면 읽기를 지원하지 않는 터미널이라 대화 기록 표시"
            }
        } else if mode == .auto {
            note = "터미널 정보가 없는 세션이라 대화 기록 표시"
        }
        guard let path = s.transcriptPath else { return ("대화 기록 파일을 찾지 못함", note) }
        return (TranscriptRenderer.render(path: path, agent: s.agent), note.isEmpty ? "대화 기록" : note)
    }
}
