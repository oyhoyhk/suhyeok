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

LOGOFRAME = ("Ornate 16-bit pixel art logo banner for a fantasy RPG title screen: a wide golden ribbon banner across "
             "the middle, a royal golden crown on top, two crossed golden pennant flags behind it, small white sparkles, "
             "deep navy blue background, rich gold and crimson accents, thick dark outline. The center of the ribbon is a "
             "large EMPTY flat gold area with absolutely no text, no letters, no symbols.")
LOGOTEXT = ("Ornate 16-bit pixel art fantasy RPG title logo that reads exactly \"SUHYEOK\" in large bold golden pixel "
            "letters with a thick dark outline and a warm glow, a royal golden crown above the word, two crossed golden "
            "pennant flags behind it, small white sparkles, deep navy blue background. The only text in the image is "
            "SUHYEOK, spelled S-U-H-Y-E-O-K, seven letters.")

SHEET = ("16-bit pixel art RPG character sprite sheet of EXACTLY the same character as the reference image ({visual}). "
         "Same outfit, colors and proportions in every cell. A strict grid of 3 columns and 6 rows of equal cells, "
         "one full-body chibi pose per cell, all the same size, on a plain flat bright magenta background (#FF00FF), "
         "no grid lines, no shadows, no text. "
         "Row 1: walking toward the viewer (front view), 3 frames: left foot forward, standing, right foot forward. "
         "Row 2: walking to the left (side view facing left), 3 frames: left foot forward, standing, right foot forward. "
         "Row 3: walking away from the viewer (back view), 3 frames: left foot forward, standing, right foot forward. "
         "Row 4: front view swinging a blacksmith hammer down onto a small anvil, 3 frames: raised, mid swing, striking. "
         "Row 5: front view sitting at a small wooden desk typing on a keyboard, 3 frames with hands at different keys. "
         "Row 6: front view reading an open book held in both hands, 3 frames: reading, turning a page, reading. "
         "Correct anatomy, exactly two arms and two legs.")

AREA_STYLE = ("Top-down 16-bit pixel art RPG interior map, seen from directly above at a slight angle like a classic JRPG, "
              "same style as a cozy adventurers' guild hall: warm lighting, wooden floors, stone walls, thick dark outlines. ")
AREAS = {
    "tavern": "A large cozy tavern hall: many round wooden tables with stools spread across the floor, a long bar counter "
              "along the top wall with barrels and bottles, a big stone fireplace on the left wall, hanging lanterns, "
              "wide open walkways between the tables.",
    "garden": "An enclosed courtyard garden: stone paths, a round fountain in the center, wooden benches along the paths, "
              "flower beds, small trees and hedges, soft grass, low stone walls around the edges, wide open walkways.",
    "library": "A grand library: tall bookshelves along the walls and in neat rows, reading desks with candles, a large "
               "celestial globe in the center, rugs, wide aisles between the shelves.",
}

TOWN = ("Highly detailed 16-bit pixel art top-down RPG town map, seen from directly above at a slight angle like a classic "
        "JRPG overworld interior, one single coherent fortified guild compound at night with warm lantern light. "
        "The compound has four large buildings with open interiors (no roofs, you see the floors and furniture inside), "
        "arranged in a 2 by 2 layout around a central cobblestone plaza: "
        "TOP-LEFT: a guild workshop hall with rows of wooden work desks with chairs, a blacksmith forge with a glowing furnace "
        "and an anvil, and a few round meeting tables. "
        "TOP-RIGHT: a grand library with tall bookshelves along the walls, rows of reading desks with candles, and a large "
        "celestial globe on a rug in the middle. "
        "BOTTOM-LEFT: a cozy tavern with many round wooden tables and stools, a long bar counter with barrels and bottles, "
        "and a stone fireplace. "
        "BOTTOM-RIGHT: an open garden courtyard with a round fountain, stone paths, wooden benches, flower beds and small trees. "
        "Each building has a clear open doorway facing the central plaza, and wide cobblestone paths connect every doorway "
        "through the plaza. Stone walls with torches surround the compound. Consistent scale and lighting across the whole map, "
        "crisp pixels, rich detail, wide walkable floor space. No characters, no people, no text, no letters, no UI.")

