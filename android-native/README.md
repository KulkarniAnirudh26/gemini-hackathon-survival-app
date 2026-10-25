# Android integration

The phone never parses the PDF. A build-time step turns the GeoPDF into a small **map pack**, and
the app reads that with a pure-Kotlin library (`:mappack`) — fully offline.

```
data/yosemite.pdf ──(Python, build time)──► app/src/main/assets/maps/yosemite/
                                              mappack.json   0.1 MB  places, guidance, roads, georef
                                              map.jpg        1.8 MB  the page as an image (150 dpi)
```

Why not run the Python on the phone: PyMuPDF is AGPL-licensed (shipping it would put the app
under the AGPL) and the PDF is 28 MB, while the pack is ~2 MB and needs nothing but
kotlinx.serialization.

## Modules

| Module | What it is |
|---|---|
| `mappack` | Kotlin/JVM library, no Android dependencies. `MapPack.parse(json)`, then `search()`, `guidanceFor(place)`, `guidanceAt(latLon)`, `parkWide`, `latLonToPage()` / `pageToImagePx()` for markers. |
| `app` | Jetpack Compose demo: search, zoomable map with marker, guidance panel, "my location" button. |

```kotlin
val pack = MapPack.parse(assets.open("maps/yosemite/mappack.json").bufferedReader().readText())

val hit = pack.search("olmsted point").first()          // ranked like the Python locate()
hit.place.location                                      // LatLon(37.81025, -119.48555)
pack.guidanceFor(hit.place)                             // Tioga Road closures, summer-only facilities…
pack.guidanceAt(LatLon(lat, lon))                       // same rules for a GPS fix
val (px, py) = pack.pageToImagePx(hit.place.page)       // where to draw the marker on map.jpg
```

## Rebuilding the map pack

```bash
python scripts/build_android_assets.py data/yosemite.pdf
```

This rewrites the assets and `mappack/src/test/resources/parity.json` — what the Python side
answers for every place name and a grid of GPS positions. The Kotlin tests must reproduce it
exactly, so the phone and the Python pipeline cannot drift apart.

## Build and test

Requires JDK 17+ and the Android SDK (`local.properties` with `sdk.dir=…`, or `ANDROID_HOME`).

```bash
./gradlew :mappack:test          # library + parity tests (JVM only, no SDK needed)
./gradlew :app:assembleDebug     # the demo APK
./gradlew :app:installDebug      # onto a connected phone or emulator
```

Emulator GPS for trying "my location": `adb emu geo fix -119.4855 37.8102` (longitude first).

## 3D map

The 2D/3D chips switch to a 3D view: real Yosemite terrain with **aerial imagery** draped over it
by default (a Satellite / Park map switch on the map swaps in the printed park map), the selected
place pinned and the GPS position shown. It is MapLibre GL JS (bundled in `assets/map3d`, BSD-3)
in a WebView, so it uses the phone's GPU through WebGL and needs no network: `WebViewAssetLoader`
serves the page from assets and the tiles straight from the MBTiles files.

The tilesets aren't in git; build them before building the app (without the first two the 3D
chips are hidden; without imagery, 3D shows the park map only):

```bash
python scripts/build_android_assets.py data/yosemite.pdf --tiles --terrain --imagery
```

| File | What | Zooms | Size |
|---|---|---|---|
| `yosemite.mbtiles` | printed park map, rendered from the PDF | 9–13 | 8.3 MB |
| `yosemite-terrain.mbtiles` | elevation (Terrain Tiles: USGS 3DEP, SRTM et al.) | 8–11 | 6.6 MB |
| `yosemite-imagery.mbtiles` | aerial photos (USDA/USGS The National Map, public domain) | 9–13 | 14.8 MB |

The release APK is 31.7 MB. The terrain checks out against real summits: Half Dome 2686 m (true
2695), Yosemite Valley floor 1207 m (1220), El Capitan 2303 m (2307), Tuolumne Meadows 2617 m
(2620). Imagery at zoom 13 is ~15 m per pixel and looks soft when zoomed right in;
`--imagery-max-zoom 14` sharpens it at ~65 MB.

The 3D page opened straight from disk (`file://`) has no tiles and says so; use the app or
`tools/map-viewer/serve.py`.

## Device notes

- `minSdk 26`, `compileSdk`/`targetSdk 37` (Android 17, the release Pixel 11 Pro ships with).
  Current Compose libraries require compiling against API 37.
- Edge-to-edge is on (required from Android 15); content uses safe-drawing insets.
- The 2428×2570 map image is decoded as RGB_565 (~12 MB). For larger maps, tile the image
  rather than raising the dpi.
- Location uses the platform `LocationManager` (GPS → fused → network); no Google Play services.
  Denying the permission leaves search and the map working.
- Release builds are minified with R8; `proguard-rules.pro` keeps the kotlinx.serialization
  classes of the pack model. The demo's release build is signed with the debug key — use your
  own signing config to ship.

## Verified

On an Android 17 (API 37) emulator with the `pixel_9_pro` hardware profile (1280×2856, 480 dpi —
the closest profile the emulator ships; there is no Pixel 11 Pro profile yet), both the debug
and the minified release APK:

- launch and show the map;
- search "Olmsted Point" → 37.81025, −119.48555, marker on the map's dot, Tioga Road closures
  listed — identical to the Python CLI;
- `adb emu geo fix -119.36 37.873` + ◎ → blue dot at Tuolumne Meadows with the same guidance
  Python gives for that position; denying the permission shows a message and nothing breaks.

3D, on the same emulator with the host GPU passed through (WebView 145, WebGL 2): search →
3D flies to the place with a pin on the map's own symbol (Half Dome's summit, the top of El
Capitan's face, Glacier Point's rim, over aerial imagery); GPS dot on the terrain; the Satellite /
Park map switch; five 2D/3D
switches with no crash and memory back to ~155 MB PSS (the WebView and its GL context are
destroyed on leaving 3D); minified release APK too. A device without WebGL gets a message.

Not verified on physical Pixel hardware, so GPU performance on a real Pixel 11 Pro is unmeasured.
