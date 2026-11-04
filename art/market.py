"""Build market packs for characters sold on the market instead of bundled with the app.
usage: python3 market.py <id> ...   ->  art/market/packs/<id>/ (portrait.jpg, sprite.png, frames/, manifest.json)

Profiles come from art/market/profiles.json. Everything under art/market/ is gitignored: the repo is public
and these packs are sold, so they must not land in art/out (which ships in the app bundle) or in git.
Generate the raw art first with gen.py (sprite, portrait, strip <id>-{down,left,up}-a, attack <id>-a).
Then check: node art/validate_pack.mjs <pack>... (server rules), python3 art/review_board.py <pack> <out.png>
(by eye), python3 art/preview.py (all packs animated in one page, art/market/preview.html).
"""
import json
import shutil
import sys
from pathlib import Path

from PIL import Image

from pack import PROFILE_KEYS, write_manifest
from process import SPRITE_H, key_background
from sheet import STAND_H, slice_strip_to

ROOT = Path(__file__).parent
RAW = ROOT / "raw"
MODEL = "seedream_5_0_flash"
PROFILES = {c["id"]: c for c in json.loads((ROOT / "market/profiles.json").read_text())}
# Frames the model drew facing the wrong way, checked by eye: replaced by a good frame of the same row (as sheet.py's
# REUSE). Frames 0 and 3 are the two contact poses; a mirror would move a one-handed weapon to the other hand.
REUSE = {"skeleton": {"walk_up_3": "walk_up_0"}}


def build(cid: str) -> dict:
    c = PROFILES[cid]
    out = ROOT / "market/packs" / cid
    frames = out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    # Same steps as process.py (sprite, portrait) and sheet.py (strips, attacks), written to the pack instead.
    img = Image.open(RAW / f"sprite_{cid}_{MODEL}.webp").convert("RGB")
    img = img.resize((img.width // 4, img.height // 4), Image.LANCZOS)
    s = key_background(img)
    s.resize((max(1, round(s.width * SPRITE_H / s.height)), SPRITE_H), Image.NEAREST).save(out / "sprite.png")
    p = Image.open(RAW / f"portrait_{cid}_{MODEL}.webp").convert("RGB")
    p.thumbnail((768, 1024), Image.LANCZOS)
    p.save(out / "portrait.jpg", quality=86)
    for view in ("down", "left", "up"):
        slice_strip_to(RAW / f"strip_{cid}-{view}-a_{MODEL}.webp", frames, f"walk_{view}", STAND_H)
    stand = Image.open(frames / "walk_down_2.png").height
    slice_strip_to(RAW / f"attack_{cid}-a_{MODEL}.webp", frames, "attack", stand, by="min", effects_left=True)
    for bad, good in REUSE.get(cid, {}).items():
        shutil.copy(frames / f"{good}.png", frames / f"{bad}.png")
    counts = {}
    for f in frames.glob("*.png"):
        motion = f.stem.rsplit("_", 1)[0]
        counts[motion] = counts.get(motion, 0) + 1
    profile = {k: c[k] for k in PROFILE_KEYS if isinstance(c.get(k), str) and c[k].strip()}
    return write_manifest(out, c["name"], counts, profile)


if __name__ == "__main__":
    for cid in sys.argv[1:]:
        m = build(cid)
        print(cid, m["frames"], len(m["files"]), "files", sum(f["bytes"] for f in m["files"].values()), "bytes")
