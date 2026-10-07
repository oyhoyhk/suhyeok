"""Walk grid, boss positions and standing spots for the field map (out/field.jpg), written to out/walkmap.json.

Rectangles are (x0, x1, y0, y1) as fractions of the image (measured on raw/town2_b_gpt_image_2.webp).
World units used by the app: the map is 1 wide and 9/16 tall.
usage: python3 fieldmap.py [preview.png]
"""
import json
import math
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
ASPECT = 9 / 16
RES = 192

FLOORS = [
    (0.06, 0.45, 0.08, 0.43),   # camp clearing
    (0.00, 1.00, 0.445, 0.515), # east-west road
    (0.47, 0.525, 0.00, 1.00),  # north-south road
    (0.53, 0.96, 0.12, 0.43),   # forest glade (low)
    (0.07, 0.46, 0.55, 0.92),   # crystal cave (mid)
    (0.53, 0.93, 0.56, 0.93),   # volcanic altar (high)
    (0.22, 0.30, 0.40, 0.46),   # camp gate in the fence
    (0.375, 0.47, 0.41, 0.46),  # camp side path to the road
    (0.66, 0.88, 0.40, 0.46),   # forest glade down to the road
    (0.20, 0.40, 0.50, 0.57),   # road down into the cave
    (0.64, 0.80, 0.50, 0.58),   # road down onto the altar
]
BLOCKS = [
    # camp: tents, watchtower, fire ring, benches, crates
    (0.06, 0.15, 0.06, 0.21), (0.28, 0.36, 0.03, 0.15), (0.35, 0.41, 0.14, 0.23), (0.10, 0.17, 0.29, 0.40),
    (0.02, 0.09, 0.20, 0.36), (0.20, 0.285, 0.21, 0.31), (0.14, 0.17, 0.22, 0.28), (0.31, 0.34, 0.21, 0.27),
    (0.26, 0.30, 0.33, 0.37), (0.20, 0.24, 0.15, 0.18), (0.38, 0.45, 0.30, 0.41),
    # fences beside the camp gate
    (0.06, 0.22, 0.41, 0.445), (0.30, 0.375, 0.41, 0.445),
    # forest: tree clumps and rocks around the clearing
    (0.53, 0.62, 0.12, 0.30), (0.88, 0.96, 0.12, 0.34), (0.53, 0.60, 0.33, 0.43), (0.88, 0.96, 0.36, 0.43),
    (0.62, 0.66, 0.36, 0.43),
    # cave: crystal clusters on the edges
    (0.07, 0.13, 0.55, 0.92), (0.13, 0.20, 0.82, 0.92), (0.40, 0.46, 0.55, 0.62), (0.40, 0.46, 0.80, 0.92),
    (0.13, 0.20, 0.55, 0.60),
    # altar: pillars and lava edges
    (0.53, 0.57, 0.56, 0.93), (0.88, 0.93, 0.56, 0.93), (0.58, 0.64, 0.56, 0.62), (0.80, 0.88, 0.56, 0.64),
    (0.57, 0.66, 0.86, 0.93), (0.82, 0.88, 0.84, 0.93),
]
# Boss arenas: centre and the boss footprint (blocked), in image fractions.
BOSSES = {
    "low": {"center": (0.750, 0.255), "half": (0.045, 0.075)},
    "mid": {"center": (0.255, 0.745), "half": (0.050, 0.085)},
    "high": {"center": (0.735, 0.765), "half": (0.055, 0.095)},
}
CAMP_FIRE = (0.245, 0.26)


def build():
    cols, rows = RES, round(RES * ASPECT)
    grid = [[False] * cols for _ in range(rows)]

    def fill(r, v):
        x0, x1, y0, y1 = r
        for y in range(int(y0 * rows), min(rows, math.ceil(y1 * rows))):
            for x in range(int(x0 * cols), min(cols, math.ceil(x1 * cols))):
                grid[y][x] = v

    for r in FLOORS:
        fill(r, True)
    for r in BLOCKS:
        fill(r, False)
    for b in BOSSES.values():
        (cx, cy), (hx, hy) = b["center"], b["half"]
        fill((cx - hx, cx + hx, cy - hy, cy + hy), False)
    return grid, cols, rows


