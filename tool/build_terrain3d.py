"""Downloads the elevation tiles for the 3D map (run once, with internet).

  python tool/build_terrain3d.py            # writes android/app/src/main/assets/map3d/terrain/{z}/{x}/{y}.png

Source: the open "Terrain Tiles" on AWS (Terrarium encoding: elevation = R*256 + G + B/256 - 32768
metres), built from USGS 3DEP, SRTM and others (attribution:
https://github.com/tilezen/joerd/blob/master/docs/attribution.md). Same tiles as tool/build_geo.py
and PR #5's geopdf_locator/terrain.py. MapLibre renders them as a `raster-dem` source with
`"encoding": "terrarium"`. Zooms 8-11 (~60 m per pixel) cover the park map in 56 tiles, ~6.5 MB.
"""
import math
import os
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
# the official park map's footprint (assets/park_map/mappack.json), as in PR #5's index.html
WEST, SOUTH, EAST, NORTH = -119.9206, 37.4655, -119.0368, 38.2043
ZOOMS = range(8, 12)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "android", "app", "src", "main", "assets",
                   "map3d", "terrain")


def tile(lon, lat, z):
    n = 1 << z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def fetch(zxy):
    z, x, y = zxy
    path = os.path.join(OUT, str(z), str(x), f"{y}.png")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return os.path.getsize(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    req = urllib.request.Request(URL.format(z=z, x=x, y=y), headers={"User-Agent": "sherpa-hackathon/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def main():
    jobs = []
    for z in ZOOMS:
        x0, y0 = tile(WEST, NORTH, z)
        x1, y1 = tile(EAST, SOUTH, z)
        jobs += [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    with ThreadPoolExecutor(8) as pool:
        total = sum(pool.map(fetch, jobs))
    print(f"{len(jobs)} terrain tiles, {total / 1e6:.1f} MB in {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
