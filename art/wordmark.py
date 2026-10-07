"""Pixel-art "SUHYEOK" wordmark rendered in code, so the spelling is always exact.
usage: python3 wordmark.py [out.png]
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

TEXT = "SUHYEOK"
FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
SMALL = 30   # glyph height in "pixels" before upscaling; this sets the pixel grain
SCALE = 8


def wordmark(style: str = "gold") -> Image.Image:
    """style: "gold" for dark backgrounds, "navy" for placing on a gold plate."""
    font = ImageFont.truetype(FONT, SMALL)
    l, t, r, b = font.getbbox(TEXT)
    pad = 4
    w, h = r - l + pad * 2, b - t + pad * 2
    mask_img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask_img)
    d.fontmode = "1"  # no anti-aliasing: hard pixel edges
    d.text((pad - l, pad - t), TEXT, font=font, fill=255)
    mask = np.asarray(mask_img) > 0

    def dilate(m, n):
        out = m.copy()
        for _ in range(n):
            g = out.copy()
            g[1:] |= out[:-1]; g[:-1] |= out[1:]; g[:, 1:] |= out[:, :-1]; g[:, :-1] |= out[:, 1:]
            out = g
        return out

    outline = dilate(mask, 1)
    shadow = np.zeros_like(outline)
    shadow[2:, 1:] = outline[:-2, :-1]  # drop shadow down-right

    rows = np.linspace(0, 1, h)[:, None]
    # Gold ramp: pale highlight on top, rich gold, deep orange at the base, with a bright band.
    if style == "navy":
        top, mid, low = np.array([110, 140, 230]), np.array([36, 58, 140]), np.array([14, 22, 70])
    else:
        top, mid, low = np.array([255, 246, 170]), np.array([255, 196, 40]), np.array([214, 112, 20])
    ramp = np.where(rows < 0.5, top + (mid - top) * (rows / 0.5), mid + (low - mid) * ((rows - 0.5) / 0.5))
    ramp = np.repeat(ramp[:, None, :], w, axis=1).reshape(h, w, 3)
    band = (np.abs(rows - 0.38) < 0.04)
    band_color = np.array([170, 200, 255]) if style == "navy" else np.array([255, 255, 230])
    ramp = np.where(np.repeat(band, w, axis=1)[..., None], band_color, ramp)

    img = np.zeros((h, w, 4), np.uint8)
    img[shadow] = [90, 50, 10, 160] if style == "navy" else [40, 16, 4, 200]
    img[outline] = [255, 236, 150, 255] if style == "navy" else [58, 24, 6, 255]
    img[mask, :3] = ramp[mask].astype(np.uint8)
    img[mask, 3] = 255
    big = Image.fromarray(img, "RGBA").resize((w * SCALE, h * SCALE), Image.NEAREST)

    # Warm glow behind the letters.
    margin = SCALE * 6
    size = (big.width + margin * 2, big.height + margin * 2)
    # Blur on the full canvas so the glow fades out instead of stopping at the letters' box.
    glow_mask = Image.new("L", size, 0)
    glow_mask.paste(Image.fromarray((dilate(mask, 2) * 255).astype(np.uint8)).resize(big.size, Image.NEAREST), (margin, margin))
    glow = Image.new("RGBA", size, (255, 250, 210, 0) if style == "navy" else (255, 190, 60, 0))
    glow.putalpha(glow_mask.filter(ImageFilter.GaussianBlur(SCALE * 3)).point(lambda v: int(v * 0.7)))
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.alpha_composite(glow)
    canvas.alpha_composite(big, (margin, margin))
    return canvas


def on_plate(frame_path: Path, plate: tuple, style: str = "navy") -> Image.Image:
    """Fit the wordmark into the plate box (fractions x0, y0, x1, y1) of a generated frame."""
    frame = Image.open(frame_path).convert("RGBA")
    W, H = frame.size
    x0, y0, x1, y1 = plate[0] * W, plate[1] * H, plate[2] * W, plate[3] * H
    wm = wordmark(style)
    s = min((x1 - x0) * 0.92 / wm.width, (y1 - y0) * 1.25 / wm.height)
    wm = wm.resize((int(wm.width * s), int(wm.height * s)), Image.NEAREST)
    frame.alpha_composite(wm, (int((x0 + x1 - wm.width) / 2), int((y0 + y1 - wm.height) / 2)))
    return frame


# Empty plate boxes measured on the two generated frames.
PLATES = {"a": (0.15, 0.38, 0.86, 0.77), "b": (0.22, 0.42, 0.79, 0.71)}

if __name__ == "__main__":
    outdir = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
    wordmark().save(outdir / "wordmark.png")
    for v, plate in PLATES.items():
        on_plate(Path(__file__).parent / f"raw/logoframe_{v}_seedream_5_0_flash.webp", plate).convert("RGB") \
            .save(outdir / f"logo_frame_{v}.png")
    print("ok")
