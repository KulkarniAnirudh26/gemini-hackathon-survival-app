"""Cut a park-sized extract of the NPS "Park Tiles" vector tilesets for offline use.

    python scripts/extract_park_tiles.py data/yosemite.pdf out/parktiles [--mbtiles]

The NPS publishes nationwide vector tiles (Mapbox Vector Tile, zoom 0-15) as PMTiles:
https://www.nps.gov/maps/web/blog/tilejson/index.html . `pmtiles extract` (Homebrew: `brew
install pmtiles`) downloads only the tiles inside a bounding box via HTTP range requests, so
the whole national files (hundreds of MB to 1.4 GB each) are never fetched. The box is the
GeoPDF's own footprint, so the vector layer covers exactly the area of the printed-map tiles.

For Yosemite this takes ~10 s and writes ~23 MB: boundary (parks, wilderness), data (roads,
trails, buildings, parking), hydro (streams, lakes) and label-point (named points: restrooms,
trailheads, campgrounds, viewpoints... with lat/lon). NPS and USGS data, public domain.

--mbtiles also writes each extract as a vector MBTiles file (needs `pip install pmtiles`).
"""
import argparse
import json
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

LAYERS = ["boundary", "data", "hydro", "label-point"]
SOURCE = "https://www.nps.gov/maps/pmtiles/park-tiles-4-{}.pmtiles"


def footprint(pdf: str) -> tuple[float, float, float, float]:
    from geopdf_locator import GeoPdfMap
    from geopdf_locator.tiles import TileRenderer

    return TileRenderer(GeoPdfMap.open(pdf)).bounds_lonlat()


def to_mbtiles(src: Path, dst: Path) -> int:
    """Copy a PMTiles vector archive into an MBTiles 1.3 file (gzipped pbf tiles)."""
    from pmtiles.reader import MmapSource, Reader, all_tiles

    with open(src, "rb") as f:
        source = MmapSource(f)
        reader = Reader(source)
        header, metadata = reader.header(), reader.metadata()
        if dst.exists():
            dst.unlink()
        db = sqlite3.connect(dst)
        db.executescript("""
            CREATE TABLE metadata (name TEXT, value TEXT);
            CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
            CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
        """)
        lon0, lat0 = header["min_lon_e7"] / 1e7, header["min_lat_e7"] / 1e7
        lon1, lat1 = header["max_lon_e7"] / 1e7, header["max_lat_e7"] / 1e7
        meta = {
            "name": metadata.get("name", src.stem), "format": "pbf", "type": "overlay",
            "minzoom": str(header["min_zoom"]), "maxzoom": str(header["max_zoom"]),
            "bounds": f"{lon0},{lat0},{lon1},{lat1}",
            "center": f"{(lon0 + lon1) / 2},{(lat0 + lat1) / 2},{header['max_zoom']}",
            "attribution": metadata.get("attribution", "NPS"),
            "json": json.dumps({"vector_layers": metadata.get("vector_layers", [])}),
        }
        db.executemany("INSERT INTO metadata VALUES (?, ?)", meta.items())
        n = 0
        for (z, x, y), data in all_tiles(source):
            # PMTiles stores tiles as-is (gzip here); MBTiles vector tiles are gzipped pbf too
            db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, x, (1 << z) - 1 - y, data))
            n += 1
        db.commit()
        db.close()
    return n


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("pdf", help="the GeoPDF whose footprint to extract")
    parser.add_argument("out_dir")
    parser.add_argument("--max-zoom", type=int, default=15)
    parser.add_argument("--mbtiles", action="store_true", help="also write vector MBTiles copies")
    args = parser.parse_args()
    if not shutil.which("pmtiles"):
        sys.exit("needs the pmtiles CLI: brew install pmtiles (or https://github.com/protomaps/go-pmtiles)")

    lon0, lat0, lon1, lat1 = footprint(args.pdf)
    bbox = f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}"
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stem = Path(args.pdf).stem
    for layer in LAYERS:
        dst = out / f"{stem}-{layer}.pmtiles"
        subprocess.run(["pmtiles", "extract", SOURCE.format(layer), str(dst), f"--bbox={bbox}",
                        f"--maxzoom={args.max_zoom}"], check=True, capture_output=True)
        line = f"wrote {dst} ({dst.stat().st_size / 1e6:.1f} MB)"
        if args.mbtiles:
            mb = dst.with_suffix(".mbtiles")
            line += f", {mb.name} ({to_mbtiles(dst, mb)} tiles)"
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
