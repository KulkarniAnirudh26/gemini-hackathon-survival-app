"""Download aerial imagery for a GeoPDF's footprint into an MBTiles file, to drape over 3D terrain.

    python -m geopdf_locator.imagery data/yosemite.pdf out/yosemite-imagery.mbtiles [--max-zoom 13]

Source: USGS The National Map orthoimagery (USDA NAIP and USGS imagery), public domain; credit
"USDA, USGS The National Map: Orthoimagery". Zoom 13 is ~15 m per pixel; for Yosemite zooms 9-13
are ~670 tiles, ~16 MB, and adding zoom 14 (~7.5 m per pixel) brings it to ~65 MB.
"""
import argparse
from pathlib import Path

from .terrain import download_mbtiles

# ArcGIS tile services order the path z/row/column
URL = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"
ATTRIBUTION = "Imagery: USDA, USGS The National Map: Orthoimagery"


def fetch_imagery(pdf: str, out: str, min_zoom: int = 9, max_zoom: int = 13) -> int:
    """Write orthoimagery tiles covering the GeoPDF's footprint to `out`. Returns the tile count."""
    return download_mbtiles(URL, pdf, out, min_zoom, max_zoom, {
        "name": f"{Path(pdf).stem} imagery", "format": "jpg", "type": "baselayer", "attribution": ATTRIBUTION,
    })


def main() -> int:
    parser = argparse.ArgumentParser(description="Download USGS orthoimagery tiles for a GeoPDF's footprint.")
    parser.add_argument("pdf")
    parser.add_argument("out")
    parser.add_argument("--min-zoom", type=int, default=9)
    parser.add_argument("--max-zoom", type=int, default=13)
    args = parser.parse_args()
    n = fetch_imagery(args.pdf, args.out, args.min_zoom, args.max_zoom)
    print(f"wrote {args.out} ({n} tiles, {Path(args.out).stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
