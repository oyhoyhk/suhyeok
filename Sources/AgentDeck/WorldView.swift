import AppKit
import SwiftUI

/// The world is one 16:9 town map (art/out/town.jpg), 1 world unit wide and 9/16 tall.
/// Standing spots and the walk grid come from art/walkmap.py (walkmap.json).
enum World {
    static let size = CGSize(width: 1, height: 9.0 / 16.0)
    static let image = "field_4k"
    static let minimap = "field"
    /// Avatar height in world units.
    static let avatarHeight: CGFloat = 0.034

    static func key(_ t: Hunt.Tier) -> String { ["low", "mid", "high"][t.rawValue] }
    static func boss(_ t: Hunt.Tier) -> CGRect { Pathfinder.shared.bosses[key(t)] ?? .zero }
    static func attackSpots(_ t: Hunt.Tier) -> [CGPoint] { Pathfinder.shared.spots("attack_" + key(t)) }
    static var campSpots: [CGPoint] { Pathfinder.shared.spots("camp") }

    /// Spot i of a list; past the end, agents stand in small steps beside the earlier ones.
    static func spot(_ list: [CGPoint], _ i: Int) -> CGPoint {
        guard !list.isEmpty else { return CGPoint(x: 0.5, y: 0.27) }
        var p = list[i % list.count]
        p.y += CGFloat(i / list.count) * 0.012
        return p
    }
}

/// Maps world units to view points: `scale` points per world unit, `center` is the world point in the middle.
struct Camera: Equatable {
    var center = CGPoint(x: 0.5, y: World.size.height / 2)
    var scale: CGFloat = 0

    func screen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: (p.y - center.y) * scale + size.height / 2)
    }
    func world(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / scale + center.x, y: (p.y - size.height / 2) / scale + center.y)
    }
    func visible(in size: CGSize) -> CGRect {
        let tl = world(.zero, in: size)
        return CGRect(x: tl.x, y: tl.y, width: size.width / scale, height: size.height / scale)
    }

    /// Smallest scale shows the whole world; largest shows a quarter of an area.
    static func limits(_ size: CGSize) -> ClosedRange<CGFloat> {
        let fitAll = min(size.width / World.size.width, size.height / World.size.height)
        return fitAll...(size.width * 6)  // closest: a sixth of the map across the view
    }

    mutating func clamp(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }  // not laid out yet
        let l = Camera.limits(size)
        scale = min(max(scale, l.lowerBound), l.upperBound)
        let half = CGSize(width: size.width / scale / 2, height: size.height / scale / 2)
        func c(_ v: CGFloat, _ h: CGFloat, _ total: CGFloat) -> CGFloat { h * 2 >= total ? total / 2 : min(max(v, h), total - h) }
        center = CGPoint(x: c(center.x, half.width, World.size.width), y: c(center.y, half.height, World.size.height))
    }
}

struct WorldView: View {
    @ObservedObject var store: SessionStore
    @State private var selectedId: String?
    @State private var hoveredId: String?
    @State private var dialogueId: String?
    @AppStorage("dialogueLarge") private var dialogueLarge = true
    /// Docked panel size: width as a fraction of the view (0.4–0.7), height as a fraction of the room
    /// between the status counts and the minimap (0.5 of the view up to all of that room).
    @AppStorage("panelWidth") private var panelWidth = 0.5
    @AppStorage("panelHeight") private var panelHeight = 1.0
    @State private var resizeStart: (Double, Double)?
    @AppStorage("pipX") private var pipX = 0.78  // PIP centre, as a fraction of the world view
    @AppStorage("pipY") private var pipY = 0.72
    @State private var pipDrag: CGSize = .zero
    @State private var ending: AgentSession?
    @State private var migrating: AgentSession?
    @AppStorage(OpenMode.storageKey) private var openMode = OpenMode.dialogue.rawValue
    @StateObject private var input = MapInput()
    @State private var dragStart: CGPoint?
    @State private var walker = Walker()
    /// Latest drawn positions, for hit-testing, cards, the minimap and edge markers.
    @State private var drawn: [String: CGPoint] = [:]
    /// Agents whose session just ended: they fade away where they stood.
    @State private var departures: [Departure] = []
    @State private var lastSeen: [String: (Character?, CGPoint)] = [:]