WORK = ("16-bit pixel art RPG character sprite sheet of EXACTLY the same character as the reference image ({visual}). "
        "Same outfit, colors and proportions in every cell. A strict grid of 3 columns and 3 rows of equal cells, one full-body "
        "chibi pose per cell, all the same size, standing, on a plain flat bright magenta background (#FF00FF). "
        "IMPORTANT: draw ONLY the character and the small item held in the hands. No furniture at all: no desk, no table, "
        "no chair, no anvil, no keyboard, no floor, no shadow, no grid lines, no text. "
        "Row 1: front view, standing, writing with a feather quill on a small parchment held in one hand, 3 frames: "
        "quill touching the paper, quill lifted, quill touching the paper again. "
        "Row 2: side view facing LEFT, standing, holding a blacksmith hammer with both hands, 3 frames: hammer raised high "
        "above the head, hammer halfway down, hammer swung down low in front at waist height. "
        "Row 3: front view, standing, reading an open book held in both hands, 3 frames: reading, turning a page, reading. "
        "Correct anatomy, exactly two arms and two legs.")

def upload(path):
    """Upload once and remember the media id (logs/uploads.json)."""
    cache_path = ROOT / "logs/uploads.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    if path.name in cache:
        return cache[path.name]
    out = subprocess.run(["npx", "-y", "-p", "@higgsfield/cli", "higgsfield", "upload", "create", str(path), "--json"],
                         capture_output=True, text=True).stdout
    m = re.search(r'"id"\s*:\s*"([^"]+)"', out)
    if not m:
        raise SystemExit("upload failed: " + out[-300:])
    cache[path.name] = m.group(1)
    cache_path.write_text(json.dumps(cache, indent=1))
    return m.group(1)

def run(kind, model, cid):
    if kind == "map":
        prompt, aspect, out = MAP, "16:9", f"map_{model}"
    elif kind == "town":
        prompt, aspect, out = TOWN, "16:9", f"town_{cid}_{model}"
    elif kind == "area":
        # cid = "<area>-<variant>"
        prompt, aspect = AREA_STYLE + AREAS[cid.rsplit("-", 1)[0]] + " No characters, no people, no text, no UI.", "16:9"
        out = f"area_{cid}_{model}"
    elif kind == "work":
        char = cid.rsplit("-", 1)[0]
        prompt, aspect = WORK.format(visual=ROSTER[char]["visual"]), "1:1"
        out = f"work_{cid}_{model}"
    elif kind == "sheet":
        # cid = "<character>-<variant>"; the character's front sprite is the identity reference.
        char = cid.rsplit("-", 1)[0]
        prompt, aspect = SHEET.format(visual=ROSTER[char]["visual"]), "9:16"
        out = f"sheet_{cid}_{model}"
    elif kind in ("hero", "icon", "logoframe", "logotext"):
        prompt, aspect = {"hero": (HERO, "16:9"), "icon": (ICON, "1:1"),
                          "logoframe": (LOGOFRAME, "16:9"), "logotext": (LOGOTEXT, "16:9")}[kind]
        out = f"{kind}_{cid}_{model}"
    else:
        tmpl = SPRITE if kind == "sprite" else PORTRAIT
        prompt, aspect = tmpl.format(visual=ROSTER[cid]["visual"]), ("1:1" if kind == "sprite" else "3:4")
        out = f"{kind}_{cid}_{model}"
    cmd = ["npx", "-y", "-p", "@higgsfield/cli", "higgsfield", "generate", "create", model,
           "--prompt", prompt, "--aspect_ratio", aspect,
           "--wait", "--wait-timeout", "30m", "--json"]
    if model != "z_image":  # z_image rejects unknown params
        cmd[8:8] = ["--resolution", "4k" if kind == "town" else "2k"]
    if model == "gpt_image_2":
        cmd[8:8] = ["--quality", "medium"]
    if kind in ("sheet", "work"):
        ref = ROOT / f"raw/sprite_{cid.rsplit('-', 1)[0]}_seedream_5_0_flash.webp"
        cmd[8:8] = ["--image-references", upload(ref)]
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
