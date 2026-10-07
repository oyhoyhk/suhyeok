"""Walk grid and standing spots for the town map (out/town.jpg, 16:9), written to out/walkmap.json.

All rectangles are (x0, x1, y0, y1) as fractions of the image, measured on art/raw/town_b_gpt_image_2.webp.
World units used by the app: the map is 1 wide and 9/16 tall.
usage: python3 walkmap.py [preview.png]
"""
import json
import math
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
ASPECT = 9 / 16
RES = 192  # cells per world unit (map width)

FLOORS = [
    (0.14, 0.434, 0.156, 0.383),   # guild workshop interior
    (0.578, 0.859, 0.183, 0.356),  # library interior
    (0.105, 0.415, 0.667, 0.826),  # tavern floor (below the bar stools)
    (0.585, 0.900, 0.530, 0.826),  # garden inside its low walls
    (0.07, 0.93, 0.440, 0.505),    # east-west road
    (0.44, 0.56, 0.04, 0.94),      # north-south road with the grass strips beside it
    (0.262, 0.300, 0.355, 0.445),  # guild door
    (0.700, 0.735, 0.350, 0.445),  # library door
    (0.405, 0.445, 0.680, 0.730),  # tavern side door
    (0.700, 0.735, 0.495, 0.535),  # garden north gate
    (0.555, 0.590, 0.680, 0.730),  # garden west gate
]
BLOCKS = [
    # guild workshop
    (0.150, 0.200, 0.128, 0.239), (0.125, 0.142, 0.16, 0.32), (0.162, 0.186, 0.264, 0.296),
    (0.236, 0.268, 0.187, 0.280), (0.286, 0.318, 0.187, 0.224), (0.286, 0.318, 0.248, 0.296),
    (0.336, 0.368, 0.187, 0.224), (0.336, 0.368, 0.248, 0.296), (0.386, 0.418, 0.187, 0.224),
    (0.386, 0.418, 0.248, 0.296), (0.240, 0.285, 0.300, 0.345), (0.302, 0.348, 0.310, 0.357),
    (0.362, 0.407, 0.321, 0.372), (0.137, 0.173, 0.348, 0.383), (0.193, 0.217, 0.332, 0.383),
    (0.386, 0.420, 0.128, 0.172),
    # library
    (0.578, 0.600, 0.17, 0.33), (0.593, 0.655, 0.198, 0.230), (0.593, 0.655, 0.265, 0.297),
    (0.593, 0.655, 0.331, 0.362), (0.776, 0.848, 0.198, 0.230), (0.776, 0.848, 0.265, 0.297),
    (0.776, 0.848, 0.331, 0.362), (0.693, 0.742, 0.209, 0.302), (0.704, 0.732, 0.160, 0.185),
    (0.855, 0.875, 0.17, 0.26),
    # tavern
    (0.150, 0.200, 0.52, 0.635), (0.218, 0.364, 0.590, 0.668), (0.100, 0.142, 0.575, 0.725),
    (0.398, 0.418, 0.56, 0.69), (0.140, 0.189, 0.667, 0.713), (0.211, 0.257, 0.681, 0.730),
    (0.293, 0.341, 0.681, 0.730), (0.352, 0.401, 0.704, 0.752), (0.102, 0.148, 0.731, 0.785),
    (0.171, 0.220, 0.748, 0.796), (0.265, 0.313, 0.742, 0.791), (0.327, 0.376, 0.770, 0.819),
    (0.107, 0.132, 0.798, 0.826),
    # garden
    (0.584, 0.620, 0.528, 0.684), (0.665, 0.704, 0.528, 0.573), (0.733, 0.773, 0.528, 0.573),
    (0.636, 0.663, 0.50, 0.552), (0.771, 0.838, 0.50, 0.573), (0.811, 0.857, 0.605, 0.684),
    (0.868, 0.902, 0.570, 0.674), (0.674, 0.766, 0.624, 0.757), (0.584, 0.620, 0.727, 0.830),
    (0.811, 0.857, 0.727, 0.823), (0.868, 0.902, 0.698, 0.790), (0.636, 0.670, 0.588, 0.645),
    (0.768, 0.798, 0.588, 0.651), (0.643, 0.676, 0.755, 0.812), (0.765, 0.798, 0.755, 0.812),
    (0.799, 0.867, 0.776, 0.830),
]

