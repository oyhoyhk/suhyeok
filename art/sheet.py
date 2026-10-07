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


def isolate(img: Image.Image) -> Image.Image:
    """Strips pack frames tightly, so a cut can carry a slice of the neighbouring frame (a cape edge, a sword tip).
    Keep the biggest blob (the character) and any blob that does not touch the left or right edge of the cell."""
    a = np.asarray(img).copy()
    mask = a[..., 3] > 0
    h, w = mask.shape
    label = np.zeros((h, w), np.int32)
    sizes, touches = [0], [False]
    n = 0
    for y0 in range(h):
        for x0 in range(w):
            if not mask[y0, x0] or label[y0, x0]:
                continue
            n += 1
            label[y0, x0] = n
            stack, size, edge = [(y0, x0)], 0, False
            while stack:
                y, x = stack.pop()
                size += 1
                edge = edge or x == 0 or x == w - 1
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not label[ny, nx]:
                            label[ny, nx] = n
                            stack.append((ny, nx))
            sizes.append(size)
            touches.append(edge)
    if n <= 1:
        return img
    main = int(np.argmax(sizes))
    keep = np.zeros(n + 1, bool)
    for i in range(1, n + 1):
        keep[i] = i == main or (not touches[i] and sizes[i] >= 4)
    a[..., 3] = np.where(keep[label], a[..., 3], 0)
    out = Image.fromarray(a, "RGBA")
    return out.crop(out.getbbox())


def components(mask):
    """Connected blobs (8-neighbour) of a boolean mask -> (label image, list of (size, x0, x1))."""
    h, w = mask.shape
    label = np.zeros((h, w), np.int32)
    info = [None]
    n = 0
    for y0 in range(h):
        for x0 in np.nonzero(mask[y0] & (label[y0] == 0))[0]:
            if label[y0, x0]:
                continue
            n += 1
            label[y0, x0] = n
            stack, size, lo, hi = [(y0, x0)], 0, x0, x0
            while stack:
                y, x = stack.pop()
                size += 1
                lo, hi = min(lo, x), max(hi, x)
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not label[ny, nx]:
                            label[ny, nx] = n
                            stack.append((ny, nx))
            info.append((size, lo, hi))
    return label, info


