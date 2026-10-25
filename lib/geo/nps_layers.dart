import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// One NPS point of interest or place label (assets/nps/points.json, from NPS Park Tiles).
class NpsPoint {
  final String name, type; // type: "trailhead", "ranger station", ... or "label:peak", "label:small lake", ...
  final double lat, lon;
  final String? description;
  const NpsPoint(this.name, this.type, this.lat, this.lon, this.description);

  LatLng get latLng => LatLng(lat, lon);
  bool get isLabel => type.startsWith('label:');
  String get kind => isLabel ? type.substring(6) : type;
}

/// The NPS basemap geometry, built by tool/build_nps.py.
class NpsLayers {
  final Map<String, List<List<LatLng>>> lines; // trail, road, stream
  final Map<String, List<List<LatLng>>> polygons; // park, wilderness, water, parking, building
  final List<NpsPoint> points;
  NpsLayers(this.lines, this.polygons, this.points);

  static Future<NpsLayers> load() async {
    final raw = await Future.wait([
      rootBundle.loadString('assets/nps/lines.json'),
      rootBundle.loadString('assets/nps/polygons.json'),
      rootBundle.loadString('assets/nps/points.json'),
    ]);
    return compute(_parse, raw);
  }

  static Map<String, List<List<LatLng>>> _geoms(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    return {
      for (final e in m.entries)
        e.key: [
          for (final g in e.value as List)
            [
              for (var i = 0; i + 1 < (g as List).length; i += 2)
                LatLng((g[i] as num).toDouble(), (g[i + 1] as num).toDouble()),
            ],
        ],
    };
  }

  static NpsLayers _parse(List<String> raw) => NpsLayers(
        _geoms(raw[0]),
        _geoms(raw[1]),
        [
          for (final p in jsonDecode(raw[2]) as List)
            NpsPoint(p['n'] as String, p['t'] as String, (p['lat'] as num).toDouble(), (p['lon'] as num).toDouble(),
                p['d'] as String?),
        ],
      );
}
