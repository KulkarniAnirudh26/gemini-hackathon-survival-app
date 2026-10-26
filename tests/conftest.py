import os
from pathlib import Path

import pymupdf
import pytest

WEB_MERCATOR_GCS = (
    '<< /Type /PROJCS /EPSG 3857 /WKT (PROJCS["WGS 84 / Pseudo-Mercator",'
    'PROJECTION["Mercator_Auxiliary_Sphere"],UNIT["Meter",1]]) >>'
)
# Synthetic map: a 600x600 pt page covering this lat/lon box
SOUTH, NORTH, WEST, EAST = 37.5, 38.0, -120.0, -119.5


def add_geo_viewport(doc: pymupdf.Document, page: pymupdf.Page) -> None:
    gcs = doc.get_new_xref()
    doc.update_object(gcs, WEB_MERCATOR_GCS)
    measure = doc.get_new_xref()
    # corners: lower-left, upper-left, upper-right, lower-right (LPTS unit square)
    doc.update_object(
        measure,
        f"<< /Type /Measure /Subtype /GEO /Bounds [0 0 0 1 1 1 1 0] /LPTS [0 0 0 1 1 1 1 0]"
        f" /GPTS [{SOUTH} {WEST} {NORTH} {WEST} {NORTH} {EAST} {SOUTH} {EAST}] /GCS {gcs} 0 R >>",
    )
    w, h = page.rect.width, page.rect.height
    doc.xref_set_key(page.xref, "VP", f"[<< /Type /Viewport /BBox [0 0 {w} {h}] /Measure {measure} 0 R >>]")


@pytest.fixture
def synthetic_map(tmp_path):
    """A small GeoPDF exercising ranking, symbol snapping, leader lines and elevation notes."""
    doc = pymupdf.open()
    page = doc.new_page(width=600, height=600)

    # A peak label with its dot just to the right
    page.insert_text((100, 100), "Foo Peak", fontsize=8)
    page.draw_circle((140, 97), 0.8, color=None, fill=(0, 0, 0))

    # The same words as part of a longer road label, far away
    page.insert_text((300, 500), "Foo Peak Road", fontsize=8)

    # A camp icon beside its label, with a leader line from the icon to the real spot
    page.insert_text((100, 300), "Bar Camp", fontsize=8)
    page.draw_rect(pymupdf.Rect(142, 290, 152, 300), color=None, fill=(0, 0, 0))
    page.draw_line((152, 295), (180, 310), color=(0, 0, 0), width=0.3)
    page.draw_circle((181, 311), 0.8, color=None, fill=(0, 0, 0))

    # A peak whose elevation note sits closer to the dot than the name does
    page.insert_text((400, 100), "Baz Dome", fontsize=8)
    page.insert_text((405, 109), "9000 ft", fontsize=6)
    page.draw_circle((436, 107), 0.8, color=None, fill=(0, 0, 0))

    # A town: amenity icon touching the label, town dot a little further off
    page.insert_text((100, 450), "Qux Town", fontsize=8)
    page.draw_rect(pymupdf.Rect(110, 452, 120, 462), color=None, fill=(0, 0, 0))
    page.draw_circle((144, 444), 1.8, color=(0, 0, 0), fill=(1, 0.87, 0), width=0.3)

    # Legend text that should be ignored when excluded
    page.insert_text((20, 580), "Foo Peak", fontsize=8)

    add_geo_viewport(doc, page)
    path = tmp_path / "synthetic.pdf"
    doc.save(path)
    return path


@pytest.fixture
def guidance_map(tmp_path):
    """A road with a seasonal closure between two gates, and places on and off it.

    Pine Road runs west-east along y=300. It is closed "east of" a gate at x=100 and "west of"
    a gate at x=450, so only the stretch between them is closed.
    """
    doc = pymupdf.open()
    page = doc.new_page(width=600, height=600)
    brown = (0.56, 0.33, 0.0)
    page.draw_polyline([(50, 300), (200, 300), (350, 300), (550, 300)], color=brown, width=1.4)
    page.insert_text((240, 296), "Pine Road", fontsize=7, color=brown)

    red = (0.8, 0.1, 0.1)
    page.insert_text((60, 251), "Pine Road closed in winter east of this point", fontsize=6, color=red)
    page.draw_line((80, 254), (100, 299), color=(0, 0, 0), width=0.3)
    page.insert_text((380, 351), "Pine Road closed in winter west of this point", fontsize=6, color=red)
    page.draw_line((420, 343), (450, 301), color=(0, 0, 0), width=0.3)
    page.insert_text((300, 151), "Facilities along Pine Road available summer only", fontsize=6, color=brown)

    page.insert_text((250, 320), "Alpha Camp", fontsize=7)  # on the road, inside the closed stretch
    page.insert_text((510, 320), "Beta Camp", fontsize=7)  # on the road, past the east gate
    page.insert_text((250, 500), "Gamma Camp", fontsize=7)  # far from the road
    page.insert_text((265, 512), "No swimming", fontsize=5, color=red)  # next to Gamma
    page.insert_text((250, 420), "Delta Hut", fontsize=7)
    page.insert_text((250, 427), "(summer only)", fontsize=5)

    page.insert_text((20, 580), "Natural areas present hazards. Be prepared for rapidly changing weather.",
                     fontsize=6, color=brown)

    add_geo_viewport(doc, page)
    path = tmp_path / "guidance.pdf"
    doc.save(path)
    return path


@pytest.fixture(scope="session")
def yosemite_map():
    """The NPS Yosemite park map. Download it to data/yosemite.pdf (see README) or point
    YOSEMITE_MAP_PDF at it; tests using it are skipped otherwise."""
    path = Path(os.environ.get("YOSEMITE_MAP_PDF", Path(__file__).parent.parent / "data" / "yosemite.pdf"))
    if not path.exists():
        pytest.skip(f"Yosemite map not found at {path}")
    from geopdf_locator import GeoPdfMap

    return GeoPdfMap.open(str(path))