def split_strip(strip: Image.Image, n: int = 6, effects_left: bool = False):
    """Split a strip into n frames by blobs instead of straight cuts, so a hammer or cape that reaches into the
    neighbour's column stays with its own figure. Falls back to column cuts when figures touch each other."""
    small = strip.resize((strip.width // 3, strip.height // 3), Image.LANCZOS)
    keyed = drop_floor_shadow_full(key_background(small, crop=False))
    a = np.asarray(keyed)
    label, info = components(a[..., 3] > 0)
    bodies = sorted(range(1, len(info)), key=lambda i: -info[i][0])[:n]
    if len(bodies) < n or info[bodies[-1]][0] < info[bodies[0]][0] * 0.35:
        return None  # merged figures: let the caller cut by columns
    bodies.sort(key=lambda i: info[i][1])
    centres = [(info[b][1] + info[b][2]) / 2 for b in bodies]
    owner = np.zeros(len(info), np.int32)
    for i in range(1, len(info)):
        if info[i][0] < 3:
            owner[i] = -1  # specks
            continue
        mid = (info[i][1] + info[i][2]) / 2
        owner[i] = min(range(n), key=lambda k: abs(centres[k] - mid))
        if effects_left and i not in bodies:
            # Loose pieces (impact flashes, projectiles) go to the figure whose edge they are closest to, measured
            # edge to edge: an impact flash sits just left of its attacker even when that attacker's centre is
            # farther away than the previous figure's.
            lo, hi = info[i][1], info[i][2]
            def gap(k):
                b0, b1 = info[bodies[k]][1], info[bodies[k]][2]
                return max(0, b0 - hi, lo - b1)
            owner[i] = min(range(n), key=gap)
            # Attackers face left: a loose piece to the right of its figure's centre is the next figure's flash.
            k = owner[i]
            if (lo + hi) / 2 > centres[k] and k + 1 < n:
                owner[i] = k + 1
    frames = []
    for k in range(n):
        m = (owner[label] == k) & (label > 0)
        f = a.copy()
        f[..., 3] = np.where(m, a[..., 3], 0)
        img = Image.fromarray(f, "RGBA")
        frames.append(img.crop(img.getbbox()))
    return frames


def drop_floor_shadow_full(img):
    a = np.asarray(img).copy()
    r, g, b = (a[..., i].astype(int) for i in range(3))
    magenta = (r > g + 40) & (b > g + 40) & (abs(r - b) < 90)
    a[magenta, 3] = 0
    return Image.fromarray(a, "RGBA")


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


def slice_strips(char: str, variant: str = "a"):
    """1x6 walk strips per direction -> walk_{down,left,up}_{0..5}.png, same scale as the standing frame."""
    out = ROOT / "out/frames" / char
    srcs = {v: ROOT / f"raw/strip_{char}-{v}-{variant}_seedream_5_0_flash.webp" for v in ("down", "left", "up")}
    if not all(p.exists() for p in srcs.values()):
        return False
    stand = Image.open(out / "walk_down_1.png") if (out / "walk_down_1.png").exists() else None
    for view, src in srcs.items():
        strip = Image.open(src).convert("RGB")
        cells = split_strip(strip)
        if cells is None:
            xs = cuts(strip, 6, axis=1)
            cells = []
            for c in range(6):
                cell = strip.crop((xs[c], 0, xs[c + 1], strip.height))
                cell = cell.resize((cell.width // 3, cell.height // 3), Image.LANCZOS)
                cells.append(isolate(drop_floor_shadow(key_background(cell))))
        target = stand.height if stand else STAND_H
        scale = target / max(f.height for f in cells)
        frames = [f.resize((max(1, round(f.width * scale)), max(1, round(f.height * scale))), Image.NEAREST) for f in cells]
        for c, f in enumerate(align_row(frames)):
            f.quantize(256, method=Image.Quantize.FASTOCTREE).save(out / f"walk_{view}_{c}.png", optimize=True)
    return True


def slice_work_strips(char: str, variant: str = "a"):
    """1x6 work strips -> {write,smith,study}_{0..5}.png at the walking scale."""
    out = ROOT / "out/frames" / char
    stand = Image.open(out / "walk_down_2.png") if (out / "walk_down_2.png").exists() else Image.open(out / "walk_down_1.png")
    done = False
    for act in ("write", "smith", "study"):
        src = ROOT / f"raw/workstrip_{char}-{act}-{variant}_seedream_5_0_flash.webp"
        if not src.exists():
            continue
        strip = Image.open(src).convert("RGB")
        cells = split_strip(strip)
        if cells is None:
            xs = cuts(strip, 6, axis=1)
            cells = []
            for c in range(6):
                cell = strip.crop((xs[c], 0, xs[c + 1], strip.height))
                cell = cell.resize((cell.width // 3, cell.height // 3), Image.LANCZOS)
                cells.append(isolate(drop_floor_shadow(key_background(cell))))
        # Raised hammers stick out above the head: scale smithing by the shortest frame (hammer down).
        body = min(f.height for f in cells) if act == "smith" else max(f.height for f in cells)
        scale = stand.height / body
        frames = [f.resize((max(1, round(f.width * scale)), max(1, round(f.height * scale))), Image.NEAREST) for f in cells]
        for c, f in enumerate(align_row(frames)):
            f.quantize(256, method=Image.Quantize.FASTOCTREE).save(out / f"{act}_{c}.png", optimize=True)
        done = True
    return done


def slice_strip_to(src: Path, out_dir: Path, prefix: str, height: int, by: str = "max", effects_left: bool = False):
    """Generic 1x6 strip -> <prefix>_{0..5}.png scaled so the tallest (or shortest) frame is `height` px."""
    strip = Image.open(src).convert("RGB")
    cells = split_strip(strip, effects_left=effects_left)
    if cells is None:
        xs = cuts(strip, 6, axis=1)
        cells = []
        for c in range(6):
            cell = strip.crop((xs[c], 0, xs[c + 1], strip.height))
            cell = cell.resize((cell.width // 3, cell.height // 3), Image.LANCZOS)
            cells.append(isolate(drop_floor_shadow(key_background(cell))))
    ref = max(f.height for f in cells) if by == "max" else min(f.height for f in cells)
    scale = height / ref
    frames = [f.resize((max(1, round(f.width * scale)), max(1, round(f.height * scale))), Image.NEAREST) for f in cells]
    out_dir.mkdir(parents=True, exist_ok=True)
    for c, f in enumerate(align_row(frames)):
        f.quantize(256, method=Image.Quantize.FASTOCTREE).save(out_dir / f"{prefix}_{c}.png", optimize=True)


def slice_attacks():
    import json
    for c in json.loads((ROOT / "roster.json").read_text()):
        src = ROOT / f"raw/attack_{c['id']}-a_seedream_5_0_flash.webp"
        if src.exists():
            out = ROOT / "out/frames" / c["id"]
            stand = Image.open(out / "walk_down_2.png").height
            # Weapons stick out sideways, not up: match by the shortest frame so the body keeps walking size.
            slice_strip_to(src, out, "attack", stand, by="min", effects_left=True)
            print(c["id"], "ok")


def slice_bosses():
    for b in ("low", "mid", "high"):
        for kind, prefix, by in (("boss", b, "max"), ("bossattack", f"{b}_attack", "max"), ("bossspecial", f"{b}_special", "min")):
            src = ROOT / f"raw/{kind}_{b}-a_seedream_5_0_flash.webp"
            if src.exists():
                # Special effects spread wide: scale by the plainest frame so the body matches the idle size.
                slice_strip_to(src, ROOT / "out/bosses", prefix, 256, by=by)
                print(prefix, "ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["attacks"]:
        slice_attacks()
    elif sys.argv[1:2] == ["bosses"]:
        slice_bosses()
    elif sys.argv[1:2] == ["workstrips"]:
        import json
        for c in json.loads((ROOT / "roster.json").read_text()):
            if slice_work_strips(c["id"]): print(c["id"], "ok")
    elif sys.argv[1:2] == ["strips"]:
        import json
        for c in json.loads((ROOT / "roster.json").read_text()):
            print(c["id"], "ok" if slice_strips(c["id"]) else "no strips")
    elif sys.argv[1:2] == ["work"]:
        import json
        for c in json.loads((ROOT / "roster.json").read_text()):
            print(c["id"], "ok" if slice_work(c["id"]) else "no sheet")
    else:
        for arg in sys.argv[1:]:
            slice_sheet(*arg.split("="))




