# Yosemite Survival Assistant (offline, on-device)

An offline voice survival assistant for Yosemite. You hold the mic and ask "where's water?", "how do I get out?" or "I'm cold and it's getting dark". The phone answers out loud, using its GPS position, offline trail maps with elevation, sunset times and a bundled survival guide.

Everything runs on the phone: Zipformer for speech-to-text, Laya to route each question, Gemma 4 E2B for open questions, and KittenTTS for speech. Release builds have **no INTERNET permission**.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design, memory and battery strategy.

## Setup

```sh
# 1. models (once): Kitten TTS + G2P, Laya router -> ~/Personal/gemma-models/models
sh tool/fetch_models.sh          # Gemma 4 E2B and Zipformer are expected there already

# 2. geo assets (once, needs internet): OSM trails/POIs + AWS terrain tiles -> assets/geo/
python tool/build_geo.py

# 3. build + install
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 4. push models to the phone (~3.4 GB)
sh tool/push_models.sh
```

Open the app and grant the microphone and location permissions.

## Demo tips
- **Pin a position:** long-press the map to place yourself anywhere in the park. Tap the GPS button to go back to the real GPS fix.
- **Battery modes:** tap the battery chip to force `saver` or `critical` mode. In `critical` mode Gemma stays unloaded and every answer comes from templates or the guide.
- **Seeing which path answered:** each answer is labelled with the path the router chose (`template, no LLM` or `Gemma`), plus the router's scores and its latency.
- **Logs:** `adb logcat -s SurvivalAi`

## Data sources
- **Trails and points of interest:** © OpenStreetMap contributors (ODbL).
- **Elevation:** AWS Terrain Tiles.
- **Models:** each one keeps its own license, listed in ARCHITECTURE.md:
  - Gemma (Gemma terms)
  - Zipformer, Kitten, Laya (Apache-2.0)
  - G2P (MIT / BSD-3-Clause-Clear)
