"""Lay one character pack out on a grey board for review by eye.
usage: python3 art/review_board.py <pack dir> <out.png>

Rows: walk_down, walk_left, walk_up, attack (6 frames each, actual size); portrait and sprite on the right.
Frames are drawn at 1x: enlarged frames overlap the next cell and look like two characters merged into one.
"""
import sys
from pathlib import Path

from PIL import Image

ROWS = ["walk_down", "walk_left", "walk_up", "attack"]
CELL = 200


def board(pack: Path) -> Image.Image:
    out = Image.new("RGB", (CELL * 6 + 260, CELL * len(ROWS)), (90, 90, 100))
    portrait = next(pack / f"portrait.{e}" for e in ("jpg", "png") if (pack / f"portrait.{e}").exists())
    p = Image.open(portrait).convert("RGB")
    p.thumbnail((250, 330))
    out.paste(p, (CELL * 6 + 5, 0))
    s = Image.open(pack / "sprite.png").convert("RGBA")
    out.paste(s, (CELL * 6 + 60, 400), s)
    for r, name in enumerate(ROWS):
        for c in range(6):
            f = Image.open(pack / f"frames/{name}_{c}.png").convert("RGBA")
            out.paste(f, (c * CELL + (CELL - f.width) // 2, max(0, r * CELL + CELL - f.height)), f)
    return out


if __name__ == "__main__":
    board(Path(sys.argv[1])).save(sys.argv[2])
