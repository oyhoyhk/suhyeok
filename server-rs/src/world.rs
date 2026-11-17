//! The world map: a port of the `World` enum (Sources/AgentDeck/WorldView.swift) and the parts of
//! `Pathfinder` (Pathfinder.swift) the server needs: the walk grid from art `walkmap.json`, boss footprints,
//! named standing spots and `nearest`. A* routes are not ported: the desk page walks agents itself
//! (axis-aligned steps towards `agents[].x/y`), and `/api/state` only uses placements and boss rects.

use crate::hunt::Tier;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;

/// World size in world units (Swift `World.size`): 1 × 9/16.
pub const WIDTH: f64 = 1.0;
pub const HEIGHT: f64 = 9.0 / 16.0;
/// Avatar height in world units (Swift `World.avatarHeight`).
pub const AVATAR_HEIGHT: f64 = 0.034;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    pub fn mid_x(&self) -> f64 {
        self.x + self.w / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.0
    }
}

/// Walk grid, spots and bosses loaded from `walkmap.json` (Swift `Pathfinder.shared` + `World`).
#[derive(Clone, Debug)]
pub struct World {
    res: f64,
    cols: i64,
    rows: i64,
    walkable: Vec<bool>,
    spots: HashMap<String, Vec<Point>>,
    bosses: HashMap<String, Rect>,
}

#[derive(Deserialize)]
struct WalkFile {
    res: i64,
    cols: i64,
    rows: i64,
    #[allow(dead_code)]
    corridors: Vec<Vec<f64>>,
    cells: Vec<String>,
    spots: Option<HashMap<String, Vec<Vec<f64>>>>,
    bosses: Option<HashMap<String, BossFile>>,
}

#[derive(Deserialize)]
struct BossFile {
    center: Vec<f64>,
    half: Vec<f64>,
}

impl World {
    /// Reads `<art_dir>/walkmap.json` (the app bundle's Resources/art; art/out in the repo). Without the file,
    /// or when it does not decode, everything is walkable and there are no spots or bosses, like Swift.
    pub fn load(art_dir: &Path) -> World {
        std::fs::read(art_dir.join("walkmap.json"))
            .ok()
            .and_then(|d| serde_json::from_slice::<WalkFile>(&d).ok())
            .and_then(World::from_file)
            .unwrap_or_else(World::empty)
    }

    /// No grid shipped: everything is walkable and agents walk straight.
    pub fn empty() -> World {
        World { res: 1.0, cols: 0, rows: 0, walkable: vec![], spots: HashMap::new(), bosses: HashMap::new() }
    }

    fn from_file(f: WalkFile) -> Option<World> {
        // Swift indexes `$0[0]`… and traps on short arrays; here a malformed entry fails the whole load instead.
        let pt = |v: &Vec<f64>| (v.len() >= 2).then(|| Point { x: v[0], y: v[1] });
        let mut spots = HashMap::new();
        for (k, list) in f.spots.unwrap_or_default() {
            spots.insert(k, list.iter().map(pt).collect::<Option<Vec<_>>>()?);
        }
        let mut bosses = HashMap::new();
        for (k, b) in f.bosses.unwrap_or_default() {
            let (c, h) = (pt(&b.center)?, pt(&b.half)?);
            bosses.insert(k, Rect { x: c.x - h.x, y: c.y - h.y, w: 2.0 * h.x, h: 2.0 * h.y });
        }
        let walkable = f.cells.iter().flat_map(|row| row.chars().map(|c| c == '.')).collect();
        Some(World { res: f.res as f64, cols: f.cols, rows: f.rows, walkable, spots, bosses })
    }