    init(store: SessionStore, initialSelection: String? = nil, initialDialogue: String? = nil) {
        self.store = store
        _selectedId = State(initialValue: initialSelection)
        _dialogueId = State(initialValue: initialDialogue)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cam = input.camera.scale == 0 ? initialCamera(size) : input.camera
            let items = placed()
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color(red: 0.05, green: 0.04, blue: 0.08)
                    let tl = cam.screen(.zero, in: size)
                    mapImage
                        .frame(width: World.size.width * cam.scale, height: World.size.height * cam.scale)
                        .position(x: tl.x + World.size.width * cam.scale / 2, y: tl.y + World.size.height * cam.scale / 2)
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let positions = walker.step(targets: items.map { ($0.session.id, $0.point) }, now: t)
                        ZStack(alignment: .topLeading) {
                            ForEach(Hunt.Tier.allCases, id: \.self) { tier in
                                let r = World.boss(tier)
                                let attackers = items.filter { $0.tier == tier && $0.session.status == .busy
                                    && positions[$0.session.id] == $0.point }
                                BossView(tier: tier, time: t, size: CGSize(width: r.width * cam.scale, height: r.height * cam.scale),
                                         attackers: attackers.map { (cam.screen($0.point, in: size), Double(abs($0.session.id.hashValue % 100)) / 15) },
                                         center: cam.screen(CGPoint(x: r.midX, y: r.midY), in: size))
                            }
                            // Lower on the map = closer to the viewer = drawn on top.
                            ForEach(items.sorted { (positions[$0.session.id] ?? $0.point).y < (positions[$1.session.id] ?? $1.point).y },
                                    id: \.session.id) { item in
                                let p = positions[item.session.id] ?? item.point
                                let kb = knockback(item, at: p, time: t)
                                let sp = cam.screen(CGPoint(x: p.x + kb, y: p.y), in: size)
                                Avatar(session: item.session, character: item.character, pose: pose(for: item, at: p),
                                       agentName: store.agentName(for: item.session), time: t,
                                       height: cam.scale * World.avatarHeight, selected: item.session.id == selectedId,
                                       walking: p != item.point,
                                       facing: p != item.point ? (walker.facing[item.session.id] ?? .down) : .down)
                                    .position(sp)
                                    .onTapGesture { dialogueId = nil; selectedId = item.session.id == selectedId ? nil : item.session.id }
                                    .contextMenu {
                                        AgentMenu(store: store, session: item.session,
                                                  openDialogue: { selectedId = nil; dialogueId = item.session.id },
                                                  ending: $ending, migrating: $migrating)
                                    }
                            }
                        }
                        .onChange(of: Int(t * 2)) {
                            drawn = positions  // twice a second is enough for overlays
                            // Debug: play a departure for the first agent once (SUHYEOK_FAKE_DEPART=1).
                            if ProcessInfo.processInfo.environment["SUHYEOK_FAKE_DEPART"] != nil, departures.isEmpty,
                               let first = items.first, lastSeen["__fake"] == nil {
                                lastSeen["__fake"] = (nil, .zero)
                                departures.append(Departure(id: first.session.id + "-fake", character: first.character,
                                                            point: positions[first.session.id] ?? first.point, start: t))
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                ForEach(departures) { d in
                                    DepartureView(departure: d, time: t, height: cam.scale * World.avatarHeight)
                                        .position(cam.screen(d.point, in: size))
                                }
                            }
                            .frame(width: size.width, height: size.height)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { selectedId = nil; dialogueId = nil }  // clicking the world closes cards and the dialogue
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if dragStart == nil { dragStart = cam.center }
                        var c = cam
                        c.center = CGPoint(x: dragStart!.x - v.translation.width / cam.scale,
                                           y: dragStart!.y - v.translation.height / cam.scale)
                        c.clamp(size); input.camera = c
                    }
                    .onEnded { _ in dragStart = nil })
                // Per-avatar onHover misses exit events while the timeline rebuilds the views,
                // so hit-test the pointer against avatar positions instead.
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        input.cursor = loc
                        let radius = cam.scale * World.avatarHeight * 0.6
                        hoveredId = items.map { item -> (String, CGFloat) in
                            let sp = cam.screen(drawn[item.session.id] ?? item.point, in: size)
                            return (item.session.id, hypot(sp.x - loc.x, sp.y - loc.y))
                        }.filter { $0.1 < radius }.min { $0.1 < $1.1 }?.0
                    case .ended:
                        hoveredId = nil
                        input.cursor = nil
                    }
                }
                .onAppear { input.size = size; input.install() }
                .onChange(of: store.sessions.map(\.id)) { _, ids in
                    let live = Set(ids)
                    let now = Date().timeIntervalSinceReferenceDate
                    for (id, seen) in lastSeen where !live.contains(id) {
                        departures.append(Departure(id: id, character: seen.0, point: drawn[id] ?? seen.1, start: now))
                        if ProcessInfo.processInfo.environment["SUHYEOK_DEBUG"] != nil {
                            FileHandle.standardError.write("depart \(id) at \(now)\n".data(using: .utf8)!)
                        }
                    }
                    lastSeen = Dictionary(uniqueKeysWithValues: items.map { ($0.session.id, ($0.character, drawn[$0.session.id] ?? $0.point)) })
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        departures.removeAll { Date().timeIntervalSinceReferenceDate - $0.start > 1.6 }
                    }
                }
                .onChange(of: Int(Date().timeIntervalSinceReferenceDate)) {
                    // Keep last known positions fresh so a departure starts where the agent stood.
                    lastSeen = Dictionary(uniqueKeysWithValues: items.map { ($0.session.id, ($0.character, drawn[$0.session.id] ?? $0.point)) })
                }
                .onChange(of: size) { input.size = size }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                edgeMarkers(items, cam: cam, size: size)
                // Agent count per state, top-right of whatever part of the map is visible.
                let mapRight = size.width
                HStack { Spacer(); StatusCounts(store: store).fixedSize() }
                    .frame(width: max(0, mapRight - 12))
                    .offset(y: 12)
                zoomControls(cam: cam, size: size)
                    .position(x: 40, y: size.height - 70)
                Minimap(items: items.map { ($0.session.id, drawn[$0.session.id] ?? $0.point, $0.session.activity) },
                        visible: cam.visible(in: size), selected: selectedId) { p in
                    var c = cam; c.center = p; c.clamp(size)
                    withAnimation(.easeInOut(duration: 0.35)) { input.camera = c }
                }
                .frame(width: 220, height: 220 * World.size.height / World.size.width)
                .position(x: size.width - 122, y: size.height - 12 - 110 * World.size.height / World.size.width)

                // Cards live outside the clipped map so they can overflow its edges.
                if let id = hoveredId, id != selectedId, let item = items.first(where: { $0.session.id == id }) {
                    HoverCard(session: item.session, agentName: store.agentName(for: item.session), huntLine: store.huntLine(for: item.session))
                        .fixedSize()
                        .position(cardCenter(cam.screen(drawn[id] ?? item.point, in: size), cardSize: CGSize(width: 240, height: 120),
                                             avatar: cam.scale * World.avatarHeight, bounds: size))
                }
                if let id = selectedId, let item = items.first(where: { $0.session.id == id }) {
                    StatusCard(session: item.session, agentName: store.agentName(for: item.session), huntLine: store.huntLine(for: item.session),
                               character: item.character, close: { selectedId = nil },
                               openTerminal: {
                                   if openMode == OpenMode.dialogue.rawValue {
                                       dialogueId = item.session.id
                                       selectedId = nil
                                   } else {
                                       store.selection = store.pane(for: item.session)
                                   }
                               })
                        .fixedSize()
                        .position(cardCenter(cam.screen(drawn[id] ?? item.point, in: size), cardSize: CGSize(width: 320, height: 340),
                                             avatar: cam.scale * World.avatarHeight, bounds: size))
                }
                // NPC-style conversation: docked to the right half, or a small picture-in-picture window.
                if let id = dialogueId {
                    let pip = CGSize(width: 340, height: 320)
                    let panel = DialogueView(store: store, sessionId: id, onClose: { dialogueId = nil },
                                 onTerminal: {
                                     if let s = store.sessions.first(where: { $0.id == id }) { store.selection = store.pane(for: s) }
                                     dialogueId = nil
                                 },
                                 large: dialogueLarge,
                                 onToggleSize: { withAnimation(.easeInOut(duration: 0.2)) { dialogueLarge.toggle() } },
                                 onHeaderDrag: dialogueLarge ? nil : { pipDrag = $0 },
                                 onHeaderDragEnd: dialogueLarge ? nil : { t in
                                     pipX = clamp(pipX + t.width / geo.size.width, pip.width / 2 / geo.size.width)
                                     pipY = clamp(pipY + t.height / geo.size.height, pip.height / 2 / geo.size.height)
                                     pipDrag = .zero
                                 })
                        .id(id)  // a different agent gets fresh dialogue state, never the previous one's
                    if dialogueLarge {
                        // Right half, with a margin above and the minimap left visible below.
                        let top: CGFloat = 50  // below the status counts
                        let room = max(240, geo.size.height - top - minimapHeight - 24)
                        let minH = min(room, geo.size.height * 0.5)
                        let width = geo.size.width * min(max(panelWidth, 0.4), 0.7)
                        let height = minH + (room - minH) * min(max(panelHeight, 0), 1)
                        panel
                            .frame(width: width, height: height)
                            .overlay(alignment: .bottomLeading) {
                                // Corner grip: drag left/down to grow, right/up to shrink.
                                ResizeGrip()
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { v in
                                            if resizeStart == nil { resizeStart = (panelWidth, panelHeight) }
                                            let (w0, h0) = resizeStart!
                                            panelWidth = min(max(w0 - v.translation.width / geo.size.width, 0.4), 0.7)
                                            let span = max(room - minH, 1)
                                            panelHeight = min(max(h0 + v.translation.height / span, 0), 1)
                                        }
                                        .onEnded { _ in resizeStart = nil })
                            }
                            .position(x: geo.size.width - 8 - width / 2, y: top + height / 2)
                            .shadow(radius: 16)
                            .transition(.move(edge: .trailing))
                    } else {
                        panel
                            .frame(width: pip.width, height: pip.height)
                            .position(x: pipX * geo.size.width + pipDrag.width, y: pipY * geo.size.height + pipDrag.height)
                            .shadow(radius: 12)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.25), value: dialogueId)
        .endSessionDialog(store: store, ending: $ending, migrating: $migrating)
    }

    private var minimapHeight: CGFloat { 220 * World.size.height / World.size.width }

    /// Keeps a fraction inside [margin, 1 - margin] so the PIP never leaves the view.
    private func clamp(_ v: Double, _ margin: Double) -> Double { min(max(v, margin), 1 - margin) }

    /// Beside the avatar, on the side with more room, clamped to the view.
    private func cardCenter(_ a: CGPoint, cardSize: CGSize, avatar: CGFloat, bounds: CGSize) -> CGPoint {
        let gap = avatar + cardSize.width / 2
        let x = a.x > bounds.width / 2 ? a.x - gap : a.x + gap
        let hw = cardSize.width / 2, hh = cardSize.height / 2
        return CGPoint(x: min(max(x, hw), bounds.width - hw), y: min(max(a.y, hh), bounds.height - hh))
    }

    /// Opens on the whole town.
    private func initialCamera(_ size: CGSize) -> Camera {
        var c = Camera(center: CGPoint(x: 0.5, y: World.size.height / 2), scale: 0)
        c.clamp(size)
        DispatchQueue.main.async { if input.camera.scale == 0 { input.camera = c } }
        return c
    }

    @ViewBuilder private var mapImage: some View {
        if let img = Art.image(World.image) {
            // Smooth scaling when zoomed out, crisp pixels when zoomed in.
            Image(nsImage: img).resizable().interpolation(input.camera.scale > 3840 ? .none : .high)
        } else {
            Color(red: 0.25, green: 0.18, blue: 0.13)
        }
    }

    private struct Marker { let item: Placed; var at: CGPoint; let side: Int; let angle: CGFloat }

    /// Agents outside the view: a small face on the edge pointing to them; click to go there.
    /// Faces on the same edge are spread apart and kept clear of the minimap and zoom buttons.
    @ViewBuilder private func edgeMarkers(_ items: [Placed], cam: Camera, size: CGSize) -> some View {
        ForEach(layoutMarkers(items, cam: cam, size: size), id: \.item.session.id) { m in
            EdgeMarker(character: m.item.character, color: m.item.session.activity.color, angle: m.angle)
                .position(m.at)
                .help("\(store.agentName(for: m.item.session)) · \(m.item.session.name)")
                .onTapGesture {
                    var n = cam; n.center = drawn[m.item.session.id] ?? m.item.point; n.clamp(size)
                    withAnimation(.easeInOut(duration: 0.4)) { input.camera = n }
                    selectedId = m.item.session.id
                }
        }
    }

    private func layoutMarkers(_ items: [Placed], cam: Camera, size: CGSize) -> [Marker] {
        let inset: CGFloat = 36, spacing: CGFloat = 57
        // The window reports a zero or tiny size while it first lays out; no edges to place markers on yet.
        guard size.width > 400, size.height > 300, cam.scale > 0 else { return [] }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        var markers: [Marker] = []
        for item in items {
            let sp = cam.screen(drawn[item.session.id] ?? item.point, in: size)
            guard sp.x < 0 || sp.y < 0 || sp.x > size.width || sp.y > size.height else { continue }
            let dx = sp.x - c.x, dy = sp.y - c.y
            let kx = (size.width / 2 - inset) / max(abs(dx), 0.001), ky = (size.height / 2 - inset) / max(abs(dy), 0.001)
            let k = min(kx, ky)
            // side: 0 top, 1 right, 2 bottom, 3 left
            let side = kx < ky ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
            markers.append(Marker(item: item, at: CGPoint(x: c.x + dx * k, y: c.y + dy * k), side: side, angle: atan2(dy, dx)))
        }
        // Allowed span on each edge; the bottom-right corner belongs to the minimap, bottom-left to the zoom buttons.
        let minimapH = 220 * World.size.height / World.size.width + 24
        func span(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<CGFloat> { lo...max(lo, hi) }
        let spans: [Int: ClosedRange<CGFloat>] = [
            0: span(inset, size.width - inset), 1: span(inset, size.height - minimapH - inset),
            2: span(90, size.width - 250), 3: span(inset, size.height - 130),
        ]
        for side in 0..<4 {
            let idx = markers.indices.filter { markers[$0].side == side }
                .sorted { side % 2 == 0 ? markers[$0].at.x < markers[$1].at.x : markers[$0].at.y < markers[$1].at.y }
            guard let span = spans[side], !idx.isEmpty else { continue }
            // Push apart forward, then pull back if the last one ran past the end of the span.
            var pos = idx.map { side % 2 == 0 ? markers[$0].at.x : markers[$0].at.y }
            for i in pos.indices { pos[i] = max(pos[i], i == 0 ? span.lowerBound : pos[i - 1] + spacing) }
            if let last = pos.last, last > span.upperBound {
                for i in pos.indices.reversed() { pos[i] = min(pos[i], i == pos.count - 1 ? span.upperBound : pos[i + 1] - spacing) }
            }
            for (i, m) in idx.enumerated() {
                if side % 2 == 0 { markers[m].at.x = pos[i] } else { markers[m].at.y = pos[i] }
            }
        }
        return markers
    }

    private func zoomControls(cam: Camera, size: CGSize) -> some View {
        VStack(spacing: 6) {
            Button { zoom(cam, 1.3, size) } label: { Image(systemName: "plus") }
            Button { zoom(cam, 1 / 1.3, size) } label: { Image(systemName: "minus") }
            Button {
                var c = cam; c.scale = 0; c.clamp(size)  // clamps up to the smallest scale = whole world
                withAnimation(.easeInOut(duration: 0.35)) { input.camera = c }
            } label: { Image(systemName: "rectangle.expand.vertical") }
            .help("전체 보기")
        }
        .buttonStyle(.borderedProminent).tint(Color.black.opacity(0.55)).controlSize(.small)
    }

    private func zoom(_ cam: Camera, _ f: CGFloat, _ size: CGSize) {
        var c = cam; c.scale *= f; c.clamp(size)
        withAnimation(.easeInOut(duration: 0.2)) { input.camera = c }
    }

    struct Placed { let session: AgentSession; let character: Character?; let point: CGPoint; var tier: Hunt.Tier? = nil }

    /// Demo agents (defaults key `demoWalkers`, e.g. "knight,fox"): every 16 s they walk to the next
    /// hunting ground (low → mid → high → camp) and attack its boss, to check the animation in the app.
    private func demoWalkers() -> [Placed] {
        guard let ids = UserDefaults.standard.string(forKey: "demoWalkers"), !ids.isEmpty else { return [] }
        let tick = Int(Date().timeIntervalSince1970 / 16)
        return ids.split(separator: ",").enumerated().compactMap { k, id in
            guard let c = Art.roster.first(where: { $0.id == String(id) }) else { return nil }
            let stop: Hunt.Tier? = [Hunt.Tier.low, .mid, .high, nil][(tick + k) % 4]
            let s = AgentSession(id: "demo-\(id)", agent: .claude, name: "시연 · \(c.name)", cwd: "/demo",
                                 status: stop == nil ? .idle : .busy, startedAt: Date(), updatedAt: Date(),
                                 lastUser: nil, lastAssistant: nil, estimated: true)
            let spots = stop.map(World.attackSpots) ?? World.campSpots
            return Placed(session: s, character: c, point: World.spot(spots, k + 6), tier: stop)
        }
    }

    /// Agents standing at a boss get pushed back (and flash) when its slam or skill lands.
    private func knockback(_ item: Placed, at p: CGPoint, time: TimeInterval) -> CGFloat {
        guard let tier = item.tier, p == item.point else { return 0 }
        let f = BossPattern.impact(tier, time: time)
        return f == 0 ? 0 : (p.x < World.boss(tier).midX ? -1 : 1) * CGFloat(f) * 0.012
    }

    /// At a hunting ground agents face the boss: attacking while their turn runs, standing guard otherwise.
    private func pose(for item: Placed, at p: CGPoint) -> Avatar.Pose {
        guard let tier = item.tier else { return .camp }
        let faceRight = p.x < World.boss(tier).midX
        return item.session.status == .busy ? .attack(faceRight: faceRight) : .guarding(faceRight: faceRight)
    }

    /// Hunting grounds by continuous activity; agents that have rested an hour sit at the camp fire.
    private func placed() -> [Placed] {
        demoWalkers() + store.placements().map {
            Placed(session: $0.session, character: store.character(for: $0.session), point: $0.point, tier: $0.tier)
        }
    }
}

