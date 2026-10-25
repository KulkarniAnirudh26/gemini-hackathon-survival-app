"""Build the map pack for the Android app, plus a parity fixture for its unit tests.

    python scripts/build_android_assets.py data/yosemite.pdf

writes
    android-native/app/src/main/assets/maps/yosemite/{mappack.json, map.jpg}
    android-native/app/src/main/assets/maps/yosemite/yosemite.mbtiles          (--tiles; map tiles for 3D)
    android-native/app/src/main/assets/maps/yosemite/yosemite-terrain.mbtiles  (--terrain; elevation)
    android-native/app/src/main/assets/maps/yosemite/yosemite-imagery.mbtiles  (--imagery; aerial photos)
                                    (--terrain and --imagery download; all .mbtiles are gitignored)
    android/app/src/main/assets/maps/yosemite/{*.mbtiles, mappack.json}   (copies for the Flutter app's
                                                                          3D MAP screen)
    android-native/mappack/src/test/resources/parity.json   (what the Python side answers, which the
                                                      Kotlin tests must reproduce)
"""
import argparse
import json
import shutil
from pathlib import Path

from geopdf_locator import GeoPdfMap, Guidance
from geopdf_locator.export import export
from geopdf_locator.imagery import fetch_imagery
from geopdf_locator.terrain import fetch_terrain
from geopdf_locator.tiles import write_mbtiles

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "android-native" / "app" / "src" / "main" / "assets" / "maps"
FLUTTER_ASSETS = ROOT / "android" / "app" / "src" / "main" / "assets" / "maps" / "yosemite"
FIXTURE = ROOT / "android-native" / "mappack" / "src" / "test" / "resources" / "parity.json"


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
    parser.add_argument("--tiles", action="store_true", help="also render an MBTiles tileset")
    parser.add_argument("--max-zoom", type=int, default=13, help="highest map tile zoom (default 13, ~8 MB)")
    parser.add_argument("--terrain", action="store_true", help="also download elevation tiles for 3D")
    parser.add_argument("--terrain-max-zoom", type=int, default=11, help="default 11, ~6.5 MB")
    parser.add_argument("--imagery", action="store_true", help="also download aerial imagery for 3D")
    parser.add_argument("--imagery-max-zoom", type=int, default=13, help="default 13, ~15 MB")
    args = parser.parse_args()

    pack_path, image_path = export(args.pdf, str(ASSETS / args.name), dpi=args.dpi)
    pack = json.loads(pack_path.read_text())
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(parity_cases(GeoPdfMap.open(args.pdf), pack), indent=1))
    written = [pack_path, image_path, FIXTURE]
    if args.tiles:
        tiles = ASSETS / args.name / f"{args.name}.mbtiles"
        write_mbtiles(args.pdf, str(tiles), max_zoom=args.max_zoom)
        written.append(tiles)
    if args.terrain:
        terrain = ASSETS / args.name / f"{args.name}-terrain.mbtiles"
        fetch_terrain(args.pdf, str(terrain), max_zoom=args.terrain_max_zoom)
        written.append(terrain)
    if args.imagery:
        imagery = ASSETS / args.name / f"{args.name}-imagery.mbtiles"
        fetch_imagery(args.pdf, str(imagery), max_zoom=args.imagery_max_zoom)
        written.append(imagery)
    # the Flutter app's 3D MAP screen reads the same tilesets from its own Android assets
    mbtiles = [p for p in written if p.suffix == ".mbtiles"]
    mbtiles.append(pack_path)  # its search box and guidance use the map pack
    if mbtiles:
        FLUTTER_ASSETS.mkdir(parents=True, exist_ok=True)
        for p in mbtiles:
            copy = FLUTTER_ASSETS / p.name
            shutil.copyfile(p, copy)
            written.append(copy)
    for p in written:
        print(f"wrote {p.relative_to(ROOT)} ({p.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
