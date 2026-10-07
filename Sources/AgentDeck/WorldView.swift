import SwiftUI

/// The world: four 16:9 areas in a 2×2 grid with a dark gap between them.
/// World units: one area is 1 wide and 9/16 tall. Spots inside an area are given as fractions (0...1) of it.
enum World {
    enum Area: String, CaseIterable {
        case guild, library, tavern, garden

        var image: String { self == .guild ? "map" : "area_\(rawValue)" }
        var label: String {
            switch self {
            case .guild: return "길드홀"
            case .library: return "도서관"
            case .tavern: return "선술집"
            case .garden: return "정원"
            }
        }
        var origin: CGPoint {
            switch self {
            case .guild: return CGPoint(x: 0, y: 0)
            case .library: return CGPoint(x: 1 + World.gap, y: 0)
            case .tavern: return CGPoint(x: 0, y: World.areaH + World.gap)
            case .garden: return CGPoint(x: 1 + World.gap, y: World.areaH + World.gap)
            }
        }
        var rect: CGRect { CGRect(origin: origin, size: CGSize(width: 1, height: World.areaH)) }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x, y: origin.y + y * World.areaH)
        }
    }

    static let areaH: CGFloat = 9.0 / 16.0
    static let gap: CGFloat = 0.05
    static let size = CGSize(width: 2 + gap, height: 2 * areaH + gap)

    /// Where agents doing each kind of work stand.
    static func stations(for kind: AgentAction.Kind) -> [CGPoint] {
        let g = Area.guild, lib = Area.library
        switch kind {
        case .shell:  // around the anvil in the forge
            return [g.point(0.50, 0.36), g.point(0.60, 0.36), g.point(0.47, 0.27), g.point(0.63, 0.27)]
        case .web:  // by the guild hall's front door, looking out
            return [g.point(0.80, 0.15), g.point(0.86, 0.15), g.point(0.74, 0.15)]
        case .delegating:  // around the round tables
            return [g.point(0.12, 0.80), g.point(0.28, 0.80), g.point(0.17, 0.88), g.point(0.24, 0.88)]
        case .reading:  // in front of the library reading desks
            return [0.37, 0.47, 0.57, 0.67].flatMap { y in [0.25, 0.70].map { lib.point($0, y) } }
                + [lib.point(0.38, 0.37), lib.point(0.38, 0.67)]
        case .thinking:  // around the great globe
            return [lib.point(0.45, 0.30), lib.point(0.60, 0.30), lib.point(0.42, 0.72), lib.point(0.62, 0.72)]
        case .editing, .replying, .other:  // chairs at the guild hall desks
            return [0.26, 0.43, 0.71, 0.86].flatMap { y in [0.09, 0.15, 0.22, 0.29].map { g.point($0, y) } }
        }
    }

    /// Waiting agents fill the tavern aisles; resting agents spread over the garden.
    static func spots(for activity: Activity) -> [CGPoint] {
        switch activity {
        case .working:
            return stations(for: .editing)
        case .waiting:
            return [0.39, 0.62].flatMap { y in stride(from: 0.16, through: 0.82, by: 0.083).map { Area.tavern.point($0, y) } }
        case .resting:
            return [(0.20, 0.30), (0.33, 0.40), (0.62, 0.40), (0.72, 0.30), (0.15, 0.50), (0.30, 0.50), (0.64, 0.50),
                    (0.78, 0.50), (0.20, 0.68), (0.33, 0.72), (0.62, 0.70), (0.72, 0.65), (0.38, 0.62), (0.56, 0.62),
                    (0.38, 0.40), (0.56, 0.40)].map { Area.garden.point($0.0, $0.1) }
        }
    }

    /// Spot i of a list; past the end, agents stand in small steps beside the earlier ones.
    static func spot(_ list: [CGPoint], _ i: Int) -> CGPoint {
        var p = list[i % list.count]
        p.x += CGFloat(i / list.count) * 0.025
        return p
    }
}

/// Maps world units to view points: `scale` points per world unit, `center` is the world point in the middle.
struct Camera: Equatable {
    var center = CGPoint(x: 0.5, y: World.areaH / 2)
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
        return fitAll...(size.width * 2.5)
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
    @AppStorage("pipX") private var pipX = 0.78  // PIP centre, as a fraction of the world view
    @AppStorage("pipY") private var pipY = 0.72
    @State private var pipDrag: CGSize = .zero
    @State private var ending: AgentSession?
    @State private var migrating: AgentSession?
    @AppStorage(OpenMode.storageKey) private var openMode = OpenMode.dialogue.rawValue
    @State private var camera = Camera()
    @State private var dragStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var walker = Walker()
    /// Latest drawn positions, for hit-testing, cards, the minimap and edge markers.
    @State private var drawn: [String: CGPoint] = [:]

