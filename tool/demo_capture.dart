import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yosemite_survival/ai/assistant.dart';
import 'package:yosemite_survival/geo/geo_data.dart';
import 'package:yosemite_survival/geo/nps_layers.dart';
import 'package:yosemite_survival/geo/trail_router.dart';
import 'package:yosemite_survival/location/location_service.dart';
import 'package:yosemite_survival/rag/guide.dart';
import 'package:yosemite_survival/main.dart' as app;
import 'package:yosemite_survival/ui/theme.dart';

/// Recording-only entrypoint: real Flutter widgets, app assets, and routing/data layers, but no
/// microphone, camera, or Tensor runtime. This must never be used as the release app entrypoint.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  late final Assistant assistant;
  const aiChannel = MethodChannel('survival/ai');
  aiChannel.setMethodCallHandler((call) async {
    // Text-to-speech is unavailable in this browser-only capture build. All
    // other platform AI operations remain unimplemented rather than simulated.
    if (call.method == 'speak') {
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        assistant.speaking = false;
        assistant.speakingSource = null;
        if (assistant.phase == Phase.speaking) assistant.phase = Phase.ready;
        if (assistant.status == 'Speaking…') assistant.status = 'Ready.';
        assistant.log(
          'capture',
          'Platform TTS audio is omitted in this browser preview.',
        );
      });
      return null;
    }
    if (call.method == 'stopSpeaking') return null;
    throw MissingPluginException(
      'Native AI is not part of the recording harness.',
    );
  });
  final location = LocationService();
  assistant = Assistant(location);
  assistant.status = 'Offline demo ready';
  assistant.phase = Phase.ready;
  assistant.geo = await GeoData.load();
  assistant.router = TrailRouter(assistant.geo!);
  assistant.nps = await NpsLayers.load();
  assistant.guide = await Guide.load();

  // Deterministic in-pack demonstration position and a real routed breadcrumb line.
  location.simulate(LocationService.demoLat, LocationService.demoLon);
  final back = assistant.router!.routeToPlace(
    LocationService.demoLat,
    LocationService.demoLon,
    LocationService.demoStartName,
    LocationService.demoStartLat,
    LocationService.demoStartLon,
  );
  if (back != null && !back.offTrail) {
    location.setDemoTrack(
      back.points.reversed.map((p) => (p.latitude, p.longitude)).toList(),
    );
  }

  runApp(_RecordingApp(assistant: assistant, location: location));
}

class _RecordingApp extends StatelessWidget {
  final Assistant assistant;
  final LocationService location;
  const _RecordingApp({required this.assistant, required this.location});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sherpa · Offline map demo',
    debugShowCheckedModeBanner: false,
    theme: survivalTheme(),
    home: app.Shell(assistant: assistant, location: location),
  );
}