    /// "low" / "mid" / "high" (Swift `World.key`).
    pub fn key(t: Tier) -> &'static str {
        ["low", "mid", "high"][t as usize]
    }

    /// Boss footprint in world units, zero when the walkmap has none.
    pub fn boss(&self, t: Tier) -> Rect {
        self.bosses.get(World::key(t)).copied().unwrap_or(Rect::ZERO)
    }

    /// Standing spots picked by art/walkmap.py, in fill order.
    pub fn spots(&self, name: &str) -> &[Point] {
        self.spots.get(name).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn attack_spots(&self, t: Tier) -> &[Point] {
        self.spots(&format!("attack_{}", World::key(t)))
    }

    pub fn camp_spots(&self) -> &[Point] {
        self.spots("camp")
    }

    /// Spot i of a list; past the end, agents stand in small steps beside the earlier ones.
    pub fn spot(list: &[Point], i: usize) -> Point {
        if list.is_empty() {
            return Point { x: 0.5, y: 0.27 };
        }
        let mut p = list[i % list.len()];
        p.y += (i / list.len()) as f64 * 0.012;
        p
    }

    pub fn enabled(&self) -> bool {
        !self.walkable.is_empty()
    }

    fn cell(&self, p: Point) -> (i64, i64) {
        // Swift `Int(p.x * res)` truncates toward zero; `as` does too (and saturates instead of trapping).
        (((p.x * self.res) as i64).clamp(0, self.cols - 1), ((p.y * self.res) as i64).clamp(0, self.rows - 1))
    }

    fn centre(&self, x: i64, y: i64) -> Point {
        Point { x: (x as f64 + 0.5) / self.res, y: (y as f64 + 0.5) / self.res }
    }

    fn ok(&self, x: i64, y: i64) -> bool {
        x >= 0 && y >= 0 && x < self.cols && y < self.rows && self.walkable.get((y * self.cols + x) as usize) == Some(&true)
    }

    pub fn is_walkable(&self, p: Point) -> bool {
        if !self.enabled() {
            return true;
        }
        let (x, y) = self.cell(p);
        self.ok(x, y)
    }

    /// The walkable cell centre closest to p (searching outward ring by ring).
    pub fn nearest(&self, p: Point) -> Point {
        if !self.enabled() || self.is_walkable(p) {
            return p;
        }
        let (cx, cy) = self.cell(p);
        for r in 1..60i64 {
            let mut best: Option<(f64, Point)> = None;
            for dy in -r..=r {
                for dx in -r..=r {
                    if dx.abs() != r && dy.abs() != r {
                        continue;
                    }
                    if !self.ok(cx + dx, cy + dy) {
                        continue;
                    }
                    let c = self.centre(cx + dx, cy + dy);
                    let d = (c.x - p.x).hypot(c.y - p.y);
                    if best.is_none_or(|(bd, _)| d < bd) {
                        best = Some((d, c));
                    }
                }
            }
            if let Some((_, c)) = best {
                return c;
            }
        }
        p
    }

    /// `bosses[]` of `/api/state`: key, name, centre and size of each boss, low to high.
    pub fn bosses_json(&self, en: bool) -> Value {
        Value::Array(
            Tier::ALL
                .iter()
                .map(|&t| {
                    let r = self.boss(t);
                    json!({"key": World::key(t), "name": t.boss(en), "x": r.mid_x(), "y": r.mid_y(), "w": r.w, "h": r.h})
                })
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn art_out() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../art/out")
    }

    #[test]
    fn loads_the_real_walkmap() {
        let w = World::load(&art_out());
        assert!(w.enabled());
        assert_eq!((w.res, w.cols, w.rows), (192.0, 192, 108));
        assert_eq!(w.walkable.len(), 192 * 108);
        assert_eq!(w.camp_spots().len(), 32);
        assert_eq!(w.attack_spots(Tier::Low).len(), 21);
        assert_eq!(w.attack_spots(Tier::High).len(), 20);
        let low = w.boss(Tier::Low);
        assert!((low.mid_x() - 0.75).abs() < 1e-12 && (low.mid_y() - 0.1434).abs() < 1e-12);
        assert!((low.w - 0.09).abs() < 1e-12);
        // Every standing spot art/walkmap.py picked is on a walkable cell, so `nearest` keeps it.
        for name in ["camp", "attack_low", "attack_mid", "attack_high"] {
            for &p in w.spots(name) {
                assert_eq!(w.nearest(p), p, "{name} {p:?}");
            }
        }
    }

    #[test]
    fn nearest_moves_off_blocked_cells_to_a_cell_centre() {
        let w = World::load(&art_out());
        let boss = w.boss(Tier::High);
        let p = Point { x: boss.mid_x(), y: boss.mid_y() };
        assert!(!w.is_walkable(p)); // bosses stand on blocked cells
        let q = w.nearest(p);
        assert!(w.is_walkable(q));
        // A cell centre: (k + 0.5) / res.
        assert!(((q.x * 192.0 - 0.5).fract()).abs() < 1e-9);
    }

    #[test]
    fn missing_walkmap_is_open_ground() {
        let w = World::load(Path::new("/nonexistent-art-dir"));
        assert!(!w.enabled());
        let p = Point { x: 0.3, y: 0.2 };
        assert_eq!(w.nearest(p), p);
        assert_eq!(w.boss(Tier::Mid), Rect::ZERO);
        assert_eq!(World::spot(w.camp_spots(), 3), Point { x: 0.5, y: 0.27 });
    }

    #[test]
    fn spots_past_the_end_step_down() {
        let list = [Point { x: 0.1, y: 0.2 }, Point { x: 0.3, y: 0.4 }];
        assert_eq!(World::spot(&list, 1), Point { x: 0.3, y: 0.4 });
        let p = World::spot(&list, 4);
        assert_eq!(p.x, 0.1);
        assert!((p.y - (0.2 + 2.0 * 0.012)).abs() < 1e-12);
    }

    #[test]
    fn grid_from_a_small_walkmap() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("walkmap.json"),
            r#"{"res":4,"cols":4,"rows":2,"corridors":[],"cells":["x..x","xxxx"],
                "spots":{"camp":[[0.4,0.1]]},"bosses":{"low":{"center":[0.5,0.25],"half":[0.1,0.05]}}}"#,
        )
        .unwrap();
        let w = World::load(dir.path());
        assert!(w.is_walkable(Point { x: 0.3, y: 0.1 }));
        assert!(!w.is_walkable(Point { x: 0.1, y: 0.1 }));
        // From cell (0,1) the ring-1 candidates are (1,0) only: centre (0.375, 0.125).
        assert_eq!(w.nearest(Point { x: 0.1, y: 0.3 }), Point { x: 0.375, y: 0.125 });
        assert_eq!(w.boss(Tier::Low), Rect { x: 0.4, y: 0.2, w: 0.2, h: 0.1 });
        let b = w.bosses_json(true);
        assert_eq!(b[0]["name"], "Forest Slime King");
        assert_eq!(b[1]["w"], 0.0);
    }
}
