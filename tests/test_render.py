import pymupdf

from geopdf_locator import GeoPdfMap
from geopdf_locator.__main__ import main
from geopdf_locator.render import render_hit


def test_render_writes_closeup_and_overview(synthetic_map, tmp_path):
    m = GeoPdfMap.open(str(synthetic_map))
    hit = m.locate("Foo Peak")[0]
    closeup, overview = render_hit(m, hit, tmp_path / "sub" / "foo.png")

    assert closeup == tmp_path / "sub" / "foo.png"
    assert overview == tmp_path / "sub" / "foo_overview.png"
    big, small = pymupdf.Pixmap(str(closeup)), pymupdf.Pixmap(str(overview))
    # close-up is a ~200x90 pt crop at 300 dpi; overview is the whole 600x600 page at 50 dpi
    assert big.width > 700 and big.height > 300
    assert (small.width, small.height) == (417, 417)


def test_render_marks_the_anchor_in_red(synthetic_map, tmp_path):
    m = GeoPdfMap.open(str(synthetic_map))
    hit = m.locate("Foo Peak")[0]
    _, overview = render_hit(m, hit, tmp_path / "foo.png")
    pix = pymupdf.Pixmap(str(overview))
    scale = 50 / 72
    x, y = hit.page_xy
    # a point on the overview ring (radius 25 pt) right of the anchor
    r, g, b = pix.pixel(round((x + 25) * scale), round(y * scale))[:3]
    assert r > 150 and r - g > 60 and r - b > 60  # red, allowing for anti-aliasing


def test_render_leaves_map_untouched(synthetic_map, tmp_path):
    m = GeoPdfMap.open(str(synthetic_map))
    before = m.locate("Foo Peak")
    drawings = len(m.page.get_drawings())
    render_hit(m, before[0], tmp_path / "foo.png")
    assert len(m.page.get_drawings()) == drawings
    assert [(h.label, h.page_xy) for h in m.locate("Foo Peak")] == [(h.label, h.page_xy) for h in before]


def test_cli_render_single_and_multiple(synthetic_map, tmp_path, capsys):
    assert main([str(synthetic_map), "Foo Peak", "--render", str(tmp_path / "one.png")]) == 0
    assert (tmp_path / "one.png").exists() and (tmp_path / "one_overview.png").exists()

    main([str(synthetic_map), "Foo Peak", "Bar Camp", "Nowhere", "--render", str(tmp_path / "many.png")])
    names = sorted(p.name for p in tmp_path.glob("many*"))
    assert names == ["many_bar-camp.png", "many_bar-camp_overview.png",
                     "many_foo-peak.png", "many_foo-peak_overview.png"]
    assert "rendered" in capsys.readouterr().err
