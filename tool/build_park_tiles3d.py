"""Cuts the official park map image into map tiles for the 3D view (run once, no internet).

  python tool/build_park_tiles3d.py         # writes android/app/src/main/assets/map3d/park/{z}/{x}/{y}.jpg

MapLibre drapes raster *tiles* over terrain reliably (a single image source left most of the
ground blank on the Pixel), so the 3D view uses tiles like PR #5. PR #5 renders them from the
GeoPDF; here they come from the map pack's image and georeference (assets/park_map/), which is
the same map, so no PDF is needed. Zooms 9-12: z12 is about the image's own resolution.
"""
import json
import math
import os

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PACK = os.path.join(ROOT, "assets", "park_map")
OUT = os.path.join(ROOT, "android", "app", "src", "main", "assets", "map3d", "park")
ZOOMS = range(9, 13)
R = 6378137.0
WORLD = 2 * math.pi * R


def affine(m, x, y):
    return x * m[0][0] + y * m[1][0] + m[2][0], x * m[0][1] + y * m[1][1] + m[2][1]


def main():
    pack = json.load(open(os.path.join(PACK, "mappack.json"), encoding="utf-8"))
    img = Image.open(os.path.join(PACK, pack["image"]["file"])).convert("RGB")
    px_per_pt = pack["image"]["px_per_pt"]
    m2p = pack["georef"]["mercator_to_page"]
    p2m = pack["georef"]["page_to_mercator"]
    # the image's footprint in Web Mercator metres
    mx0, my0 = affine(p2m, 0, 0)
    mx1, my1 = affine(p2m, pack["page"]["width"], pack["page"]["height"])
    west, east, north, south = min(mx0, mx1), max(mx0, mx1), max(my0, my1), min(my0, my1)

    def mercator_to_px(mx, my):
        x, y = affine(m2p, mx, my)
        return x * px_per_pt, y * px_per_pt

    count = size = 0
    for z in ZOOMS:
        n = 1 << z
        tile_m = WORLD / n
        tx0, tx1 = int((west + WORLD / 2) // tile_m), int((east + WORLD / 2) // tile_m)
        ty0, ty1 = int((WORLD / 2 - north) // tile_m), int((WORLD / 2 - south) // tile_m)
        for tx in range(tx0, tx1 + 1):
            for ty in range(ty0, ty1 + 1):
                # tile corners in mercator, then in source pixels (no rotation: an axis-aligned box)
                tw = tx * tile_m - WORLD / 2
                tn = WORLD / 2 - ty * tile_m
                ax, ay = mercator_to_px(tw, tn)
                bx, by = mercator_to_px(tw + tile_m, tn - tile_m)
                if bx <= 0 or by <= 0 or ax >= img.width or ay >= img.height:
                    continue
                # crop with the transparent-free margin filled by the map's own edge colour
                tile = img.transform((256, 256), Image.Transform.EXTENT, (ax, ay, bx, by), Image.Resampling.BICUBIC,
                                     fillcolor=(223, 230, 234))
                path = os.path.join(OUT, str(z), str(tx), f"{ty}.jpg")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                tile.save(path, quality=82, optimize=True)
                count += 1
                size += os.path.getsize(path)
    lon0, lat0 = west / R * 180 / math.pi, math.degrees(2 * math.atan(math.exp(south / R)) - math.pi / 2)
    lon1, lat1 = east / R * 180 / math.pi, math.degrees(2 * math.atan(math.exp(north / R)) - math.pi / 2)
    print(f"{count} park map tiles, {size / 1e6:.1f} MB; bounds {lon0:.4f},{lat0:.4f},{lon1:.4f},{lat1:.4f}")


if __name__ == "__main__":
    main()
