import SwiftUI

struct BoardView: View {
    @ObservedObject var store: SessionStore
    @State private var busyOnly = false

    private var visible: [AgentSession] {
        busyOnly ? store.sessions.filter { $0.activity == .working } : store.sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty {
                Spacer()
                Text("떠 있는 세션 없음").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(visible) { SessionCard(session: $0) }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ForEach(Activity.allCases, id: \.self) { s in
                Label("\(s.label) \(store.sessions.filter { $0.activity == s }.count)", systemImage: "circle.fill")
                    .foregroundStyle(s.color)
                    .font(.callout.monospacedDigit())
            }
            Spacer()
            Toggle("작업 중만", isOn: $busyOnly).toggleStyle(.switch).controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("갱신 \(Int(-store.lastRefresh.timeIntervalSinceNow))초 전")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct SessionCard: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(session.activity.color).frame(width: 9, height: 9)
                Text(session.activity.label).font(.caption.bold()).foregroundStyle(session.activity.color)
                Text(session.agent.rawValue + (session.estimated ? " · 추정" : ""))
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                if let updated = session.updatedAt {
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Text(relative(updated)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Text(session.name).font(.headline).lineLimit(1)
            Text(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let u = session.lastUser {
                message(icon: "person.fill", text: u, lines: 2)
            }
            if let a = session.lastAssistant {
                message(icon: "sparkle", text: a, lines: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.activity.color.opacity(session.activity == .working ? 0.7 : 0.15), lineWidth: 1.5))
        .help(session.lastAssistant ?? "")
    }

    private func message(icon: String, text: String, lines: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary).frame(width: 12).padding(.top, 2)
            Text(text).font(.callout).lineLimit(lines).textSelection(.enabled)
        }
    }

    private func relative(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }
}

extension Activity {
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .resting: return .gray
        }
    }
}
