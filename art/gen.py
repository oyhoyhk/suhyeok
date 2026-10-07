"""Generate Agent Deck art via Higgsfield CLI.
usage: python3 gen.py sprite|portrait|map <model> [ids...]
"""
import json, re, subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).parent
ROSTER = {c["id"]: c for c in json.loads((ROOT / "roster.json").read_text())}

SPRITE = ("16-bit pixel art RPG game character sprite, single character, full body, standing, "
          "front view facing the viewer, chibi proportions with a big head, crisp pixels, limited palette, "
          "bold dark outline. {visual}. Centered on a plain flat solid bright magenta background (#FF00FF), "
          "no shadow, no ground, no text, no border.")
PORTRAIT = ("Detailed pixel art character portrait in the style of a 16-bit fantasy RPG dialogue portrait, "
            "upper body, three-quarter view, expressive friendly face. {visual}. "
            "Simple warm dark tavern background with soft bokeh. No text, no frame, no watermark.")
MAP = ("Top-down 16-bit pixel art RPG interior map of a cozy adventurers' guild hall, seen from directly above "
       "at a slight angle like a classic JRPG. Left half: a large work hall with three rows of wooden desks "
       "and quest boards on the wall. Upper right: a blacksmith forge corner with an anvil, furnace glow and "
       "weapon racks. Lower right: a tavern lounge with round tables, sofas, a fireplace and a bar counter. "
       "Wooden floor, stone walls, warm lighting, wide open floor space between areas, no characters, "
       "no people, no text, no UI.")

HERO = ("Wide 16-bit pixel art scene in a fantasy RPG style. Inside a cozy wooden adventurers' guild hall with warm "
        "torch light, a confident guild master in a long navy cape with gold trim stands on an upper balcony, raising a "
        "baton with a small golden pennant flag and directing the hall below. Below, many small chibi adventurers work: "
        "a knight and a wizard at wooden desks, a fox adventurer reading a scroll, a dwarf hammering at a glowing forge, "
        "an engineer gnome with a wrench. Cheerful, busy, organized atmosphere. Correct anatomy, no extra limbs. "
        "No text, no letters, no UI, no watermark.")
ICON = ("Pixel art app icon, a single bold emblem centered on a rounded square deep navy blue background: a golden "
        "commander's pennant flag on a short pole with one small white star above it. Thick dark outline, very simple "
        "shapes, high contrast, readable at 16 pixels, flat colors, no gradients. No text, no letters, no border frame.")

def run(kind, model, cid):
    if kind == "map":
        prompt, aspect, out = MAP, "16:9", f"map_{model}"
    elif kind in ("hero", "icon"):
        prompt, aspect = (HERO, "16:9") if kind == "hero" else (ICON, "1:1")
        out = f"{kind}_{cid}_{model}"
    else:
        tmpl = SPRITE if kind == "sprite" else PORTRAIT
        prompt, aspect = tmpl.format(visual=ROSTER[cid]["visual"]), ("1:1" if kind == "sprite" else "3:4")
        out = f"{kind}_{cid}_{model}"
    cmd = ["npx", "-y", "-p", "@higgsfield/cli", "higgsfield", "generate", "create", model,
           "--prompt", prompt, "--aspect_ratio", aspect,
           "--wait", "--wait-timeout", "30m", "--json"]
    if model != "z_image":  # z_image rejects unknown params
        cmd[8:8] = ["--resolution", "2k"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    text = p.stdout + p.stderr
    (ROOT / f"logs/{out}.json").write_text(text)
    m = re.search(r'https://[^"\s]+\.(png|jpg|jpeg|webp)', text)
    if not m:
        return f"FAIL {out} (exit {p.returncode}) {text.strip().splitlines()[-1] if text.strip() else ''}"
    dest = ROOT / f"raw/{out}.{m.group(1)}"
    urllib.request.urlretrieve(m.group(0), dest.with_suffix(".part"))  # rename so readers never see half a file
    dest.with_suffix(".part").rename(dest)
    return f"ok {out}"

if __name__ == "__main__":
    kind, model, ids = sys.argv[1], sys.argv[2], sys.argv[3:] or [None]  # hero/icon: ids are variant labels (a b)
    # Skip finished ones so reruns only fill gaps.
    ids = [c for c in ids if not list((ROOT / "raw").glob(f"{kind}_{c}_{model}.*"))] if ids != [None] else ids
    # Starter plan allows 4 concurrent jobs account-wide; keep one slot free.
    with ThreadPoolExecutor(3) as ex:
        for r in ex.map(lambda c: run(kind, model, c), ids):
            print(r, flush=True)
