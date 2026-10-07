"""Slice generated 3x6 sprite sheets into animation frames under out/frames/<character>/.
usage: python3 sheet.py <character>=<variant> ...   e.g. knight=b fox=b
Rows: walk_down, walk_left, walk_up, hammer, type, read; 3 frames each.
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image
from process import key_background

ROOT = Path(__file__).parent
ROWS = ["walk_down", "walk_left", "walk_up", "hammer", "type", "read"]
# Which way each generated "walk left" frame really faces (L left, R right, F front, B back), checked by eye.
# The model often ignored the row's direction; R frames are mirrored, F/B frames replaced by an L frame.
SIDE = {
    "knight": "LLL", "mage": "LFL", "ranger": "LLR", "alchemist": "LFL", "bard": "LLL", "cleric": "LLR",
    "rogue": "LFF", "blacksmith": "LFL", "paladin": "LFL", "necro": "LLL", "monk": "LLL", "pirate": "LFL",
    "engineer": "LLB", "druid": "LLB", "samurai": "RFR", "merchant": "LFL", "archer": "LLL", "chef": "LLR",
    "viking": "LFB", "witch": "LLB", "scholar": "LLL", "ninja": "FFF", "astronomer": "LLL", "farmer": "LFL",
    "guard": "LLL", "jester": "LFL", "miner": "LFL", "golem": "LFF", "robot": "LFL", "fox": "LLL",
    "cat": "LLL", "panda": "LFF",
}
# Frames the model left without the character (anvil only); reuse a good frame of the same row instead.
REUSE = {"necro": {"hammer_2": "hammer_0"}, "miner": {"hammer_2": "hammer_0"}, "robot": {"hammer_2": "hammer_0"}}
STAND_H = 128  # height of the standing front frame; every frame of a character shares its scale


def cuts(sheet: Image.Image, n: int, axis: int) -> list:
    """Boundaries between n sprites along an axis. The generated grid is not exact (feet spill into the
    next row), so each cut moves to the emptiest line within ±30% of a cell around its expected spot."""
    rgb = np.asarray(sheet).astype(np.int16)
    bg = np.median(np.concatenate([rgb[0], rgb[-1]]), axis=0)
    fg = np.sqrt(((rgb - bg) ** 2).sum(axis=2)) > 70
    profile = fg.sum(axis=1 - axis)  # foreground pixels per row (axis 0) or column (axis 1)
    size = len(profile) / n
    out = [0]
    for k in range(1, n):
        lo, hi = int((k - 0.3) * size), int((k + 0.3) * size)
        out.append(lo + int(np.argmin(profile[lo:hi])))
    return out + [len(profile)]


def drop_floor_shadow(img: Image.Image) -> Image.Image:
    """The model paints a dark magenta floor shadow despite "no shadows"; clear magenta-hued pixels in the
    bottom strip only, so purple clothing higher up stays."""
    a = np.asarray(img).copy()
    r, g, b = (a[..., i].astype(int) for i in range(3))
    strip = np.zeros(a.shape[:2], bool)
    strip[int(a.shape[0] * 0.92):] = True
    magenta = (r > g + 40) & (b > g + 40) & (abs(r - b) < 90)
    a[strip & magenta, 3] = 0
    out = Image.fromarray(a, "RGBA")
    return out.crop(out.getbbox())


def fix_side_row(cells: dict, facing: str):
    """Make all three walk_left frames face left; with no side view at all, walk sideways facing front."""
    frames = [cells[f"walk_left_{c}"] for c in range(3)]
    for c, f in enumerate(facing):
        if f == "R":
            frames[c] = frames[c].transpose(Image.FLIP_LEFT_RIGHT)
    good = [c for c, f in enumerate(facing) if f in "LR"]
    if not good:
        for c in range(3):
            cells[f"walk_left_{c}"] = cells[f"walk_down_{c}"]
        return
    for c in range(3):
        if facing[c] not in "LR":
            frames[c] = frames[min(good, key=lambda g: abs(g - c))]
        cells[f"walk_left_{c}"] = frames[c]


def align_row(frames: list) -> list:
    """Same canvas for every frame of a row: feet on the bottom edge, body centre (alpha mass) in the middle,
    so the sprite does not jump between frames."""
    def centre(img):
        a = np.asarray(img)[..., 3].astype(float)
        cols = a.sum(axis=0)
        return (cols * np.arange(len(cols))).sum() / max(cols.sum(), 1)
    cs = [centre(f) for f in frames]
    left = max(cs)
    right = max(f.width - c for f, c in zip(frames, cs))
    w, h = int(left + right) + 2, max(f.height for f in frames)
    out = []
    for f, c in zip(frames, cs):
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        canvas.alpha_composite(f, (int(round(left - c)), h - f.height))
        out.append(canvas)
    return out


def slice_sheet(char: str, variant: str):
    sheet = Image.open(ROOT / f"raw/sheet_{char}-{variant}_seedream_5_0_flash.webp").convert("RGB")
    ys, xs = cuts(sheet, 6, axis=0), cuts(sheet, 3, axis=1)
    cells = {}
    for r, row in enumerate(ROWS):
        for c in range(3):
            cell = sheet.crop((xs[c], ys[r], xs[c + 1], ys[r + 1]))
            cell = cell.resize((cell.width // 3, cell.height // 3), Image.LANCZOS)  # speed + collapse AI dither
            cells[f"{row}_{c}"] = drop_floor_shadow(key_background(cell))
    for bad, good in REUSE.get(char, {}).items():
        cells[bad] = cells[good]
    fix_side_row(cells, SIDE.get(char, "LLL"))
    walk_scale = STAND_H / cells["walk_down_1"].height
    # The model draws work rows smaller; scale each work row so its tallest frame matches the standing height.
    row_scale = {row: walk_scale if row.startswith("walk") else
                 STAND_H / max(cells[f"{row}_{c}"].height for c in range(3)) for row in ROWS}
    out = ROOT / "out/frames" / char
    out.mkdir(parents=True, exist_ok=True)
    warnings = []
    scaled = {}
    for name, img in cells.items():
        scale = row_scale[name.rsplit("_", 1)[0]]
        scaled[name] = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.NEAREST)
    for row in ROWS:
        for c, f in enumerate(align_row([scaled[f"{row}_{c}"] for c in range(3)])):
            scaled[f"{row}_{c}"] = f
    for name, frame in scaled.items():
        # Pixel art fits a 256-color palette; about 4x smaller than RGBA PNGs.
        frame.quantize(256, method=Image.Quantize.FASTOCTREE).save(out / f"{name}.png", optimize=True)
        if frame.height > STAND_H * 1.6 or frame.height < STAND_H * 0.6:
            warnings.append(f"{name} height {frame.height}")
    print(char, "ok" if not warnings else "CHECK: " + ", ".join(warnings))


WORK_ROWS = ["write", "smith", "study"]  # quill on parchment, hammer swing facing left, reading a book


def slice_work(char: str, variant: str = "a"):
    """3x3 prop-free work sheet -> out/frames/<char>/{write,smith,study}_{0,1,2}.png, same scale as walking."""
    src = ROOT / f"raw/work_{char}-{variant}_seedream_5_0_flash.webp"
    if not src.exists():
        return False
    sheet = Image.open(src).convert("RGB")
    ys, xs = cuts(sheet, 3, axis=0), cuts(sheet, 3, axis=1)
    out = ROOT / "out/frames" / char
    stand = Image.open(out / "walk_down_1.png")
    for r, row in enumerate(WORK_ROWS):
        cells = []
        for c in range(3):
            cell = sheet.crop((xs[c], ys[r], xs[c + 1], ys[r + 1]))
            cell = cell.resize((cell.width // 3, cell.height // 3), Image.LANCZOS)
            cells.append(drop_floor_shadow(key_background(cell)))
        # Standing poses: scale the row so its body matches the walking height (raised hammers may stick out).
        body = sorted(f.height for f in cells)[0] if row == "smith" else max(f.height for f in cells)
        scale = stand.height / body
        frames = [f.resize((max(1, round(f.width * scale)), max(1, round(f.height * scale))), Image.NEAREST) for f in cells]
        for c, f in enumerate(align_row(frames)):
            f.quantize(256, method=Image.Quantize.FASTOCTREE).save(out / f"{row}_{c}.png", optimize=True)
    return True


if __name__ == "__main__":
    if sys.argv[1:2] == ["work"]:
        import json
        for c in json.loads((ROOT / "roster.json").read_text()):
            print(c["id"], "ok" if slice_work(c["id"]) else "no sheet")
    else:
        for arg in sys.argv[1:]:
            slice_sheet(*arg.split("="))

