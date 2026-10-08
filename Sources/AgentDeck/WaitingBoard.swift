import SwiftUI

/// Top-left board on the world map: agents waiting on you. Ones stopped on a question come first (they are
/// blocked until you answer), then ones that finished and wait for the next instruction; longest wait first.
/// Click a row to go to the agent and open its conversation.
struct WaitingBoard: View {
    @ObservedObject var store: SessionStore
    let open: (AgentSession) -> Void
    @AppStorage("waitingBoardCollapsed") private var collapsed = false
    @State private var hovered: String?

    private static let gold = Color(red: 0.85, green: 0.68, blue: 0.25)
    private static let maxRows = 8

    var body: some View {
        let asking = store.sessions.filter { $0.status == .waiting }.sorted(by: Self.longestWait)
        let done = store.sessions.filter { $0.status != .waiting && $0.activity == .waiting }.sorted(by: Self.longestWait)
        let rows = asking.map { ($0, true) } + done.map { ($0, false) }
        VStack(alignment: .leading, spacing: 0) {
            header(count: rows.count, asking: asking.count)
            if !collapsed {
                Divider().overlay(Self.gold.opacity(0.4))
                if rows.isEmpty {
                    Text("기다리는 에이전트 없음 — 모두 일하는 중이거나 쉬는 중")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(Self.maxRows), id: \.0.id) { s, isAsking in row(s, asking: isAsking) }
                    }
                    .padding(.vertical, 4)
                    if rows.count > Self.maxRows {
                        Text("+\(rows.count - Self.maxRows)명 더 — 목록 화면에서 모두 보기")
                            .font(.caption2).foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            }
        }
        .frame(width: 280)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.gold.opacity(0.8), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {}  // keep clicks on the board from reaching the map (which closes cards)
    }

    private static func longestWait(_ a: AgentSession, _ b: AgentSession) -> Bool {
        (a.updatedAt ?? .distantPast) < (b.updatedAt ?? .distantPast)
    }

    private func header(count: Int, asking: Int) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(Self.gold)
                Text("입력 기다리는 에이전트").font(.caption.bold()).foregroundStyle(.white)
                Text("\(count)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(count == 0 ? .white.opacity(0.6) : .black)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(count == 0 ? Color.white.opacity(0.12) : Self.gold, in: Capsule())
                if asking > 0 {
                    Label("\(asking)", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.monospacedDigit().bold()).foregroundStyle(.red)
                        .help("선택지에서 멈춰 답을 기다리는 에이전트 \(asking)명")
                }
                Spacer(minLength: 4)
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ s: AgentSession, asking: Bool) -> some View {
        HStack(spacing: 8) {
            face(s, asking: asking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(store.agentName(for: s))
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(projectColor(s.cwd).opacity(0.85), in: Capsule())
                        .fixedSize()
                    Text(asking ? "선택 필요" : "다음 지시 대기")
                        .font(.caption2.bold())
                        .foregroundStyle(asking ? Color.red : Color.orange)
                        .fixedSize()
                }
                Text(s.name).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(s.updatedAt.map(SessionRow.ago) ?? "")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(hovered == s.id ? Color.white.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
        .onTapGesture { open(s) }
        .help(s.lastAssistant.map { "마지막 답변: " + $0 } ?? s.name)
    }

    private func face(_ s: AgentSession, asking: Bool) -> some View {
        let ring = asking ? Color.red : Color.orange
        return ZStack(alignment: .topTrailing) {
            Group {
                if let c = store.character(for: s), let img = Art.image("portraits/\(c.id)") ?? Art.image("sprites/\(c.id)") {
                    Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.overlay(Text(String(store.agentName(for: s).prefix(1))).font(.caption.bold()).foregroundStyle(.white))
                }
            }
            .frame(width: 30, height: 30)
            .background(Color(red: 0.15, green: 0.13, blue: 0.2))
            .clipShape(Circle())
            .overlay(Circle().stroke(ring, lineWidth: 1.5))
            if asking {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.white, .red)
                    .symbolEffect(.pulse, isActive: true)
                    .offset(x: 4, y: -4)
            }
        }
    }
}
