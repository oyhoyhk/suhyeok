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

    /// Work stations on art/out/map.png; agents walk to the one that matches what they are doing.
    static func stations(for kind: AgentAction.Kind) -> [CGPoint] {
        switch kind {
        case .shell:  // around the anvil in the forge
            return [CGPoint(x: 0.50, y: 0.36), CGPoint(x: 0.60, y: 0.36), CGPoint(x: 0.47, y: 0.27), CGPoint(x: 0.63, y: 0.27)]
        case .reading:  // in front of the quest boards on the walls
            return [0.16, 0.57].flatMap { y in [0.10, 0.20, 0.29].map { CGPoint(x: $0, y: y) } }
        case .web:  // by the guild hall's front door, looking out
            return [CGPoint(x: 0.80, y: 0.15), CGPoint(x: 0.86, y: 0.15), CGPoint(x: 0.74, y: 0.15)]
        case .delegating:  // around the round tables
            return [CGPoint(x: 0.12, y: 0.80), CGPoint(x: 0.28, y: 0.80), CGPoint(x: 0.17, y: 0.88), CGPoint(x: 0.24, y: 0.88)]
        case .thinking:  // pacing in the corridor between the halls
            return [CGPoint(x: 0.375, y: 0.45), CGPoint(x: 0.375, y: 0.62), CGPoint(x: 0.40, y: 0.53)]
        case .editing, .replying, .other:
            return deskSeats
        }
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
    @State private var dialogueId: String?
    @AppStorage("dialogueLarge") private var dialogueLarge = true
    @AppStorage(OpenMode.storageKey) private var openMode = OpenMode.dialogue.rawValue

    init(store: SessionStore, initialSelection: String? = nil, initialDialogue: String? = nil) {
        self.store = store
        _selectedId = State(initialValue: initialSelection)
        _dialogueId = State(initialValue: initialDialogue)
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
                        .onTapGesture { selectedId = nil; dialogueId = nil }  // clicking the world closes cards and the dialogue
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let positions = walker.step(targets: items.map { ($0.session.id, $0.point) }, now: t)
                        ZStack(alignment: .topLeading) {
                            ForEach(items, id: \.session.id) { item in
                                let p = positions[item.session.id] ?? item.point
                                Avatar(session: item.session, character: item.character, station: store.station(for: item.session),
                                       agentName: store.agentName(for: item.session), time: t,
                                       height: size.width * 0.07, selected: item.session.id == selectedId,
                                       walking: p != item.point,
                                       facing: p != item.point ? (walker.facing[item.session.id] ?? .down) : .down)
                                    .position(x: p.x * size.width, y: p.y * size.height)
                                    .onTapGesture { dialogueId = nil; selectedId = item.session.id == selectedId ? nil : item.session.id }
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
                               openTerminal: {
                                   if openMode == OpenMode.dialogue.rawValue {
                                       dialogueId = item.session.id
                                       selectedId = nil
                                   } else {
                                       store.selection = store.pane(for: item.session)
                                   }
                               })
                        .fixedSize()
                        .position(cardCenter(item.point, cardSize: CGSize(width: 320, height: 340),
                                             map: size, origin: origin, bounds: geo.size))
                }
                // NPC-style conversation docked to the right: half the screen, or a narrow strip.
                if let id = dialogueId {
                    let width = max(360, geo.size.width * (dialogueLarge ? 0.5 : 0.34))
                    DialogueView(store: store, sessionId: id, onClose: { dialogueId = nil },
                                 onTerminal: {
                                     if let s = store.sessions.first(where: { $0.id == id }) { store.selection = store.pane(for: s) }
                                     dialogueId = nil
                                 },
                                 large: dialogueLarge,
                                 onToggleSize: { withAnimation(.easeInOut(duration: 0.2)) { dialogueLarge.toggle() } })
                        .frame(width: width, height: geo.size.height)
                        .position(x: geo.size.width - width / 2, y: geo.size.height / 2)
                        .shadow(radius: 16)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.25), value: dialogueId)
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
        let byStart: (AgentSession, AgentSession) -> Bool = { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        // Working agents: grouped by station; a crowded station overflows in small steps.
        let working = Dictionary(grouping: store.sessions.filter { store.station(for: $0) != nil }) { store.station(for: $0)! }
        let pace = Int(Date().timeIntervalSince1970 / 3) % 2  // thinkers turn around every few seconds
        for (kind, members) in working {
            let spots = Zone.stations(for: kind)
            for (i, s) in members.sorted(by: byStart).enumerated() {
                var p = spots[i % spots.count]
                p.x += CGFloat(i / spots.count) * 0.03
                if kind == .thinking { p.y += (pace + i) % 2 == 0 ? -0.06 : 0.06 }
                out.append(Placed(session: s, character: store.character(for: s), point: p))
            }
        }
        let others = Dictionary(grouping: store.sessions.filter { store.station(for: $0) == nil }) { $0.activity }
        for (activity, members) in others {
            let sorted = members.sorted(by: byStart)
            for (i, s) in sorted.enumerated() {
                let p = Zone.slot(i, of: sorted.count, in: Zone.rect(for: activity), aspect: mapAspect)
                out.append(Placed(session: s, character: store.character(for: s), point: p))
            }
        }
        return out
    }
}

/// Moves each avatar toward its zone slot at walking speed, frame by frame.
/// SwiftUI implicit animations stall when the TimelineView rebuilds the tree every tick.
enum Facing { case down, up, left, right }

final class Walker {
    private var current: [String: CGPoint] = [:]
    private(set) var facing: [String: Facing] = [:]  // kept after arriving, so agents face where they walked
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
                // Map y grows downward; compare in screen proportions (the map is 16:9).
                facing[id] = abs(dx) * 16 / 9 > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
            } else if dist == 0, facing[id] == nil {
                facing[id] = .down
            }
        }
        current = next
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
        .background(selected ? Color.white.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 2))
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
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(height: height * img.size.height / 128)
                .scaleEffect(x: mirrored ? -1 : 1)
        } else if let c = character, let img = Art.image("sprites/\(c.id)") {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(height: height)
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