/// Whole-world overview: area thumbnails, a dot per agent, the visible rectangle. Click to move there.
struct Minimap: View {
    let items: [(String, CGPoint, Activity)]
    let visible: CGRect
    let selected: String?
    let go: (CGPoint) -> Void

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / World.size.width
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.75)
                Group {
                    if let img = Art.image(World.minimap) { Image(nsImage: img).resizable() } else { Color.gray }
                }
                .frame(width: World.size.width * k, height: World.size.height * k)
                .opacity(0.85)
                ForEach(items, id: \.0) { id, p, activity in
                    Circle().fill(activity.color)
                        .overlay(Circle().stroke(id == selected ? Color.yellow : Color.black, lineWidth: id == selected ? 2 : 1))
                        .frame(width: 7, height: 7)
                        .position(x: p.x * k, y: p.y * k)
                }
                Rectangle().stroke(Color.white, lineWidth: 1.5)
                    .frame(width: visible.width * k, height: visible.height * k)
                    .offset(x: visible.minX * k, y: visible.minY * k)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in go(CGPoint(x: v.location.x / k, y: v.location.y / k)) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.85, green: 0.68, blue: 0.25), lineWidth: 2))
    }
}

/// A round face on the view's edge with a small arrow toward an off-screen agent.
struct EdgeMarker: View {
    let character: Character?
    let color: Color
    let angle: CGFloat

