"""Export a GeoPDF as an offline "map pack" for the mobile app.

The app never parses the PDF (PyMuPDF is AGPL and heavy on a phone). Everything the app needs
is computed here at build time:

  mappack.json  georeference, every place label with its snapped location and guidance,
                guidance notes, and the road lines needed to check a GPS position
  map.jpg       the page rendered as an image, with `image.px_per_pt` to place markers on it
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import numpy as np

from .guidance import (CORRIDOR_KM, FEATURE_LABEL_DISTANCE, INFO, NEARBY_KM, WARNING, Advisory,
                       Guidance)
from .locator import GeoPdfMap, _inside, _is_area_label, _union, normalize

FORMAT_VERSION = 1
MAX_LABEL_WORDS = 8


def _affine(points_in: list[tuple[float, float]], points_out: list[tuple[float, float]]) -> list[list[float]]:
    """3x2 matrix M with [x, y, 1] @ M = out (exact for affine maps, least squares otherwise)."""
    a = np.c_[np.array(points_in), np.ones(len(points_in))]
    m, *_ = np.linalg.lstsq(a, np.array(points_out), rcond=None)
    return [[float(v) for v in row] for row in m]


def _georef(m: GeoPdfMap) -> dict:
    """Page point (top-left origin) <-> Web Mercator metres, as affine matrices per viewport."""
    from .georef import _web_mercator, _web_mercator_inv

    if m.georef.viewports[0].forward.__name__ != "_web_mercator":
        raise NotImplementedError("map pack export currently supports Web Mercator GeoPDFs")
    r = m.page.rect
    grid = [(r.x0 + r.width * fx, r.y0 + r.height * fy) for fx in (0.1, 0.5, 0.9) for fy in (0.1, 0.5, 0.9)]
    merc = [_web_mercator(*m.to_latlon(x, y)) for x, y in grid]
    page_to_merc = _affine(grid, merc)
    merc_to_page = _affine(merc, grid)
    # sanity: the round trip through the exported matrices matches the PDF transform
    for (x, y), (mx, my) in zip(grid, merc):
        px, py = np.array([mx, my, 1.0]) @ np.array(merc_to_page)
        assert abs(px - x) < 1e-3 and abs(py - y) < 1e-3, (px - x, py - y)  # 1e-3 pt ~ 7 cm
    _ = _web_mercator_inv  # the app implements the same spherical formulas
    return {"projection": "EPSG:3857", "earth_radius_m": 6378137.0,
            "page_to_mercator": page_to_merc, "mercator_to_page": merc_to_page}


def _labels(m: GeoPdfMap) -> list[dict]:
    """Every place label on the map, snapped to its symbol the same way `locate` does."""
    seen: set[int] = set()
    labels = []
    for i, c in enumerate(m.chars):
        if i in seen or not c.text or c.elevation or _inside(c.bbox, m.exclude):
            continue
        idx = m._grow_label([i])
        seen.update(idx)
        letters = [j for j in idx if m.chars[j].text]
        text = m._label_text(idx)
        norm = normalize(text)
        if len(norm) < 3 or not re.search(r"[a-z]", norm) or len(text.split()) > MAX_LABEL_WORDS:
            continue
        if WARNING.search(text) or INFO.search(text) or text[0].islower():
            continue  # guidance notes (and pieces of them, "east of this point") are exported separately
        bbox = _union(m.chars[j].bbox for j in letters)
        size = m.chars[letters[0]].size
        symbol, via_leader = m._snap(idx, bbox, size)
        x, y = symbol.center if symbol else ((bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2)
        lat, lon = m.to_latlon(x, y)
        labels.append({
            "text": text, "norm": norm, "lat": round(lat, 6), "lon": round(lon, 6),
            "x": round(x, 2), "y": round(y, 2), "bbox": [round(v, 2) for v in bbox],
            "size": round(size, 2), "snapped": symbol is not None, "via_leader": via_leader,
            "area": _is_area_label(m.chars[j].raw for j in idx),
        })
    return labels


def _advisory(a: Advisory, note_ids: dict[int, int]) -> dict:
    return {"note": note_ids[id(a.note)], "reason": a.reason,
            "distance_km": None if a.distance_km is None else round(a.distance_km, 3)}


def build_pack(m: GeoPdfMap, dpi: int = 150, image_name: str = "map.jpg") -> tuple[dict, bytes]:
    g = Guidance(m)
    note_ids = {id(n): i for i, n in enumerate(g.notes)}

    paths, path_ids = [], {}
    notes = []
    for n in g.notes:
        entry = {
            "text": n.text, "severity": n.severity, "scope": n.scope, "feature": n.feature,
            "direction": n.direction, "bbox": [round(v, 2) for v in n.bbox],
            "x": None if n.anchor_xy is None else round(n.anchor_xy[0], 2),
            "y": None if n.anchor_xy is None else round(n.anchor_xy[1], 2),
            "lat": None if n.lat is None else round(n.lat, 6),
            "lon": None if n.lon is None else round(n.lon, 6),
            "paths": [],
        }
        for p in (g._paths_for(n.feature) if n.feature else []):
            if id(p) not in path_ids:
                path_ids[id(p)] = len(paths)
                paths.append([[round(x, 2), round(y, 2)] for x, y in p.points])
            section = g._section(n, p) if n.direction else None
            entry["paths"].append({"path": path_ids[id(p)],
                                   "section": None if section is None else [round(s, 3) for s in section]})
        notes.append(entry)

    labels = _labels(m)
    for lb in labels:
        lb["guidance"] = [_advisory(a, note_ids) for a in g.for_point((lb["x"], lb["y"]), tuple(lb["bbox"]))
                          if a.reason != "park-wide"]

    pix = m.page.get_pixmap(dpi=dpi)
    image = pix.tobytes("jpg", jpg_quality=88)
    source = Path(m.doc.name) if m.doc.name else None
    pack = {
        "format": "geopdf-mappack",
        "version": FORMAT_VERSION,
        "source": {
            "title": m.doc.metadata.get("title") or "",
            "file": source.name if source else None,
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest() if source else None,
            "page": m.page.number,
        },
        "page": {"width": round(m.page.rect.width, 3), "height": round(m.page.rect.height, 3)},
        "image": {"file": image_name, "width": pix.width, "height": pix.height, "px_per_pt": dpi / 72},
        "georef": _georef(m),
        "guidance_params": {"km_per_pt": g.km_per_pt, "corridor_km": CORRIDOR_KM, "nearby_km": NEARBY_KM,
                            "feature_label_distance_pt": FEATURE_LABEL_DISTANCE},
        "labels": labels,
        "notes": notes,
        "paths": paths,
    }
    return pack, image


def export(pdf: str, out_dir: str, dpi: int = 150) -> tuple[Path, Path]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    pack, image = build_pack(GeoPdfMap.open(pdf), dpi=dpi)
    pack_path, image_path = out / "mappack.json", out / pack["image"]["file"]
    pack_path.write_text(json.dumps(pack, separators=(",", ":"), ensure_ascii=False))
    image_path.write_bytes(image)
    return pack_path, image_path


def main(argv=None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Export a GeoPDF as an offline map pack for the app.")
    parser.add_argument("pdf")
    parser.add_argument("out_dir")
    parser.add_argument("--dpi", type=int, default=150, help="map image resolution (default 150)")
    args = parser.parse_args(argv)
    for path in export(args.pdf, args.out_dir, args.dpi):
        print(f"wrote {path} ({path.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
