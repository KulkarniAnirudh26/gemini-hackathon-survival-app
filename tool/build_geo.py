"""Builds the offline geo assets for the Yosemite survival app (run once, with internet).

  python tool/build_geo.py            # writes assets/geo/*

Outputs (assets/geo/):
  pois.json       [{name, type, lat, lon, elev, node}]  type: trailhead|exit|water|help|shelter
  trails.json     {nodes: [[lat,lon,elev]], edges: [[a,b,len_m,up_m,down_m,way]], ways: [{name,kind,sac}],
                   geom: {edge_index: [lat,lon,lat,lon,...]}}
  dem.bin         int16 little-endian elevation (m), Web Mercator grid at zoom DEM_Z
  dem.json        {z, px0, py0, width, height}  global pixel origin of the grid
  hillshade.png   shaded relief of the same grid (downsampled), with its lat/lon bounds in dem.json

Sources: OpenStreetMap via the Overpass API (ODbL), AWS Terrain Tiles (Terrarium, public).
"""

import io
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image

SOUTH, WEST, NORTH, EAST = 37.49, -119.89, 38.19, -119.20
DEM_Z = 12
SIMPLIFY_M = 8.0
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "geo")
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "geo_cache")
OVERPASS = "https://overpass-api.de/api/interpreter"
UA = {"User-Agent": "yosemite-survival-hackathon/1.0"}

BBOX = f"{SOUTH},{WEST},{NORTH},{EAST}"

Q_WAYS = f"""[out:json][timeout:300];
(
  way["highway"~"^(path|footway|track|bridleway|steps)$"]({BBOX});
  way["highway"~"^(primary|secondary|tertiary|unclassified|residential|service)$"]({BBOX});
);
out body geom;"""

Q_POIS = f"""[out:json][timeout:300];
(
  nwr["highway"="trailhead"]({BBOX});
  nwr["amenity"="parking"]["name"]({BBOX});
  nwr["barrier"~"^(toll_booth|entrance)$"]({BBOX});
  nwr["natural"="spring"]({BBOX});
  nwr["amenity"="drinking_water"]({BBOX});
  nwr["natural"="water"]["name"]({BBOX});
  nwr["amenity"="ranger_station"]({BBOX});
  nwr["tourism"="information"]["information"="office"]({BBOX});
  nwr["amenity"~"^(clinic|hospital|doctors)$"]({BBOX});
  nwr["amenity"="shelter"]({BBOX});
  nwr["tourism"~"^(alpine_hut|wilderness_hut)$"]({BBOX});
);
out center tags;"""

Q_RIVERS = f"""[out:json][timeout:300];
way["waterway"~"^(river|stream)$"]["name"]({BBOX});
out geom tags;"""


def fetch(url, data=None, cache_name=None):
    if cache_name:
        os.makedirs(CACHE, exist_ok=True)
        path = os.path.join(CACHE, cache_name)
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
    body = urllib.parse.urlencode({"data": data}).encode() if data else None
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, data=body, headers=UA)
            with urllib.request.urlopen(req, timeout=360) as r:
                raw = r.read()
            break
        except Exception as e:  # noqa: BLE001
            print(f"  retry {attempt + 1}: {e}")
            time.sleep(5 * (attempt + 1))
    else:
        raise SystemExit(f"failed: {url}")
    if cache_name:
        with open(path, "wb") as f:
            f.write(raw)
    return raw


def overpass(query, name):
    print(f"overpass: {name}")
    return json.loads(fetch(OVERPASS, query, f"{name}.json"))["elements"]


# ---------------- DEM ----------------

def lonlat_to_px(lon, lat, z):
    n = 256 * 2**z
    x = (lon + 180.0) / 360.0 * n
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n
    return x, y


def px_to_lonlat(x, y, z):
    n = 256 * 2**z
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lon, lat


