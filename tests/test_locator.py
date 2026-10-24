import math

import pytest

from geopdf_locator import GeoPdfMap
from geopdf_locator.__main__ import main
from conftest import EAST, NORTH, SOUTH, WEST


def km(a, b):
    dy = (a[0] - b[0]) * 111.2
    dx = (a[1] - b[1]) * 111.2 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


# -- georeferencing ------------------------------------------------------------------------


def test_page_corners_map_to_control_points(synthetic_map):
    m = GeoPdfMap.open(str(synthetic_map))
    assert m.to_latlon(0, 600) == pytest.approx((SOUTH, WEST), abs=1e-9)  # bottom-left
    assert m.to_latlon(600, 0) == pytest.approx((NORTH, EAST), abs=1e-9)  # top-right


def test_to_page_inverts_to_latlon(synthetic_map):
    m = GeoPdfMap.open(str(synthetic_map))
    for x, y in [(10, 20), (300, 300), (590, 450)]:
        assert m.to_page(*m.to_latlon(x, y)) == pytest.approx((x, y), abs=1e-6)


def test_mercator_not_linear_in_latitude(synthetic_map):
    m = GeoPdfMap.open(str(synthetic_map))
    lat_mid, _ = m.to_latlon(300, 300)
    assert lat_mid != pytest.approx((SOUTH + NORTH) / 2, abs=1e-4)


def test_non_geopdf_rejected(tmp_path):
    import pymupdf

    doc = pymupdf.open()
    doc.new_page()
    doc.save(tmp_path / "plain.pdf")
    with pytest.raises(ValueError, match="not a GeoPDF"):
        GeoPdfMap.open(str(tmp_path / "plain.pdf"))


# -- ranking and snapping ------------------------------------------------------------------


def test_exact_label_ranks_above_longer_phrase(synthetic_map):
    hits = GeoPdfMap.open(str(synthetic_map), exclude=[]).locate("foo peak")
    assert [h.label for h in hits][:1] == ["Foo Peak"]
    assert hits[0].standalone and hits[0].snapped
    road = next(h for h in hits if h.label == "Foo Peak Road")
    assert not road.standalone and road.score < hits[0].score


def test_snaps_to_symbol_next_to_label(synthetic_map):
    m = GeoPdfMap.open(str(synthetic_map))
    best = m.locate("Foo Peak")[0]
    assert best.page_xy == pytest.approx((140, 97), abs=0.2)
    assert (best.lat, best.lon) == pytest.approx(m.to_latlon(140, 97))


def test_follows_leader_line_from_icon_to_dot(synthetic_map):
    best = GeoPdfMap.open(str(synthetic_map)).locate("Bar Camp")[0]
    assert best.via_leader
    assert best.page_xy == pytest.approx((181, 311), abs=0.2)


def test_elevation_note_does_not_steal_dot(synthetic_map):
    best = GeoPdfMap.open(str(synthetic_map)).locate("Baz Dome")[0]
    assert best.snapped
    assert best.page_xy == pytest.approx((436, 107), abs=0.2)


def test_town_dot_beats_amenity_icon(synthetic_map):
    best = GeoPdfMap.open(str(synthetic_map)).locate("Qux Town")[0]
    assert best.page_xy == pytest.approx((144, 444), abs=0.3)


def test_no_snap_uses_label_centre(synthetic_map):
    best = GeoPdfMap.open(str(synthetic_map)).locate("Foo Peak", snap=False)[0]
    assert not best.snapped
    assert 100 < best.page_xy[0] < 140


def test_excluded_region_is_ignored(synthetic_map):
    m = GeoPdfMap.open(str(synthetic_map), exclude=[(0, 560, 120, 600)])
    assert all(h.page_xy[1] < 560 for h in m.locate("Foo Peak"))
    assert len(m.locate("Foo Peak")) == 2


def test_missing_name_returns_nothing(synthetic_map):
    assert GeoPdfMap.open(str(synthetic_map)).locate("Nowhere Lake") == []


def test_cli_exit_code(synthetic_map, capsys):
    assert main([str(synthetic_map), "Foo Peak"]) == 0
    assert "Foo Peak" in capsys.readouterr().out
    assert main([str(synthetic_map), "Nowhere Lake"]) == 1


# -- real map: NPS Yosemite ----------------------------------------------------------------

PEAKS = {
    "Half Dome": (37.7459, -119.5332),
    "Mount Lyell": (37.7394, -119.2714),
    "Clouds Rest": (37.7676, -119.4895),
    "Matterhorn Peak": (38.0930, -119.3810),
    "Mount Hoffmann": (37.8463, -119.5110),
}


@pytest.mark.parametrize("name,truth", PEAKS.items())
def test_yosemite_peaks_within_200m(yosemite_map, name, truth):
    best = yosemite_map.locate(name)[0]
    assert best.label == name
    assert km((best.lat, best.lon), truth) < 0.2


def test_yosemite_road_labels_rank_below_place(yosemite_map):
    hits = yosemite_map.locate("Glacier Point")
    assert hits[0].label == "Glacier Point"
    assert {"Glacier Point Rd", "Glacier Point Road"} <= {h.label for h in hits[1:]}


def test_yosemite_leader_line(yosemite_map):
    best = yosemite_map.locate("Vogelsang")[0]
    assert best.via_leader
    assert km((best.lat, best.lon), (37.7964, -119.3437)) < 0.15


def test_yosemite_town_dot(yosemite_map):
    best = yosemite_map.locate("Lee Vining")[0]
    assert best.symbol.is_dot
    assert km((best.lat, best.lon), (37.9577, -119.1218)) < 0.5


def test_yosemite_area_label_not_snapped(yosemite_map):
    best = yosemite_map.locate("Tuolumne Meadows")[0]
    assert best.label == "TUOLUMNE MEADOWS" and not best.snapped


@pytest.mark.parametrize("name", [
    "Clouds Rest",        # two lines in two different PDF blocks
    "Smedberg Lake",      # second line is a generic word
    "Lembert Dome",       # stacked lines need a word break
    "TUOLUMNE MEADOWS",   # curved, letter-spaced caps split into pieces
    "Kendrick Creek",     # curved, written a few glyphs per block
    "Wawona Road",        # curved, running downhill
    "Badger Pass Ski Area",
])
def test_yosemite_label_text(yosemite_map, name):
    assert yosemite_map.locate(name)[0].label == name


def test_yosemite_stacked_separate_names_stay_apart(yosemite_map):
    assert yosemite_map.locate("Mount Maclure")[0].label == "Mount Maclure"
    assert yosemite_map.locate("Mount Lyell")[0].label == "Mount Lyell"


def test_yosemite_legend_excluded(yosemite_map):
    assert all(not (45 <= h.page_xy[0] <= 256 and 938 <= h.page_xy[1] <= 1216)
               for h in yosemite_map.locate("Campground"))
