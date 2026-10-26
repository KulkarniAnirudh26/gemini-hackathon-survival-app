import json

import pytest

from geopdf_locator import GeoPdfMap
from geopdf_locator.__main__ import main
from geopdf_locator.guidance import Guidance

LEGEND = [(0, 560, 600, 600)]


@pytest.fixture
def guide(guidance_map):
    return Guidance(GeoPdfMap.open(str(guidance_map), exclude=LEGEND))


def texts(advisories, include_park=False):
    return [a.note.text for a in advisories if include_park or a.reason != "park-wide"]


def at(guide, name):
    return guide.for_hit(guide.m.locate(name)[0])


def test_extracts_notes_with_severity_and_feature(guide):
    by_text = {n.text: n for n in guide.notes}
    closure = by_text["Pine Road closed in winter east of this point"]
    assert (closure.severity, closure.feature, closure.direction, closure.pointed) == ("warning", "Pine Road", "east", True)
    assert closure.anchor_xy == pytest.approx((100, 299), abs=0.5)
    assert by_text["Facilities along Pine Road available summer only"].severity == "info"
    assert "Pine Road" not in by_text  # a road label alone is not guidance


def test_closure_applies_only_between_gates(guide):
    alpha = texts(at(guide, "Alpha Camp"))
    assert "Pine Road closed in winter east of this point" in alpha
    assert "Pine Road closed in winter west of this point" in alpha
    beta = texts(at(guide, "Beta Camp"))
    assert not any("closed" in t for t in beta)


def test_road_notes_apply_along_the_road_only(guide):
    assert "Facilities along Pine Road available summer only" in texts(at(guide, "Alpha Camp"))
    assert "Facilities along Pine Road available summer only" in texts(at(guide, "Beta Camp"))
    assert not any("Pine Road" in t for t in texts(at(guide, "Gamma Camp")))


def test_nearby_note_without_road(guide):
    gamma = at(guide, "Gamma Camp")
    swim = next(a for a in gamma if a.note.text == "No swimming")
    assert swim.reason.startswith("nearby") and swim.note.severity == "warning"
    assert "No swimming" not in texts(at(guide, "Alpha Camp"))


def test_qualifier_attached_to_its_label(guide):
    delta = at(guide, "Delta Hut")
    assert delta[0].note.text == "Delta Hut (summer only)"
    assert delta[0].reason == "printed with this label"


def test_park_wide_notes_apply_everywhere(guide):
    park = [n for n in guide.notes if n.scope == "park"]
    assert [n.text for n in park] == ["Natural areas present hazards. Be prepared for rapidly changing weather."]
    for name in ("Alpha Camp", "Gamma Camp"):
        assert park[0].text in texts(at(guide, name), include_park=True)


def test_warnings_rank_before_info(guide):
    alpha = [a for a in at(guide, "Alpha Camp") if a.reason != "park-wide"]
    severities = [a.note.severity for a in alpha]
    assert severities == sorted(severities, key=lambda s: s != "warning")


def test_gps_position(guide):
    lat, lon = guide.m.to_latlon(300, 305)  # on the road, mid-closure
    assert "Pine Road closed in winter east of this point" in texts(guide.for_latlon(lat, lon))


def test_cli_guidance_json(guidance_map, capsys):
    main([str(guidance_map), "Alpha Camp", "--guidance", "--json", "--exclude", "0,560,600,600"])
    out = json.loads(capsys.readouterr().out)
    reasons = {g["text"]: g["reason"] for g in out["Alpha Camp"][0]["guidance"]}
    assert reasons["Pine Road closed in winter east of this point"] == "on Pine Road, east of the marked point"


def test_cli_at_position_needs_no_name(guidance_map, capsys):
    m = GeoPdfMap.open(str(guidance_map))
    lat, lon = m.to_latlon(300, 305)
    assert main([str(guidance_map), "--at", f"{lat},{lon}"]) == 0
    assert "WARNING Pine Road closed" in capsys.readouterr().out


# -- real map: NPS Yosemite ----------------------------------------------------------------


@pytest.fixture(scope="session")
def yosemite_guide(yosemite_map):
    return Guidance(yosemite_map)


def yose(yosemite_guide, name):
    return texts(yosemite_guide.for_hit(yosemite_guide.m.locate(name)[0]))


def test_yosemite_tioga_closure_between_gates(yosemite_guide):
    for name in ("Olmsted Point", "White Wolf", "Tuolumne Meadows"):
        assert any(t.startswith("Tioga Road closed") for t in yose(yosemite_guide, name)), name
    # Lee Vining is past the Tioga Pass gate, outside the closed stretch
    assert not any(t.startswith("Tioga Road closed") for t in yose(yosemite_guide, "Lee Vining"))


def test_yosemite_glacier_point_road(yosemite_guide):
    assert any(t.startswith("Glacier Point Road Closed") for t in yose(yosemite_guide, "Glacier Point"))
    assert not any("Glacier Point Road" in t for t in yose(yosemite_guide, "Olmsted Point"))


def test_yosemite_label_qualifier(yosemite_guide):
    assert yose(yosemite_guide, "Badger Pass Ski Area")[0] == "Badger Pass Ski Area (winter only)"


def test_yosemite_park_wide_notes(yosemite_guide):
    park = [n.text for n in yosemite_guide.notes if n.scope == "park"]
    assert len(park) == 3
    assert any(t.startswith("Natural areas present hazards") for t in park)
