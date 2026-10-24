"""Converts NPS Park Tiles (PMTiles extracts) for Yosemite into compact JSON the app draws offline.

  # once, with internet: cut Yosemite out of the four national archives (~22 MB)
  for l in data label-point hydro boundary; do
    pmtiles extract https://www.nps.gov/maps/pmtiles/park-tiles-4-$l.pmtiles build/nps/$l.pmtiles \
      --bbox=-119.89,37.49,-119.19,38.19 --maxzoom=15
  done
  python tool/build_nps.py      # needs: pip install pmtiles mapbox-vector-tile shapely

Outputs (assets/nps/):
  lines.json     {layer: [[lat,lon,lat,lon,...], ...]}   trails, roads, rivers/streams, carto lines
  polygons.json  {layer: [[ring], ...]}                    lakes, park/wilderness, buildings, parking
  points.json    [{n, t, lat, lon, d?}]                     NPS points of interest and place labels
Also merges NPS trailheads / entrances / ranger stations / water into assets/geo/pois.json for routing.

Source: National Park Service Park Tiles 4 (https://www.nps.gov/maps/web/blog/tilejson/index.html),
hydrography from USGS NHD.
"""

import gzip
import json
import math
import os

import mapbox_vector_tile
from pmtiles.reader import MmapSource, Reader
from shapely.geometry import box, shape
from shapely.geometry.base import BaseGeometry

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "build", "nps")
OUT = os.path.join(ROOT, "assets", "nps")
SOUTH, WEST, NORTH, EAST = 37.49, -119.89, 38.19, -119.20

# (archive, layer, zoom, output key)
LINES = [
    ("data", "nps_trail", 14, "trail"),
    ("data", "nps_national_trail", 14, "trail"),
    ("data", "nps_road", 13, "road"),
    ("hydro", "nps_hydrography_flowline", 13, "stream"),
]
POLYGONS = [
    ("boundary", "nps_bound_poly", 11, "park"),
    ("boundary", "nps_wilderness_poly", 11, "wilderness"),
    ("hydro", "nps_hydrography_area", 13, "water"),
    ("data", "nps_parking_lot", 14, "parking"),
    ("data", "nps_building", 14, "building"),
]
TOLERANCE = {11: 6.0, 13: 3.0, 14: 2.0}  # simplification in tile units (extent 4096)


def tile_range(z):
    def t(lon, lat):
        n = 2**z
        x = int((lon + 180) / 360 * n)
        y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
        return x, y
    x0, y0 = t(WEST, NORTH)
    x1, y1 = t(EAST, SOUTH)
    return range(x0, x1 + 1), range(y0, y1 + 1)


def tile_to_lonlat(z, tx, ty, extent):
    n = 2**z

    def f(px, py):
        x = (tx + px / extent) / n
        y = (ty + py / extent) / n
        lon = x * 360 - 180
        lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y))))
        return round(lat, 5), round(lon, 5)
    return f


_readers = {}


def tiles(archive, z):
    if archive not in _readers:
        _readers[archive] = Reader(MmapSource(open(os.path.join(SRC, f"{archive}.pmtiles"), "rb")))
    r = _readers[archive]
    xs, ys = tile_range(z)
    for tx in xs:
        for ty in ys:
            data = r.get(z, tx, ty)
            if not data:
                continue
            if data[:2] == b"\x1f\x8b":
                data = gzip.decompress(data)
            yield tx, ty, mapbox_vector_tile.decode(data, default_options={"y_coord_down": True})


def flat(coords, conv):
    out = []
    for px, py in coords:
        lat, lon = conv(px, py)
        out += [lat, lon]
    return out


def collect(specs, kind):
    result = {}
    for archive, layer, z, key in specs:
        n = 0
        for tx, ty, t in tiles(archive, z):
            lay = t.get(layer)
            if not lay:
                continue
            extent = lay.get("extent", 4096)
            clip = box(0, 0, extent, extent)
            conv = tile_to_lonlat(z, tx, ty, extent)
            for f in lay["features"]:
                try:
                    g: BaseGeometry = shape(f["geometry"]).intersection(clip)
                except Exception:  # noqa: BLE001 (invalid source geometry)
                    continue
                if g.is_empty:
                    continue
                g = g.simplify(TOLERANCE[z], preserve_topology=kind == "poly")
                parts = getattr(g, "geoms", [g])
                for p in parts:
                    if kind == "line" and p.geom_type == "LineString" and len(p.coords) >= 2:
                        result.setdefault(key, []).append(flat(p.coords, conv))
                        n += 1
                    elif kind == "poly" and p.geom_type == "Polygon" and p.area > 4:
                        result.setdefault(key, []).append(flat(p.exterior.coords, conv))
                        n += 1
        print(f"  {kind} {key:10s} <- {layer} z{z}: {n}")
    # nps_national_trail repeats segments of nps_trail; drop exact duplicates
    for key, items in result.items():
        seen, unique = set(), []
        for it in items:
            k = tuple(it)
            if k not in seen:
                seen.add(k)
                unique.append(it)
        result[key] = unique
    return result


# ---------------- points ----------------