def build_dem():
    x0, y0 = lonlat_to_px(WEST, NORTH, DEM_Z)
    x1, y1 = lonlat_to_px(EAST, SOUTH, DEM_Z)
    tx0, ty0, tx1, ty1 = int(x0 // 256), int(y0 // 256), int(x1 // 256), int(y1 // 256)
    w, h = (tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256
    grid = np.zeros((h, w), dtype=np.float32)
    total = (tx1 - tx0 + 1) * (ty1 - ty0 + 1)
    done = 0
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            url = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{DEM_Z}/{tx}/{ty}.png"
            raw = fetch(url, cache_name=f"terrarium_{DEM_Z}_{tx}_{ty}.png")
            a = np.asarray(Image.open(io.BytesIO(raw)).convert("RGB"), dtype=np.float32)
            elev = a[:, :, 0] * 256 + a[:, :, 1] + a[:, :, 2] / 256 - 32768
            grid[(ty - ty0) * 256:(ty - ty0 + 1) * 256, (tx - tx0) * 256:(tx - tx0 + 1) * 256] = elev
            done += 1
            print(f"\r  dem tiles {done}/{total}", end="")
    print()
    # crop to bbox
    cx0, cy0 = int(x0) - tx0 * 256, int(y0) - ty0 * 256
    cx1, cy1 = int(math.ceil(x1)) - tx0 * 256, int(math.ceil(y1)) - ty0 * 256
    grid = grid[cy0:cy1, cx0:cx1]
    px0, py0 = int(x0), int(y0)
    return grid, px0, py0


def hillshade(grid, px0, py0):
    # cell size in metres at this latitude and zoom
    lat = (NORTH + SOUTH) / 2
    cell = 156543.03392 * math.cos(math.radians(lat)) / 2**DEM_Z
    gy, gx = np.gradient(grid, cell)
    slope = np.arctan(np.hypot(gx, gy) * 1.5)
    aspect = np.arctan2(-gx, gy)
    az, alt = math.radians(315), math.radians(45)
    shade = np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(az - aspect)
    shade = np.clip(shade, 0, 1)
    # dark theme: low-key relief, elevation tint
    e = (grid - grid.min()) / max(1.0, grid.max() - grid.min())
    v = (shade * 150 + 20).astype(np.uint8)
    rgb = np.stack([v * (0.75 + 0.25 * e), v * (0.85 + 0.1 * e), v * (0.8 + 0.2 * (1 - e))], axis=-1)
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    scale = min(1.0, 2048 / max(img.size))
    if scale < 1:
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
    img.save(os.path.join(OUT, "hillshade.png"), optimize=True)
    h, w = grid.shape
    west, north = px_to_lonlat(px0, py0, DEM_Z)
    east, south = px_to_lonlat(px0 + w, py0 + h, DEM_Z)
    return {"north": north, "south": south, "west": west, "east": east}


class Dem:
    def __init__(self, grid, px0, py0):
        self.g, self.px0, self.py0 = grid, px0, py0

    def at(self, lat, lon):
        x, y = lonlat_to_px(lon, lat, DEM_Z)
        x, y = x - self.px0, y - self.py0
        h, w = self.g.shape
        x = min(max(x, 0), w - 1.001)
        y = min(max(y, 0), h - 1.001)
        ix, iy = int(x), int(y)
        fx, fy = x - ix, y - iy
        g = self.g
        return float(
            g[iy, ix] * (1 - fx) * (1 - fy) + g[iy, ix + 1] * fx * (1 - fy)
            + g[iy + 1, ix] * (1 - fx) * fy + g[iy + 1, ix + 1] * fx * fy
        )


# ---------------- trails graph ----------------

def hav(a, b):
    r = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    d = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(d))


def dp(points, eps):
    """Douglas-Peucker on [lat, lon] with a local metric projection."""
    if len(points) < 3:
        return points
    lat0 = math.radians(points[0][0])
    k = 111320.0
    xy = [((p[1]) * k * math.cos(lat0), p[0] * k) for p in points]

    def rec(i, j, keep):
        ax, ay = xy[i]
        bx, by = xy[j]
        dx, dy = bx - ax, by - ay
        L = math.hypot(dx, dy) or 1e-9
        best, idx = 0.0, -1
        for m in range(i + 1, j):
            px, py = xy[m]
            d = abs(dy * (px - ax) - dx * (py - ay)) / L
            if d > best:
                best, idx = d, m
        if best > eps:
            rec(i, idx, keep)
            keep.add(idx)
            rec(idx, j, keep)

    keep = {0, len(points) - 1}
    rec(0, len(points) - 1, keep)
    return [points[i] for i in sorted(keep)]


def build_graph(ways_el, dem):
    trail_kinds = {"path", "footway", "track", "bridleway", "steps"}
    use = {}
    ways = []
    for el in ways_el:
        if el.get("type") != "way" or "geometry" not in el:
            continue
        tags = el.get("tags", {})
        if tags.get("access") in ("private", "no"):
            continue
        hw = tags.get("highway", "")
        kind = "trail" if hw in trail_kinds else "road"
        coords = [(g["lat"], g["lon"]) for g in el["geometry"]]
        ways.append((el["nodes"], coords, {"name": tags.get("name", ""), "kind": kind, "sac": tags.get("sac_scale", "")}))
        for nid in el["nodes"]:
            use[nid] = use.get(nid, 0) + 1

    node_index, nodes, edges, geom, way_meta = {}, [], [], {}, []

    def nid_of(osm_id, c):
        if osm_id not in node_index:
            node_index[osm_id] = len(nodes)
            nodes.append([round(c[0], 6), round(c[1], 6), round(dem.at(*c), 1)])
        return node_index[osm_id]

    for ids, coords, meta in ways:
        wi = len(way_meta)
        way_meta.append(meta)
        start = 0
        for k in range(1, len(ids)):
            if k == len(ids) - 1 or use[ids[k]] > 1:
                seg = coords[start:k + 1]
                length = sum(hav(seg[i], seg[i + 1]) for i in range(len(seg) - 1))
                if length < 0.5:
                    start = k
                    continue
                # ascent / descent on a 30 m resampling
                up = down = 0.0
                prev = dem.at(*seg[0])
                for i in range(len(seg) - 1):
                    d = hav(seg[i], seg[i + 1])
                    steps = max(1, int(d // 30))
                    for s in range(1, steps + 1):
                        t = s / steps
                        e = dem.at(seg[i][0] + (seg[i + 1][0] - seg[i][0]) * t, seg[i][1] + (seg[i + 1][1] - seg[i][1]) * t)
                        if e > prev:
                            up += e - prev
                        else:
                            down += prev - e
                        prev = e
                a, b = nid_of(ids[start], coords[start]), nid_of(ids[k], coords[k])
                ei = len(edges)
                edges.append([a, b, round(length, 1), round(up, 1), round(down, 1), wi])
                simp = dp(seg, SIMPLIFY_M)
                if len(simp) > 2:
                    geom[str(ei)] = [round(v, 5) for p in simp[1:-1] for v in p]
                start = k
    return {"nodes": nodes, "edges": edges, "ways": way_meta, "geom": geom}


# ---------------- POIs ----------------

def poi_type(tags):
    if tags.get("highway") == "trailhead":
        return "trailhead"
    if tags.get("amenity") == "parking" or tags.get("barrier") in ("toll_booth", "entrance"):
        return "exit"
    if tags.get("natural") in ("spring", "water") or tags.get("amenity") == "drinking_water":
        return "water"
    if tags.get("amenity") in ("ranger_station", "clinic", "hospital", "doctors") or tags.get("tourism") == "information":
        return "help"
    if tags.get("amenity") == "shelter" or tags.get("tourism") in ("alpine_hut", "wilderness_hut"):
        return "shelter"
    return None


def default_name(t, tags):
    return {
        "trailhead": "Trailhead",
        "exit": "Road access",
        "water": "Spring" if tags.get("natural") == "spring" else "Drinking water",
        "help": "Ranger station",
        "shelter": "Shelter",
    }[t]


def build_pois(poi_el, river_el, dem, graph):
    out = []
    for el in poi_el:
        tags = el.get("tags", {})
        t = poi_type(tags)
        if not t:
            continue
        lat = el.get("lat") or el.get("center", {}).get("lat")
        lon = el.get("lon") or el.get("center", {}).get("lon")
        if lat is None:
            continue
        name = tags.get("name") or default_name(t, tags)
        if t == "exit" and tags.get("barrier") in ("toll_booth", "entrance"):
            name = tags.get("name") or "Park entrance station"
        out.append({"name": name, "type": t, "lat": round(lat, 6), "lon": round(lon, 6)})
    # rivers and streams: one sample point every ~400 m
    for el in river_el:
        name = el.get("tags", {}).get("name")
        g = el.get("geometry") or []
        acc = 400.0
        for i in range(1, len(g)):
            a, b = (g[i - 1]["lat"], g[i - 1]["lon"]), (g[i]["lat"], g[i]["lon"])
            acc += hav(a, b)
            if acc >= 400:
                out.append({"name": name, "type": "water", "lat": round(b[0], 6), "lon": round(b[1], 6)})
                acc = 0.0
    # de-duplicate same name+type within 150 m
    dedup = []
    for p in out:
        if any(q["type"] == p["type"] and q["name"] == p["name"] and hav((q["lat"], q["lon"]), (p["lat"], p["lon"])) < 150 for q in dedup[-200:]):
            continue
        dedup.append(p)
    # elevation + nearest graph node (grid index)
    cell = 0.01
    grid = {}
    for i, n in enumerate(graph["nodes"]):
        grid.setdefault((int(n[0] / cell), int(n[1] / cell)), []).append(i)
    for p in dedup:
        p["elev"] = round(dem.at(p["lat"], p["lon"]), 0)
        gx, gy = int(p["lat"] / cell), int(p["lon"] / cell)
        best, bi = 1e18, -1
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((gx + dx, gy + dy), []):
                    n = graph["nodes"][i]
                    d = hav((p["lat"], p["lon"]), (n[0], n[1]))
                    if d < best:
                        best, bi = d, i
        p["node"] = bi if best < 400 else -1
    return dedup


def main():
    os.makedirs(OUT, exist_ok=True)
    grid, px0, py0 = build_dem()
    dem = Dem(grid, px0, py0)
    bounds = hillshade(grid, px0, py0)
    grid.round().astype("<i2").tofile(os.path.join(OUT, "dem.bin"))
    h, w = grid.shape
    with open(os.path.join(OUT, "dem.json"), "w") as f:
        json.dump({"z": DEM_Z, "px0": px0, "py0": py0, "width": w, "height": h, "hillshade": bounds}, f)
    print(f"dem {w}x{h}, {grid.min():.0f}..{grid.max():.0f} m")

    graph = build_graph(overpass(Q_WAYS, "ways"), dem)
    with open(os.path.join(OUT, "trails.json"), "w") as f:
        json.dump(graph, f, separators=(",", ":"))
    print(f"graph: {len(graph['nodes'])} nodes, {len(graph['edges'])} edges, {len(graph['ways'])} ways")

    pois = build_pois(overpass(Q_POIS, "pois"), overpass(Q_RIVERS, "rivers"), dem, graph)
    with open(os.path.join(OUT, "pois.json"), "w") as f:
        json.dump(pois, f, separators=(",", ":"))
    counts = {}
    for p in pois:
        counts[p["type"]] = counts.get(p["type"], 0) + 1
    print(f"pois: {counts}")
    print("spot check: Half Dome", round(dem.at(37.7459, -119.5332)), "m; Valley floor", round(dem.at(37.7456, -119.5936)), "m")


if __name__ == "__main__":
    sys.exit(main())
