import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../geo/map_pack.dart';
import '../geo/nps_layers.dart';
import '../location/location_service.dart';
import 'map_layers.dart';
import 'map_search.dart';
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

const _streamColor = kStreamColor;

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
  int _zoomBucket = 14;
  bool _parkMap = false; // official NPS park map image under our layers
  bool _notesOpen = false; // "Map notes here" card expanded
  bool _loaded = false;
  final Map<int, List<Marker>> _markerCache = {};
  List<LatLng>? _pendingFit;
  bool _mapReady = false;

  static const _valley = LatLng(37.7456, -119.5936);

  Assistant get a => widget.assistant;

  @override
  void initState() {
    super.initState();
    _loaded = a.geo != null && a.nps != null;
    a.addListener(_onAssistant);
    a.mapFocus.addListener(_onFocus);
    // opened from a chat mini map: show that route once the map is laid out
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocus());
  }

  @override
  void dispose() {
    a.removeListener(_onAssistant);
    a.mapFocus.removeListener(_onFocus);
    super.dispose();
  }

  /// The map only rebuilds once, when its data arrives: assistant chatter (streamed tokens,
  /// speaking state) must not rebuild 20k polylines.
  void _onAssistant() {
    if (!_loaded && a.geo != null && a.nps != null) setState(() => _loaded = true);
  }

  void _onFocus() {
    final r = a.mapFocus.value;
    if (r == null || !mounted) return;
    a.mapFocus.value = null;
    a.activeRoute.value = r;
    _pendingFit = r.points;
    _fitPending();
  }

  void _fitPending() {
    final pts = _pendingFit;
    if (pts == null || !_mapReady) return;
    _pendingFit = null;
    _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.fromLTRB(48, 160, 48, 48)));
  }

  // ---------- markers ----------

  List<Marker> _markersFor(NpsLayers nps, int zoom) => _markerCache.putIfAbsent(zoom, () {
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
              onTap: () => _details(p.name, p.kind, s.icon, s.color, p.lat, p.lon, p.description),
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
      });

  (double, double)? _nearbyFor;
  List<Marker> _nearbyCache = const [];

  /// The nearest water, ways out and help around the hiker, always visible and labelled.
  List<Marker> _nearby(Fix? f) {
    final geo = a.geo;
    if (f == null || geo == null) return const [];
    final key = (f.lat, f.lon);
    if (_nearbyFor == key) return _nearbyCache;
    _nearbyFor = key;
    final picks = <(Poi, double)>[];
    void take(PoiType? t, int n, {bool Function(Poi)? where}) {
      final seen = <String>{};
      for (final hit in geo.nearest(t, f.lat, f.lon, limit: 40, where: where)) {
        if (hit.$2 > 6000 || picks.length > 12) break;
        if (!seen.add(hit.$1.name)) continue; // river samples share a name
        picks.add(hit);
        if (seen.length >= n) break;
      }
    }

    take(PoiType.water, 3);
    take(null, 3, where: (p) => p.isWayOut);
    take(PoiType.help, 2);
    take(PoiType.shelter, 1);
    _nearbyCache = [
      for (final (p, d) in picks)
        Marker(
          point: p.latLng,
          width: 150,
          height: 58,
          alignment: const Alignment(0, -0.6),
          child: GestureDetector(
            onTap: () => _details(p.name, _poiKind(p.type), _poiIcon(p.type), _poiColor(p.type), p.lat, p.lon, null),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _poiColor(p.type), width: 2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_poiIcon(p.type), size: 14, color: _poiColor(p.type)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text('${p.name} · ${formatDistance(d)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: label(kInk, size: 10)),
                  ),
                ]),
              ),
              Container(width: 2, height: 10, color: _poiColor(p.type)),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _poiColor(p.type), border: Border.all(color: kCard, width: 2)),
              ),
            ]),
          ),
        ),
    ];
    return _nearbyCache;
  }

  static IconData _poiIcon(PoiType t) => switch (t) {
        PoiType.water => Icons.water_drop,
        PoiType.trailhead => Icons.hiking,
        PoiType.exit => Icons.exit_to_app,
        PoiType.help => Icons.local_hospital,
        PoiType.shelter => Icons.cabin,
      };

  static Color _poiColor(PoiType t) => switch (t) {
        PoiType.water => kWater,
        PoiType.trailhead || PoiType.exit => kMoss,
        PoiType.help => kClay,
        PoiType.shelter => kTrail,
      };

  static String _poiKind(PoiType t) => switch (t) {
        PoiType.water => 'water',
        PoiType.trailhead => 'trailhead (way out)',
        PoiType.exit => 'road access (way out)',
        PoiType.help => 'help',
        PoiType.shelter => 'shelter',
      };

  // ---------- walked so far ----------

  int _walkedFor = -1;
  (double, double) _walked = (0, 0); // metres, ascent

  (double, double) _walkedStats() {
    final crumbs = widget.location.breadcrumbs;
    if (crumbs.length == _walkedFor) return _walked;
    _walkedFor = crumbs.length;
    var d = 0.0, up = 0.0;
    double? prev;
    for (var i = 0; i < crumbs.length; i++) {
      if (i > 0) d += haversineM(crumbs[i - 1].lat, crumbs[i - 1].lon, crumbs[i].lat, crumbs[i].lon);
      final e = a.geo?.dem.elevation(crumbs[i].lat, crumbs[i].lon);
      if (e != null && prev != null && e > prev) up += e - prev;
      if (e != null) prev = e;
    }
    return _walked = (d, up);
  }

  // ---------- details sheet ----------

  void _details(String name, String kind, IconData icon, Color color, double lat, double lon, String? description,
      {List<Advisory>? notes}) {
    final f = widget.location.fix;
    final elev = a.geo?.dem.elevation(lat, lon);
    final mapNotes = notes ?? a.mapPack?.guidanceAt(lat, lon) ?? const <Advisory>[];
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              kind[0].toUpperCase() + kind.substring(1),
              if (elev != null) '${elev.round()} m elevation',
              if (f != null)
                '${formatDistance(haversineM(f.lat, f.lon, lat, lon))} ${compassWord(bearingDeg(f.lat, f.lon, lat, lon))} of you',
            ].join(' · '),
            style: const TextStyle(color: kInkMuted),
          ),
          if (description != null) ...[
            const SizedBox(height: 10),
            Text(description.replaceAll(RegExp(r'<[^>]+>'), ''), style: const TextStyle(height: 1.4)),
          ],
          if (mapNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('PARK MAP NOTES', style: label(kInkMuted, size: 11)),
            const SizedBox(height: 4),
            for (final n in mapNotes.take(4)) _NoteRow(n),
          ],
          const SizedBox(height: 16),
          Row(children: [
            if (f != null)
              FilledButton.icon(
                icon: const Icon(Icons.directions_walk),
                label: const Text('Route here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  final r = a.router?.routeToPlace(f.lat, f.lon, name, lat, lon);
                  a.activeRoute.value = r;
                  if (r != null) {
                    _pendingFit = r.points;
                    _fitPending();
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
                    : ' It is ${spokenDistance(haversineM(f.lat, f.lon, lat, lon))} to the ${compassWord(bearingDeg(f.lat, f.lon, lat, lon))}.';
                Navigator.pop(ctx); // the global "Stop speaking" bar is then visible
                a.speak('$name, $kind.$dist ${description?.replaceAll(RegExp(r'<[^>]+>'), '') ?? ''}', source: 'map');
              },
            ),
          ]),
        ]),
      ),
    );
  }

  // ---------- park map: search + printed notes ----------

  (double, double)? _notesFor;
  List<Advisory> _notesCache = const [];

  /// Printed park-map notes that apply where the hiker is (closures first).
  List<Advisory> _notesHere(Fix? f) {
    final pack = a.mapPack;
    if (f == null || pack == null) return const [];
    final key = (f.lat, f.lon);
    if (_notesFor != key) {
      _notesFor = key;
      _notesCache = pack.guidanceAt(f.lat, f.lon);
    }
    return _notesCache;
  }

  void _onSearchPick(MapSearchResult r) {
    _map.move(r.location, 15);
    final place = r.parkPlace;
    _details(r.name, r.kind, Icons.place, kMoss, r.location.latitude, r.location.longitude, null,
        notes: place == null ? null : a.mapPack!.guidanceFor(place));
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final geo = a.geo;
    final nps = a.nps;
    if (!_loaded || geo == null || nps == null) return const Center(child: Text('Loading map…'));
    final c = MapLayerCache.of(nps);
    final z = _zoomBucket;
    final bounds = LatLngBounds(geo.dem.hillshadeNorthWest, geo.dem.hillshadeSouthEast);
    final loc = widget.location;
    final start = loc.fix;
    final live = Listenable.merge([loc, a.activeRoute]);

    return Stack(children: [
      RepaintBoundary(
        child: FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: start == null ? _valley : LatLng(start.lat, start.lon),
            initialZoom: 15,
            minZoom: 9,
            maxZoom: 18,
            backgroundColor: kGround,
            cameraConstraint: CameraConstraint.contain(bounds: bounds),
            onMapReady: () {
              _mapReady = true;
              _fitPending();
            },
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              enableMultiFingerGestureRace: true,
            ),
            onPositionChanged: (camera, _) {
              final b = camera.zoom.floor();
              if (b != _zoomBucket) setState(() => _zoomBucket = b);
            },
            onLongPress: (_, p) {
              loc.simulate(p.latitude, p.longitude);
              a.activeRoute.value = null;
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
            if (_parkMap && a.mapPack != null)
              OverlayImageLayer(overlayImages: [
                OverlayImage(
                  bounds: LatLngBounds(a.mapPack!.imageBounds.$1, a.mapPack!.imageBounds.$2),
                  imageProvider: const AssetImage('assets/park_map/map.jpg'),
                ),
              ]),
            PolygonLayer(polygons: c.park),
            if (z >= 11) PolygonLayer(polygons: c.water),
            if (z >= 13) PolylineLayer(polylines: c.streams),
            if (z >= 14) PolygonLayer(polygons: c.parking),
            if (z >= 15) PolygonLayer(polygons: c.buildings),
            PolylineLayer(polylines: c.roads),
            if (z >= 11) PolylineLayer(polylines: c.trails),
            // ---- live layers: only these rebuild when the position or route changes ----
            ListenableBuilder(
              listenable: loc,
              builder: (_, _) {
                final crumbs = [for (final b in loc.breadcrumbs) LatLng(b.lat, b.lon)];
                return crumbs.length < 2
                    ? const SizedBox.shrink()
                    : PolylineLayer(polylines: [
                        Polyline(points: crumbs, color: kCard, strokeWidth: 7),
                        Polyline(points: crumbs, color: kWater, strokeWidth: 4),
                      ]);
              },
            ),
            ListenableBuilder(
              listenable: live,
              builder: (_, _) {
                final route = a.activeRoute.value ?? Situation.build(loc, geo, a.router).routeOut;
                return route == null
                    ? const SizedBox.shrink()
                    : PolylineLayer(polylines: [
                        Polyline(points: route.points, color: kCard, strokeWidth: 9),
                        Polyline(
                          points: route.points,
                          color: kMoss,
                          strokeWidth: 5,
                          pattern: route.offTrail ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid(),
                        ),
                      ]);
              },
            ),
            MarkerLayer(markers: _markersFor(nps, z)),
            ListenableBuilder(
              listenable: live,
              builder: (_, _) {
                final f = loc.fix;
                final route = a.activeRoute.value ?? Situation.build(loc, geo, a.router).routeOut;
                final crumbs = loc.breadcrumbs;
                return MarkerLayer(markers: [
                  ..._nearby(f),
                  if (crumbs.length > 1)
                    Marker(
                      point: LatLng(crumbs.first.lat, crumbs.first.lon),
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.trip_origin, color: kWater, size: 24),
                    ),
                  if (route != null)
                    Marker(point: route.target.latLng, width: 40, height: 40, child: const Icon(Icons.flag_circle, color: kClay, size: 38)),
                  if (f != null)
                    Marker(
                      point: LatLng(f.lat, f.lon),
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: f.simulated ? kClay : kWater,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6)],
                        ),
                      ),
                    ),
                ]);
              },
            ),
            const SimpleAttributionWidget(source: Text('NPS Park Tiles · USGS · OpenStreetMap')),
          ],
        ),
      ),
      // ---- overlays ----
      Positioned(
        left: 12,
        right: 12,
        top: 12,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MapSearchBar(assistant: a, location: loc, onPick: _onSearchPick),
          ListenableBuilder(
          listenable: live,
          builder: (_, _) {
            final s = Situation.build(loc, geo, a.router);
            final custom = a.activeRoute.value;
            final route = custom ?? s.routeOut;
            final (walked, climbed) = _walkedStats();
            final crumbs = loc.breadcrumbs;
            final since = crumbs.length > 1 ? DateTime.now().difference(crumbs.first.time) : null;
            final here = _notesHere(loc.fix);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (loc.demoMode)
                Card(
                  color: const Color(0xFFFFDBCF),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(children: [
                      const Icon(Icons.science, color: kClay, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Demo hiker on the Mist Trail. Long-press the map to move.', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(onPressed: loc.clearSimulation, child: const Text('Use GPS')),
                    ]),
                  ),
                ),
              if (walked > 50)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      const Icon(Icons.timeline, color: kWater, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: 'Walked ${formatDistance(walked)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(
                            text: '${loc.trackStartName != null ? ' from ${loc.trackStartName}' : ''}'
                                ' · +${climbed.round()} m${since != null ? ' · ${formatDuration(since)}' : ''}',
                            style: const TextStyle(color: kInkMuted),
                          ),
                        ])),
                      ),
                    ]),
                  ),
                ),
              if (route != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(children: [
                      Icon(custom == null ? Icons.exit_to_app : Icons.flag_circle, color: custom == null ? kMoss : kClay),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${custom != null ? 'To' : 'Way out:'} ${route.target.name}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                          Text(
                            '${formatDistance(route.distanceM)} · +${route.ascentM.round()} m / -${route.descentM.round()} m · ~${formatDuration(route.walkTime)}'
                            ' · head ${compassShort(route.initialBearing)}${route.offTrail ? ' · off trail' : ''}',
                            style: const TextStyle(color: kInkMuted, fontSize: 12),
                          ),
                          if (s.untilSunset != null && !s.untilSunset!.isNegative && route.walkTime > s.untilSunset!)
                            const Text('Longer than the daylight left: plan for the night.', style: TextStyle(color: kClay)),
                        ]),
                      ),
                      if (custom != null)
                        IconButton(
                          tooltip: 'Back to way out',
                          onPressed: () => a.activeRoute.value = null,
                          icon: const Icon(Icons.close),
                        ),
                    ]),
                  ),
                ),
              if (here.isNotEmpty)
                Card(
                  color: here.first.note.severity == Severity.warning ? const Color(0xFFFFEDE6) : kCard,
                  child: InkWell(
                    onTap: () => setState(() => _notesOpen = !_notesOpen),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(Icons.report_outlined,
                              size: 18, color: here.first.note.severity == Severity.warning ? kClay : kInkMuted),
                          const SizedBox(width: 6),
                          Expanded(child: Text('PARK MAP NOTES HERE (${here.length})', style: label(kInk, size: 11))),
                          Icon(_notesOpen ? Icons.expand_less : Icons.expand_more, size: 18),
                        ]),
                        if (!_notesOpen)
                          Text(here.first.note.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))
                        else ...[
                          for (final n in here) _NoteRow(n),
                          const SizedBox(height: 4),
                          Text('PARK-WIDE', style: label(kInkMuted, size: 10)),
                          for (final n in a.mapPack?.parkWide ?? const <MapNote>[])
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(n.text, style: const TextStyle(fontSize: 12, color: kInkMuted)),
                            ),
                        ],
                      ]),
                    ),
                  ),
                ),
            ]);
          },
        ),
        ]),
      ),
      Positioned(
        right: 12,
        bottom: 28,
        child: Column(children: [
          if (a.mapPack != null) ...[
            FloatingActionButton.small(
              heroTag: 'parkmap',
              tooltip: _parkMap ? 'Hide the park map' : 'Show the official park map',
              backgroundColor: _parkMap ? kInk : null,
              foregroundColor: _parkMap ? kCard : null,
              onPressed: () => setState(() => _parkMap = !_parkMap),
              child: const Icon(Icons.layers),
            ),
            const SizedBox(height: 8),
          ],
          FloatingActionButton.small(
            heroTag: 'gps',
            tooltip: 'Use real GPS',
            onPressed: () async {
              loc.clearSimulation();
              final fix = await loc.fixNow();
              if (fix != null) _map.move(LatLng(fix.lat, fix.lon), 15);
            },
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'me',
            tooltip: 'Center on me',
            onPressed: () {
              final f = loc.fix;
              if (f != null) _map.move(LatLng(f.lat, f.lon), 15);
            },
            child: const Icon(Icons.center_focus_strong),
          ),
        ]),
      ),
    ]);
  }
}


/// One printed park-map note: closures and hazards in clay, information in ink.
class _NoteRow extends StatelessWidget {
  final Advisory a;
  const _NoteRow(this.a);

  @override
  Widget build(BuildContext context) {
    final warn = a.note.severity == Severity.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warn ? Icons.warning_amber : Icons.info_outline, size: 16, color: warn ? kClay : kInkMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: a.note.text, style: TextStyle(fontSize: 13, color: warn ? kInk : kInkMuted)),
            TextSpan(text: '  ${a.reason}', style: const TextStyle(fontSize: 11, color: kInkMuted)),
          ])),
        ),
      ]),
    );
  }
}