    var body: some View {
        ZStack {
            // 1.5x the original 34pt marker.
            Triangle().fill(color).frame(width: 15, height: 15).offset(x: 33).rotationEffect(.radians(angle))
            Circle().fill(Color.black.opacity(0.7)).frame(width: 51, height: 51)
            if let c = character, let img = Art.image("sprites/\(c.id)") {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                    .frame(width: 45, height: 45, alignment: .top).clipShape(Circle())
            }
            Circle().stroke(color, lineWidth: 3).frame(width: 51, height: 51)
        }
        .contentShape(Circle())
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }
    }
}

/// Moves each avatar toward its zone slot at walking speed, frame by frame.
/// SwiftUI implicit animations stall when the TimelineView rebuilds the tree every tick.
enum Facing: String { case down, up, left, right }

final class Walker {
    private var current: [String: CGPoint] = [:]
    private var routes: [String: [CGPoint]] = [:]      // remaining waypoints, target last
    private var routeTarget: [String: CGPoint] = [:]   // target the route was planned for
    private var speedNow: [String: CGFloat] = [:]
    private(set) var facing: [String: Facing] = [:]  // kept after arriving, so agents face where they walked
    /// Debug hook (--trace-walk): receives every step.
    nonisolated(unsafe) static var trace: (([String: CGPoint], [String: Facing], TimeInterval) -> Void)?
    private var lastTick: TimeInterval?
    private let topSpeed: CGFloat = 0.12   // world units per second
    private let accel: CGFloat = 0.5       // world units per second², for easing in and out

