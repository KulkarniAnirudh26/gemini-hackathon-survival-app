"""Render a GeoPDF into an MBTiles raster tileset (Web Mercator XYZ tiles in SQLite).

Each tile is drawn straight from the PDF's vector content at that zoom, so labels stay sharp
at every level; nothing is resampled from one big image. Coordinates come from the same
georeference the place search and guidance use, so markers placed by lat/lon line up with
the map's own symbols.

    python -m geopdf_locator.tiles data/yosemite.pdf out/yosemite.mbtiles --max-zoom 14
"""
from __future__ import annotations

import math
import sqlite3
import time
from pathlib import Path

import pymupdf

from .georef import EARTH_RADIUS, _web_mercator, _web_mercator_inv
from .locator import GeoPdfMap

TILE_SIZE = 256
ORIGIN = math.pi * EARTH_RADIUS  # Web Mercator half-extent in metres


def _tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """XYZ tile -> Web Mercator (min_x, min_y, max_x, max_y) in metres."""
    size = 2 * ORIGIN / (1 << z)
    return -ORIGIN + x * size, ORIGIN - (y + 1) * size, -ORIGIN + (x + 1) * size, ORIGIN - y * size


def _tile_range(z: int, merc: tuple[float, float, float, float]) -> tuple[range, range]:
    min_x, min_y, max_x, max_y = merc
    size = 2 * ORIGIN / (1 << z)
    xs = range(int((min_x + ORIGIN) // size), int((max_x + ORIGIN) // size) + 1)
    ys = range(int((ORIGIN - max_y) // size), int((ORIGIN - min_y) // size) + 1)
    return xs, ys


class TileRenderer:
    def __init__(self, m: GeoPdfMap, background=(255, 255, 255)):
        vp = m.georef.viewports
        if len(vp) != 1 or vp[0].forward is not _web_mercator:
            raise NotImplementedError("tiling supports single-viewport Web Mercator GeoPDFs")
        self.m = m
        self.page = m.page
        self.background = background
        self.display_list = m.page.get_displaylist()  # parse the page once, render many times
        r = m.page.rect
        corners = [m.to_latlon(x, y) for x, y in ((r.x0, r.y0), (r.x1, r.y1))]
        (lat0, lon0), (lat1, lon1) = corners
        mx0, my0 = _web_mercator(lat0, lon0)
        mx1, my1 = _web_mercator(lat1, lon1)
        self.merc = (min(mx0, mx1), min(my0, my1), max(mx0, mx1), max(my0, my1))
        # page x/y per mercator metre (the georeference is axis-aligned: checked below)
        self._px_per_m = (r.width / (self.merc[2] - self.merc[0]), r.height / (self.merc[3] - self.merc[1]))
        mid = m.to_page(*_web_mercator_inv((self.merc[0] + self.merc[2]) / 2, (self.merc[1] + self.merc[3]) / 2))
        expect = ((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
        if math.dist(mid, expect) > 0.01:
            raise NotImplementedError("tiling needs a north-up, axis-aligned georeference")

    def bounds_lonlat(self) -> tuple[float, float, float, float]:
        (lat0, lon0), (lat1, lon1) = (_web_mercator_inv(self.merc[0], self.merc[1]),
                                       _web_mercator_inv(self.merc[2], self.merc[3]))
        return lon0, lat0, lon1, lat1

    def page_rect(self, merc: tuple[float, float, float, float]) -> pymupdf.Rect:
        """Mercator box -> page rectangle (top-left origin)."""
        r = self.page.rect
        sx, sy = self._px_per_m
        return pymupdf.Rect(
            r.x0 + (merc[0] - self.merc[0]) * sx, r.y0 + (self.merc[3] - merc[3]) * sy,
            r.x0 + (merc[2] - self.merc[0]) * sx, r.y0 + (self.merc[3] - merc[1]) * sy,
        )

    def render(self, z: int, x: int, y: int, quality: int = 85) -> bytes | None:
        """JPEG bytes for tile (z, x, y), or None when the tile doesn't touch the page."""
        clip = self.page_rect(_tile_bounds(z, x, y))
        visible = clip & self.page.rect
        if visible.is_empty:
            return None
        sx, sy = TILE_SIZE / clip.width, TILE_SIZE / clip.height
        matrix = pymupdf.Matrix(sx, sy)
        canvas = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, TILE_SIZE, TILE_SIZE), False)
        canvas.set_rect(canvas.irect, self.background)
        src = self.display_list.get_pixmap(matrix=matrix, clip=visible, alpha=False)
        # place the rendered part where it belongs inside the tile (edge tiles are partial)
        src.set_origin(round((visible.x0 - clip.x0) * sx), round((visible.y0 - clip.y0) * sy))
        canvas.copy(src, src.irect)
        return canvas.tobytes("jpg", jpg_quality=quality)


def write_mbtiles(pdf: str, out: str, min_zoom: int = 9, max_zoom: int = 14, quality: int = 85,
                  name: str | None = None, page_number: int = 0, progress=None) -> dict:
    """Render zooms min_zoom..max_zoom into an MBTiles 1.3 file. Returns a small summary."""
    m = GeoPdfMap.open(pdf, page_number)
    renderer = TileRenderer(m)
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
    lon0, lat0, lon1, lat1 = renderer.bounds_lonlat()
    title = name or m.doc.metadata.get("title") or Path(pdf).stem
    metadata = {
        "name": title,
        "format": "jpg",
        "type": "baselayer",
        "version": "1",
        "description": f"Rendered from {Path(pdf).name} by geopdf_locator",
        "attribution": "National Park Service",
        "bounds": f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}",
        "center": f"{(lon0 + lon1) / 2:.6f},{(lat0 + lat1) / 2:.6f},{min(max_zoom, max(min_zoom, 12))}",
        "minzoom": str(min_zoom),
        "maxzoom": str(max_zoom),
    }
    db.executemany("INSERT INTO metadata VALUES (?, ?)", metadata.items())

    counts, started = {}, time.time()
    for z in range(min_zoom, max_zoom + 1):
        xs, ys = _tile_range(z, renderer.merc)
        n = 0
        for x in xs:
            for y in ys:
                data = renderer.render(z, x, y, quality)
                if data is None:
                    continue
                tms_row = (1 << z) - 1 - y  # MBTiles stores rows bottom-up (TMS)
                db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, x, tms_row, data))
                n += 1
        counts[z] = n
        db.commit()
        if progress:
            progress(z, n)
    db.close()
    return {"path": str(path), "tiles": counts, "bytes": path.stat().st_size,
            "seconds": round(time.time() - started, 1), "bounds": (lon0, lat0, lon1, lat1)}


def main(argv=None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Render a GeoPDF into an MBTiles raster tileset.")
    parser.add_argument("pdf")
    parser.add_argument("out")
    parser.add_argument("--min-zoom", type=int, default=9)
    parser.add_argument("--max-zoom", type=int, default=14)
    parser.add_argument("--quality", type=int, default=85, help="JPEG quality (default 85)")
    args = parser.parse_args(argv)
    summary = write_mbtiles(args.pdf, args.out, args.min_zoom, args.max_zoom, args.quality,
                            progress=lambda z, n: print(f"zoom {z}: {n} tiles"))
    print(f"wrote {summary['path']} ({summary['bytes'] / 1e6:.1f} MB, "
          f"{sum(summary['tiles'].values())} tiles, {summary['seconds']} s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
