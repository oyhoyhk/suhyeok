import SwiftUI

/// Normalized (0...1) rectangles on the map image where each activity gathers.
enum Zone {
    static func rect(for activity: Activity) -> CGRect {
        switch activity {
        // Tuned to art/out/map.png (z_image guild hall).
        case .working: return CGRect(x: 0.06, y: 0.12, width: 0.28, height: 0.76) // desk hall, left
        case .waiting: return CGRect(x: 0.44, y: 0.62, width: 0.22, height: 0.26) // tavern by the bar, bottom middle
        case .resting: return CGRect(x: 0.70, y: 0.22, width: 0.25, height: 0.68) // lounge, right
        }
    }

    /// Chairs in front of the desks in the work hall (art/out/map.png), filled top to bottom.
    static let deskSeats: [CGPoint] = [0.26, 0.43, 0.71, 0.86].flatMap { y in
        [0.09, 0.15, 0.22, 0.29].map { x in CGPoint(x: x, y: y) }
    }

    /// Spreads `count` slots over the zone in a grid that follows the zone's shape.
    static func slot(_ index: Int, of count: Int, in r: CGRect, aspect: CGFloat) -> CGPoint {
        let ratio = (r.width * aspect) / r.height
        let cols = max(1, Int(ceil(sqrt(Double(count) * ratio))))
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))
        let col = index % cols, row = index / cols
        return CGPoint(x: r.minX + r.width * (CGFloat(col) + 0.5) / CGFloat(cols),
                       y: r.minY + r.height * (CGFloat(row) + 0.5) / CGFloat(rows))
    }
}

struct WorldView: View {
    @ObservedObject var store: SessionStore
    @State private var selectedId: String?
    @State private var hoveredId: String?

    init(store: SessionStore, initialSelection: String? = nil) {
        self.store = store
        _selectedId = State(initialValue: initialSelection)
    }
    @State private var walker = Walker()

    private let mapAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader { geo in
            let size = fitted(geo.size)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            let items = placed()
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    mapBackground.frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedId = nil }
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let positions = walker.step(targets: items.map { ($0.session.id, $0.point) }, now: t)
                        ZStack(alignment: .topLeading) {
                            ForEach(items, id: \.session.id) { item in
                                let p = positions[item.session.id] ?? item.point
                                Avatar(session: item.session, character: item.character,
                                       agentName: store.agentName(for: item.session), time: t,
                                       height: size.width * 0.07, selected: item.session.id == selectedId,
                                       walking: p != item.point)
                                    .position(x: p.x * size.width, y: p.y * size.height)
                                    .onTapGesture { selectedId = item.session.id == selectedId ? nil : item.session.id }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Per-avatar onHover misses exit events while the timeline rebuilds the views,
                // so hit-test the pointer against avatar slots instead.
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let radius = size.width * 0.045
                        hoveredId = items.map { item -> (String, CGFloat) in
                            let dx = item.point.x * size.width - loc.x, dy = item.point.y * size.height - loc.y
                            return (item.session.id, sqrt(dx * dx + dy * dy))
                        }.filter { $0.1 < radius }.min { $0.1 < $1.1 }?.0
                    case .ended:
                        hoveredId = nil
                    }
                }
                .offset(x: origin.x, y: origin.y)

                // Cards live outside the clipped map so they can overflow its edges.
                if let id = hoveredId, id != selectedId, let item = items.first(where: { $0.session.id == id }) {
                    HoverCard(session: item.session, agentName: store.agentName(for: item.session))
                        .fixedSize()
                        .position(cardCenter(item.point, cardSize: CGSize(width: 240, height: 120),
                                             map: size, origin: origin, bounds: geo.size))
                }
                if let id = selectedId, let item = items.first(where: { $0.session.id == id }) {
                    StatusCard(session: item.session, agentName: store.agentName(for: item.session),
                               character: item.character, close: { selectedId = nil },
                               openTerminal: { store.selection = store.pane(for: item.session) })
                        .fixedSize()
                        .position(cardCenter(item.point, cardSize: CGSize(width: 320, height: 340),
                                             map: size, origin: origin, bounds: geo.size))
                }
            }
        }
        .padding(12)
    }

    /// Beside the avatar, on the side with more room, clamped to the view.
    private func cardCenter(_ p: CGPoint, cardSize: CGSize, map: CGSize, origin: CGPoint, bounds: CGSize) -> CGPoint {
        let ax = origin.x + p.x * map.width, ay = origin.y + p.y * map.height
        let gap = map.width * 0.06 + cardSize.width / 2
        let x = p.x > 0.5 ? ax - gap : ax + gap
        let hw = cardSize.width / 2, hh = cardSize.height / 2
        return CGPoint(x: min(max(x, hw), bounds.width - hw), y: min(max(ay, hh), bounds.height - hh))
    }

    @ViewBuilder private var mapBackground: some View {
        if let map = Art.image("map") {
            Image(nsImage: map).resizable().interpolation(.none)
        } else {
            ZStack {
                Color(red: 0.25, green: 0.18, blue: 0.13)
                ForEach(Activity.allCases, id: \.self) { s in
                    GeometryReader { g in
                        let r = Zone.rect(for: s)
                        RoundedRectangle(cornerRadius: 6).fill(s.color.opacity(0.12))
                            .overlay(Text(s.zoneName).font(.caption.bold()).foregroundStyle(.white.opacity(0.5))
                                .padding(6), alignment: .topLeading)
                            .frame(width: r.width * g.size.width, height: r.height * g.size.height)
                            .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                    }
                }
            }
        }
    }

    private func fitted(_ avail: CGSize) -> CGSize {
        let w = min(avail.width, avail.height * mapAspect)
        return CGSize(width: w, height: w / mapAspect)
    }

    private struct Placed { let session: AgentSession; let character: Character?; let point: CGPoint }

    private func placed() -> [Placed] {
        var out: [Placed] = []
        let groups = Dictionary(grouping: store.sessions) { $0.activity }
        for (activity, members) in groups {
            let sorted = members.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            for (i, s) in sorted.enumerated() {
                let p = activity == .working && i < Zone.deskSeats.count
                    ? Zone.deskSeats[i]
                    : Zone.slot(i, of: sorted.count, in: Zone.rect(for: activity), aspect: mapAspect)
                out.append(Placed(session: s, character: store.character(for: s), point: p))
            }
        }
        return out
    }
}

