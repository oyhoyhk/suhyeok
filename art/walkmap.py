"""Walkable grid for art/out/map.png (48x27 cells), written to out/walkmap.json.
Floors are opened first, then furniture and walls closed. Coordinates are cell ranges [x0, x1) x [y0, y1).
usage: python3 walkmap.py [preview.png]
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
W, H = 48, 27

FLOORS = [
    (3, 16, 4, 12),    # work hall, top room
    (3, 16, 16, 24),   # work hall, bottom room
    (16, 21, 10, 13),  # top room doorway into the corridor
    (16, 21, 13, 19),  # bottom room opening into the corridor
    (17, 21, 4, 25),   # central corridor
    (20, 33, 7, 12),   # forge floor in front of the furnace
    (20, 34, 11, 15),  # landing between forge and tavern
    (33, 46, 4, 24),   # big hall on the right
    (19, 22, 18, 21),  # tavern door on its left wall
    (21, 32, 18, 23),  # tavern floor
]
BLOCKS = [
    (3, 8, 5, 7), (9, 16, 5, 7), (3, 16, 9, 11),          # top room desks and long table
    (3, 8, 17, 19), (9, 16, 17, 19),                      # bottom room desks
    (4, 8, 21, 24), (11, 16, 21, 24),                     # round tables with chairs
    (2, 4, 22, 24), (15, 17, 22, 24),                     # plants
    (25, 28, 8, 11), (30, 33, 7, 11),                     # anvil, tool stand
    (35, 37, 4, 7), (44, 47, 3, 6),                       # stove + chair, plant (right hall)
    (44, 47, 7, 11), (44, 47, 19, 22), (45, 47, 13, 16),  # armchairs, wall gear
    (35, 44, 13, 19),                                     # sofa + counter on stone base
    (32, 34, 15, 25),                                     # tavern right wall
    (24, 29, 18, 20),                                     # tavern fireplace hearth
    (21, 23, 19, 23), (30, 32, 19, 23),                   # tavern armchairs
    (25, 28, 20, 23),                                     # tavern round table
]


def build():
    grid = [[False] * W for _ in range(H)]
    for x0, x1, y0, y1 in FLOORS:
        for y in range(y0, y1):
            for x in range(x0, x1):
                grid[y][x] = True
    for x0, x1, y0, y1 in BLOCKS:
        for y in range(y0, y1):
            for x in range(x0, x1):
                grid[y][x] = False
    return grid


if __name__ == "__main__":
    grid = build()
    (ROOT / "out/walkmap.json").write_text(json.dumps(
        {"cols": W, "rows": H, "cells": ["".join("." if c else "#" for c in row) for row in grid]}, indent=0))
    if len(sys.argv) > 1:
        im = Image.open(ROOT / "out/map.png").convert("RGBA").resize((1920, 1080))
        over = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        sx, sy = 1920 / W, 1080 / H
        for y in range(H):
            for x in range(W):
                color = (0, 255, 0, 70) if grid[y][x] else (255, 0, 0, 60)
                d.rectangle([x * sx, y * sy, (x + 1) * sx - 1, (y + 1) * sy - 1], fill=color)
        im.alpha_composite(over)
        im.convert("RGB").save(sys.argv[1])
    print("ok", sum(map(sum, grid)), "walkable cells")
