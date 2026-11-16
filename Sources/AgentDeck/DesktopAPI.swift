import Foundation

/// What the desktop page (DesktopPage, Windows 수혁) needs beyond the phone's API: the Mac's sidebar as it is laid
/// out (same sections, sort and grouping as WorkspaceView), more per-agent detail, and resuming a recent conversation.
@MainActor
enum DesktopAPI {
    /// Index into `projectColor`'s palette for this folder (same hash), so the page's name pills match the Mac's.
    nonisolated static func colorIndex(_ cwd: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in cwd.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % 10)
    }

    /// Extra fields for an agent in /api/state: the hover card, the status card and the list view's cards.
    static func extras(_ store: SessionStore, _ s: AgentSession) -> [String: Any] {
        var o: [String: Any] = [
            "color": colorIndex(s.cwd), "estimated": s.estimated, "charName": store.character(for: s)?.name ?? "",
            "started": s.startedAt?.timeIntervalSince1970 ?? 0, "updated": s.updatedAt?.timeIntervalSince1970 ?? 0,
            "lastUser": s.lastUser ?? "", "lastAssistant": s.lastAssistant ?? "", "parent": s.parentId ?? "",
            "actionSymbol": s.action?.symbol ?? "",
        ]
        if let h = s.hostedName { o["term"] = h }
        if let w = store.working[s.id] { o["working"] = w }
        return o
    }

    /// GET /api/sidebar: 수혁 세션, 터미널, 다른 터미널 and 최근 대화, ordered as the Mac orders them.
    static func sidebar(_ store: SessionStore, sort: String?, ascending: Bool) -> [String: Any] {
        let by = sort.flatMap(SidebarSort.init(rawValue:)) ?? .lastActivity
        func groups(_ items: [SidebarItem]) -> [[String: Any]] {
            store.ordered(items, by: by, ascending: ascending).map { g in
                ["folder": g.folder ?? "", "items": g.items.map { item(store, $0) }] as [String: Any]
            }
        }
        let agents = store.hosted.filter { $0.agent != nil }.map(store.hostedItem)
        let shells = store.hosted.filter { $0.agent == nil && $0.name != TmuxEngine.panelName }.map(store.hostedItem)
        let external = store.sessions.filter { $0.hostedName == nil && $0.parentId == nil }.map { s in
            SidebarItem(id: s.id, tag: .external(s.id), title: s.name, subtitle: s.agent.rawValue + " · " + s.project,
                        session: s, cwd: s.cwd, created: s.startedAt, hosted: nil)
        }
        return [
            "hosted": groups(agents), "shells": groups(shells), "external": groups(external),
            "recent": store.recent.prefix(15).map { r in
                ["id": r.id, "agent": r.agent.rawValue, "title": r.title, "folder": (r.cwd as NSString).lastPathComponent,
                 "updated": r.updated.timeIntervalSince1970] as [String: Any]
            },
            "sorts": SidebarSort.allCases.map { ["key": $0.rawValue, "label": $0.label] },
            "sort": by.rawValue, "ascending": ascending,
            "panel": store.hosted.contains { $0.name == TmuxEngine.panelName },
        ]
    }

    private static func item(_ store: SessionStore, _ i: SidebarItem) -> [String: Any] {
        var o: [String: Any] = ["key": i.id, "title": i.title, "subtitle": i.subtitle]
        if let h = i.hosted { o["term"] = h.name }
        guard let s = i.session else { return o }
        o["id"] = s.id
        o["name"] = store.agentName(for: s)
        o["color"] = colorIndex(s.cwd)
        o["status"] = s.status.rawValue
        o["activityCode"] = "\(s.activity)"
        o["last"] = store.lastActivity(for: s)?.timeIntervalSince1970 ?? 0
        if let w = store.working[s.id] { o["working"] = w }
        o["children"] = store.children(of: s).map { c in
            ["id": c.id, "name": store.agentName(for: c), "title": c.name, "activityCode": "\(c.activity)"] as [String: Any]
        }
        o["subagents"] = s.subagents.map { w in ["title": w.title, "detail": w.action?.detail ?? ""] }
        return o
    }

    /// POST /api/resume: the sidebar's "이어서" on a recent conversation.
    static func resume(_ store: SessionStore, id: String) -> Bool {
        guard let r = store.recent.first(where: { $0.id == id }) else { return false }
        store.resume(r)
        return true
    }
}
