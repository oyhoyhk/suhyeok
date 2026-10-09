import SwiftUI

/// How the sidebar orders agents (수혁 세션 and 다른 터미널). Kept across launches.
enum SidebarSort: String, CaseIterable {
    case folder, lastActivity, created, name, status

    static let key = "sidebarSort"
    static let ascendingKey = "sidebarSortAscending"

    var label: String {
        switch self {
        case .folder: return "폴더별"
        case .lastActivity: return "마지막 응답 순"
        case .created: return "생성 순"
        case .name: return "이름 순"
        case .status: return "상태 순"
        }
    }

    var icon: String {
        switch self {
        case .folder: return "folder"
        case .lastActivity: return "clock.arrow.circlepath"
        case .created: return "calendar.badge.plus"
        case .name: return "textformat"
        case .status: return "circle.lefthalf.filled"
        }
    }
}

/// One agent row in the sidebar, whether it runs on 수혁's tmux server or in another terminal.
struct SidebarItem: Identifiable {
    let id: String
    let tag: Pane
    let title: String
    let subtitle: String
    let session: AgentSession?
    let cwd: String
    let created: Date?
    let hosted: TmuxEngine.Hosted?
}

extension SessionStore {
    /// Items in the chosen order; for `.folder`, grouped under their folder (folders in order, newest activity
    /// first inside each). Other orders come back as a single group with no folder name.
    func ordered(_ items: [SidebarItem], by sort: SidebarSort, ascending: Bool) -> [(folder: String?, items: [SidebarItem])] {
        func last(_ i: SidebarItem) -> Date { i.session.flatMap { lastActivity(for: $0) } ?? i.created ?? .distantPast }
        func name(_ i: SidebarItem) -> String { i.session.map { agentName(for: $0) } ?? i.title }
        // Needs you first: stopped on a question, then working, waiting, resting.
        func rank(_ i: SidebarItem) -> Int {
            guard let s = i.session else { return 9 }
            return s.status == .waiting ? 0 : s.activity.sortRank + 1
        }
        func by<T: Comparable>(_ key: @escaping (SidebarItem) -> T, then: @escaping (SidebarItem, SidebarItem) -> Bool) -> (SidebarItem, SidebarItem) -> Bool {
            { a, b in
                let ka = key(a), kb = key(b)
                if ka == kb { return then(a, b) }
                return ascending ? ka < kb : ka > kb
            }
        }
        let newestFirst: (SidebarItem, SidebarItem) -> Bool = { last($0) > last($1) }
        switch sort {
        case .folder:
            let groups = Dictionary(grouping: items) { ($0.cwd as NSString).lastPathComponent }
            let folders = groups.keys.sorted { ascending ? $0.localizedStandardCompare($1) == .orderedAscending
                                                         : $0.localizedStandardCompare($1) == .orderedDescending }
            return folders.map { ($0, groups[$0]!.sorted(by: newestFirst)) }
        case .lastActivity:
            return [(nil, items.sorted(by: by(last, then: { name($0) < name($1) })))]
        case .created:
            return [(nil, items.sorted(by: by({ $0.created ?? .distantPast }, then: newestFirst)))]
        case .name:
            return [(nil, items.sorted { a, b in
                let r = name(a).localizedStandardCompare(name(b))
                return r == .orderedSame ? newestFirst(a, b) : (ascending ? r == .orderedAscending : r == .orderedDescending)
            })]
        case .status:
            return [(nil, items.sorted(by: by(rank, then: newestFirst)))]
        }
    }
}

/// The sort control at the top of the sidebar: the order to use and its direction.
struct SidebarSortBar: View {
    @AppStorage(SidebarSort.key) private var sort = SidebarSort.lastActivity.rawValue
    @AppStorage(SidebarSort.ascendingKey) private var ascending = false

    var body: some View {
        let current = SidebarSort(rawValue: sort) ?? .lastActivity
        HStack(spacing: 6) {
            Menu {
                Picker("정렬", selection: $sort) {
                    ForEach(SidebarSort.allCases, id: \.rawValue) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(current.label, systemImage: current.icon).font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(directionHelp(current))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func directionHelp(_ s: SidebarSort) -> String {
        switch s {
        case .folder, .name: return ascending ? "가 → 하 (누르면 반대로)" : "하 → 가 (누르면 반대로)"
        case .lastActivity, .created: return ascending ? "오래된 것 먼저 (누르면 최신 먼저)" : "최신 먼저 (누르면 오래된 것 먼저)"
        case .status: return ascending ? "선택 필요 → 작업 중 → 대기 → 휴식" : "휴식 → 대기 → 작업 중 → 선택 필요"
        }
    }
}
