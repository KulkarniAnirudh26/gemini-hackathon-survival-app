import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../location/location_service.dart';
import 'theme.dart';

/// Offline map: hillshade image + trail polylines + POIs. No tile layer, no network.
class MapScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const MapScreen({super.key, required this.assistant, required this.location});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  double _zoom = 13;
  List<Polyline>? _trails, _roads;
  List<Marker>? _poiMarkers;
  List<CircleMarker>? _water;

  static const _valley = LatLng(37.7456, -119.5936);

  void _build(GeoData geo) {
    if (_trails != null) return;
    final g = geo.graph;
    final trails = <Polyline>[], roads = <Polyline>[];
    for (var i = 0; i < g.edges.length; i++) {
      final e = g.edges[i];
      final w = g.ways[e.way];
      final pts = g.edgePoints(i, e.a);
      if (w.isTrail) {
        final hard = w.sac.contains('alpine') || w.sac.contains('demanding');
        trails.add(Polyline(points: pts, color: hard ? kDanger.withValues(alpha: 0.8) : kTrail, strokeWidth: 1.6));
      } else {
        roads.add(Polyline(points: pts, color: const Color(0xFFBDBDBD), strokeWidth: 2.2));
      }
    }
    _trails = trails;
    _roads = roads;
    _poiMarkers = [
      for (final p in geo.pois)
        if (p.type != PoiType.water)
          Marker(
            point: p.latLng,
            width: 28,
            height: 28,
            child: Tooltip(message: p.name, child: Icon(_icon(p.type), color: _color(p.type), size: 22)),
          ),
    ];
    _water = [
      for (final p in geo.pois)
        if (p.type == PoiType.water) CircleMarker(point: p.latLng, radius: 3, color: kWater.withValues(alpha: 0.8)),
    ];
  }

  static IconData _icon(PoiType t) => switch (t) {
        PoiType.trailhead => Icons.hiking,
        PoiType.exit => Icons.local_parking,
        PoiType.help => Icons.local_hospital,
        PoiType.shelter => Icons.cabin,
        PoiType.water => Icons.water_drop,
      };

  static Color _color(PoiType t) => switch (t) {
        PoiType.trailhead => kAccent,
        PoiType.exit => kGood,
        PoiType.help => kDanger,
        PoiType.shelter => Colors.white,
        PoiType.water => kWater,
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.location]),
      builder: (context, _) {
        final geo = widget.assistant.geo;
        if (geo == null) return const Center(child: Text('Loading map…'));
        _build(geo);
        final s = Situation.build(widget.location, geo, widget.assistant.router);
        final f = s.fix;
        final me = f == null ? null : LatLng(f.lat, f.lon);
        final crumbs = [for (final c in widget.location.breadcrumbs) LatLng(c.lat, c.lon)];
        final route = s.routeOut;
        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: me ?? _valley,
              initialZoom: 13,
              minZoom: 9,
              maxZoom: 17,
              backgroundColor: kBlack,
              cameraConstraint: CameraConstraint.contain(
                bounds: LatLngBounds(geo.dem.hillshadeNorthWest, geo.dem.hillshadeSouthEast),
              ),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onPositionChanged: (camera, _) {
                final crossed = (camera.zoom >= 13) != (_zoom >= 13) || (camera.zoom >= 11) != (_zoom >= 11);
                _zoom = camera.zoom;
                if (crossed) setState(() {});
              },
              onLongPress: (_, p) {
                widget.location.simulate(p.latitude, p.longitude);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Position pinned here (demo). Tap the GPS button to use real GPS.')),
                );
              },
            ),
            children: [
              OverlayImageLayer(overlayImages: [
                OverlayImage(
                  bounds: LatLngBounds(geo.dem.hillshadeNorthWest, geo.dem.hillshadeSouthEast),
                  imageProvider: const AssetImage('assets/geo/hillshade.png'),
                ),
              ]),
              PolylineLayer(polylines: _roads!),
              if (_zoom >= 11) PolylineLayer(polylines: _trails!),
              if (_zoom >= 13) CircleLayer(circles: _water!),
              if (crumbs.length > 1)
                PolylineLayer(polylines: [Polyline(points: crumbs, color: kWater, strokeWidth: 2, pattern: StrokePattern.dotted())]),
              if (route != null)
                PolylineLayer(polylines: [
                  Polyline(points: route.points, color: kGood, strokeWidth: 5, pattern: route.offTrail ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid()),
                ]),
              if (_zoom >= 11) MarkerLayer(markers: _poiMarkers!),
              if (me != null)
                MarkerLayer(markers: [
                  Marker(
                    point: me,
                    width: 26,
                    height: 26,
                    child: Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, color: kWater, border: Border.all(color: Colors.white, width: 3)),
                    ),
                  ),
                ]),
            ],
          ),
          if (route != null)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('To ${route.target.name}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text(
                      '${formatDistance(route.distanceM)} · +${route.ascentM.round()} m / -${route.descentM.round()} m · ~${formatDuration(route.walkTime)}'
                      '${route.offTrail ? ' · off trail (straight line)' : route.viaText}',
                      style: const TextStyle(color: kMuted),
                    ),
                    if (s.untilSunset != null && !s.untilSunset!.isNegative && route.walkTime > s.untilSunset!)
                      const Text('Longer than the daylight left: plan for the night.', style: TextStyle(color: kDanger)),
                  ]),
                ),
              ),
            ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(children: [
              FloatingActionButton.small(
                heroTag: 'gps',
                onPressed: () async {
                  widget.location.clearSimulation();
                  final fix = await widget.location.fixNow();
                  if (fix != null) _map.move(LatLng(fix.lat, fix.lon), 14);
                },
                child: const Icon(Icons.my_location),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: 'route',
                onPressed: route == null ? null : () => _map.fitCamera(CameraFit.coordinates(coordinates: route.points, padding: const EdgeInsets.all(48))),
                child: const Icon(Icons.alt_route),
              ),
            ]),
          ),
          if (f == null)
            const Positioned(
              left: 12,
              bottom: 12,
              child: Card(child: Padding(padding: EdgeInsets.all(8), child: Text('No GPS yet. Long-press the map to pin a position.'))),
            ),
        ]);
      },
    );
  }
}
