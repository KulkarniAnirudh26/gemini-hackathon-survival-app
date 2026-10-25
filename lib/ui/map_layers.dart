import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../geo/nps_layers.dart';
import 'theme.dart';

const kRoadColor = Color(0xFF9E958A);
const kWaterFill = Color(0xFFA9CCE3);
const kStreamColor = Color(0xFF3E86BF);
const kParkFill = Color(0x1A66BB6A);
const kBuildingFill = Color(0xFFB9A89E);
const kParkingFill = Color(0xFFD5DAD5);

/// NPS basemap geometry turned into flutter_map layers once, shared by the Map tab and the
/// in-chat mini maps (building ~20k polylines/polygons per map would be wasteful).
class MapLayerCache {
  final List<Polyline> trails, roads, streams;
  final List<Polygon> park, water, parking, buildings;

  MapLayerCache._(this.trails, this.roads, this.streams, this.park, this.water, this.parking, this.buildings);

  static NpsLayers? _for;
  static MapLayerCache? _cache;

  static MapLayerCache of(NpsLayers nps) {
    if (identical(_for, nps) && _cache != null) return _cache!;
    List<Polyline> lines(String k, Color c, double w) =>
        [for (final pts in nps.lines[k] ?? const <List<LatLng>>[]) Polyline(points: pts, color: c, strokeWidth: w)];
    List<Polygon> polys(String k, Color c) =>
        [for (final pts in nps.polygons[k] ?? const <List<LatLng>>[]) Polygon(points: pts, color: c, borderStrokeWidth: 0)];
    _for = nps;
    return _cache = MapLayerCache._(
      lines('trail', kTrail, 1.8),
      lines('road', kRoadColor, 2.6),
      lines('stream', kStreamColor.withValues(alpha: 0.6), 1.0),
      polys('park', kParkFill),
      polys('water', kWaterFill),
      polys('parking', kParkingFill),
      polys('building', kBuildingFill),
    );
  }
}