    func step(targets: [(String, CGPoint)], now: TimeInterval) -> [String: CGPoint] {
        let dt = CGFloat(min(now - (lastTick ?? now), 0.25))
        lastTick = now
        var next: [String: CGPoint] = [:]
        for (id, target) in targets {
            var p = current[id] ?? target  // new sessions appear in place
            if routeTarget[id] != target {
                routes[id] = p == target ? [] : Pathfinder.shared.route(from: p, to: target)
                routeTarget[id] = target
            }
            var path = routes[id] ?? []
            // Remaining distance along the route, to slow down before arriving.
            var left: CGFloat = 0
            var prev = p
            for w in path { left += hypot(w.x - prev.x, w.y - prev.y); prev = w }
            var v = speedNow[id] ?? 0
            v = min(topSpeed, v + accel * dt, sqrt(max(0, 2 * accel * left)) + 0.01)
            var budget = v * dt
            while budget > 0, let w = path.first {
                let dx = w.x - p.x, dy = w.y - p.y
                let d = hypot(dx, dy)
                if d > 0.0005 {
                    facing[id] = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
                }
                if d <= budget { p = w; budget -= d; path.removeFirst() }
                else { p = CGPoint(x: p.x + dx / d * budget, y: p.y + dy / d * budget); budget = 0 }
            }
            if path.isEmpty { v = 0 }
            if facing[id] == nil { facing[id] = .down }
            routes[id] = path
            speedNow[id] = v
            next[id] = p
        }
        current = next
        let live = Set(next.keys)
        routes = routes.filter { live.contains($0.key) }
        routeTarget = routeTarget.filter { live.contains($0.key) }
        if let trace = Walker.trace { trace(next, facing, now) }
        return next
    }
}

struct Avatar: View {
    let session: AgentSession
    let character: Character?
    enum Pose: Equatable { case camp, attack(faceRight: Bool), guarding(faceRight: Bool) }
    let pose: Pose
    let agentName: String
    let time: TimeInterval
    let height: CGFloat
    let selected: Bool
    var walking = false
    var facing: Facing = .down

    /// Generated animation frames (art/frames/<id>); characters without them use the single sprite.
    private var frames: Bool { character.map { Art.image("frames/\($0.id)/walk_down_1") != nil } ?? false }

    /// Current frame name and whether to mirror it (right = mirrored left).
    private func frame(_ phase: Double) -> (String, Bool) {
        let cycle = [0, 1, 2, 1]
        // Six-frame walk strips when the character has them: a full cycle every 0.6 s, which matches
        // two steps at walking speed; three-frame sheets ping-pong at 8 fps as before.
        let six = character.map { Art.image("frames/\($0.id)/walk_down_5") != nil } ?? false
        if walking {
            let f = six ? Int(time * 10) % 6 : cycle[Int(time * 8) % 4]
            switch facing {
            case .down: return ("walk_down_\(f)", false)
            case .up: return ("walk_up_\(f)", false)
            case .left: return ("walk_left_\(f)", false)
            case .right: return ("walk_left_\(f)", true)
            }
        }
        let standing = six ? "walk_down_2" : "walk_down_1"  // strips: frame 2 has both feet together
        switch pose {
        case .camp:
            return (standing, false)
        case .guarding(let faceRight):
            // Side-on toward the boss; frames face left, so mirror when the boss is to the right.
            return (six ? "walk_left_2" : "walk_left_1", faceRight)
        case .attack(let faceRight):
            let hasAttack = character.map { Art.image("frames/\($0.id)/attack_5") != nil } ?? false
            guard hasAttack else { return ("smith_\(Int(time * 7 + phase) % 6)", faceRight) }
            return ("attack_\(Self.attackFrame(time + phase))", faceRight)
        }
    }

    /// One swing every 1.2 s: hold the ready stance, wind up, then the strike frames go by fast.
    static let attackBeat: [Int] = [0, 0, 1, 1, 2, 3, 3, 4, 5, 5, 0, 0]
    static func attackFrame(_ t: TimeInterval) -> Int { attackBeat[Int(t * 10) % attackBeat.count] }
    /// True on the beats where the weapon connects (for hit effects on the boss).
    static func isImpact(_ t: TimeInterval) -> Bool { attackFrame(t) == 3 }

