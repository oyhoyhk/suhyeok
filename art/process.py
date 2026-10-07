"""Turn raw generations into app-ready PNGs under out/.
usage: python3 process.py   (processes every raw file; picks model per kind)
"""
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).parent
RAW, OUT = ROOT / "raw", ROOT / "out"
SPRITE_MODEL, PORTRAIT_MODEL, MAP_MODEL = "seedream_5_0_flash", "seedream_5_0_flash", "z_image"
SPRITE_H = 128  # display uses nearest-neighbor scaling, so keep sprites small and crisp


def key_background(img: Image.Image, tol: float = 70) -> Image.Image:
    """Flood-fill from the borders over pixels close to the border color, so magenta-ish
    clothing inside the character is never keyed out."""
    rgb = np.asarray(img.convert("RGB")).astype(np.int16)
    h, w, _ = rgb.shape
    border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    bg = np.median(border, axis=0)
    close = np.sqrt(((rgb - bg) ** 2).sum(axis=2)) < tol
    mask = np.zeros((h, w), bool)
    q = deque((y, x) for y in range(h) for x in (0, w - 1) if close[y, x])
    q.extend((y, x) for x in range(w) for y in (0, h - 1) if close[y, x])
    while q:
        y, x = q.popleft()
        if mask[y, x]:
            continue
        mask[y, x] = True
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and close[ny, nx] and not mask[ny, nx]:
                q.append((ny, nx))
    dist = np.sqrt(((rgb - bg) ** 2).sum(axis=2))
    # Enclosed pockets (e.g. between staff and hair) are pure background color.
    mask |= dist < tol * 0.6
    # Drop the anti-aliased fringe: near-background pixels touching the keyed area.
    edge = np.zeros_like(mask)
    edge[1:] |= mask[:-1]; edge[:-1] |= mask[1:]; edge[:, 1:] |= mask[:, :-1]; edge[:, :-1] |= mask[:, 1:]
    mask |= edge & (dist < tol * 1.6)
    rgba = np.dstack([rgb.astype(np.uint8), np.where(mask, 0, 255).astype(np.uint8)])
    out = Image.fromarray(rgba, "RGBA")
    return out.crop(out.getbbox())


def main():
    for d in ("sprites", "portraits"):
        (OUT / d).mkdir(parents=True, exist_ok=True)
    for f in sorted(RAW.iterdir()):
        stem = f.stem
        try:
            Image.open(f).verify()
        except Exception:
            print("skip unreadable", f.name)  # partial download in progress
            continue
        if stem.startswith("sprite_") and stem.endswith(SPRITE_MODEL):
            cid = stem[len("sprite_"):-len(SPRITE_MODEL) - 1]
            # Shrink first so the flood fill is fast and anti-aliased fringe collapses.
            img = Image.open(f).convert("RGB")
            img = img.resize((img.width // 4, img.height // 4), Image.LANCZOS)
            s = key_background(img)
            s = s.resize((max(1, round(s.width * SPRITE_H / s.height)), SPRITE_H), Image.NEAREST)
            s.save(OUT / f"sprites/{cid}.png")
        elif stem.startswith("portrait_") and stem.endswith(PORTRAIT_MODEL):
            cid = stem[len("portrait_"):-len(PORTRAIT_MODEL) - 1]
            img = Image.open(f).convert("RGB")
            img.thumbnail((768, 1024), Image.LANCZOS)
            img.save(OUT / f"portraits/{cid}.jpg", quality=86)  # photos-like art: jpg is ~10x smaller than png
        elif stem == f"map_{MAP_MODEL}":
            img = Image.open(f).convert("RGB")
            img.thumbnail((2048, 2048), Image.LANCZOS)
            img.save(OUT / "map.png")
    # Extra world areas (chosen candidates), same size as the guild hall map.
    for name, src in {"tavern": "area_tavern-a_z_image", "garden": "area_garden-a_z_image",
                      "library": "area_library-b_z_image"}.items():
        f = RAW / f"{src}.webp"
        if f.exists():
            Image.open(f).convert("RGB").resize((2048, 1152), Image.LANCZOS).save(OUT / f"area_{name}.jpg", quality=88)
    print(sorted(str(p.relative_to(OUT)) for p in OUT.rglob("*.png")))


if __name__ == "__main__":
    main()
