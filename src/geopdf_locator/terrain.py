"""Download elevation tiles for a GeoPDF's footprint into an MBTiles file, for 3D terrain.

    python -m geopdf_locator.terrain data/yosemite.pdf out/yosemite-terrain.mbtiles [--max-zoom 12]

Source: the open "Terrain Tiles" on AWS (Terrarium encoding: elevation = R*256 + G + B/256 - 32768
metres), built from USGS 3DEP, SRTM and other public datasets. Attribution is required:
https://github.com/tilezen/joerd/blob/master/docs/attribution.md

MapLibre renders these as a `raster-dem` source with `"encoding": "terrarium"`. Zoom 12 is ~30 m
per pixel; for Yosemite zooms 8-12 are 188 tiles, 24 MB, and zooms 8-11 (~60 m per pixel, which
looks nearly the same under a park map) are 56 tiles, 6.5 MB.
"""
import argparse
import math
import sqlite3
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
ATTRIBUTION = ("Terrain: USGS 3DEP, SRTM and others via Terrain Tiles "
               "(https://github.com/tilezen/joerd/blob/master/docs/attribution.md)")


def tile_range(z, lon0, lat0, lon1, lat1):
    def tx(lon):
        return int((lon + 180) / 360 * (1 << z))

    def ty(lat):
        return int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * (1 << z))

    return [(z, x, y) for x in range(tx(lon0), tx(lon1) + 1) for y in range(ty(lat1), ty(lat0) + 1)]


def download_mbtiles(url: str, pdf: str, out: str, min_zoom: int, max_zoom: int, metadata: dict) -> int:
    """Download the XYZ tiles of `url` (with {z}/{x}/{y}) covering the GeoPDF's footprint into an
    MBTiles file. Returns the tile count."""
    from .locator import GeoPdfMap
    from .tiles import TileRenderer

    lon0, lat0, lon1, lat1 = TileRenderer(GeoPdfMap.open(pdf)).bounds_lonlat()
    tiles = [t for z in range(min_zoom, max_zoom + 1) for t in tile_range(z, lon0, lat0, lon1, lat1)]

    def fetch(tile):
        z, x, y = tile
        with urllib.request.urlopen(url.format(z=z, x=x, y=y), timeout=30) as r:
            return tile, r.read()

    path = Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
    """)
    db.executemany("INSERT INTO metadata VALUES (?, ?)", {
        **metadata, "minzoom": str(min_zoom), "maxzoom": str(max_zoom),
        "bounds": f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}",
    }.items())
    with ThreadPoolExecutor(8) as pool:
        for (z, x, y), data in pool.map(fetch, tiles):
            db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, x, (1 << z) - 1 - y, data))
    db.commit()
    db.close()
    return len(tiles)


def fetch_terrain(pdf: str, out: str, min_zoom: int = 8, max_zoom: int = 12) -> int:
    """Write Terrarium elevation tiles covering the GeoPDF's footprint to `out`. Returns the tile count."""
    return download_mbtiles(URL, pdf, out, min_zoom, max_zoom, {
        "name": f"{Path(pdf).stem} terrain", "format": "png", "type": "baselayer",
        "encoding": "terrarium", "attribution": ATTRIBUTION,
    })


def main() -> int:
    parser = argparse.ArgumentParser(description="Download Terrarium elevation tiles for a GeoPDF's footprint.")
    parser.add_argument("pdf")
    parser.add_argument("out")
    parser.add_argument("--min-zoom", type=int, default=8)
    parser.add_argument("--max-zoom", type=int, default=12)
    args = parser.parse_args()
    n = fetch_terrain(args.pdf, args.out, args.min_zoom, args.max_zoom)
    print(f"wrote {args.out} ({n} tiles, {Path(args.out).stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
