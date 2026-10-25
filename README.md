# Sherpa

## Yosemite Survival Assistant

Sherpa is an Android prototype that helps hikers access practical, location-aware wilderness guidance when internet connectivity is unavailable. It combines on-device Gemma inference with local park reference data, speech recognition, GPS, and a curated safety guide.

| | |
|---|---|
| Hackathon track | Mobile AI |
| Platform | Android; designed for evaluation on compatible Pixel hardware |
| Primary model | Gemma 4 E2B using LiteRT-LM |

## Project overview

In a remote setting, a hiker may need to understand their surroundings, find a mapped resource, or quickly review safety guidance. Sherpa provides a voice-first interface to locally stored information and on-device AI, with deterministic responses available for common lookups and emergency guidance.

The prototype is designed to run inference and access its park reference data locally. Models must be downloaded and copied to the device before use. Map, trail, and point-of-interest data are reference data; they do not provide live trail conditions, closures, weather, or water availability.

## Capabilities

- **Voice and text questions:** Zipformer transcribes spoken questions locally; typed questions use the same assistant flow.
- **Question routing:** Laya classifies requests. Nearby lookups can be answered with templates and local geographic data; supported hazards can use the bundled safety guide; open-ended questions are sent to Gemma 4 E2B.
- **Location-aware context:** When location is available, the assistant can use the current position, nearby mapped points, route information, elevation, battery state, and sunset timing.
- **Offline map and guide:** The app includes local park map layers and a browsable first-aid and wilderness guide.
- **3D map:** The **3D MAP** button at the top of the home screen opens Yosemite in 3D: aerial imagery or the
  printed NPS park map draped over real terrain. Search a place to fly there and see the park map's safety
  guidance for that spot (closures, limits, park-wide notes), or check the guidance at your GPS position.
  Everything is bundled, so it works offline.
- **Spoken responses:** KittenTTS generates speech on-device.
- **Inspectable decisions:** Answers are labeled by source. Long-press an answer to inspect routing details and, for Gemma answers, the prompt provided to the model.

For urgent questions, the app presents scripted guidance immediately; Gemma may provide a follow-up when enabled and battery conditions allow. This prototype is not a substitute for trained emergency response and cannot dispatch rescuers.

## Evaluation walkthrough

1. **Local information:** Ask, “Where is the nearest water?” Grant location permission or pin a demonstration location on the map. Review the answer’s source label and, when available, its mapped destination.
2. **Gemma response:** Ask, “Explain what I should consider if I’m cold, wet, and sunset is approaching.” Confirm that the answer is labeled **Gemma**, then long-press it to inspect the routing decision and model prompt.
3. **Safety content:** Open the first-aid guide and select a topic, or demonstrate the emergency response. Note which guidance is scripted and which response, if any, comes from Gemma.
4. **Offline behavior:** Enable airplane mode and repeat a local lookup and a Gemma question. This requires the model files to be present on the device. GPS reception and emergency calling or Satellite SOS depend on device capabilities and coverage.

For a controlled location demo, long-press the map to pin a position in Yosemite. Use the GPS control to return to the device’s current location.

## Technical design

```text
Voice input → Zipformer ASR → Laya routing ─┬─ local templates + park data
                                            ├─ bundled safety guide
                                            └─ Gemma 4 E2B → KittenTTS
```

The user interface, location and map experience, retrieval, and routing policy are implemented in Flutter. Android Kotlin code hosts the LiteRT and LiteRT-LM inference and audio components. Gemma can use the Tensor G5 NPU model on compatible Pixel hardware or another supported backend/model combination.

| Component | Role | Execution |
|---|---|---|
| Zipformer | Speech recognition | On-device, LiteRT |
| Laya | Question classification and routing | On-device, LiteRT |
| Gemma 4 E2B | Open-ended responses | On-device, LiteRT-LM |
| KittenTTS | Speech generation | On-device, LiteRT |
| Park data and safety guide | Local context and reference content | Bundled with the app |

## Build and run

The Android app requires Flutter, Android SDK/ADB, JDK 17, and an ARM64 Android device. The Tensor G5 model requires compatible Pixel hardware. Model assets are not included in the APK; Gemma 4 E2B and Zipformer files must be obtained separately. The model set is several gigabytes.

1. Set `MODELS` to a local directory containing the Gemma and Zipformer files, then download the remaining model assets:

   ```sh
   export MODELS="$HOME/Personal/gemma-models/models"
   sh tool/fetch_models.sh
   ```