# Hand-picked work spots (image fractions), in fill order.
STATIONS = {
    "editing": [(0.302, 0.237), (0.352, 0.237), (0.402, 0.237), (0.302, 0.176), (0.352, 0.176),
                (0.252, 0.176), (0.425, 0.205), (0.425, 0.27), (0.225, 0.290), (0.40, 0.30)],
    "shell": [(0.205, 0.280), (0.150, 0.310), (0.190, 0.312), (0.212, 0.255)],
    "delegating": [(0.232, 0.322), (0.292, 0.322), (0.355, 0.340), (0.415, 0.345)],
    "web": [(0.48, 0.86), (0.52, 0.86), (0.50, 0.83)],
    "reading": [(0.610, 0.243), (0.645, 0.243), (0.800, 0.243), (0.830, 0.243), (0.610, 0.312),
                (0.645, 0.312), (0.800, 0.312), (0.830, 0.312), (0.615, 0.186), (0.825, 0.186)],
    "thinking": [(0.718, 0.322), (0.675, 0.255), (0.762, 0.255), (0.718, 0.195)],
}
# Rooms whose free floor is shared out among waiting / resting agents.
ROOMS = {"waiting": (0.105, 0.415, 0.667, 0.826), "resting": (0.585, 0.900, 0.530, 0.826)}


def build():
    cols, rows = RES, round(RES * ASPECT)
    grid = [[False] * cols for _ in range(rows)]

    def fill(r, value):
        x0, x1, y0, y1 = r
        for y in range(int(y0 * rows), min(rows, math.ceil(y1 * rows))):
            for x in range(int(x0 * cols), min(cols, math.ceil(x1 * cols))):
                grid[y][x] = value

    for r in FLOORS:
        fill(r, True)
    for r in BLOCKS:
        fill(r, False)
    return grid, cols, rows


def room_spots(grid, cols, rows, room, n=24):
    """Spread-out standing spots: lattice points with a clear cell all around, then farthest-point order."""
    x0, x1, y0, y1 = room
    cands = []
    for gy in range(int(y0 * rows) + 1, int(y1 * rows) - 1, 2):
        for gx in range(int(x0 * cols) + 1, int(x1 * cols) - 1, 2):
            if all(0 <= gy + dy < rows and 0 <= gx + dx < cols and grid[gy + dy][gx + dx]
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                cands.append(((gx + 0.5) / cols, (gy + 0.5) / rows))
    if not cands:
        return []
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    picked = [min(cands, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)]
    while len(picked) < min(n, len(cands)):
        picked.append(max(cands, key=lambda p: min((p[0] - q[0]) ** 2 + ((p[1] - q[1]) * ASPECT) ** 2 for q in picked)))
    return picked


def world(p):
    return [round(p[0], 4), round(p[1] * ASPECT, 4)]


if __name__ == "__main__":
    grid, cols, rows = build()
    spots = {k: [world(p) for p in v] for k, v in STATIONS.items()}
    spots.update({k: [world(p) for p in room_spots(grid, cols, rows, r)] for k, r in ROOMS.items()})
    (ROOT / "out/walkmap.json").write_text(json.dumps({
        "res": RES, "cols": cols, "rows": rows, "corridors": [], "spots": spots,
        "cells": ["".join("." if c else "#" for c in row) for row in grid]}))
    if len(sys.argv) > 1:
        im = Image.open(ROOT / "out/town.jpg").convert("RGBA").resize((1920, 1080))
        over = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        sx, sy = 1920 / cols, 1080 / rows
        for y in range(rows):
            for x in range(cols):
                if grid[y][x]:
                    d.rectangle([x * sx, y * sy, (x + 1) * sx - 1, (y + 1) * sy - 1], fill=(0, 255, 0, 70))
        colors = {"editing": "yellow", "shell": "orange", "delegating": "magenta", "web": "cyan",
                  "reading": "white", "thinking": "pink", "waiting": "red", "resting": "blue"}
        for k, pts in spots.items():
            for x, y in pts:
                X, Y = x * 1920, y / ASPECT * 1080
                d.ellipse([X - 5, Y - 5, X + 5, Y + 5], outline=colors[k], width=3)
        im.alpha_composite(over)
        im.convert("RGB").save(sys.argv[1])
    print("ok", cols, "x", rows, sum(map(sum, grid)), "walkable", {k: len(v) for k, v in spots.items()})
