from geopdf_locator.terrain import tile_range

# The Yosemite park map's footprint (west, south, east, north)
YOSEMITE = (-119.920578, 37.465547, -119.036849, 38.204320)


def test_tile_range_covers_the_footprint():
    # counts match what was downloaded for the app: 4, 4, 12, 36, 132 tiles at zooms 8-12
    assert [len(tile_range(z, *YOSEMITE)) for z in range(8, 13)] == [4, 4, 12, 36, 132]


def test_tile_range_contains_half_dome():
    # Half Dome (37.7459, -119.5332) is in XYZ tile 12/688/1582
    assert (12, 688, 1582) in tile_range(12, *YOSEMITE)
