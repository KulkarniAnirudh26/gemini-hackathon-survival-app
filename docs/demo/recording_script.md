# Sherpa — 2-minute live-recording script

**Review status:** Approved for recording by the user on 2026-11-10
**Target:** 2:00, landscape 16:9, 1280×720 H.264/AAC
**Visual rule:** Product footage is continuous screen recording of the running Flutter app and its bundled MapLibre 3D page. Do not substitute screenshots or still-frame sequences for product footage. The edit may add restrained titles, captions, voice-over, and music over the recordings.
**Demonstration location:** Yosemite is the sample offline map pack; narration must continue to say “built for anyplace,” not imply that Yosemite is the only supported region.

## Capture order and timed edit

| Time | Live recording / edit | Voice-over | On-screen text / sound |
|---|---|---|---|
| 0:00–0:07 | Start already on the 2D survival map. Hold the route arrow, target, distance, and off-trail alert in frame; make a small real zoom-in. | “No bars. No trail in sight. Sherpa turns the map in your pocket into a practical way to find safety.” | Hook: **NO SIGNAL. FIND YOUR WAY.** Brief music impact, then restrained score. |
| 0:07–0:23 | Show the live route card and breadcrumb line. Pan/zoom once, then use Center on me. Hold long enough to read route distance and walking time. | “This is a live map view, not a mockup. It shows your position, a route to a way out, walking time, and the path you have already walked.” | Small label: **OFFLINE 2D MAP**. Subtle tap sounds only on visible controls. |
| 0:23–0:37 | Tap **Water** in the destination row. Let the selected destination and route update. Tap a nearby blue water pin to open its details, then close the sheet. | “Choose water, help, a road, or the nearest way out. The route and bearing update from the bundled trail and place data. Remember: wilderness water still needs treatment.” | Label: **ROUTE TO WATER · TREAT BEFORE DRINKING**. |
| 0:37–0:50 | Tap **Retrace**. Show the cyan breadcrumb line, then switch back to **Way out**. | “If turning around is the safer choice, retrace follows your recorded breadcrumbs instead of asking you to invent a new route.” | Label: **RETRACE YOUR RECORDED PATH**. |
| 0:50–1:03 | Hold on the off-trail guidance and compass card. Tap compass lock, then center and zoom once; keep the movement deliberate. | “When you are off trail, Sherpa points toward the nearest mapped trail and reports the bearing and terrain slope. The phone compass can keep the map oriented as you turn.” | Label: **BEARING + TERRAIN SLOPE**. |
| 1:03–1:14 | Return to the dashboard. Hold on the daylight and elevation card; do not imply a real GPS fix—the scene is clearly the Yosemite demo position. | “Daylight and elevation add context to the decision. In this recording, the position is a reproducible demo fix; on a phone, Sherpa uses the device location and compass.” | Small label: **REPRODUCIBLE DEMO FIX**. |
| 1:14–1:32 | From the dashboard, tap **Find water** and hold on its real offline-data answer and route mini-map. Return to Trail Map, tap the book/guide control, choose **Too cold**, and show the numbered field-guide steps. Do not tap the microphone. | “Short map questions resolve against local data. The field guide keeps essential safety instructions available when a network is not. No cloud response is needed for these map lookups.” | Label: **LOCAL MAP ANSWERS · OFFLINE FIELD GUIDE**. No fake model telemetry or synthetic “live inference” graphics. |
| 1:32–1:51 | Cut to a continuous recording of the bundled 3D page. Start on the north-up **Park map** and show the trail/road network and safety points. Tap **3D** (it switches to **Aerial** terrain mode); tap a water cluster to zoom in, tap an individual source marker for its caution, then toggle back to restore the readable plan map. | “The 3D view starts on a readable park map with the region’s trails, roads, and safety places. Tap 3D: it switches to aerial terrain while those markers stay visible. Water clusters expand into individual sources; none is a drinking guarantee. Return to the plan map to read labels.” | Label: **OFFLINE TERRAIN · LOCAL TRAILS & SAFETY POINTS**. Keep real map interaction and UI visible throughout. |
| 1:51–2:00 | Return to the real dashboard/map; hold a clean frame, then finish on the Sherpa name and project link. | “Yosemite is the demonstration pack, not the boundary. Sherpa is built for anyplace—offline, on Android and iOS.” | Closing: **SHERPA · BUILT FOR ANYPLACE** · **Android + iOS** · repository URL. Music resolves and fades. |

## Spoken script (verbatim)

No bars. No trail in sight. Sherpa turns the map in your pocket into a practical way to find safety.

This is a live map view, not a mockup. It shows your position, a route to a way out, walking time, and the path you have already walked.

Choose water, help, a road, or the nearest way out. The route and bearing update from the bundled trail and place data. Remember: wilderness water still needs treatment.

If turning around is the safer choice, retrace follows your recorded breadcrumbs instead of asking you to invent a new route.

When you are off trail, Sherpa points toward the nearest mapped trail and reports the bearing and terrain slope. The phone compass can keep the map oriented as you turn.

Daylight and elevation add context to the decision. In this recording, the position is a reproducible demo fix; on a phone, Sherpa uses the device location and compass.

Short map questions resolve against local data. The field guide keeps essential safety instructions available when a network is not. No cloud response is needed for these map lookups.

The 3D view starts on a readable park map with the region’s trails, roads, and safety places. Tap 3D: it switches to aerial terrain while those markers stay visible. Water clusters expand into individual sources; none is a drinking guarantee. Return to the plan map to read labels.

Yosemite is the demonstration pack, not the boundary. Sherpa is built for anyplace—offline, on Android and iOS.

## Recording and edit notes

The reproducible app capture uses `tool/demo_capture.dart`: real Flutter screens, offline map/router/guide data and a deterministic Yosemite demo fix, with only platform TTS playback omitted. The separate 3D recording uses the same bundled local tiles. The browser capture does not exercise native AI, live GPS or the phone compass. Record at device-like proportions so route cards remain legible; retain each real tap that causes a visible result and trim only dead time or loading waits. Keep the opening action visible by the first second. Burn in captions, but never cover the route arrow, current-location marker, destination pins or 3D controls. Keep music below the voice. The script is approved; capture the footage, then assemble only after reviewing the takes, narration, and synchronization.

**Accuracy check before export:** confirm the chosen water POI exists in the bundled dataset, verify the displayed route/time against the live app, keep the demo-fix disclosure on screen, and make no claim that the browser recording exercises the phone’s native AI, GPS, or compass sensors.

## Reference / inspiration

The edit follows the real-UI, evidence-first launch approach: show the product's strongest result immediately, retain the user action that causes each visible outcome, focus on a few meaningful flows, and give the result a readable hold. The reference project is [latent-spaces/brag](https://github.com/latent-spaces/brag), including its [Brag workflow](https://raw.githubusercontent.com/latent-spaces/brag/main/skills/brag/SKILL.md) and [slim workflow](https://raw.githubusercontent.com/latent-spaces/brag/main/skills/brag-slim/SKILL.md). These are video/creative-workflow references, not map-widget libraries; the map interaction design remains specific to Sherpa's offline navigation needs.