/// Moves each avatar toward its zone slot at walking speed, frame by frame.
/// SwiftUI implicit animations stall when the TimelineView rebuilds the tree every tick.
final class Walker {
    private var current: [String: CGPoint] = [:]
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
        }
        current = next
        return next
    }
}

struct Avatar: View {
    let session: AgentSession
    let character: Character?
    let agentName: String
    let time: TimeInterval
    let height: CGFloat
    let selected: Bool
    var walking = false

    var body: some View {
        // Per-session phase so characters don't move in lockstep.
        let phase = Double(abs(session.id.hashValue % 100)) / 15
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                sprite
                    .frame(height: height)
                    .offset(y: bob(phase))
                    .rotationEffect(.degrees(swing(phase)), anchor: .bottom)
                if session.activity == .working, !walking {
                    WorkEffect(action: session.action ?? AgentAction(kind: session.status == .shell ? .shell : .other, detail: ""),
                               time: time + phase, height: height)
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
        .background(selected ? Color.white.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 2))
    }

    private func swing(_ phase: Double) -> Double {
        if walking { return sin(time * 12) * 5 }
        guard session.activity == .working else { return 0 }
        switch session.action?.kind ?? (session.status == .shell ? .shell : .other) {
        case .shell: return max(0, sin(time * 6 + phase)) * 10 - 3  // hammer strikes
        case .reading: return sin(time * 1.5 + phase) * 3           // nodding over a page
        default: return 0
        }
    }

    private func bob(_ phase: Double) -> CGFloat {
        if walking { return -CGFloat(abs(sin(time * 12))) * height * 0.08 }
        switch session.activity {
        case .working:
            switch session.action?.kind {
            case .shell?: return 0  // swings instead (rotation)
            case .reading?, .thinking?: return CGFloat(sin(time * 2 + phase)) * height * 0.02
            default: return -CGFloat(abs(sin(time * 9 + phase))) * height * 0.05  // typing
            }
        case .waiting: return CGFloat(sin(time * 3 + phase)) * height * 0.02
        case .resting: return CGFloat(sin(time * 1.2 + phase)) * height * 0.012
        }
    }

    @ViewBuilder private var sprite: some View {
        if let c = character, let img = Art.image("sprites/\(c.id)") {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
        } else {
            Circle().fill(session.activity.color)
                .overlay(Text(String(agentName.prefix(1))).font(.headline).foregroundStyle(.white))
                .aspectRatio(1, contentMode: .fit)
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

/// Floating action icon plus particles above a working avatar.
struct WorkEffect: View {
    let action: AgentAction
    let time: TimeInterval
    let height: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in particle(i) }
            Image(systemName: action.symbol)
                .font(.system(size: height * 0.18, weight: .bold))
                .foregroundStyle(tint)
                .padding(height * 0.06)
                .background(.white, in: Circle())
                .scaleEffect(1 + 0.08 * sin(time * 4))
                .offset(y: -height * 0.62)
        }
        .allowsHitTesting(false)
    }

    private var tint: Color {
        switch action.kind {
        case .shell: return .orange
        case .editing: return .blue
        case .reading: return .brown
        case .web: return .teal
        case .delegating: return .purple
        case .thinking: return .pink
        default: return .green
        }
    }

    /// Each particle loops on its own phase: sparks burst for shell, keys pop for typing, dots drift otherwise.
    private func particle(_ i: Int) -> some View {
        let t = (time * 1.4 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
        let angle = Double(i) * .pi / 2 + 0.6
        let size = height * (action.kind == .shell ? 0.05 : 0.04)
        let dx: CGFloat, dy: CGFloat
        switch action.kind {
        case .shell:
            dx = CGFloat(cos(angle) * t) * height * 0.35
            dy = height * 0.1 - CGFloat(abs(sin(angle)) * t) * height * 0.35
        case .editing, .replying, .other:
            dx = CGFloat(Double(i) - 1.5) * height * 0.1
            dy = height * 0.05 - CGFloat(t) * height * 0.3
        default:
            dx = CGFloat(sin(t * .pi * 2 + Double(i))) * height * 0.08
            dy = -height * 0.3 - CGFloat(t) * height * 0.2
        }
        return RoundedRectangle(cornerRadius: action.kind == .shell ? size : size * 0.2)
            .fill(action.kind == .shell ? Color.yellow : tint.opacity(0.8))
            .frame(width: size, height: size)
            .offset(x: dx, y: dy)
            .opacity(1 - t)
    }
}