def ok(grid, cols, rows, p):
    x, y = int(p[0] * cols), int(p[1] * rows)
    return 0 <= y < rows and 0 <= x < cols and grid[y][x]


def attack_slots(grid, cols, rows, boss):
    """Spots left and right of the boss, nearest first, alternating sides; agents face the boss from there."""
    (cx, cy), (hx, _) = boss["center"], boss["half"]
    out = []
    for ring in range(3):
        dx = hx + 0.03 + ring * 0.035
        for dy in (0, -0.055, 0.055, -0.11, 0.11):
            for side in (-1, 1):
                p = (round(cx + side * dx, 4), round(cy + dy, 4))
                if ok(grid, cols, rows, p):
                    out.append(p)
    return out


def camp_spots(grid, cols, rows, n=32):
    """Around the fire first, then spread over the clearing."""
    fx, fy = CAMP_FIRE
    cands = []
    for gy in range(int(0.09 * rows), int(0.42 * rows), 2):
        for gx in range(int(0.07 * cols), int(0.45 * cols), 2):
            if all(0 <= gy + dy < rows and 0 <= gx + dx < cols and grid[gy + dy][gx + dx] for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                cands.append(((gx + 0.5) / cols, (gy + 0.5) / rows))
    cands.sort(key=lambda p: math.hypot(p[0] - fx, (p[1] - fy) * ASPECT))
    picked = []
    for p in cands:
        if all(math.hypot(p[0] - q[0], (p[1] - q[1]) * ASPECT) > 0.028 for q in picked):
            picked.append(p)
        if len(picked) >= n:
            break
    return picked


def reachable(grid, cols, rows, start=(0.5, 0.48)):
    from collections import deque
    s = (int(start[0] * cols), int(start[1] * rows))
    seen, q = {s}, deque([s])
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (x + dx, y + dy)
            if 0 <= n[0] < cols and 0 <= n[1] < rows and grid[n[1]][n[0]] and n not in seen:
                seen.add(n); q.append(n)
    return seen


def world(p):
    return [round(p[0], 4), round(p[1] * ASPECT, 4)]


if __name__ == "__main__":
    grid, cols, rows = build()
    seen = reachable(grid, cols, rows)
    # Cells cut off from the roads are walls in practice.
    grid = [[grid[y][x] and (x, y) in seen for x in range(cols)] for y in range(rows)]
    spots = {f"attack_{k}": [world(p) for p in attack_slots(grid, cols, rows, b)] for k, b in BOSSES.items()}
    spots["camp"] = [world(p) for p in camp_spots(grid, cols, rows)]
    bosses = {k: {"center": world(b["center"]), "half": [b["half"][0], b["half"][1] * ASPECT]} for k, b in BOSSES.items()}
    (ROOT / "out/walkmap.json").write_text(json.dumps({
        "res": RES, "cols": cols, "rows": rows, "corridors": [], "spots": spots, "bosses": bosses,
        "fire": world(CAMP_FIRE),
        "cells": ["".join("." if c else "#" for c in row) for row in grid]}))
    if len(sys.argv) > 1:
        im = Image.open(ROOT / "out/field.jpg").convert("RGBA").resize((1920, 1080))
        over = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        sx, sy = 1920 / cols, 1080 / rows
        for y in range(rows):
            for x in range(cols):
                if grid[y][x]:
                    d.rectangle([x * sx, y * sy, (x + 1) * sx - 1, (y + 1) * sy - 1], fill=(0, 255, 0, 60))
        colors = {"attack_low": "yellow", "attack_mid": "cyan", "attack_high": "red", "camp": "white"}
        for k, pts in spots.items():
            for x, y in pts:
                X, Y = x * 1920, y / ASPECT * 1080
                d.ellipse([X - 6, Y - 6, X + 6, Y + 6], outline=colors[k], width=3)
        im.alpha_composite(over)
        im.convert("RGB").save(sys.argv[1])
    print("ok", {k: len(v) for k, v in spots.items()})
