import math
import sqlite3

import pymupdf
import pytest

from geopdf_locator import GeoPdfMap
from geopdf_locator.tiles import main, write_mbtiles


def tile_pixel(lat, lon, z):
    """Slippy-map (XYZ) tile and pixel within it for a WGS84 point."""
    n = 1 << z
    x = (lon + 180) / 360 * n
    y = (1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n
    return int(x), int(y), int((x % 1) * 256), int((y % 1) * 256)


def read_tile(db, z, x, y):
    row = db.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                     (z, x, (1 << z) - 1 - y)).fetchone()  # stored bottom-up (TMS)
    return pymupdf.Pixmap(row[0]) if row else None


@pytest.fixture
def tileset(synthetic_map, tmp_path):
    out = tmp_path / "map.mbtiles"
    summary = write_mbtiles(str(synthetic_map), str(out), min_zoom=9, max_zoom=12)
    return out, summary


def test_metadata_follows_mbtiles_spec(tileset):
    out, _ = tileset
    meta = dict(sqlite3.connect(out).execute("SELECT name, value FROM metadata"))
    assert meta["format"] == "jpg" and meta["type"] == "baselayer"
    assert (meta["minzoom"], meta["maxzoom"]) == ("9", "12")
    west, south, east, north = map(float, meta["bounds"].split(","))
    assert (west, south, east, north) == pytest.approx((-120.0, 37.5, -119.5, 38.0), abs=1e-4)


def test_tile_counts_grow_with_zoom(tileset):
    _, summary = tileset
    counts = summary["tiles"]
    assert all(counts[z] < counts[z + 1] for z in range(9, 12))


def test_symbol_drawn_where_its_coordinates_say(tileset, synthetic_map):
    """The Foo Peak dot (page 140, 97) must appear at its own lat/lon in the tiles."""
    out, _ = tileset
    m = GeoPdfMap.open(str(synthetic_map))
    lat, lon = m.to_latlon(140, 97)
    tx, ty, px, py = tile_pixel(lat, lon, 12)
    pix = read_tile(sqlite3.connect(out), 12, tx, ty)
    darkest = min(sum(pix.pixel(px + dx, py + dy)[:3]) for dx in (-1, 0, 1) for dy in (-1, 0, 1))
    assert darkest < 150
    # and blank paper a little way off
    lat2, lon2 = m.to_latlon(170, 60)
    tx, ty, px, py = tile_pixel(lat2, lon2, 12)
    assert sum(read_tile(sqlite3.connect(out), 12, tx, ty).pixel(px, py)[:3]) > 700


def test_tiles_outside_the_page_are_not_stored(tileset):
    out, _ = tileset
    tx, ty, _, _ = tile_pixel(37.75, -121.0, 12)  # well west of the map
    assert read_tile(sqlite3.connect(out), 12, tx, ty) is None


def test_cli(synthetic_map, tmp_path, capsys):
    assert main([str(synthetic_map), str(tmp_path / "t.mbtiles"), "--min-zoom", "9", "--max-zoom", "10"]) == 0
    assert "tiles" in capsys.readouterr().out


def test_yosemite_peak_dots_on_tiles(yosemite_map, tmp_path):
    out = tmp_path / "yose.mbtiles"
    write_mbtiles(yosemite_map.doc.name, str(out), min_zoom=13, max_zoom=13)
    db = sqlite3.connect(out)
    for name in ("Half Dome", "Mount Lyell", "Clouds Rest"):
        hit = yosemite_map.locate(name)[0]
        tx, ty, px, py = tile_pixel(hit.lat, hit.lon, 13)
        pix = read_tile(db, 13, tx, ty)
        darkest = min(sum(pix.pixel(min(255, px + dx), min(255, py + dy))[:3])
                      for dx in (-1, 0, 1) for dy in (-1, 0, 1))
        assert darkest < 150, name