KEEP_POINT_TYPES = {
    "trailhead", "ranger station", "visitor center", "information", "first aid station", "drinking water",
    "spring", "campground", "entrance station", "parking lot", "waterfall", "viewpoint", "lodging", "store",
    "food service", "hut", "historic cabin", "picnic area", "bridge", "gas station", "restroom", "bus stop / shuttle stop",
    "emergency telephone", "telephone", "shelter", "backcountry campsite", "point of interest", "dam", "tunnel",
    "cliff", "woods", "historic site", "historic building", "stable", "amphitheater", "showers", "post office",
}
LABEL_TYPES = {
    "peak", "small lake", "lake", "reservoir", "falls", "flat", "gap", "pillar", "valley", "ridge", "cliff", "dome",
    "basin", "woods", "bench", "slope", "meadow", "canyon", "summit", "pass",
}


def collect_points():
    points, seen = [], set()
    descr = {}
    for tx, ty, t in tiles("label-point", 15):
        for f in t.get("nps_structured_data", {}).get("features", []):
            p = f["properties"]
            if p.get("name") and p.get("description"):
                descr[p["name"].strip().lower()] = p["description"]
    for z in (15, 13, 11):
        for tx, ty, t in tiles("label-point", z):
            lay = t.get("nps_point")
            if lay:
                for f in lay["features"]:
                    p = f["properties"]
                    typ, name = (p.get("type") or "").lower(), (p.get("name") or "").strip()
                    lat, lon = p.get("latitude"), p.get("longitude")
                    if typ not in KEEP_POINT_TYPES or lat is None:
                        continue
                    k = (name.lower(), typ, round(lat, 3), round(lon, 3))
                    if k in seen:
                        continue
                    seen.add(k)
                    item = {"n": name or typ.title(), "t": typ, "lat": round(lat, 6), "lon": round(lon, 6)}
                    d = descr.get(name.lower())
                    if d:
                        item["d"] = d[:400]
                    points.append(item)
            lab = t.get("nps_carto_label_other")
            if lab:
                extent = lab.get("extent", 4096)
                conv = tile_to_lonlat(z, tx, ty, extent)
                for f in lab["features"]:
                    p = f["properties"]
                    typ, name = (p.get("type") or "").lower(), (p.get("name") or "").strip()
                    if typ not in LABEL_TYPES or not name or f["geometry"]["type"] != "Point":
                        continue
                    lat, lon = conv(*f["geometry"]["coordinates"])
                    k = (name.lower(), "label", round(lat, 2), round(lon, 2))
                    if k in seen:
                        continue
                    seen.add(k)
                    points.append({"n": name, "t": "label:" + typ, "lat": lat, "lon": lon})
    return [p for p in points if SOUTH <= p["lat"] <= NORTH and WEST <= p["lon"] <= EAST]


# ---------------- merge into routing POIs ----------------

ROUTE_TYPES = {
    "trailhead": "trailhead",
    "entrance station": "exit",
    "parking lot": "exit",
    "ranger station": "help",
    "visitor center": "help",
    "information": "help",
    "first aid station": "help",
    "drinking water": "water",
    "spring": "water",
    "hut": "shelter",
    "historic cabin": "shelter",
}


def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    d = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(d))


def merge_pois(points):
    pois_path = os.path.join(ROOT, "assets", "geo", "pois.json")
    trails = json.load(open(os.path.join(ROOT, "assets", "geo", "trails.json")))
    nodes = trails["nodes"]
    cell = 0.01
    grid = {}
    for i, n in enumerate(nodes):
        grid.setdefault((int(n[0] / cell), int(n[1] / cell)), []).append(i)
    pois = [p for p in json.load(open(pois_path)) if p.get("src") != "nps"]
    added = 0
    for p in points:
        t = ROUTE_TYPES.get(p["t"])
        if not t:
            continue
        # skip if an OSM POI of the same type is within 80 m
        if any(q["type"] == t and hav((q["lat"], q["lon"]), (p["lat"], p["lon"])) < 80 for q in pois if abs(q["lat"] - p["lat"]) < 0.002):
            continue
        gx, gy = int(p["lat"] / cell), int(p["lon"] / cell)
        best, bi = 1e18, -1
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((gx + dx, gy + dy), []):
                    d = hav((p["lat"], p["lon"]), (nodes[i][0], nodes[i][1]))
                    if d < best:
                        best, bi = d, i
        pois.append({
            "name": p["n"], "type": t, "lat": p["lat"], "lon": p["lon"],
            "elev": None, "node": bi if best < 400 else -1, "src": "nps",
        })
        added += 1
    json.dump(pois, open(pois_path, "w"), separators=(",", ":"))
    print(f"  merged {added} NPS POIs into pois.json ({len(pois)} total)")


def main():
    os.makedirs(OUT, exist_ok=True)
    lines = collect(LINES, "line")
    json.dump(lines, open(os.path.join(OUT, "lines.json"), "w"), separators=(",", ":"))
    polys = collect(POLYGONS, "poly")
    json.dump(polys, open(os.path.join(OUT, "polygons.json"), "w"), separators=(",", ":"))
    points = collect_points()
    json.dump(points, open(os.path.join(OUT, "points.json"), "w"), separators=(",", ":"))
    types = {}
    for p in points:
        types[p["t"]] = types.get(p["t"], 0) + 1
    print(f"  points: {len(points)}  {dict(sorted(types.items(), key=lambda kv: -kv[1])[:15])}")
    merge_pois(points)
    for f in ("lines.json", "polygons.json", "points.json"):
        print(f"  {f}: {os.path.getsize(os.path.join(OUT, f)) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
