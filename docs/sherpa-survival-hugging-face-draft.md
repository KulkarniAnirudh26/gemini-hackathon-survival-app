# Sherpa Survival: Offline AI Assistant for Outdoor Adventures

You’re on a camping trip, walking on a quiet trail when it starts to rain. It’s getting dark, and it’s been a while since you passed a trail marker. You stop to check the map on your phone. No signal.

Then you remember you installed Sherpa Survival. You open it and see your position, the nearby trails, and the path you’ve walked so far.

As you are walking back to the trailhead, you see faint shadow of a bear in distance, and your heart races. You quickly whisper to Sherpa Survival, "I see a bear. What should I do?", instead of waiting for inference to generate token by token, the assistant immediate response "Stay calm, do not approach the bear, and slowly back away while keeping it in sight."

At distance, you use camera mode to take a photo of the bear, the assistance analyzes the image and tells you it is a black bear, which is generally not aggressive unless provoked.

You later went back to your campsite safely, and ask assistant for "how to start a fire"...

We built Sherpa Survival to make that possible on Android and iOS.

Both platforms run Gemma through LiteRT-LM, with an optimized model bundle for compatible Android phones with Google Tensor. The sections below explain how the model, location history, maps, and routing fit together.

## Local Model Capabilities/Limitations

Sherpa’s map and field guide run independently of the language model. LiteRT-LM loads **Gemma 4 E2B** when a request needs generation, reuses the engine for follow-ups, and releases it after five minutes of inactivity. Keeping the engine warm reduces the wait on the next request. Releasing it frees memory for the rest of the phone.

Sherpa uses E2B and can retry with an installed generic bundle if the optimized model fails to load.

| Standard LiteRT-LM bundle | Gemma 4 E2B-it | Gemma 4 E4B-it |
| --- | ---: | ---: |
| Effective parameters | 2.3B | 4.5B |
| Model file on disk | 2,583 MB | 3,654 MB |

### Gemma 4 E2B on Pixel 10 Pro: AICore and LiteRT-LM

| Metric | Gemini Nano via AICore · TPU | Gemma 4 E2B-it via LiteRT-LM · CPU | Gemma 4 E2B-it via LiteRT-LM · TPU |
| --- | ---: | ---: | ---: |
| Prefill speed (tokens/s) | 616.14 | 229.87 | 1,904.54 |
| Time to first token (s) | 0.45 | 1.18 | 0.19 |
| Decode speed (tokens/s) | 47.17 | 15.74 | 19.49 |
| First initialization (ms) | 107.57 | 8,438.25 | 7,798.01 |
| Steady initialization (ms) | — | 791.29 | 2,440.95 |

