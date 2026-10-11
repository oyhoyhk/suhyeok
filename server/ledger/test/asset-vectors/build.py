#!/usr/bin/env python3
"""Builds the character-pack test vectors shared by assets.test.js and AssetPackTests.swift.

    python3 server/ledger/test/asset-vectors/build.py

Each case is a directory: the pack files plus expected.json = {"js": [codes], "swift": [codes]} (sorted,
unique error codes from docs/asset-pack-spec.md; empty = valid). Packs are tiny synthetic characters, except
`ok_knight`, which is the real bundled character.
"""
import io
import json
import pathlib
import shutil
import struct
import sys
import zlib

from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[3] / "art"))
import pack  # noqa: E402

REQUIRED = {"walk_down": 6, "walk_left": 6, "walk_up": 6, "attack": 6}


def png(size=(16, 24), mode="P", trns=True) -> bytes:
    img = Image.new("RGBA", size, (200, 40, 40, 255))
    for x in range(size[0] // 2):
        for y in range(size[1]):
            img.putpixel((x, y), (0, 0, 0, 0))
    buf = io.BytesIO()
    if mode == "P":
        p = img.convert("RGB").quantize(colors=4)
        if trns:
            p.info["transparency"] = 0
        p.save(buf, "PNG", **({"transparency": 0} if trns else {}))
    else:
        img.convert(mode).save(buf, "PNG")
    return buf.getvalue()


def jpeg(size=(128, 160), noise=False, quality=85) -> bytes:
    img = Image.effect_noise(size, 120).convert("RGB") if noise else Image.new("RGB", size, (90, 60, 30))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def corrupt_idat(data: bytes) -> bytes:
    """Keep a valid signature and IHDR, but make the image data undecodable (CRC fixed so the chunk walk passes)."""
    out, i = bytearray(data[:8]), 8
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        kind, body = data[i + 4:i + 8], bytearray(data[i + 8:i + 8 + n])
        if kind == b"IDAT":
            body = bytearray(b"\x00garbage-not-zlib" + bytes(max(0, n - 17)))
        out += struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        i += 12 + n
    return bytes(out)


def minimal(d: pathlib.Path, frames=REQUIRED, frame=None, sprite=None, portrait=("portrait.jpg", None), name="Tester"):
    d.mkdir(parents=True)
    if portrait:
        (d / portrait[0]).write_bytes(portrait[1] or jpeg())
    (d / "sprite.png").write_bytes(sprite or png(mode="RGBA"))
    (d / "frames").mkdir()
    for motion, n in frames.items():
        for i in range(n):
            (d / "frames" / f"{motion}_{i}.png").write_bytes(png())
    if frame:
        (d / "frames" / frame[0]).write_bytes(frame[1])
    return pack.write_manifest(d, name, dict(frames))


def edit_manifest(d: pathlib.Path, fn):
    m = json.loads((d / "manifest.json").read_text())
    fn(m)
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False, indent=1))


def case(name, js, swift=None):
    d = HERE / name
    shutil.rmtree(d, ignore_errors=True)
    return d, {"js": sorted(set(js)), "swift": sorted(set(swift if swift is not None else js))}


def main():
    cases = []

    d, exp = case("ok_knight", [])
    pack.pack("knight", d, "Sir Bolt"); cases.append((d, exp))

    d, exp = case("ok_minimal", [])
    minimal(d); cases.append((d, exp))

    d, exp = case("svg_sprite", ["bad_format"])
    minimal(d, sprite=b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'); cases.append((d, exp))

    d, exp = case("jpeg_frame", ["bad_format"])
    minimal(d, frame=("attack_0.png", jpeg((16, 24)))); cases.append((d, exp))

    d, exp = case("bad_path", ["bad_path"])
    minimal(d)
    edit_manifest(d, lambda m: m["files"].update({"../evil.png": {"sha256": "0" * 64, "bytes": 1}})); cases.append((d, exp))

    d, exp = case("short_walk", ["frame_count"])
    minimal(d, frames={**REQUIRED, "walk_down": 5}); cases.append((d, exp))

    d, exp = case("frames_disagree", ["frame_count"])
    minimal(d)
    edit_manifest(d, lambda m: m["frames"].update({"hammer": 3})); cases.append((d, exp))

    d, exp = case("big_frame", ["bad_dimensions"])
    minimal(d, frame=("attack_0.png", png(size=(300, 300)))); cases.append((d, exp))

    d, exp = case("hash_mismatch", ["hash_mismatch"])
    minimal(d)
    edit_manifest(d, lambda m: m["files"]["sprite.png"].update({"sha256": "f" * 64})); cases.append((d, exp))

    d, exp = case("map_kind", ["bad_kind"])
    minimal(d)
    edit_manifest(d, lambda m: m.update({"kind": "map"})); cases.append((d, exp))

    d, exp = case("rgb_frame", ["no_transparency"])
    minimal(d, frame=("walk_up_2.png", png(mode="RGB"))); cases.append((d, exp))

    d, exp = case("palette_without_trns", ["no_transparency"])
    minimal(d, frame=("walk_up_2.png", png(trns=False))); cases.append((d, exp))

    d, exp = case("tiny_portrait", ["bad_dimensions"])
    minimal(d, portrait=("portrait.jpg", jpeg((64, 64)))); cases.append((d, exp))

    d, exp = case("no_portrait", ["missing_file"])
    minimal(d, portrait=None); cases.append((d, exp))

    d, exp = case("huge_portrait", ["too_large"])
    minimal(d, portrait=("portrait.jpg", jpeg((700, 960), noise=True, quality=100))); cases.append((d, exp))

    d, exp = case("long_name", ["bad_name"])
    minimal(d, name="N" * 41); cases.append((d, exp))

    d, exp = case("missing_listed_file", ["missing_file"])
    minimal(d)
    (d / "frames" / "attack_5.png").unlink(); cases.append((d, exp))

    d, exp = case("undecodable_frame", [], ["undecodable"])
    minimal(d, frame=("walk_down_0.png", corrupt_idat(png()))); cases.append((d, exp))

    d, exp = case("not_json_manifest", ["bad_manifest"])
    minimal(d)
    (d / "manifest.json").write_text("{not json"); cases.append((d, exp))

    for d, exp in cases:
        (d / "expected.json").write_text(json.dumps(exp))
    print(f"{len(cases)} cases")


if __name__ == "__main__":
    main()