    var body: some View {
        // Per-session phase so characters don't move in lockstep.
        let phase = Double(abs(session.id.hashValue % 100)) / 15
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                sprite(phase)
                    .background(alignment: .bottom) {
                        Ellipse().fill(Color.black.opacity(0.3))
                            .frame(width: height * 0.42, height: height * 0.11)
                            .offset(y: height * 0.04)
                    }
                    .offset(y: bob(phase))
                    .rotationEffect(.degrees(swing(phase)), anchor: .bottom)
                if session.activity == .waiting {
                    // "…" waiting for the next instruction; a red "!" when it is blocked on your choice.
                    let ask = session.status == .waiting
                    Text(ask ? "!" : "…").font(.system(size: height * (ask ? 0.26 : 0.2), weight: .heavy))
                        .foregroundStyle(ask ? .white : .black)
                        .padding(.horizontal, height * 0.06)
                        .background(ask ? Color.red : Color.white, in: Capsule())
                        .opacity(0.6 + 0.4 * abs(sin(time * 2 + phase)))
                        .offset(x: height * 0.2, y: -height * 0.12)
                }
                if pose == .camp, session.activity != .working {
                    Text("z").font(.system(size: height * 0.22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .opacity(0.4 + 0.6 * abs(sin(time + phase)))
                        .offset(x: height * 0.15, y: -height * 0.1 - CGFloat((time + phase).truncatingRemainder(dividingBy: 2)) * 4)
                }
            }
            Text(agentName)
                .font(.system(size: max(9, height * 0.16), weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(projectColor(session.cwd).opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
                .frame(maxWidth: height * 2.2)
        }
        .padding(4)
    }

    private struct Offset: Hashable { let x: CGFloat; let y: CGFloat }

    private static func ring(_ w: CGFloat) -> [Offset] {
        (0..<8).map { k in
            let a = Double(k) * .pi / 4
            return Offset(x: CGFloat(cos(a)) * w, y: CGFloat(sin(a)) * w)
        }
    }

    /// The sprite with a gold outline that follows its silhouette when selected:
    /// gold-tinted copies nudged in eight directions sit behind the real sprite.
    @ViewBuilder private func outlined(_ img: NSImage, height h: CGFloat, mirrored: Bool) -> some View {
        let base = Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
        let tinted = Image(nsImage: img).renderingMode(.template).resizable().interpolation(.none)
            .aspectRatio(contentMode: .fit).foregroundStyle(Color(red: 1, green: 0.82, blue: 0.2))
        ZStack {
            if selected {
                ForEach(Self.ring(max(2, h * 0.025)), id: \.self) { o in
                    tinted.offset(x: o.x, y: o.y)
                }
            }
            base
        }
        .frame(height: h)
        .shadow(color: selected ? Color(red: 1, green: 0.8, blue: 0.2).opacity(0.8) : .clear, radius: selected ? 6 : 0)
        .scaleEffect(x: mirrored ? -1 : 1)
    }

    private func swing(_ phase: Double) -> Double { walking && !frames ? sin(time * 12) * 5 : 0 }

    private func bob(_ phase: Double) -> CGFloat {
        if walking { return frames ? 0 : -CGFloat(abs(sin(time * 12))) * height * 0.08 }
        switch pose {
        case .attack: return 0
        case .guarding: return CGFloat(sin(time * 3 + phase)) * height * 0.015
        case .camp: return CGFloat(sin(time * 1.2 + phase)) * height * 0.012  // breathing by the fire
        }
    }

    @ViewBuilder private func sprite(_ phase: Double) -> some View {
        let (name, mirrored) = frame(phase)
        if let c = character, frames, let img = Art.image("frames/\(c.id)/\(name)") {
            // Frames share one scale per character: a 128px-tall standing frame maps to `height`.
            outlined(img, height: height * img.size.height / 128, mirrored: mirrored)
        } else if let c = character, let img = Art.image("sprites/\(c.id)") {
            outlined(img, height: height, mirrored: false)
        } else {
            Circle().fill(session.activity.color)
                .overlay(Text(String(agentName.prefix(1))).font(.headline).foregroundStyle(.white))
                .aspectRatio(1, contentMode: .fit)
                .frame(height: height)
        }
    }
}

extension Activity {
    var zoneName: String {
        switch self {
        case .working: return "작업대 홀"
        case .waiting: return "선술집"
        case .resting: return "라운지"
        }
    }
}

/// Sparks flying off the anvil in front of a hammering avatar.
struct Sparks: View {
    let time: TimeInterval
    let height: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                let t = (time * 1.6 + Double(i) / 5).truncatingRemainder(dividingBy: 1)
                let angle = -Double.pi / 2 + (Double(i) - 2) * 0.45
                Circle()
                    .fill(i % 2 == 0 ? Color.yellow : Color.orange)
                    .frame(width: height * 0.045, height: height * 0.045)
                    .offset(x: CGFloat(cos(angle) * t) * height * 0.4,
                            y: height * 0.35 + CGFloat(sin(angle) * t) * height * 0.4)
                    .opacity(1 - t)
            }
        }
        .allowsHitTesting(false)
    }
}


/// Camera plus Figma-style input: two-finger scroll pans, pinch or ⌘/⌃+scroll zooms around the pointer.
@MainActor
final class MapInput: ObservableObject {
    @Published var camera = Camera()
    var size: CGSize = .zero
    /// Pointer position over the map; nil when it is elsewhere (cards, dialogue, other windows).
    var cursor: CGPoint?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, let at = self.cursor, self.camera.scale > 0 else { return event }
            switch event.type {
            case .magnify:
                self.zoom(at: at, by: 1 + event.magnification)
            case .scrollWheel:
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12  // mouse wheels report lines
                let dx = event.scrollingDeltaX * k, dy = event.scrollingDeltaY * k
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                    self.zoom(at: at, by: exp(dy * 0.01))
                } else {
                    var c = self.camera
                    c.center.x -= dx / c.scale
                    c.center.y -= dy / c.scale
                    c.clamp(self.size)
                    self.camera = c
                }
            default:
                return event
            }
            return nil  // consumed by the map
        }
    }

    /// Scales by f while keeping the world point under the pointer in place.
    func zoom(at p: CGPoint, by f: CGFloat) {
        var c = camera
        let w = c.world(p, in: size)
        c.scale *= f
        c.clamp(size)
        c.center = CGPoint(x: w.x - (p.x - size.width / 2) / c.scale, y: w.y - (p.y - size.height / 2) / c.scale)
        c.clamp(size)
        camera = c
    }
}

/// Wooden walkways between the areas (rectangles from walkmap.json), drawn over the area walls they open.
struct Corridors: View {
    let cam: Camera
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            let plank: CGFloat = 0.014 * cam.scale, edge = max(2, 0.007 * cam.scale)
            for r in Pathfinder.shared.corridors {
                let o = cam.screen(r.origin, in: size)
                let rect = CGRect(x: o.x, y: o.y, width: r.width * cam.scale, height: r.height * cam.scale)
                ctx.fill(Path(rect), with: .color(Color(red: 0.55, green: 0.36, blue: 0.20)))
                let horizontal = rect.width > rect.height
                // Planks run across the walking direction.
                var line = Path()
                if horizontal {
                    var x = rect.minX
                    while x < rect.maxX { line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY)); x += plank }
                } else {
                    var y = rect.minY
                    while y < rect.maxY { line.move(to: CGPoint(x: rect.minX, y: y)); line.addLine(to: CGPoint(x: rect.maxX, y: y)); y += plank }
                }
                ctx.stroke(line, with: .color(Color(red: 0.36, green: 0.22, blue: 0.12)), lineWidth: 1)
                // Low walls along both sides.
                let wall = Color(red: 0.25, green: 0.17, blue: 0.12)
                if horizontal {
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge)), with: .color(wall))
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge)), with: .color(wall))
                } else {
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: edge, height: rect.height)), with: .color(wall))
                    ctx.fill(Path(CGRect(x: rect.maxX - edge, y: rect.minY, width: edge, height: rect.height)), with: .color(wall))
                }
            }
        }
        .allowsHitTesting(false)
    }
}


