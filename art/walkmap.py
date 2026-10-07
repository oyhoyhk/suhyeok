"""World walk grid: which cells agents may stand on, written to out/walkmap.json.

The world is four 16:9 areas in a 2x2 grid joined by corridors (same layout as World in WorldView.swift).
Each area lists floor rectangles (opened) and furniture/wall rectangles (closed) as fractions (x0, x1, y0, y1)
of that area; corridors are given in world units. Order: area floors, area blocks, corridors (always open).
usage: python3 walkmap.py [preview.png]
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
AREA_H = 9 / 16
GAP = 0.14                      # must match World.gap
RES = 96                        # cells per world unit
ORIGINS = {"guild": (0, 0), "library": (1 + GAP, 0), "tavern": (0, AREA_H + GAP), "garden": (1 + GAP, AREA_H + GAP)}
IMAGES = {"guild": "map.png", "library": "area_library.jpg", "tavern": "area_tavern.jpg", "garden": "area_garden.jpg"}


def cells(x0, x1, y0, y1, cols=48, rows=27):
    return (x0 / cols, x1 / cols, y0 / rows, y1 / rows)


AREAS = {
    "guild": {  # measured on a 48x27 cell grid
        "floors": [cells(*r) for r in [
            (3, 16, 4, 12), (3, 16, 16, 24), (16, 21, 10, 13), (16, 21, 13, 19), (17, 21, 4, 25),
            (20, 33, 7, 12), (20, 34, 11, 15), (33, 46, 4, 24), (19, 22, 18, 21), (21, 32, 18, 23),
            (46, 48, 11, 13),   # opening in the right wall -> library corridor
            (32, 35, 24, 27),   # opening in the bottom wall -> tavern corridor
        ]],
        "blocks": [cells(*r) for r in [
            (3, 8, 5, 7), (9, 16, 5, 7), (3, 16, 9, 11), (3, 8, 17, 19), (9, 16, 17, 19),
            (4, 8, 21, 24), (11, 16, 21, 24), (2, 4, 22, 24), (15, 17, 22, 24),
            (25, 28, 8, 11), (30, 33, 7, 11), (35, 37, 4, 7), (44, 47, 3, 6),
            (44, 47, 7, 11), (44, 47, 19, 22), (45, 47, 14, 16), (35, 44, 13, 19),
            (32, 33, 15, 24), (24, 29, 18, 20), (21, 23, 19, 23), (30, 32, 19, 23), (25, 28, 20, 23),
        ]],
    },
    "library": {
        "floors": [(0.15, 0.85, 0.24, 0.72), (0.0, 0.16, 0.40, 0.48), (0.46, 0.54, 0.70, 1.0)],
        "blocks": [(0.19, 0.31, 0.27, 0.32), (0.19, 0.31, 0.37, 0.42), (0.19, 0.31, 0.47, 0.52), (0.19, 0.31, 0.57, 0.62),
                   (0.64, 0.77, 0.27, 0.32), (0.64, 0.77, 0.37, 0.42), (0.64, 0.77, 0.47, 0.52), (0.64, 0.77, 0.57, 0.62),
                   (0.33, 0.43, 0.27, 0.32), (0.33, 0.43, 0.57, 0.62), (0.46, 0.58, 0.38, 0.58)],
    },
    "tavern": {
        "floors": [(0.12, 0.86, 0.33, 0.80), (0.64, 0.74, 0.0, 0.34), (0.86, 1.0, 0.44, 0.52)],
        "blocks": [(0.05, 0.21, 0.10, 0.44), (0.25, 0.36, 0.42, 0.54), (0.49, 0.59, 0.42, 0.54), (0.64, 0.75, 0.42, 0.54),
                   (0.06, 0.14, 0.44, 0.55), (0.19, 0.30, 0.69, 0.81), (0.34, 0.44, 0.69, 0.81), (0.49, 0.59, 0.69, 0.81),
                   (0.64, 0.75, 0.69, 0.81), (0.86, 0.93, 0.55, 0.72), (0.06, 0.12, 0.6, 0.7)],
    },
    "garden": {
        "floors": [(0.08, 0.87, 0.13, 0.84), (0.43, 0.51, 0.0, 0.14), (0.0, 0.09, 0.44, 0.52)],
        "blocks": [(0.07, 0.16, 0.30, 0.43), (0.21, 0.31, 0.12, 0.26), (0.74, 0.86, 0.24, 0.41), (0.05, 0.15, 0.61, 0.76),
                   (0.75, 0.85, 0.59, 0.74), (0.41, 0.54, 0.43, 0.59), (0.27, 0.36, 0.30, 0.38), (0.60, 0.69, 0.30, 0.38)],
    },
}


def area_rect(area, r):
    ox, oy = ORIGINS[area]
    x0, x1, y0, y1 = r
    return (ox + x0, ox + x1, oy + y0 * AREA_H, oy + y1 * AREA_H)


# Corridors in world units (x0, x1, y0, y1); also drawn by the app. Each overlaps both areas it joins.
W_ = 0.045  # corridor walk half-width
CORRIDORS = [
    # guild right opening -> library left opening (area y ~0.44)
    (0.97, 1 + GAP + 0.10, 0.44 * AREA_H - W_, 0.44 * AREA_H + W_),
    # guild bottom opening (x ~0.70) -> tavern top door (x ~0.69)
    (0.69 - W_, 0.69 + W_, 0.93 * AREA_H, AREA_H + GAP + 0.20 * AREA_H),
    # library bottom doors (x 0.46-0.54) -> garden top door (x 0.43-0.51): straight where both doors overlap
    (1 + GAP + 0.485 - W_, 1 + GAP + 0.485 + W_, 0.80 * AREA_H, AREA_H + GAP + 0.12 * AREA_H),
    # tavern right opening -> garden left opening (area y ~0.48)
    (0.90, 1 + GAP + 0.10, AREA_H + GAP + 0.48 * AREA_H - W_, AREA_H + GAP + 0.48 * AREA_H + W_),
]


def build():
    world_w, world_h = 2 + GAP, 2 * AREA_H + GAP
    cols, rows = round(world_w * RES), round(world_h * RES)
    grid = [[False] * cols for _ in range(rows)]

    def fill(r, value):
        x0, x1, y0, y1 = r
        for y in range(max(0, int(y0 * RES)), min(rows, int(round(y1 * RES)))):
            for x in range(max(0, int(x0 * RES)), min(cols, int(round(x1 * RES)))):
                grid[y][x] = value

    for area, spec in AREAS.items():
        for r in spec["floors"]:
            fill(area_rect(area, r), True)
    for area, spec in AREAS.items():
        for r in spec["blocks"]:
            fill(area_rect(area, r), False)
    for r in CORRIDORS:
        fill(r, True)
    return grid, cols, rows


if __name__ == "__main__":
    grid, cols, rows = build()
    (ROOT / "out/walkmap.json").write_text(json.dumps({
        "res": RES, "cols": cols, "rows": rows, "gap": GAP,
        "corridors": CORRIDORS,
        "cells": ["".join("." if c else "#" for c in row) for row in grid]}))
    if len(sys.argv) > 1:
        px = 900  # pixels per world unit in the preview
        im = Image.new("RGBA", (round((2 + GAP) * px), round((2 * AREA_H + GAP) * px)), (20, 16, 28, 255))
        for area, img in IMAGES.items():
            ox, oy = ORIGINS[area]
            tile = Image.open(ROOT / "out" / img).convert("RGBA").resize((px, round(AREA_H * px)))
            im.alpha_composite(tile, (round(ox * px), round(oy * px)))
        over = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        s = px / RES
        for y in range(rows):
            for x in range(cols):
                if grid[y][x]:
                    d.rectangle([x * s, y * s, (x + 1) * s - 1, (y + 1) * s - 1], fill=(0, 255, 0, 80))
        im.alpha_composite(over)
        im.convert("RGB").save(sys.argv[1])
    print("ok", cols, "x", rows, sum(map(sum, grid)), "walkable")
