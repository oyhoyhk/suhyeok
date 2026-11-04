"""Build a self-contained HTML preview of the market packs: portrait, animated walk/attack, tone, review notes.
usage: python3 art/preview.py [ids...]   ->  art/market/preview.html (all profiles when no ids are given)

Reads art/market/profiles.json (order, optional review "note") and art/market/packs/<id>/. The page embeds the
sold art, so it is written under the gitignored art/market/ and never next to tracked files.
"""
import base64
import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).parent
MARKET = ROOT / "market"


def data_uri(p: Path) -> str:
    kind = "png" if p.suffix == ".png" else "jpeg"
    return f"data:image/{kind};base64," + base64.b64encode(p.read_bytes()).decode()


def character(entry: dict) -> dict:
    d = MARKET / "packs" / entry["id"]
    m = json.loads((d / "manifest.json").read_text())
    portrait = next(d / f"portrait.{e}" for e in ("jpg", "png") if (d / f"portrait.{e}").exists())
    return {"id": entry["id"], "name": m["name"], "p": m["profile"], "portrait": data_uri(portrait),
            "sprite": data_uri(d / "sprite.png"), "note": html.escape(entry.get("note", "")),
            "frames": {k: [data_uri(d / f"frames/{k}_{i}.png") for i in range(n)] for k, n in m["frames"].items()},
            "kb": round(sum(f["bytes"] for f in m["files"].values()) / 1024), "files": len(m["files"])}


def main(ids: list[str]) -> Path:
    profiles = json.loads((MARKET / "profiles.json").read_text())
    chars = [character(e) for e in profiles if (not ids or e["id"] in ids) and (MARKET / "packs" / e["id"]).exists()]
    total = sum(c["kb"] for c in chars) / 1024
    facts = (f"<span>캐릭터 <b>{len(chars)}명</b></span><span>팩 합계 <b>{total:.1f}MB</b></span>"
             f"<span>검수 메모 <b>{sum(1 for c in chars if c['note'])}건</b></span>")
    page = ((ROOT / "preview_tpl.html").read_text().replace("<!--COUNT-->", str(len(chars)))
            .replace("<!--FACTS-->", facts).replace("/*DATA*/[]", json.dumps(chars, ensure_ascii=False)))
    out = MARKET / "preview.html"
    out.write_text(page)
    return out


if __name__ == "__main__":
    out = main(sys.argv[1:])
    print(out, round(out.stat().st_size / 1e6, 2), "MB")
