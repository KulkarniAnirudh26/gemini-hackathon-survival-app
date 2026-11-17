# Sherpa — Voice-First Offline Survival Assistant: architecture

This is a voice-first offline survival assistant built for any wild place — here demonstrated with Yosemite National Park — running on Google Pixel 11 and iPhones. Everything runs on the device, with no network at runtime. The Android manifest has no `INTERNET` permission. The platform is region-agnostic by design: the same assistant core (ASR, router, Gemma, TTS, trail router, solar calculator, first-aid guide) works with any region pack (GeoPDF map + DEM + OSM data) produced by the included tooling.

## Goals

- **Voice:** talk to the survivor. Speech-to-text, a small router, the big LLM only when needed, then text-to-speech.
- **Map:** an offline map with trails, trailheads, exits, water sources and help points, plus elevation.
- **Route out:** a route along trails to the nearest trailhead or exit, with distance, climb, walking time and time to sunset.
- **Battery:** GPS tracking and breadcrumbs that are easy on the battery.
- **Guidance:** survival "what do I do" answers, grounded in a bundled guide (RAG).

## High-level design

```text
┌──────────────────────────── Flutter (Dart) ─────────────────────────────┐
│  UI: Home (status cards, hold-to-talk) · Map (2D + 3D HUD) · Guide      │
│  Location (geolocator, battery tiers) · Sun (NOAA) · Breadcrumbs        │
│  Geo: POIs, trail graph router (Dijkstra + DEM slope), DEM lookup       │
│  Assistant orchestrator: router decision → template OR LLM → speak      │
│  Context builder: SITUATION / ROUTE / NEAREST / GUIDE block             │
│  Map3d launcher: triggers native offline 3D screen via "survival/map3d"  │
└──────────────┬──────────────────────────────────────────▲───────────────┘
   MethodChannel "survival/ai"                EventChannel "survival/ai/events"
   MethodChannel "survival/map3d"                         │
               ▼                                          │
┌─────────────────────────── Native AI core ──────────────────────────────┐
│  Android (Kotlin, AiCore)            │  iOS (Swift, packages/sherpa_ios) │
│  Zipformer ASR (LiteRT GPU)          │  Apple SFSpeechRecognizer        │
│  Laya zero-shot router (LiteRT GPU)  │  (rule fallback on iOS)          │
│  Gemma 4 E2B (LiteRT-LM GPU)         │  Gemma 4 E2B (LiteRT-LM Swift)   │
│  KittenTTS (LiteRT CPU) + G2P        │  AVSpeechSynthesizer             │
│  Map3dActivity (MBTiles over WebView)│  Map3dViewController (WKWebView, │
│                                      │   sherpa-map:// tile scheme)     │
└──────────────────────────────────────┴──────────────────────────────────┘
```

**Why the ML lives in native code.** Two litert-samples apps already do this on Android with Google's LiteRT AARs:

- `samples/litert_lm/voice_assistant` runs Zipformer, Gemma 4 E2B and KittenTTS.
- `samples/litert/zero_shot_classification` runs Laya multilingual, with a Kotlin tokenizer included.

Putting all four models in one native layer on one LiteRT version (2.3.0) avoids loading two LiteRT runtimes into the same process. On iOS, the same contract is implemented by `packages/sherpa_ios` (LiteRT-LM for Swift for Gemma 4 E2B, plus Apple speech recognition and synthesis). Flutter does the UI, the geo work and the orchestration.

## Models (Android)

The models go on the device at `/sdcard/Android/data/com.hackathon.yosemite_survival/files/models/`, pushed with adb. None of them are in the APK.

| Role | Files | Size | Runtime | Source |
|---|---|---|---|---|
| Speech-to-text | `zipformer_ctc_fp16.tflite`, `tokens.txt` | 131 MB | LiteRT GPU | litert-community/Zipformer-medium-CR-CTC-LiteRT @7732ad6c (local copy) |
| Router / classifier | `laya_ml_s256_embeds_wfp16.tflite`, `laya_ml_act_head_fp32.tflite`, `laya_ml_calibration.json`, `tokenizer.json`, `tokenizer_config.json`, `token_embeddings_fp16.bin`, `token_embeddings.json` | 679 MB | LiteRT GPU FP32 | litert-community/Laya-Multilingual-LiteRT @058cbf34 |
| LLM | `gemma-4-E2B-it.litertlm` | 2.59 GB | LiteRT-LM GPU (TPU/NPU on Tensor G5) | litert-community/gemma-4-E2B-it-litert-lm (local copy) |
| Text-to-speech | `kitten_predictor.tflite`, `kitten_prosody.tflite`, `kitten_vocoder.tflite`, `voices.npz` | 67 MB | LiteRT CPU | litert-community/kitten-tts-nano-0.8 @d4662d89 |
| Text to phonemes (G2P) | `dp_g2p_matcha_fp16.tflite`, `g2p_dict.txt.gz`, `g2p_meta.json` | 28 MB | LiteRT CPU | litert-community/Matcha-TTS @8d650e79 |

