import Foundation

/// Walkable grid over the whole world (art/walkmap.py → walkmap.json) and A* routes on it.
final class Pathfinder {
    static let shared = Pathfinder()

    let res: CGFloat
    let cols: Int
    let rows: Int
    /// Corridor rectangles in world units, drawn between the areas.
    let corridors: [CGRect]
    private let walkable: [Bool]

    private init() {
        struct File: Decodable { let res: Int; let cols: Int; let rows: Int; let corridors: [[Double]]; let cells: [String] }
        if let url = Art.dir?.appendingPathComponent("walkmap.json"),
           let data = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(File.self, from: data) {
            res = CGFloat(f.res); cols = f.cols; rows = f.rows
            corridors = f.corridors.map { CGRect(x: $0[0], y: $0[2], width: $0[1] - $0[0], height: $0[3] - $0[2]) }
            walkable = f.cells.flatMap { $0.map { $0 == "." } }
        } else {
            // No grid shipped: everything is walkable and agents walk straight.
            res = 1; cols = 0; rows = 0; corridors = []; walkable = []
        }
    }

    var enabled: Bool { !walkable.isEmpty }

    private func cell(_ p: CGPoint) -> (Int, Int) {
        (min(max(Int(p.x * res), 0), cols - 1), min(max(Int(p.y * res), 0), rows - 1))
    }
    private func centre(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: (CGFloat(x) + 0.5) / res, y: (CGFloat(y) + 0.5) / res) }
    private func ok(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < cols && y < rows && walkable[y * cols + x] }

    func isWalkable(_ p: CGPoint) -> Bool {
        guard enabled else { return true }
        let (x, y) = cell(p)
        return ok(x, y)
    }

    /// The walkable cell centre closest to p (searching outward ring by ring).
    func nearest(_ p: CGPoint) -> CGPoint {
        guard enabled, !isWalkable(p) else { return p }
        let (cx, cy) = cell(p)
        for r in 1..<60 {
            var best: (CGFloat, CGPoint)?
            for dy in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dy) == r {
                    guard ok(cx + dx, cy + dy) else { continue }
                    let c = centre(cx + dx, cy + dy)
                    let d = CGFloat(hypot(c.x - p.x, c.y - p.y))
                    if best == nil || d < best!.0 { best = (d, c) }
                }
            }
            if let best { return best.1 }
        }
        return p
    }

    /// Route from a to b as world points (b last). Straight when the grid is missing or no route exists.
    func route(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        guard enabled else { return [b] }
        let start = cell(nearest(a)), goal = cell(nearest(b))
        if start == goal || clear(a, b) { return [b] }
        let n = cols * rows
        var g = [Float](repeating: .infinity, count: n)
        var from = [Int32](repeating: -1, count: n)
        var open = Heap()
        let si = start.1 * cols + start.0, gi = goal.1 * cols + goal.0
        g[si] = 0
        open.push(si, h(start, goal))
        let steps: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                          (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)]
        var found = false
        while let cur = open.pop() {
            if cur == gi { found = true; break }
            let x = cur % cols, y = cur / cols
            for (dx, dy, cost) in steps {
                let nx = x + dx, ny = y + dy
                guard ok(nx, ny) else { continue }
                if dx != 0 && dy != 0 && !(ok(x + dx, y) && ok(x, y + dy)) { continue }  // no corner cutting
                let ni = ny * cols + nx
                let ng = g[cur] + cost
                if ng < g[ni] {
                    g[ni] = ng; from[ni] = Int32(cur)
                    open.push(ni, ng + h((nx, ny), goal))
                }
            }
        }
        guard found else { return [b] }
        var cellsPath: [CGPoint] = []
        var i = gi
        while i != si { cellsPath.append(centre(i % cols, i / cols)); i = Int(from[i]) }
        cellsPath.reverse()
        // String-pull: keep only the turns that are needed to stay on walkable cells.
        var out: [CGPoint] = []
        var anchor = a
        var k = 0
        while k < cellsPath.count {
            var far = k
            while far + 1 < cellsPath.count && clear(anchor, cellsPath[far + 1]) { far += 1 }
            out.append(cellsPath[far]); anchor = cellsPath[far]; k = far + 1
        }
        if let last = out.last, clear(last, b) { out[out.count - 1] = b } else { out.append(b) }
        return out
    }

    private func h(_ a: (Int, Int), _ b: (Int, Int)) -> Float {
        let dx = Float(abs(a.0 - b.0)), dy = Float(abs(a.1 - b.1))
        return max(dx, dy) + 0.414 * min(dx, dy)
    }

    /// True when the straight segment stays on walkable cells (sampled at quarter-cell steps).
    func clear(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let d = hypot(b.x - a.x, b.y - a.y)
        let n = max(1, Int(d * res * 4))
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            if !isWalkable(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { return false }
        }
        return true
    }

    /// Minimal binary min-heap of (index, priority).
    private struct Heap {
        private var items: [(Int, Float)] = []
        mutating func push(_ i: Int, _ p: Float) {
            items.append((i, p))
            var c = items.count - 1
            while c > 0 { let parent = (c - 1) / 2; if items[parent].1 <= items[c].1 { break }; items.swapAt(c, parent); c = parent }
        }
        mutating func pop() -> Int? {
            guard !items.isEmpty else { return nil }
            let top = items[0].0
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var c = 0
                while true {
                    let l = 2 * c + 1, r = l + 1
                    var m = c
                    if l < items.count && items[l].1 < items[m].1 { m = l }
                    if r < items.count && items[r].1 < items[m].1 { m = r }
                    if m == c { break }
                    items.swapAt(c, m); c = m
                }
            }
            return top
        }
    }
}
