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