Run `tool/fetch_models.sh` to download whatever is missing, then `tool/push_models.sh` to adb-push everything. On iOS, the Gemma model bundle is embedded or sideloaded with the build; speech recognition and synthesis use the system frameworks.

## The router: Laya decides when to call Gemma

Each spoken or typed utterance first goes through **one Laya call with several questions**. That takes about 50 ms per question on the GPU.

| Question | Type | Options |
|---|---|---|
| `intent` | choice | `find_water`, `way_out`, `time_daylight`, `which_direction`, `find_help`, `emergency`, `survival_howto`, `other` |
| `topic` | choice | guide sections (≤20): hypothermia, heat, bear, mountain_lion, injury, bleeding, signaling, shelter, night, water_purify, river_crossing, lightning, fire, lost_stop |
| `urgency` | score | 0 calm · 1 worried · 2 hurt or at risk · 3 life-threatening |
| `needs_reasoning` | noul (yes/no) | "Does answering need advice or explanation beyond a simple fact lookup?" |

What happens next:

- **`emergency`, or urgency 3:** speak the scripted 911 / Satellite SOS line plus the first-aid template right away, then let Gemma add more.
- **A lookup intent** (`find_water`, `way_out`, `time_daylight`, `which_direction`, `find_help`) with confidence ≥ 0.55 and `needs_reasoning` < 0.5: fill a **template** from the geo and sun data, then speak it. **Gemma isn't used.**
- **`survival_howto`** with confidence ≥ 0.6 and `needs_reasoning` < 0.5: speak the guide section's summary.
- **Anything else:** Gemma, with the context block. Laya's `topic` answer picks the guide chunks, so retrieval needs no embedding model.

The `Retriever` interface stays pluggable. Version 1 uses Laya's topic choice plus BM25 as a fallback. Version 2 could use EmbeddingGemma. When Laya is unavailable (e.g. on iOS, or during router warm-up), a keyword classifier mirrors the same decision policy with zero cold-start delay.

## Gemma lifecycle (battery and memory)

- **Loaded on demand,** the first time the router sends it a question. A pre-recorded "Let me think about that" line plays while it loads. GPU programs are cached in `cacheDir`, so warm loads are fast.
- **Unloaded** after 5 minutes idle, on `onTrimMemory`, or when the battery is below 20%.
- **System prompt:** fixed and placed first. Output is capped at about 160 tokens. Each request gets its own conversation, with the context block in front of the question.

## Memory budget (estimates)

| Component | Resident memory |
|---|---|
| Gemma 4 E2B (GPU), only while loaded | 2.5–3.5 GB |
| Laya multilingual: 251 MB graph plus a 393 MB memory-mapped table, paged in on demand | ~0.4–0.7 GB |
| Zipformer medium (GPU) | ~200–300 MB |
| KittenTTS | ~330–600 MB peak RSS (measured in voice_assistant) |
| DEM, hillshade, trails | ~40 MB |

**Steady state without Gemma:** about 1–1.5 GB. **With Gemma:** about 4–5 GB.

## Battery strategy

1. **Laya routes most questions to templates, not the LLM.**
2. **Gemma is lazy-loaded** and unloaded when idle. Answers are short and prompts are compact.
3. **Battery tiers:**
   - **Normal (>50%):** GPS every 60 s or 25 m.
   - **Saver (20–50%):** one GPS fix every 5 minutes, shorter answers.
   - **Critical (<20%):** Gemma unloaded, templates only, GPS only when requested, SOS card shown.
4. **Push-to-talk:** no always-on mic or voice detection.
5. **Precomputed offline:** trail graph, DEM, hillshade, POI index.
6. **Screen:** true-black OLED theme, spoken answers so the screen can stay off, no animations, and the map renders only while it's visible.
7. **Breadcrumbs** are written to disk in batches.
8. **Platform-conditional GPS settings** use `AppleSettings` with fitness activity on iOS and `AndroidSettings` interval throttling on Android, so battery-saver intervals take effect everywhere.

## Geo data (`tool/build_geo.py`, run once per region on a laptop)

- **Bounding box:** lat 37.49–38.19, lon −119.89 to −119.20.
- **OpenStreetMap (Overpass API):**
  - **Trails:** `highway=path|footway|track|bridleway`.
  - **Trailheads:** `highway=trailhead`.
  - **Exits:** park entrances (`barrier=entrance`, toll booths) and parking.
  - **Water:** `natural=spring`, `amenity=drinking_water`, lakes, named rivers.
  - **Help:** ranger stations, visitor centers, clinics, shelters.