    init(store: SessionStore, initialSelection: String? = nil, initialDialogue: String? = nil) {
        self.store = store
        _selectedId = State(initialValue: initialSelection)
        _dialogueId = State(initialValue: initialDialogue)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cam = camera.scale == 0 ? initialCamera(size) : camera
            let items = placed()
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color(red: 0.05, green: 0.04, blue: 0.08)
                    ForEach(World.Area.allCases, id: \.self) { area in
                        let r = area.rect
                        let tl = cam.screen(r.origin, in: size)
                        areaImage(area)
                            .frame(width: r.width * cam.scale, height: r.height * cam.scale)
                            .position(x: tl.x + r.width * cam.scale / 2, y: tl.y + r.height * cam.scale / 2)
                    }
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let positions = walker.step(targets: items.map { ($0.session.id, $0.point) }, now: t)
                        ZStack(alignment: .topLeading) {
                            // Lower on the map = closer to the viewer = drawn on top.
                            ForEach(items.sorted { (positions[$0.session.id] ?? $0.point).y < (positions[$1.session.id] ?? $1.point).y },
                                    id: \.session.id) { item in
                                let p = positions[item.session.id] ?? item.point
                                let sp = cam.screen(p, in: size)
                                Avatar(session: item.session, character: item.character, station: store.station(for: item.session),
                                       agentName: store.agentName(for: item.session), time: t,
                                       height: cam.scale * 0.07 * World.areaH * 16 / 9, selected: item.session.id == selectedId,
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
                        .onChange(of: Int(t * 2)) { drawn = positions }  // twice a second is enough for overlays
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
                        c.clamp(size); camera = c
                    }
                    .onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { m in
                        if zoomStart == nil { zoomStart = cam.scale }
                        var c = cam; c.scale = zoomStart! * m; c.clamp(size); camera = c
                    }
                    .onEnded { _ in zoomStart = nil })
                // Per-avatar onHover misses exit events while the timeline rebuilds the views,
                // so hit-test the pointer against avatar positions instead.
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let radius = cam.scale * 0.045
                        hoveredId = items.map { item -> (String, CGFloat) in
                            let sp = cam.screen(drawn[item.session.id] ?? item.point, in: size)
                            return (item.session.id, hypot(sp.x - loc.x, sp.y - loc.y))
                        }.filter { $0.1 < radius }.min { $0.1 < $1.1 }?.0
                    case .ended:
                        hoveredId = nil
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                edgeMarkers(items, cam: cam, size: size)
                zoomControls(cam: cam, size: size)
                    .position(x: 40, y: size.height - 70)
                Minimap(items: items.map { ($0.session.id, drawn[$0.session.id] ?? $0.point, $0.session.activity) },
                        visible: cam.visible(in: size), selected: selectedId) { p in
                    var c = cam; c.center = p; c.clamp(size)
                    withAnimation(.easeInOut(duration: 0.35)) { camera = c }
                }
                .frame(width: 220, height: 220 * World.size.height / World.size.width)
                .position(x: size.width - 122, y: size.height - 12 - 110 * World.size.height / World.size.width)
                .opacity(dialogueId != nil && dialogueLarge ? 0 : 1)

                // Cards live outside the clipped map so they can overflow its edges.
                if let id = hoveredId, id != selectedId, let item = items.first(where: { $0.session.id == id }) {
                    HoverCard(session: item.session, agentName: store.agentName(for: item.session))
                        .fixedSize()
                        .position(cardCenter(cam.screen(drawn[id] ?? item.point, in: size), cardSize: CGSize(width: 240, height: 120),
                                             avatar: cam.scale * 0.06, bounds: size))
                }
                if let id = selectedId, let item = items.first(where: { $0.session.id == id }) {
                    StatusCard(session: item.session, agentName: store.agentName(for: item.session),
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
                                             avatar: cam.scale * 0.06, bounds: size))
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
                    if dialogueLarge {
                        let width = max(360, geo.size.width * 0.5)
                        panel
                            .frame(width: width, height: geo.size.height)
                            .position(x: geo.size.width - width / 2, y: geo.size.height / 2)
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

    /// Keeps a fraction inside [margin, 1 - margin] so the PIP never leaves the view.
    private func clamp(_ v: Double, _ margin: Double) -> Double { min(max(v, margin), 1 - margin) }

    /// Beside the avatar, on the side with more room, clamped to the view.
    private func cardCenter(_ a: CGPoint, cardSize: CGSize, avatar: CGFloat, bounds: CGSize) -> CGPoint {
        let gap = avatar + cardSize.width / 2
        let x = a.x > bounds.width / 2 ? a.x - gap : a.x + gap
        let hw = cardSize.width / 2, hh = cardSize.height / 2
        return CGPoint(x: min(max(x, hw), bounds.width - hw), y: min(max(a.y, hh), bounds.height - hh))
    }

    /// Opens on the guild hall filling the view.
    private func initialCamera(_ size: CGSize) -> Camera {
        var c = Camera(center: CGPoint(x: 0.5, y: World.areaH / 2),
                       scale: min(size.width, size.height * 16 / 9))
        if ProcessInfo.processInfo.environment["SUHYEOK_FIT_ALL"] != nil { c.scale = 0 }  // snapshots of the whole world
        c.clamp(size)
        DispatchQueue.main.async { if camera.scale == 0 { camera = c } }
        return c
    }

    @ViewBuilder private func areaImage(_ area: World.Area) -> some View {
        if let img = Art.image(area.image) {
            Image(nsImage: img).resizable().interpolation(.none)
        } else {
            Color(red: 0.25, green: 0.18, blue: 0.13).overlay(Text(area.label).foregroundStyle(.white.opacity(0.5)))
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
                    withAnimation(.easeInOut(duration: 0.4)) { camera = n }
                    selectedId = m.item.session.id
                }
        }
    }

    private func layoutMarkers(_ items: [Placed], cam: Camera, size: CGSize) -> [Marker] {
        let inset: CGFloat = 24, spacing: CGFloat = 38
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
                withAnimation(.easeInOut(duration: 0.35)) { camera = c }
            } label: { Image(systemName: "rectangle.expand.vertical") }
            .help("전체 보기")
        }
        .buttonStyle(.borderedProminent).tint(Color.black.opacity(0.55)).controlSize(.small)
    }

