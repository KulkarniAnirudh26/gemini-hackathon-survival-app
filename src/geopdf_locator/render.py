"""Draw a hit on the map: a close-up with the label and anchor marked, and a whole-map overview."""
from __future__ import annotations

from pathlib import Path

import pymupdf

from .locator import GeoPdfMap, Hit

RED = (0.85, 0.1, 0.1)
CLOSEUP_DPI = 300
OVERVIEW_DPI = 50
CAPTION_SIZE = 6


def _caption(hit: Hit) -> str:
    return f"{hit.label}: {hit.lat:.5f}, {hit.lon:.5f}"


def _caption_box(page: pymupdf.Page, hit: Hit) -> pymupdf.Rect:
    """Upper right of the marker, flipped to the left near the page edge."""
    x, y = hit.page_xy
    width = pymupdf.get_text_length(_caption(hit), fontsize=CAPTION_SIZE) + 6
    x0 = x + 8 if x + 8 + width <= page.rect.x1 else x - 8 - width
    return pymupdf.Rect(x0, y - 22, x0 + width, y - 12)


def _draw_marker(page: pymupdf.Page, hit: Hit) -> None:
    x, y = hit.page_xy
    page.draw_rect(pymupdf.Rect(hit.label_bbox) + (-1.5, -1.5, 1.5, 1.5), color=RED, width=0.6, dashes="[2 1] 0")
    page.draw_circle((x, y), 4, color=RED, width=1.0)
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):  # crosshair ticks outside the circle
        page.draw_line((x + 2 * dx, y + 2 * dy), (x + 7 * dx, y + 7 * dy), color=RED, width=0.8)

    box = _caption_box(page, hit)
    page.draw_rect(box, color=RED, fill=(1, 1, 1), width=0.6)
    page.insert_text((box.x0 + 3, box.y1 - 2.6), _caption(hit), fontsize=CAPTION_SIZE, color=RED)


def _closeup_clip(page: pymupdf.Page, hit: Hit) -> pymupdf.Rect:
    x, y = hit.page_xy
    clip = pymupdf.Rect(x - 100, y - 45, x + 100, y + 45) | pymupdf.Rect(hit.label_bbox)
    clip |= _caption_box(page, hit) + (-10, -5, 10, 5)
    return clip & page.rect


def render_hit(m: GeoPdfMap, hit: Hit, out: str | Path) -> tuple[Path, Path]:
    """Write `out` (close-up) and `<out stem>_overview.png`. Returns both paths.

    Draws on a scratch copy of the document, so `m` is left untouched.
    """
    out = Path(out)
    overview = out.with_name(f"{out.stem}_overview{out.suffix or '.png'}")
    out.parent.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open(m.doc.name) if m.doc.name else pymupdf.open("pdf", m.doc.tobytes())
    try:
        page = doc[m.page.number]
        _draw_marker(page, hit)
        page.get_pixmap(dpi=CLOSEUP_DPI, clip=_closeup_clip(page, hit)).save(out)
        page.draw_circle(hit.page_xy, 25, color=RED, width=3)
        page.get_pixmap(dpi=OVERVIEW_DPI).save(overview)
    finally:
        doc.close()
    return out, overview
