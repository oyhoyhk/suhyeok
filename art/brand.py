"""Build app icon (.icns), favicons, menu bar template and README hero from the chosen raw generations.
usage: python3 art/brand.py <hero_variant> <icon_variant>
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
from process import key_background

ROOT = Path(__file__).parent
MODEL = "seedream_5_0_flash"


def main(hero_v, icon_v):
    out, assets = ROOT / "out", ROOT.parent / "assets"
    hero = Image.open(ROOT / f"raw/hero_{hero_v}_{MODEL}.webp").convert("RGB")
    hero.thumbnail((1600, 1600), Image.LANCZOS)
    hero.save(assets / "hero.jpg", quality=86)

    # Icon: drop the white surround, then sit the rounded square on macOS's 824/1024 grid.
    raw = Image.open(ROOT / f"raw/icon_{icon_v}_{MODEL}.webp").convert("RGB")
    badge = key_background(raw.resize((1024, 1024), Image.LANCZOS), tol=40)
    badge = badge.resize((824, 824), Image.LANCZOS)
    icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    icon.alpha_composite(badge, (100, 100))
    icon.save(assets / "icon.png")
    badge.resize((256, 256), Image.LANCZOS).save(assets / "favicon.png")
    badge.save(assets / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out / "AppIcon.icns")], check=True)

    # Menu bar template: everything that is not the navy field (flag, pole, star) as an alpha silhouette.
    rgb = np.asarray(badge.convert("RGB")).astype(np.int16)
    alpha = np.asarray(badge)[..., 3]
    navy = np.median(rgb[alpha == 255], axis=0)
    h, w = alpha.shape
    inner = np.zeros_like(alpha, dtype=bool)
    inner[int(h * .08):int(h * .92), int(w * .08):int(w * .92)] = True  # skip the rounded edge fringe
    bright = (np.sqrt(((rgb - navy) ** 2).sum(axis=2)) > 60) & (alpha == 255) & inner
    sil = Image.fromarray(np.dstack([np.zeros_like(rgb, dtype=np.uint8), (bright * 255).astype(np.uint8)]), "RGBA")
    sil = sil.crop(sil.getbbox())
    side = max(sil.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.alpha_composite(sil, ((side - sil.width) // 2, (side - sil.height) // 2))
    small = square.resize((36, 36), Image.LANCZOS)  # 18pt @2x
    small.putalpha(small.split()[3].point(lambda v: 255 if v > 90 else 0))  # crisp edges, no grey haze
    small.save(out / "menubar.png")
    print("ok")


if __name__ == "__main__":
    main(*sys.argv[1:3])