    private func zoom(_ cam: Camera, _ f: CGFloat, _ size: CGSize) {
        var c = cam; c.scale *= f; c.clamp(size)
        withAnimation(.easeInOut(duration: 0.2)) { camera = c }
    }

    private struct Placed { let session: AgentSession; let character: Character?; let point: CGPoint }

    private func placed() -> [Placed] {
        var out: [Placed] = []
        let byStart: (AgentSession, AgentSession) -> Bool = { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let working = Dictionary(grouping: store.sessions.filter { store.station(for: $0) != nil }) { store.station(for: $0)! }
        for (kind, members) in working {
            let spots = World.stations(for: kind)
            for (i, s) in members.sorted(by: byStart).enumerated() {
                out.append(Placed(session: s, character: store.character(for: s), point: World.spot(spots, i)))
            }
        }
        let others = Dictionary(grouping: store.sessions.filter { store.station(for: $0) == nil }) { $0.activity }
        for (activity, members) in others {
            let spots = World.spots(for: activity)
            for (i, s) in members.sorted(by: byStart).enumerated() {
                out.append(Placed(session: s, character: store.character(for: s), point: World.spot(spots, i)))
            }
        }
        return out
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
                ForEach(World.Area.allCases, id: \.self) { a in
                    Group {
                        if let img = Art.image(a.image) { Image(nsImage: img).resizable() } else { Color.gray }
                    }
                    .frame(width: a.rect.width * k, height: a.rect.height * k)
                    .offset(x: a.rect.minX * k, y: a.rect.minY * k)
                    .opacity(0.8)
                }
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
            Triangle().fill(color).frame(width: 10, height: 10).offset(x: 22).rotationEffect(.radians(angle))
            Circle().fill(Color.black.opacity(0.7)).frame(width: 34, height: 34)
            if let c = character, let img = Art.image("sprites/\(c.id)") {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30, alignment: .top).clipShape(Circle())
            }
            Circle().stroke(color, lineWidth: 2).frame(width: 34, height: 34)
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
    private(set) var facing: [String: Facing] = [:]  // kept after arriving, so agents face where they walked
    /// Debug hook (--trace-walk): receives every step.
    nonisolated(unsafe) static var trace: (([String: CGPoint], [String: Facing], TimeInterval) -> Void)?
    private var lastTick: TimeInterval?
    private let speed: CGFloat = 0.12  // map widths per second

    func step(targets: [(String, CGPoint)], now: TimeInterval) -> [String: CGPoint] {
        let dt = CGFloat(min(now - (lastTick ?? now), 0.25))
        lastTick = now
        var next: [String: CGPoint] = [:]
        for (id, target) in targets {
            let p = current[id] ?? target  // new sessions appear in place
            let dx = target.x - p.x, dy = target.y - p.y
            let dist = sqrt(dx * dx + dy * dy)
            let move = speed * dt
            next[id] = dist <= move ? target : CGPoint(x: p.x + dx / dist * move, y: p.y + dy / dist * move)
            if dist > move {
                // Map y grows downward; world units are the same on both axes.
                facing[id] = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
            } else if dist == 0, facing[id] == nil {
                facing[id] = .down
            }
        }
        current = next
        if let trace = Walker.trace { trace(next, facing, now) }
        return next
    }
}

struct Avatar: View {
    let session: AgentSession
    let character: Character?
    let station: AgentAction.Kind?
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
        if walking {
            let f = cycle[Int(time * 8) % 4]
            switch facing {
            case .down: return ("walk_down_\(f)", false)
            case .up: return ("walk_up_\(f)", false)
            case .left: return ("walk_left_\(f)", false)
            case .right: return ("walk_left_\(f)", true)
            }
        }
        guard session.activity == .working else { return ("walk_down_1", false) }
        switch station {
        case .shell?: return ("hammer_\(cycle[Int(time * 6 + phase) % 4])", false)
        case .editing?, .replying?, .other?: return ("type_\(cycle[Int(time * 6 + phase) % 4])", false)
        case .reading?: return ("read_\(cycle[Int(time * 1.5 + phase) % 4])", false)
        default: return ("walk_down_1", false)
        }
    }

