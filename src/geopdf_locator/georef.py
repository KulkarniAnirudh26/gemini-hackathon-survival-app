"""Page <-> lat/lon transforms from a PDF's ISO 32000 geospatial viewport (/VP /Measure)."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass

import numpy as np
import pymupdf

EARTH_RADIUS = 6378137.0


def _web_mercator(lat: float, lon: float) -> tuple[float, float]:
    return (
        EARTH_RADIUS * math.radians(lon),
        EARTH_RADIUS * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)),
    )


def _web_mercator_inv(x: float, y: float) -> tuple[float, float]:
    return math.degrees(2 * math.atan(math.exp(y / EARTH_RADIUS)) - math.pi / 2), math.degrees(x / EARTH_RADIUS)


def _geographic(lat: float, lon: float) -> tuple[float, float]:
    return lon, lat


def _geographic_inv(x: float, y: float) -> tuple[float, float]:
    return y, x


def _projection_for(gcs: str):
    """Pick forward/inverse projection functions from the /GCS dictionary text."""
    if "/EPSG 3857" in gcs or re.search(r"Pseudo-Mercator|Mercator_Auxiliary_Sphere|Popular Visualisation", gcs):
        return _web_mercator, _web_mercator_inv
    if "/GEOGCS" in gcs or "/EPSG 4326" in gcs:
        return _geographic, _geographic_inv
    raise NotImplementedError(f"Unsupported GeoPDF coordinate system: {gcs[:200]}")


def _numbers(text: str) -> list[float]:
    return [float(v) for v in re.findall(r"-?\d*\.?\d+(?:[eE]-?\d+)?", text)]


@dataclass
class Viewport:
    bbox: tuple[float, float, float, float]  # PDF user space (origin bottom-left)
    affine: np.ndarray  # 3x2: [u, v, 1] -> projected (x, y)
    inverse: np.ndarray  # 3x2: [x, y, 1] -> (u, v)
    forward: object
    backward: object

    def contains(self, px: float, py: float) -> bool:
        x0, y0, x1, y1 = self.bbox
        return x0 <= px <= x1 and y0 <= py <= y1


class Georeference:
    """Converts between PyMuPDF page coordinates (top-left origin, points) and WGS84 lat/lon."""

    def __init__(self, doc: pymupdf.Document, page: pymupdf.Page):
        self.page = page
        # PyMuPDF coords <-> PDF user space (handles MediaBox offsets and page rotation)
        self._to_pdf = ~page.transformation_matrix
        self._from_pdf = page.transformation_matrix
        self.viewports = [self._parse_viewport(doc, vp) for vp in self._viewport_dicts(doc, page)]
        if not self.viewports:
            raise ValueError("Page has no geospatial viewport (/VP with /Measure /GEO); not a GeoPDF")

    @staticmethod
    def _viewport_dicts(doc, page) -> list[str]:
        kind, value = doc.xref_get_key(page.xref, "VP")
        if kind == "xref":
            value = doc.xref_object(int(value.split()[0]))
        elif kind == "null":
            return []
        # Split the array into individual << ... >> dictionaries
        dicts, depth, start = [], 0, None
        for m in re.finditer(r"<<|>>", value):
            if m.group() == "<<":
                if depth == 0:
                    start = m.start()
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    dicts.append(value[start : m.end()])
        return [d for d in dicts if "/Measure" in d]

    @staticmethod
    def _resolve(doc, text: str, key: str) -> str:
        """Return the value of /key in a dict string, following an indirect reference."""
        m = re.search(rf"/{key}\s+(\d+)\s+0\s+R", text)
        if m:
            return doc.xref_object(int(m.group(1)))
        m = re.search(rf"/{key}\s*(<<.*>>)", text, re.S)
        if m:
            return m.group(1)
        raise ValueError(f"/{key} missing in viewport")

    def _parse_viewport(self, doc, vp: str) -> Viewport:
        bbox = tuple(_numbers(re.search(r"/BBox\s*\[([^\]]+)\]", vp).group(1)))
        measure = self._resolve(doc, vp, "Measure")
        if "/GEO" not in measure:
            raise ValueError("Viewport measure is not geospatial")
        gcs = self._resolve(doc, measure, "GCS")
        forward, backward = _projection_for(gcs)

        gpts = _numbers(re.search(r"/GPTS\s*\[([^\]]+)\]", measure).group(1))
        m = re.search(r"/LPTS\s*\[([^\]]+)\]", measure)
        # LPTS defaults to the unit square corners matching /Bounds when absent
        lpts = _numbers(m.group(1)) if m else _numbers(re.search(r"/Bounds\s*\[([^\]]+)\]", measure).group(1))

        uv = np.array([[lpts[i], lpts[i + 1], 1.0] for i in range(0, len(lpts), 2)])
        xy = np.array([forward(gpts[i], gpts[i + 1]) for i in range(0, len(gpts), 2)])
        affine, *_ = np.linalg.lstsq(uv, xy, rcond=None)
        inverse, *_ = np.linalg.lstsq(np.c_[xy, np.ones(len(xy))], uv[:, :2], rcond=None)
        return Viewport(bbox, affine, inverse, forward, backward)

    def _viewport_at(self, px: float, py: float) -> Viewport:
        for vp in self.viewports:
            if vp.contains(px, py):
                return vp
        return self.viewports[0]  # extrapolate from the primary viewport

    def to_latlon(self, x: float, y: float) -> tuple[float, float]:
        """PyMuPDF page point (top-left origin) -> (lat, lon)."""
        p = pymupdf.Point(x, y) * self._to_pdf
        vp = self._viewport_at(p.x, p.y)
        x0, y0, x1, y1 = vp.bbox
        u, v = (p.x - x0) / (x1 - x0), (p.y - y0) / (y1 - y0)
        mx, my = np.array([u, v, 1.0]) @ vp.affine
        return vp.backward(mx, my)

    def to_page(self, lat: float, lon: float) -> tuple[float, float]:
        """(lat, lon) -> PyMuPDF page point (top-left origin), e.g. to draw a GPS fix on the map."""
        for vp in self.viewports:
            mx, my = vp.forward(lat, lon)
            u, v = np.array([mx, my, 1.0]) @ vp.inverse
            x0, y0, x1, y1 = vp.bbox
            px, py = x0 + u * (x1 - x0), y0 + v * (y1 - y0)
            if vp.contains(px, py) or vp is self.viewports[-1]:
                p = pymupdf.Point(px, py) * self._from_pdf
                return p.x, p.y
        raise AssertionError("unreachable")
