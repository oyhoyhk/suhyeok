#!/usr/bin/env python3
"""Bundle a character into a market pack (docs/asset-pack-spec.md, format 2).

    python3 art/pack.py <character id> <out dir> [--name "English Name"] [--profile profile.json]

Reads art/out/portraits/<id>.jpg, art/out/sprites/<id>.png and art/out/frames/<id>/*.png,
copies them into the pack layout and writes manifest.json with sha256 and byte counts.
The profile (ko, role, tone, visual, weapon) comes from art/roster.json; a new local character
passes its own with --profile, a JSON file with those keys.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import sys

ART = pathlib.Path(__file__).resolve().parent / "out"
MOTIONS = {"walk_down": 6, "walk_left": 6, "walk_up": 6, "attack": 6,
           "hammer": 3, "read": 3, "type": 3, "smith": 6, "study": 6, "write": 6}


PROFILE_KEYS = ("ko", "role", "tone", "visual", "weapon")


def profile_from(entry: dict, cid: str) -> dict:
    """The profile fields of a roster entry; `role` falls back to the id (with a warning) until the roster has it."""
    profile = {k: entry[k] for k in PROFILE_KEYS if isinstance(entry.get(k), str) and entry[k].strip()}
    if "role" not in profile:
        print(f"warning: no role for {cid} in roster.json; using the id", file=sys.stderr)
        profile["role"] = cid
    return profile


def write_manifest(out: pathlib.Path, name: str, frames: dict, profile: dict | None = None) -> dict:
    files = {}
    for f in sorted(p for p in out.rglob("*") if p.is_file() and p.name != "manifest.json"):
        data = f.read_bytes()
        files[f.relative_to(out).as_posix()] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    manifest = {"format": 2, "kind": "character", "name": name, "profile": profile or {}, "frames": frames, "files": files}
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    return manifest


def pack(cid: str, out: pathlib.Path, name: str, profile: dict | None = None) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    portrait = next((ART / "portraits" / f"{cid}.{ext}" for ext in ("jpg", "png") if (ART / "portraits" / f"{cid}.{ext}").exists()), None)
    if portrait is None:
        sys.exit(f"no portrait for {cid}")
    shutil.copy(portrait, out / f"portrait{portrait.suffix}")
    shutil.copy(ART / "sprites" / f"{cid}.png", out / "sprite.png")
    (out / "frames").mkdir(exist_ok=True)
    frames = {}
    for f in sorted((ART / "frames" / cid).glob("*.png")):
        m = re.fullmatch(r"([a-z_]+)_(\d+)", f.stem)
        if m and m.group(1) in MOTIONS:
            shutil.copy(f, out / "frames" / f.name)
            frames[m.group(1)] = frames.get(m.group(1), 0) + 1
    return write_manifest(out, name, frames, profile)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("id")
    ap.add_argument("out")
    ap.add_argument("--name")
    ap.add_argument("--profile", help="JSON file with ko, role, tone and optional visual, weapon")
    a = ap.parse_args()
    roster = {c["id"]: c for c in json.loads((ART.parent / "roster.json").read_text())}
    entry = roster.get(a.id, {})
    if a.profile:
        given = json.loads(pathlib.Path(a.profile).read_text())
        profile = {k: given[k] for k in PROFILE_KEYS if k in given}
    else:
        profile = profile_from(entry, a.id)
    m = pack(a.id, pathlib.Path(a.out), a.name or entry.get("name", a.id), profile)
    print(f"{len(m['files'])} files, {sum(f['bytes'] for f in m['files'].values())} bytes")