    var body: some View {
        // Per-session phase so characters don't move in lockstep.
        let phase = Double(abs(session.id.hashValue % 100)) / 15
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                sprite(phase)
                    // Looking around while scouting the web: face left and right in turns.
                    .scaleEffect(x: station == .web && !walking && Int(time / 1.5) % 2 == 1 ? -1 : 1)
                    .offset(y: bob(phase))
                    .rotationEffect(.degrees(swing(phase)), anchor: .bottom)
                if station == .shell, !walking {
                    Sparks(time: time + phase, height: height)
                }
                if session.activity == .waiting {
                    // Speech bubble: waiting for the next instruction.
                    Text("…").font(.system(size: height * 0.2, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, height * 0.06)
                        .background(.white, in: Capsule())
                        .opacity(0.6 + 0.4 * abs(sin(time * 2 + phase)))
                        .offset(x: height * 0.2, y: -height * 0.12)
                }
                if session.activity == .resting {
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

    private func swing(_ phase: Double) -> Double {
        if walking { return frames ? 0 : sin(time * 12) * 5 }
        if frames, [.shell, .reading].contains(station) { return 0 }  // drawn into the frames
        switch station {
        case .shell?: return max(0, sin(time * 6 + phase)) * 12 - 3   // hammer strikes on the anvil
        case .reading?: return sin(time * 1.2 + phase) * 3            // nodding along the board
        case .delegating?: return sin(time * 4 + phase) * 4           // animated discussion
        default: return 0
        }
    }

    private func bob(_ phase: Double) -> CGFloat {
        if walking { return frames ? 0 : -CGFloat(abs(sin(time * 12))) * height * 0.08 }
        switch session.activity {
        case .working:
            switch station {
            case .shell?, .reading?, .web?: return 0
            case .delegating?: return -CGFloat(abs(sin(time * 5 + phase))) * height * 0.05
            case .thinking?: return CGFloat(sin(time * 2 + phase)) * height * 0.015
            default: return frames ? 0 : -CGFloat(abs(sin(time * 9 + phase))) * height * 0.05  // typing at the desk
            }
        case .waiting: return CGFloat(sin(time * 3 + phase)) * height * 0.02
        case .resting: return CGFloat(sin(time * 1.2 + phase)) * height * 0.012
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