2. Build and install the Android APK from the `project/` directory:

   ```sh
   flutter pub get
   flutter build apk --release --target-platform android-arm64
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

3. Launch the app once, connect the device with USB debugging enabled, then copy models to the app’s external files directory:

   ```sh
   sh tool/push_models.sh
   ```

Grant microphone and location permissions when prompted. For model inventory, data preparation, runtime lifecycle, and battery considerations, see [ARCHITECTURE.md](ARCHITECTURE.md). Model licenses and geographic data attributions are documented there and with the corresponding assets.

## Offline map tools from the NPS park map (`geopdf_locator`)

Python tools that turn the official NPS Yosemite park map (a GeoPDF) into offline data: place-name
lookup, the map's own safety notes linked to places, MBTiles map tiles, and 3D terrain and imagery.


Offline place-name → lat/lon lookup on georeferenced PDF maps (GeoPDF), such as the NPS park maps.

```python
from geopdf_locator import GeoPdfMap

m = GeoPdfMap.open("data/yosemite.pdf")
best = m.locate("Half Dome")[0]
best.lat, best.lon          # (37.74603, -119.53303)
m.to_page(37.75, -119.55)   # GPS fix -> page point, for drawing a "you are here" marker
```

```bash
geopdf-locate data/yosemite.pdf "Half Dome" "Glacier Point" --all
geopdf-locate data/yosemite.pdf "Half Dome" --render out/half_dome.png
```

`--render OUT.png` draws the best hit: a close-up (`OUT.png`, label boxed, crosshair on the anchor, coordinates captioned) and a whole-map overview (`OUT_overview.png`). With several names, each gets its own pair (`OUT_half-dome.png`, …). From Python: `geopdf_locator.render.render_hit(m, hit, "out.png")`.

### How it works

1. **Georeference** – reads the page's `/VP` → `/Measure /GEO` dictionary (control points `GPTS`/`LPTS`, coordinate system `GCS`) and fits an affine transform from page space to projected space. Web Mercator (EPSG:3857) and plain geographic coordinates are supported.
2. **Find labels** – searches a character stream rather than words, because curved labels ("Glacier Point Rd" along a road) are stored one glyph per text block. Matches are grown into the full label using font/size/colour and proximity, so "Glacier Point" inside "Glacier Point Road" is recognised as part of a longer phrase.
3. **Snap to the symbol** – labels sit beside their feature, so the label centre is 1–2 km off. The locator anchors to the map symbol instead:
   - a leader line drawn from the label (or its icon) to a locator dot,
   - otherwise the nearest symbol that this label is the closest text to, dots before icons (a town dot beats the gas/food icons beside it); elevation notes and curved road/river/area text can't claim symbols,
   - all-caps area labels ("TUOLUMNE MEADOWS") keep their centre.
4. **Rank** – exact labels > snapped > via leader > larger type. Every hit is returned so callers can disambiguate.

### Safety guidance

The map's own safety notes (closures, limits, hazards, seasonal facilities) are linked to places, so a lookup also tells you what applies there:

```bash
geopdf-locate data/yosemite.pdf "Olmsted Point" --guidance
#   WARNING Tioga Road closed approx. November to May east of this point  (on Tioga Road, east of the marked point)
#   INFO    Facilities along Tioga Road available summer only  (along Tioga Road)
geopdf-locate data/yosemite.pdf --at 37.873,-119.36     # guidance for a GPS position
```

```python
from geopdf_locator import Guidance
g = Guidance(m)
g.for_hit(m.locate("Glacier Point")[0])   # or g.for_latlon(lat, lon)
```

- **Notes** are text blocks with advisory wording ("closed", "limit", "no swimming", "summer only", "permit"…), so no per-map colour rules are needed. Blocks printed together are merged ("Mariposa Grove Road" + "Closed approx. …"), and a lone "(summer only)" is attached to the label it sits under. Sentences in the legend become **park-wide** notes.
- **Anchor**: the end of the arrow drawn from the note to the map ("east of this point"), or the note's position.
- **Roads**: a note naming a road ("Tioga Road") is traced to that road's line through the road's own label on the map.
- **Matching a place**, in order: the note is printed with the place's label; the place is within 2 km of the note's road, and for "east/west of this point" closures only inside the closed stretch (bounded by an opposite-facing note on the same road, so Tioga Road closures cover Crane Flat → Tioga Pass but not Lee Vining); otherwise within 2.5 km of the note's anchor. Warnings rank before info; duplicates are dropped.

Non-map regions (legend, notes) are excluded via `exclude=[(x0, y0, x1, y1), ...]`; known maps get defaults from `KNOWN_EXCLUSIONS` by PDF title.

On the Yosemite map, the median error over 29 reference places is ~170 m (vs ~1.3 km for label centres); peaks and viewpoints are within ~20–170 m.

### Map tiles (MBTiles)

```bash
python -m geopdf_locator.tiles data/yosemite.pdf out/yosemite.mbtiles --max-zoom 14
```

Renders the GeoPDF into a standard MBTiles raster tileset (JPEG, Web Mercator, zooms 9–14:
2,471 tiles, ~24 MB, ~2 min) for any offline map view (`flutter_map`, MapLibre, Leaflet). Each
tile is drawn from the PDF's vector content at its own zoom, so text stays sharp, and it uses
the same georeference as the place search and guidance: on the Yosemite map, 106 of 118
snapped places land exactly on a dark map-symbol pixel at zoom 14 (8 of 118 for points 300 m
away). Zoom 14 is ~7.5 m per pixel; use `--max-zoom 13` for ~8 MB.

### NPS Park Tiles overlay (vector)

```bash
brew install pmtiles
python scripts/extract_park_tiles.py data/yosemite.pdf out/parktiles [--mbtiles]
```

Cuts the GeoPDF's footprint out of the NPS nationwide
[Park Tiles](https://www.nps.gov/maps/web/blog/tilejson/index.html) vector tilesets (MVT, zoom
0–15, PMTiles) with HTTP range requests: ~15 s, ~23 MB for Yosemite: `boundary` (park,
wilderness), `data` (roads, trails, buildings, parking), `hydro` (streams, lakes) and
`label-point` (511 named points: restrooms, trailheads, bus stops, campgrounds, viewpoints…).
`--mbtiles` also writes vector MBTiles copies (`pip install pmtiles`). NPS/USGS data, public domain.

It is a second layer, not a replacement: it is sharp at any zoom and has amenities the printed
map lacks, but not the printed map's seasonal closures and notices (still from the PDF). The
two agree: 26 places named in both are a median 141 m apart, and roads/trails/streams overlay
the printed ones.

Try both together (PDF tiles as base, Park Tiles on top, layer toggles):

```bash
python tools/map-viewer/serve.py 8766 --tiles pdf=out/yosemite.mbtiles --pmtiles out/parktiles
# open http://127.0.0.1:8766/
```

The viewer loads MapLibre and its label fonts from the web; an offline app must bundle the
renderer's glyph files too.

### 3D terrain

```bash
python -m geopdf_locator.terrain data/yosemite.pdf out/yosemite-terrain.mbtiles --max-zoom 11
```

```bash
python -m geopdf_locator.imagery data/yosemite.pdf out/yosemite-imagery.mbtiles --max-zoom 13
```

Downloads, for the map's footprint, open elevation tiles (Terrain Tiles on AWS, Terrarium encoding;
USGS 3DEP, SRTM et al.; zooms 8–11 are 6.6 MB) and aerial imagery (USDA/USGS The National Map,
public domain; zooms 9–13 are 14.8 MB) into MBTiles. The app drapes the imagery (or the park map)
over the terrain in 3D; `tools/map-viewer/serve.py --tiles pdf=… --tiles terrain=… --tiles
imagery=… --static android-native/app/src/main/assets/map3d` shows the same page in a desktop browser.

### Native Android demo (`android-native/`)

The survival app itself is the Flutter app in `android/` + `lib/`. Separately, a native Kotlin
demo shows the PDF-derived map pack on a phone without parsing the PDF: `python scripts/build_android_assets.py data/yosemite.pdf` exports
a ~2 MB offline map pack (places, guidance, roads, georeference, map image) and a Kotlin library
reads it. Parity tests keep the Kotlin results identical to this Python pipeline. See
[android-native/README.md](android-native/README.md).

### Development (map tools)

```bash
python -m venv .venv && .venv/bin/pip install -e '.[dev]'
mkdir -p data && curl -L -o data/yosemite.pdf 'https://npgallery.nps.gov/HFC/GetAsset/c51f64fd-51dc-400e-b562-d02789c95933/original.pdf'
.venv/bin/pytest
```

Tests against the real map are skipped when `data/yosemite.pdf` (or `$YOSEMITE_MAP_PDF`) is missing; the synthetic-GeoPDF tests always run.