/// Small pill: agents at the camp and at each hunting ground, and crystals collected.
struct StatusCounts: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let grounds = store.sessions.map { store.ground(for: $0) }
        HStack(spacing: 10) {
            cell("대기소", grounds.filter { $0 == nil }.count, .gray)
            ForEach(Hunt.Tier.allCases, id: \.self) { t in
                cell(["하", "중", "상"][t.rawValue], grounds.filter { $0 == t }.count, [Color.green, .cyan, .orange][t.rawValue])
            }
            HStack(spacing: 3) {
                Image(systemName: "diamond.fill").font(.caption2).foregroundStyle(.cyan)
                Text("\(store.totalCrystals)").font(.caption.monospacedDigit().bold()).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(Color(red: 0.85, green: 0.68, blue: 0.25).opacity(0.8), lineWidth: 1))
        .allowsHitTesting(false)
    }

    private func cell(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.75)).fixedSize()
            Text("\(n)").font(.caption.monospacedDigit().bold()).foregroundStyle(.white)
        }
    }
}




struct Departure: Identifiable {
    let id: String
    let character: Character?
    let point: CGPoint
    let start: TimeInterval
}

/// A finished agent waves goodbye: it rises, shrinks and fades in a puff of sparkles (about 1.5 s).
struct DepartureView: View {
    let departure: Departure
    let time: TimeInterval
    let height: CGFloat

    var body: some View {
        let t = min(max((time - departure.start) / 1.5, 0), 1)
        ZStack {
            if let c = departure.character, let img = Art.image("frames/\(c.id)/walk_down_1") ?? Art.image("sprites/\(c.id)") {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .scaleEffect(1 - 0.6 * t, anchor: .bottom)
                    .offset(y: -height * 0.5 * t)
                    .opacity(1 - t)
                    .brightness(0.6 * t)
            }
            ForEach(0..<10, id: \.self) { i in
                let a = Double(i) / 10 * 2 * .pi
                let r = height * (0.15 + 0.7 * t)
                Image(systemName: "sparkle")
                    .font(.system(size: height * 0.18))
                    .foregroundStyle(i % 2 == 0 ? Color.yellow : Color.white)
                    .offset(x: cos(a) * r, y: sin(a) * r * 0.7 - height * 0.4 * t)
                    .opacity(t < 0.1 ? t * 10 : 1 - t)
            }
        }
        .allowsHitTesting(false)
    }
}


/// A hunting-ground boss running its move script: idle, hops, slams with shockwaves, a signature skill.
/// Flashes and shows damage numbers when attackers' blows land; crystals fly from it to each attacker.
struct BossView: View {
    let tier: Hunt.Tier
    let time: TimeInterval
    let size: CGSize
    /// Screen position and animation phase of each attacking agent.
    let attackers: [(CGPoint, Double)]
    let center: CGPoint

    private var hp: Double {
        let perHit: Double = [0.04, 0.025, 0.015][tier.rawValue]
        let blows = Double(attackers.count) * time / 1.2
        return attackers.isEmpty ? 1 : 1 - (blows * perHit).truncatingRemainder(dividingBy: 1)
    }
    private var enraged: Bool { tier == .high && hp < 0.3 }

    var body: some View {
        let hits = attackers.filter { Avatar.isImpact(time + $0.1) }
        let (move, k) = BossPattern.state(tier, time: time, enraged: enraged)
        let h = size.height * 1.25
        ZStack {
            // Effects behind the boss.
            if move == .attack, k > 0.5 { shockwave((k - 0.5) / 0.5) }
            if move == .special { specialUnder(k) }
            if let img = Art.image(frameName(move, k)) {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(height: h * (move == .special || move == .attack ? 1.08 : 1))
                    .colorMultiply(enraged ? Color(red: 1, green: 0.7, blue: 0.6) : .white)
                    .brightness(hits.isEmpty ? 0 : 0.45)          // white flash when a blow lands
                    .offset(x: shakeX(move, k, hits: !hits.isEmpty), y: hopY(move, k))
                    .scaleEffect(x: squash(move, k).0, y: squash(move, k).1, anchor: .bottom)
                    .background(alignment: .bottom) {
                        Ellipse().fill(Color.black.opacity(0.35))
                            .frame(width: size.width * 1.1 * (move == .hop ? 1 - 0.3 * sin(k * .pi) : 1),
                                   height: size.height * 0.18)
                    }
                    .position(center)
            }
            if move == .special { specialOver(k) }
            if move == .roar { roarRings(k) }
            hpBar.position(x: center.x, y: center.y - size.height * 1.0)  // clear of the slime's hops
            ForEach(Array(attackers.enumerated()), id: \.offset) { _, a in
                damage(a)
                crystal(a)
            }
        }
        .allowsHitTesting(false)
    }

    private func frameName(_ move: BossPattern.Move, _ k: Double) -> String {
        let key = World.key(tier)
        switch move {
        case .attack: return "bosses/\(key)_attack_\(min(5, Int(k * 6)))"
        case .special: return "bosses/\(key)_special_\(min(5, Int(k * 6)))"
        default: return "bosses/\(key)_\(Int(time * (enraged ? 9 : 6)) % 6)"
        }
    }

    private func hopY(_ move: BossPattern.Move, _ k: Double) -> CGFloat {
        move == .hop ? -CGFloat(sin(k * .pi)) * size.height * 0.35 : 0
    }

    /// Slime squash on landing; dragon rears up while roaring.
    private func squash(_ move: BossPattern.Move, _ k: Double) -> (CGFloat, CGFloat) {
        switch move {
        case .hop:
            let land = k > 0.85 ? (k - 0.85) / 0.15 : 0
            return (1 + 0.15 * land, 1 - 0.15 * land)
        case .roar: return (1, 1 + 0.06 * CGFloat(sin(k * .pi)))
        default: return (1, 1)
        }
    }

    private func shakeX(_ move: BossPattern.Move, _ k: Double, hits: Bool) -> CGFloat {
        if move == .roar { return CGFloat(sin(time * 90)) * size.width * 0.03 }
        return hits ? CGFloat(sin(time * 80)) * size.width * 0.02 : 0
    }

    /// Expanding ground ring after a slam.
    private func shockwave(_ k: Double) -> some View {
        Ellipse()
            .stroke([Color.green, .cyan, .orange][tier.rawValue].opacity(1 - k), lineWidth: max(2, size.height * 0.06 * (1 - k)))
            .frame(width: size.width * (1 + 2.2 * k), height: size.height * 0.35 * (1 + 2.2 * k))
            .position(x: center.x, y: center.y + size.height * 0.5)
    }

