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

The 2D/3D chips switch to a terrain-draped 3D view: the park-map tiles laid over real
elevation, with the selected place pinned and the GPS position shown. It is MapLibre GL JS
(bundled in `assets/map3d`, BSD-3) in a WebView, so it uses the phone's GPU through WebGL and
needs no network: `WebViewAssetLoader` serves the page from assets and the tiles straight from
the MBTiles files. The printed labels are part of the map image, so no font files are needed.

The tilesets aren't in git; build them before building the app (otherwise the 3D chips are hidden):

```bash
python scripts/build_android_assets.py data/yosemite.pdf --tiles --terrain
```

`yosemite.mbtiles` (map, zooms 9–13, 8.3 MB) and `yosemite-terrain.mbtiles` (elevation, zooms
8–11, 6.6 MB; downloaded once from the open Terrain Tiles, USGS 3DEP/SRTM, attribution shown on
the map). The release APK is 17.8 MB.

Known quirk: the printed map's white "see valley map" callout box drapes over the valley like
a white wall.

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
3D flies to the place with a pin on the map's own symbol; GPS dot on the terrain; five 2D/3D
switches with no crash and memory back to ~155 MB PSS (the WebView and its GL context are
destroyed on leaving 3D); minified release APK too. A device without WebGL gets a message.

Not verified on physical Pixel hardware, so GPU performance on a real Pixel 11 Pro is unmeasured.
