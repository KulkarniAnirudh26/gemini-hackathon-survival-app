import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_math.dart';
import '../geo/nps_layers.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import 'theme.dart';

/// Offline NPS basemap (Park Tiles: trails, roads, water, buildings, park boundary, points of
/// interest) over a hillshade, with the route out, breadcrumbs and tap-for-details.
class MapScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const MapScreen({super.key, required this.assistant, required this.location});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _Style {
  final IconData icon;
  final Color color;
  final int minZoom;
  const _Style(this.icon, this.color, this.minZoom);
}

const _roadColor = Color(0xFF9E958A);
const _waterFill = Color(0xFFA9CCE3);
const _streamColor = Color(0xFF3E86BF);
const _parkFill = Color(0x1A66BB6A);
const _buildingFill = Color(0xFFB9A89E);
const _parkingFill = Color(0xFFD5DAD5);

_Style _styleFor(NpsPoint p) {
  switch (p.kind) {
    case 'trailhead':
      return const _Style(Icons.hiking, kClay, 11);
    case 'entrance station':
      return const _Style(Icons.flag, kMoss, 10);
    case 'ranger station':
    case 'first aid station':
      return const _Style(Icons.local_hospital, kClay, 11);
    case 'visitor center':
    case 'information':
      return const _Style(Icons.info, kClay, 11);
    case 'drinking water':
    case 'spring':
      return const _Style(Icons.water_drop, kWater, 12);
    case 'campground':
    case 'backcountry campsite':
      return const _Style(Icons.cabin, kInk, 12);
    case 'hut':
    case 'historic cabin':
    case 'shelter':
      return const _Style(Icons.house_siding, kInk, 12);
    case 'waterfall':
    case 'falls':
      return const _Style(Icons.waves, kWater, 12);
    case 'viewpoint':
      return const _Style(Icons.visibility, kTrail, 13);
    case 'parking lot':
      return const _Style(Icons.local_parking, kInkMuted, 14);
    case 'lodging':
    case 'store':
    case 'food service':
    case 'gas station':
      return const _Style(Icons.storefront, kInkMuted, 14);
    case 'restroom':
      return const _Style(Icons.wc, kInkMuted, 15);
    case 'bus stop / shuttle stop':
      return const _Style(Icons.directions_bus, kInkMuted, 15);
    case 'peak':
    case 'summit':
      return const _Style(Icons.landscape, kTrail, 12);
    case 'small lake':
    case 'lake':
    case 'reservoir':
      return const _Style(Icons.water, _streamColor, 13);
    default:
      return _Style(Icons.place, kInkMuted, p.isLabel ? 13 : 14);
  }
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  int _zoomBucket = 13;
  RouteResult? _custom; // route to a tapped place (overrides the route out)
  NpsLayers? _builtFor;
  late List<Polyline> _trails, _roads, _streams;
  late List<Polygon> _park, _water, _parking, _buildings;

  static const _valley = LatLng(37.7456, -119.5936);

  void _build(NpsLayers nps) {
    if (identical(_builtFor, nps)) return;
    _builtFor = nps;
    List<Polyline> lines(String k, Color c, double w) =>
        [for (final pts in nps.lines[k] ?? const <List<LatLng>>[]) Polyline(points: pts, color: c, strokeWidth: w)];
    List<Polygon> polys(String k, Color c) =>
        [for (final pts in nps.polygons[k] ?? const <List<LatLng>>[]) Polygon(points: pts, color: c, borderStrokeWidth: 0)];
    _trails = lines('trail', kTrail, 1.8);
    _roads = lines('road', _roadColor, 2.6);
    _streams = lines('stream', _streamColor.withValues(alpha: 0.6), 1.0);
    _park = polys('park', _parkFill);
    _water = polys('water', _waterFill);
    _parking = polys('parking', _parkingFill);
    _buildings = polys('building', _buildingFill);
  }

  List<Marker> _markers(NpsLayers nps, int zoom) {
    final out = <Marker>[];
    for (final p in nps.points) {
      final s = _styleFor(p);
      if (zoom < s.minZoom) continue;
      final showName = p.isLabel || zoom >= s.minZoom + 1 || s.minZoom <= 11 && zoom >= 12;
      out.add(Marker(
        point: p.latLng,
        width: showName ? 130 : 30,
        height: showName ? 46 : 30,
        alignment: showName ? const Alignment(0, 0.35) : Alignment.center,
        child: GestureDetector(
          onTap: () => _details(p),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!p.isLabel || zoom >= 14) Icon(s.icon, color: s.color, size: p.isLabel ? 14 : 20),
            if (showName)
              Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: p.isLabel ? 11 : 10,
                  color: p.isLabel ? s.color : kInk,
                  fontStyle: p.isLabel && p.kind.contains('lake') ? FontStyle.italic : FontStyle.normal,
                  fontWeight: p.isLabel ? FontWeight.w600 : FontWeight.w500,
                  shadows: const [Shadow(blurRadius: 3, color: kCard), Shadow(blurRadius: 6, color: kCard)],
                ),
              ),
          ]),
        ),
      ));
    }
    return out;
  }

  void _details(NpsPoint p) {
    final a = widget.assistant;
    final f = widget.location.fix;
    final elev = a.geo?.dem.elevation(p.lat, p.lon);
    final s = _styleFor(p);
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(s.icon, color: s.color),
            const SizedBox(width: 8),
            Expanded(child: Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              p.kind[0].toUpperCase() + p.kind.substring(1),
              if (elev != null) '${elev.round()} m elevation',
              if (f != null)
                '${formatDistance(haversineM(f.lat, f.lon, p.lat, p.lon))} ${compassWord(bearingDeg(f.lat, f.lon, p.lat, p.lon))} of you',
            ].join(' · '),
            style: const TextStyle(color: kInkMuted),
          ),
          if (p.description != null) ...[
            const SizedBox(height: 10),
            Text(p.description!.replaceAll(RegExp(r'<[^>]+>'), ''), style: const TextStyle(height: 1.4)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            if (f != null)
              FilledButton.icon(
                icon: const Icon(Icons.alt_route),
                label: const Text('Route here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  final r = a.router?.routeToPlace(f.lat, f.lon, p.name, p.lat, p.lon);
                  setState(() => _custom = r);
                  if (r != null) {
                    _map.fitCamera(CameraFit.coordinates(coordinates: r.points, padding: const EdgeInsets.all(56)));
                  }
                },
              ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.volume_up),
              label: const Text('Read aloud'),
              onPressed: () {
                final dist = f == null
                    ? ''
                    : ' It is ${spokenDistance(haversineM(f.lat, f.lon, p.lat, p.lon))} to the ${compassWord(bearingDeg(f.lat, f.lon, p.lat, p.lon))}.';
                a.ai.speak('${p.name}, ${p.kind}.$dist ${p.description?.replaceAll(RegExp(r'<[^>]+>'), '') ?? ''}');
              },
            ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.location]),
      builder: (context, _) {
        final geo = widget.assistant.geo;
        final nps = widget.assistant.nps;
        if (geo == null || nps == null) return const Center(child: Text('Loading map…'));
        _build(nps);
        final s = Situation.build(widget.location, geo, widget.assistant.router);
        final f = s.fix;
        final me = f == null ? null : LatLng(f.lat, f.lon);
        final crumbs = [for (final c in widget.location.breadcrumbs) LatLng(c.lat, c.lon)];
        final route = _custom ?? s.routeOut;
        final z = _zoomBucket;
        final bounds = LatLngBounds(geo.dem.hillshadeNorthWest, geo.dem.hillshadeSouthEast);
        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: me ?? _valley,
              initialZoom: 14,
              minZoom: 9,
              maxZoom: 17,
              backgroundColor: kGround,
              cameraConstraint: CameraConstraint.contain(bounds: bounds),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onPositionChanged: (camera, _) {
                final b = camera.zoom.floor();
                if (b != _zoomBucket) setState(() => _zoomBucket = b);
              },
              onLongPress: (_, p) {
                widget.location.simulate(p.latitude, p.longitude);
                setState(() => _custom = null);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Position pinned here. Tap the GPS button to use real GPS.')),
                );
              },
            ),
            children: [
              OverlayImageLayer(overlayImages: [
                // the hillshade is rendered dark; fade it over the light canvas
                OverlayImage(bounds: bounds, opacity: 0.35, imageProvider: const AssetImage('assets/geo/hillshade.png')),
              ]),
              PolygonLayer(polygons: _park),
              PolygonLayer(polygons: _water),
              if (z >= 12) PolylineLayer(polylines: _streams),
              if (z >= 14) PolygonLayer(polygons: _parking),
              if (z >= 15) PolygonLayer(polygons: _buildings),
              PolylineLayer(polylines: _roads),
              if (z >= 11) PolylineLayer(polylines: _trails),
              if (crumbs.length > 1)
                PolylineLayer(polylines: [
                  Polyline(points: crumbs, color: kWater, strokeWidth: 2.5, pattern: StrokePattern.dotted()),
                ]),
              if (route != null)
                PolylineLayer(polylines: [
                  Polyline(points: route.points, color: kCard, strokeWidth: 8),
                  Polyline(
                    points: route.points,
                    color: kMoss,
                    strokeWidth: 5,
                    pattern: route.offTrail ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid(),
                  ),
                ]),
              MarkerLayer(markers: _markers(nps, z)),
              if (route != null)
                MarkerLayer(markers: [
                  Marker(point: route.target.latLng, width: 36, height: 36, child: const Icon(Icons.flag_circle, color: kMoss, size: 34)),
                ]),
              if (me != null)
                MarkerLayer(markers: [
                  Marker(
                    point: me,
                    width: 26,
                    height: 26,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: f!.simulated ? kClay : kWater,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
                ]),
              const SimpleAttributionWidget(source: Text('NPS Park Tiles · USGS · OpenStreetMap')),
            ],
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.location.demoMode)
                Card(
                  color: const Color(0xFFFFDBCF),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      const Icon(Icons.science, color: kClay, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Demo position: you are outside Yosemite. Long-press the map to move.',
                            style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(onPressed: widget.location.clearSimulation, child: const Text('Use GPS')),
                    ]),
                  ),
                ),
              if (route != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${_custom != null ? 'To' : 'Way out:'} ${route.target.name}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          Text(
                            '${formatDistance(route.distanceM)} · +${route.ascentM.round()} m / -${route.descentM.round()} m · ~${formatDuration(route.walkTime)}'
                            ' · head ${compassShort(route.initialBearing)}${route.offTrail ? ' · off trail' : ''}',
                            style: const TextStyle(color: kInkMuted),
                          ),
                          if (s.untilSunset != null && !s.untilSunset!.isNegative && route.walkTime > s.untilSunset!)
                            const Text('Longer than the daylight left: plan for the night.', style: TextStyle(color: kClay)),
                        ]),
                      ),
                      if (_custom != null)
                        IconButton(onPressed: () => setState(() => _custom = null), icon: const Icon(Icons.close)),
                    ]),
                  ),
                ),
            ]),
          ),
          Positioned(
            right: 12,
            bottom: 28,
            child: Column(children: [
              FloatingActionButton.small(
                heroTag: 'gps',
                tooltip: 'Use real GPS',
                onPressed: () async {
                  widget.location.clearSimulation();
                  final fix = await widget.location.fixNow();
                  if (fix != null) _map.move(LatLng(fix.lat, fix.lon), 14);
                },
                child: const Icon(Icons.my_location),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: 'me',
                tooltip: 'Center on me',
                onPressed: me == null ? null : () => _map.move(me, 15),
                child: const Icon(Icons.center_focus_strong),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: 'route',
                tooltip: 'Show route',
                onPressed: route == null
                    ? null
                    : () => _map.fitCamera(CameraFit.coordinates(coordinates: route.points, padding: const EdgeInsets.all(56))),
                child: const Icon(Icons.alt_route),
              ),
            ]),
          ),
        ]);
      },
    );
  }
}