    /// Warning rings while the dragon roars.
    private func roarRings(_ k: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let r = ((k * 2 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                Circle().stroke(Color.red.opacity(0.7 * (1 - r)), lineWidth: 3)
                    .frame(width: size.width * (0.6 + 1.8 * r), height: size.width * (0.6 + 1.8 * r) * 0.6)
            }
            Text("!!").font(.system(size: max(12, size.height * 0.3), weight: .black)).foregroundStyle(.red)
                .shadow(color: .black, radius: 2)
                .offset(y: -size.height * 0.95)
        }
        .position(center)
    }

    @ViewBuilder private func specialUnder(_ k: Double) -> some View {
        if tier == .mid {
            // Crystal spikes erupting in a ring around the golem.
            ForEach(0..<12, id: \.self) { i in
                let a = Double(i) / 12 * 2 * .pi
                let rise = k < 0.4 ? k / 0.4 : k > 0.8 ? (1 - k) / 0.2 : 1
                Image(systemName: "triangle.fill")
                    .resizable()
                    .foregroundStyle(LinearGradient(colors: [.white, .cyan, .blue], startPoint: .top, endPoint: .bottom))
                    .frame(width: size.width * 0.14, height: size.height * 0.4 * rise)
                    .position(x: center.x + CGFloat(cos(a)) * size.width * 1.1,
                              y: center.y + size.height * 0.45 + CGFloat(sin(a)) * size.height * 0.35 - size.height * 0.2 * rise)
                    .opacity(rise)
            }
        }
    }

    @ViewBuilder private func specialOver(_ k: Double) -> some View {
        switch tier {
        case .low:
            // Slime blobs sprayed in all directions, bouncing once and fading.
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * .pi + 0.3
                let t = max(0, (k - 0.4) / 0.6)
                Circle().fill(RadialGradient(colors: [Color(red: 0.6, green: 1, blue: 0.5), .green, Color(red: 0.1, green: 0.5, blue: 0.2)],
                                             center: .topLeading, startRadius: 0, endRadius: size.width * 0.2))
                    .overlay(Circle().stroke(Color(red: 0.05, green: 0.3, blue: 0.1), lineWidth: 1.5))
                    .frame(width: size.width * 0.22, height: size.width * 0.18)
                    .position(x: center.x + CGFloat(cos(a) * t) * size.width * 1.6,
                              y: center.y + CGFloat(sin(a) * t) * size.height * 0.9 - CGFloat(sin(t * .pi)) * size.height * 0.5)
                    .opacity(t > 0 ? 1 - t * 0.8 : 0)
            }
        case .mid:
            EmptyView()
        case .high:
            // Fire pouring from the dragon to both sides.
            ForEach(0..<16, id: \.self) { i in
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                let t = ((k - 0.35) / 0.55 + Double(i) / 16).truncatingRemainder(dividingBy: 1)
                if k > 0.35 && k < 0.95 {
                    Image(systemName: "flame.fill")
                        .font(.system(size: size.height * (0.15 + 0.2 * t)))
                        .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom))
                        .position(x: center.x + side * CGFloat(t) * size.width * 1.8,
                                  y: center.y + size.height * 0.1 + CGFloat(sin(Double(i) * 1.7)) * size.height * 0.25 * CGFloat(t))
                        .opacity(1 - t)
                }
            }
        }
    }

    private var hpBar: some View {
        VStack(spacing: 2) {
            Text(enraged ? tier.boss + " · 분노" : tier.boss).font(.system(size: max(9, size.height * 0.12), weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.6))
                Capsule().fill(LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size.width * 1.1 * hp)
            }
            .frame(width: size.width * 1.1, height: max(4, size.height * 0.05))
        }
    }

    /// Damage number rising from the boss for 0.8 s after each blow.
    @ViewBuilder private func damage(_ a: (CGPoint, Double)) -> some View {
        let cycle = Double(Avatar.attackBeat.count) / 10
        let since = (time + a.1).truncatingRemainder(dividingBy: cycle) - 0.5  // impact at 0.5 s into the swing
        if since >= 0 && since < 0.8 {
            let n = [12, 48, 160][tier.rawValue] + Int((a.1 * 97).truncatingRemainder(dividingBy: 1) * 30)
            Text("\(n)").font(.system(size: max(10, size.height * 0.16), weight: .heavy, design: .rounded))
                .foregroundStyle(tier == .high ? Color.orange : Color.yellow)
                .shadow(color: .black, radius: 1.5)
                .position(x: center.x + (a.0.x < center.x ? -1 : 1) * size.width * 0.25,
                          y: center.y - size.height * 0.2 - CGFloat(since) * size.height * 0.6)
                .opacity(1 - since / 0.8)
        }
    }

    /// A crystal popping out of the boss and flying to the attacker, once every few blows.
    @ViewBuilder private func crystal(_ a: (CGPoint, Double)) -> some View {
        let period = 3.6  // every third swing
        let since = (time + a.1).truncatingRemainder(dividingBy: period) - 0.5
        if since >= 0 && since < 0.9 {
            let k = CGFloat(since / 0.9)
            let arc = sin(k * .pi) * size.height * 0.5
            Image(systemName: "diamond.fill")
                .font(.system(size: max(8, size.height * 0.12)))
                .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .top, endPoint: .bottom))
                .shadow(color: .cyan, radius: 3)
                .position(x: center.x + (a.0.x - center.x) * k, y: center.y + (a.0.y - center.y) * k - arc)
        }
    }
}


/// Small diagonal grip in a panel corner; shows the resize cursor on hover.
struct ResizeGrip: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: 22, height: 22)
            Path { p in
                for k in 0..<3 {
                    let d = CGFloat(6 + k * 5)
                    p.move(to: CGPoint(x: 3, y: 19 - d)); p.addLine(to: CGPoint(x: 3 + d, y: 19))
                }
            }
            .stroke(Color(red: 0.85, green: 0.68, blue: 0.25), lineWidth: 1.5)
            .frame(width: 22, height: 22)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                if #available(macOS 15.0, *) { NSCursor.frameResize(position: .bottomLeft, directions: .all).push() }
                else { NSCursor.crosshair.push() }
            } else { NSCursor.pop() }
        }
        .help("끌어서 대화창 크기 조절")
    }
}
