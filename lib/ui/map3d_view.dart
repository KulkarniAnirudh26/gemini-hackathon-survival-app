import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../location/location_service.dart';
import 'theme.dart';

/// Lets the map tab drive the 3D view (search results, "centre on me").
class Map3DController {
  MethodChannel? _channel;

  Future<void> showPlace(LatLng p, String name) async =>
      _channel?.invokeMethod('showPlace', {'lat': p.latitude, 'lon': p.longitude, 'name': name});

  Future<void> centreOnMe() async => _channel?.invokeMethod('centreOnMe');
}

/// Real 3D terrain: the official NPS park map draped over elevation, rendered by MapLibre GL in a
/// native WebView (android/.../map3d/Map3DView.kt, adapted from PR #5). Shows the same hiker,
/// walked track and route as the 2D map. Destroyed when the map tab goes back to 2D.
class Map3DView extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  final Map3DController controller;
  final ValueChanged<String>? onStatus; // "webgl: 2", "loaded", "unsupported", "error: …"
  const Map3DView({super.key, required this.assistant, required this.location, required this.controller, this.onStatus});

  @override
  State<Map3DView> createState() => _Map3DViewState();
}

class _Map3DViewState extends State<Map3DView> {
  MethodChannel? _channel;
  int _trackSent = -1;
  Object? _routeSent;
  (double, double)? _meSent;

  Assistant get a => widget.assistant;

  @override
  void initState() {
    super.initState();
    widget.location.addListener(_push);
    a.activeRoute.addListener(_push);
  }

  @override
  void dispose() {
    widget.location.removeListener(_push);
    a.activeRoute.removeListener(_push);
    widget.controller._channel = null;
    super.dispose();
  }

  void _created(int id) {
    final ch = MethodChannel('sherpa/map3d/$id');
    ch.setMethodCallHandler((call) async {
      if (call.method == 'event') widget.onStatus?.call(call.arguments as String);
    });
    _channel = ch;
    widget.controller._channel = ch;
    _push();
  }

  static List<double> _flat(Iterable<LatLng> pts) => [for (final p in pts) ...[p.latitude, p.longitude]];

  /// Sends only what changed: the hiker, the walked track and the route (way out or the answer's).
  void _push() {
    final ch = _channel;
    if (ch == null) return;
    final loc = widget.location;
    final f = loc.fix;
    if (f != null && _meSent != (f.lat, f.lon)) {
      _meSent = (f.lat, f.lon);
      ch.invokeMethod('showMe', {'lat': f.lat, 'lon': f.lon, 'pinned': f.simulated});
    }
    final crumbs = loc.breadcrumbs;
    if (crumbs.length != _trackSent) {
      _trackSent = crumbs.length;
      ch.invokeMethod('showTrack', {'points': _flat(crumbs.map((c) => LatLng(c.lat, c.lon)))});
    }
    final route = a.activeRoute.value ?? Situation.build(loc, a.geo, a.router).routeOut;
    if (!identical(route, _routeSent)) {
      _routeSent = route;
      ch.invokeMethod('showRoute', {'points': route == null ? <double>[] : _flat(route.points), 'name': route?.target.name ?? ''});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const Center(child: Text('3D map is available on Android.'));
    }
    final pack = a.mapPack;
    final (nw, se) = pack?.imageBounds ?? (const LatLng(38.2043, -119.9206), const LatLng(37.4655, -119.0368));
    return ColoredBox(
      color: const Color(0xFFDFE6EA),
      child: AndroidView(
        viewType: 'sherpa/map3d',
        creationParams: {'bounds': '${nw.longitude},${se.latitude},${se.longitude},${nw.latitude}'},
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
        // the WebView handles pan, pinch, tilt and rotate itself
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        layoutDirection: TextDirection.ltr,
        clipBehavior: Clip.hardEdge,
      ),
    );
  }
}

/// Small pill shown while the 3D view starts or if WebGL is missing.
class Map3DStatus extends StatelessWidget {
  final String status;
  const Map3DStatus(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    if (status == 'loaded') return const SizedBox.shrink();
    final text = status == 'unsupported'
        ? '3D needs WebGL, which this device does not provide.'
        : status.startsWith('error')
            ? '3D map: $status'
            : 'Loading 3D terrain…';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(text, style: label(status == 'unsupported' || status.startsWith('error') ? kClay : kInkMuted, size: 11)),
      ),
    );
  }
}