AI Edge Gallery 1.0.23, three runs per configuration with 256 prefill tokens and 256 decode tokens. The LiteRT-LM TPU configuration had the fastest prefill and time to first token. AICore had the fastest decode and first initialization. [Benchmark data and method](benchmarks/pixel-10-pro/README.md#gemma-generation).

### Sherpa’s Voice Pipeline on Pixel 10 Pro: Recognition, Routing, and Synthesis

| Component | LiteRT backend | Measured workload | Mean | p95 |
| --- | --- | --- | ---: | ---: |
| Zipformer CTC | GPU | Transcribe 4.56 s of audio | 225 ms | 240 ms |
| Laya Multilingual | GPU | Four classifier questions in the first routing pass | 1,095 ms | 1,129 ms |
| KittenTTS Nano 0.8 | CPU | Synthesize 8.42 s of audio | 798 ms | 811 ms |

Each component ran three warmups and 20 timed calls. The measurements cover individual stages. [Raw samples and method](benchmarks/pixel-10-pro/README.md#sherpa-voice-pipeline).

> **[Architecture diagram]** Show the map and guide outside the model lifecycle. Trace Gemma’s load, reuse, and release states. Show the retry with an installed generic bundle.
>
> **[Generated mobile screen]** Show model settings with the installed bundle, requested accelerator, and load status. Omit sample performance figures.

## Geolocation Integration

A location fix contains latitude, longitude, time, accuracy, and device altitude when available. While tracking is active, Sherpa adds a breadcrumb when a new fix is at least 25 metres from the last recorded point or at least two minutes newer. The saved track contains latitude, longitude, and timestamps. For current elevation, Sherpa looks up the position in its offline elevation grid and falls back to device altitude when the grid has no value.

The track serves two purposes. **Retrace** draws the recorded points in reverse. For inference, Sherpa adds up the distances between recent points and tells Gemma how far the user moved in the last hour. That gives the model a measure of recent progress, including time spent stopped.

The route planner calculates its walking estimate separately. It uses the route’s distance and ascent, with a fixed pace adjustment. Gemma can see both the route estimate and the user’s recent progress when explaining how long the walk might take. The following excerpt uses illustrative values.

```text
[SITUATION] Elevation 1,380 m. Moved 1.2 km in the last hour.
[ROUTE] Trailhead, 1.8 km, +120 m, about 44 minutes walking.
```

> **[Architecture diagram]** Show timestamped GPS points feeding Retrace and the last-hour distance calculation. Show current position feeding the elevation lookup and route planner. Pass recent progress, elevation, and the route estimate into Gemma’s context.
>
> **[Generated mobile screen]** Show the recorded track and current elevation alongside a route card. Label recent progress and estimated time remaining separately.

## Map Rendering Integration

The offline map pack stores trails as a network of connected segments. Each segment carries its shape, length, and elevation change. Named places such as trailheads and water sources are stored as points on the map. A separate elevation grid gives the app a height for any position within the covered area. Together, those layers let Sherpa calculate a route and draw it on the map.

![Three reconstructed Yosemite views: the navigation map with demo breadcrumbs, the default north-up Park map, and the tilted 3D terrain with aerial imagery draped over elevation](sherpa-map-rendering.png)

**2D navigation.** FlutterMap starts with a shaded terrain image positioned over the area it covers. It draws trails, roads, and water on top, then overlays the user’s position, recorded track, and calculated route. Smaller features such as streams and parking areas appear as you zoom in.

**3D map viewer.** The viewer opens on the north-up Park map. Tap **3D** to tilt the view and switch to aerial imagery when it’s available. MapLibre uses local elevation tiles to shape the terrain and drapes the selected map layer over it. Trails and landmarks stay visible as you switch views.

> **[Generated mobile screen]** Show the same area in the navigation map and the terrain viewer’s default Park map view. Keep the 3D toggle visible.

## Multimodal Integration

Hold the mic to record and release it to finish. On-device speech recognition turns the recording into a transcript. The assistant handles that text the same way it handles a typed question.

We considered sending audio directly to Gemma 4 E2B. Transcribing first gives Laya the text it needs to route the request before Gemma loads.

![Audio input diagram showing push-to-talk and on-device speech recognition turning a recording into text](sherpa-audio-input.png)

We cap photos at 640 pixels on the longest side and compress them as JPEG before sending them to Gemma.

![Image input diagram showing the resized photo and question combining before Gemma runs](sherpa-image-input.png)

> **[Generated mobile screen]** Show the question composer with an original photo attached. Keep the attachment, text field, and send controls visible.

## Decision Model Integration

**Laya** scores intent, urgency, and the need for reasoning. Its classifier runs on the GPU through LiteRT. Application rules combine those scores with cues in the request to select an answer path. A local lookup can complete with Gemma unloaded. The interface labels each answer with its source.

```mermaid
flowchart TD
    Request([Text request]) --> Laya[Laya scores intent, urgency, and need for reasoning]
    Laya --> Emergency{Emergency detected?}
    Emergency -->|Yes| Script[Show the emergency script first]
    Emergency -->|No| Local{Can the app answer locally?}
    Local -->|Map lookup| Map[Show the calculated result]
    Local -->|Guide topic| Guide[Show the offline guide]
    Local -->|No| Gemma[Generate with Gemma]
```

*Laya supplies scores. App rules use them alongside cues in the text to select the answer source.*

> **[Generated mobile screen]** Show a local lookup and a generated answer in the same interface, with the source of each visible.

## Closing

| Offline path | What the app does | End-to-end timing |
| --- | --- | --- |
| Retrace | Draws the recorded track in reverse | Pending |
| Guide lookup | Reads the bundled entry | Pending |
| Photo question, cold engine | Loads Gemma, then processes the image and question | Pending |
| Photo question, warm engine | Reuses Gemma for the image and question | Pending |

Sherpa’s time-to-first-token timer begins after model loading. The cold path includes that extra wait before the timer starts.

> **[Architecture diagram]** Show an offline test sequence covering Retrace, guide lookup, and cold and warm generation. Mark the start and end of each timing measurement.
>
> **[Generated mobile screen]** Show a test session in airplane mode with the answer source and selected model visible. Leave the timing values blank until measured.
