"""Build the map pack for the Android app, plus a parity fixture for its unit tests.

    python scripts/build_android_assets.py data/yosemite.pdf

writes
    android/app/src/main/assets/maps/yosemite/{mappack.json, map.jpg}
    android/mappack/src/test/resources/parity.json   (what the Python side answers, which the
                                                      Kotlin tests must reproduce)
"""
import argparse
import json
from pathlib import Path

from geopdf_locator import GeoPdfMap, Guidance
from geopdf_locator.export import export

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "android" / "app" / "src" / "main" / "assets" / "maps"
FIXTURE = ROOT / "android" / "mappack" / "src" / "test" / "resources" / "parity.json"


def parity_cases(m: GeoPdfMap, pack: dict, grid: int = 12) -> dict:
    g = Guidance(m)
    searches = []
    for name in sorted({lb["text"] for lb in pack["labels"]}):
        hits = m.locate(name)
        if hits:
            h = hits[0]
            searches.append({"query": name, "label": h.label, "lat": h.lat, "lon": h.lon})

    positions = []
    w, h = m.page.rect.width, m.page.rect.height
    points = [(w * (i + 0.5) / grid, h * (j + 0.5) / grid) for i in range(grid) for j in range(grid)]
    points += [(lb["x"], lb["y"]) for lb in pack["labels"]]  # every place, where road notes cluster
    for x, y in points:
        lat, lon = m.to_latlon(x, y)
        local = [a for a in g.for_latlon(lat, lon) if a.reason != "park-wide"]
        positions.append({"lat": lat, "lon": lon,
                          "guidance": [{"text": a.note.text, "reason": a.reason} for a in local]})
    return {"searches": searches, "positions": positions}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf")
    parser.add_argument("--name", default="yosemite", help="asset folder name (default: yosemite)")
    parser.add_argument("--dpi", type=int, default=150)
    args = parser.parse_args()

    pack_path, image_path = export(args.pdf, str(ASSETS / args.name), dpi=args.dpi)
    pack = json.loads(pack_path.read_text())
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(parity_cases(GeoPdfMap.open(args.pdf), pack), indent=1))
    for p in (pack_path, image_path, FIXTURE):
        print(f"wrote {p.relative_to(ROOT)} ({p.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