- **Elevation:** AWS Terrain Tiles (Terrarium) at z12, stitched into an int16 grid (`dem.bin` + `dem.json`), with `hillshade.png` rendered from it.
- **Outputs in `assets/geo/`:**
  - `trails.json`: the simplified polylines plus the routing graph.
  - `pois.json`.
  - `dem.bin` and `dem.json`.
  - `hillshade.png`.
- **Routing on the device:**
  - Snap the user to the nearest trail node, then run Dijkstra to the nearest trailhead or exit.
  - The cost is length × (1 + 3·max(0, gradient)).
  - Walking time uses Naismith's rule: 5 km/h plus 1 h per 600 m of ascent.
  - If the user is more than 500 m from any trail, fall back to a straight-line bearing.
- **Solar calculations** (sunrise, sunset, dusk) anchor to local solar noon so sunrise precedes sunset in every device timezone.

## Offline 3D map

The app has two 3D modes, both offline:

1. **Full-screen MapLibre 3D** (`lib/map3d/map3d.dart` → native `Map3dActivity`/`Map3dViewController`): aerial imagery or the printed NPS park map draped over terrain with place search and per-spot safety guidance. Tiles (`yosemite.mbtiles`, `yosemite-terrain.mbtiles`, `yosemite-imagery.mbtiles`) are served to MapLibre from within the app process.
2. **Tactical 3D HUD** (`lib/ui/topo_3d_viewport.dart`): an embedded isometric wireframe viewer on the Trail Map screen with an altitude-gradient GPS trail ribbon, live compass rose, pitch/zoom controls, and sensor lock.

## Flutter ↔ Native contract

Method channel `survival/ai`:

| Method | Args | Returns |
|---|---|---|
| `init` | `{modelsDir}` | `{zipformer, laya, kitten: bool}` (Gemma is not loaded) |
| `startListening` | none | none (push-to-talk down) |
| `stopListening` | none | `{text}` transcript |
| `classify` | `{text, questions}` (Laya schema JSON) | answers JSON |
| `generate` | `{system, prompt, maxTokens}` | none (streams `llm_chunk` events, then `llm_done`) |
| `cancelGenerate` | none | none |
| `speak` | `{text}` | none (`tts_done` event) |
| `stopSpeaking` | none | none |
| `unloadLlm` | none | none |
| `status` | none | `{llmLoaded, ...}` |

Event channel `survival/ai/events`: `stt_partial`, `llm_loading`, `llm_ready`, `llm_chunk{text}`, `llm_done`, `tts_start`, `tts_done`, `error{message}`.

Method channel `survival/map3d`:

| Method | Args | Returns |
|---|---|---|
| `available` | none | `bool` (tilesets present) |
| `open` | `{lat, lon}` | `bool` (true if user tapped Home) |

## Repository layout

```text
android/                Flutter Android runner + native LiteRT layer (MainActivity.kt, AiCore.kt)
android-native/         Stand-alone Kotlin map-pack demo and parity fixtures
geopdf_locator/         Python map toolchain (GeoPDF parsing, guidance, MBTiles, terrain, imagery)
ios/                    Flutter iOS runner
lib/
  main.dart             app shell, status bar badges, 3D MAP / SOS / Settings actions
  ai/                   router (Laya + keyword fallback), templates, situation context builder
  geo/                  POIs, DEM, trail router, solar calculator, compass controller
  location/             location service with battery tiers
  map3d/                3D map channel + home-screen launcher button
  rag/                  guide loader + BM25 retriever
  services/             settings service (model picker, TTS engine, latency logs)
  ui/                   home, map (survival-first 2D with compass lock + off-trail guidance), guide, settings, emergency takeover
packages/sherpa_ios/    iOS federated plugin (Swift LiteRT-LM, ASR, TTS, WKWebView 3D map)
scripts/                asset pipelines (build_android_assets.py, extract_park_tiles.py)
test/                   17 Flutter unit & widget tests
tests/                  58 Python map-tool tests against the real NPS map
tool/                   geo & model build scripts (build_geo.py, fetch_models.sh, push_models.sh)
tools/                  PMTiles extractor and desktop map viewer (serve.py)
docs/screenshots/       visual documentation referenced in README
docs/demo/              2-minute demo video
```

## Platform and testing status

| Suite | Status |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | 17/17 passing |
| `pytest` (map tools) | 58/58 passing |
| Android target | ARM64; Tensor G5 for NPU Gemma; demo mode without park GPS |
| iOS target | ARM64; `packages/sherpa_ios` federated plugin; Xcode + CocoaPods |
| Offline 3D map | MapLibre bundled screen (MBTiles served locally); verified offline |

## Fallbacks if time runs short

1. No PMTiles basemap; the hillshade plus trail lines is the map.
2. No elevation-profile UI.
3. No breadcrumbs.
4. No trail routing; use a straight-line bearing instead.
5. Laya router replaced by a keyword router.
6. Kitten replaced by platform TTS (Android `TextToSpeech` / Apple `AVSpeechSynthesizer`).
