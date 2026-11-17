import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/compass_controller.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../geo/nps_layers.dart';
import '../geo/sun.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import '../map3d/map3d.dart';
import 'guide_screen.dart';
import 'map_layers.dart';
import 'theme.dart';

// Survival-mode colours: maximum contrast in direct sunlight.
const _cRoute = Color(0xFFE87A3E); // bold orange route
const _cRouteGlow = Color(0x66E87A3E);
const _cCrumbs = Color(0xFF00C9DB); // cyan breadcrumbs
const _cHiker = Color(0xFF1E88E5);
const _cSos = Color(0xFFD93025);
const _cGradeEasy = Color(0xFF2E8B57); // ≤8%
const _cGradeMid = Color(0xFFE8A020); // 8-20%
const _cGradeHard = Color(0xFFD94819); // >20%
const _cSunAmber = Color(0xFFE6A117);

/// The survival map: "YOU ARE HERE → WALK THIS WAY → TIME TO SAFETY".
///
/// Designed for a hiker lost in a forest: an unambiguous direction arrow that
/// rotates to the required bearing, a compass-locked heading-up mode, a sunset
/// countdown, gradient trail slope colours, and an off-trail escape bearing.
class MapScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const MapScreen({super.key, required this.assistant, required this.location});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  late final CompassController _compass;
  bool _compassLock = false; // rotate map to match device heading
  bool _ready = false;
  bool _dataLoaded = false;
  int _zoomBucket = 14;
  List<LatLng>? _pendingFit;

  // Active navigation target kind: wayOut | water | help | road
  String _targetMode = 'wayOut';
  bool _retrace = false; // walk back along breadcrumbs

  Assistant get a => widget.assistant;
  LocationService get loc => widget.location;

  @override
  void initState() {
    super.initState();
    _compass = CompassController();
    _dataLoaded = a.geo != null && a.nps != null;
    a.addListener(_onAssistant);
    a.mapFocus.addListener(_onFocus);
    _compass.addListener(_onHeading);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocus());
  }

  @override
  void dispose() {
    _compass.removeListener(_onHeading);
    _compass.dispose();
    a.removeListener(_onAssistant);
    a.mapFocus.removeListener(_onFocus);
    super.dispose();
  }

  void _onAssistant() {
    if (!_dataLoaded && a.geo != null && a.nps != null) {
      setState(() => _dataLoaded = true);
    }
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
    if (pts == null || !_ready) return;
    _pendingFit = null;
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.fromLTRB(40, 200, 40, 150),
      ),
    );
  }

  void _onHeading() {
    if (!_compassLock || !_ready) return;
    try {
      _map.rotate(-_compass.heading);
    } catch (_) {}
  }

  // ---------- route computation ----------
  RouteResult? _activeRoute(Situation s, GeoData geo) {
    if (_retrace) {
      final crumbs = loc.breadcrumbs;
      if (crumbs.length >= 2) {
        final pts = [for (final b in crumbs.reversed) LatLng(b.lat, b.lon)];
        var d = 0.0;
        for (var i = 1; i < pts.length; i++) {
          d += haversineM(
            pts[i - 1].latitude,
            pts[i - 1].longitude,
            pts[i].latitude,
            pts[i].longitude,
          );
        }
        final start = loc.trackStartName ?? 'start of your track';
        return RouteResult(
          target: Poi(
            start,
            PoiType.trailhead,
            pts.last.latitude,
            pts.last.longitude,
            null,
            -1,
          ),
          points: pts,
          distanceM: d,
          ascentM: 0,
          descentM: 0,
          walkTime: Duration(minutes: (d / 80).round()),
          initialBearing: bearingDeg(
            pts[0].latitude,
            pts[0].longitude,
            pts[1].latitude,
            pts[1].longitude,
          ),
          trailNames: const ['back along your breadcrumb trail'],
          offTrail: true,
        );
      }
    }
    if (a.activeRoute.value != null) return a.activeRoute.value;
    final f = loc.fix;
    if (f == null) return s.routeOut;
    switch (_targetMode) {
      case 'water':
        final hit = geo.nearest(PoiType.water, f.lat, f.lon).firstOrNull;
        return hit == null
            ? s.routeOut
            : a.router?.routeToPlace(
                f.lat,
                f.lon,
                hit.$1.name,
                hit.$1.lat,
                hit.$1.lon,
              );
      case 'help':
        final hit = geo.nearest(PoiType.help, f.lat, f.lon).firstOrNull;
        return hit == null
            ? s.routeOut
            : a.router?.routeToPlace(
                f.lat,
                f.lon,
                hit.$1.name,
                hit.$1.lat,
                hit.$1.lon,
              );
      case 'road':
        final hit = geo
            .nearest(null, f.lat, f.lon, where: (p) => p.type == PoiType.exit)
            .firstOrNull;
        return hit == null
            ? s.routeOut
            : a.router?.routeToPlace(
                f.lat,
                f.lon,
                hit.$1.name,
                hit.$1.lat,
                hit.$1.lon,
              );
      default:
        return s.routeOut;
    }
  }

  void _centerOnMe() {
    final f = loc.fix;
    if (f == null) return;
    _map.move(LatLng(f.lat, f.lon), math.max(_map.camera.zoom, 14.5));
  }

  void _zoomBy(double delta) => _map.move(
    _map.camera.center,
    (_map.camera.zoom + delta).clamp(9.0, 18.0),
  );

  // ---------- off-trail escape guidance ----------
  (double, double, String)? _offTrailGuide(GeoData geo, Fix f) {
    final (node, snap) = geo.graph.nearestNode(f.lat, f.lon);
    if (node < 0 || snap < 50) return null;
    final nlat = geo.graph.nodeLat[node], nlon = geo.graph.nodeLon[node];
    final b = bearingDeg(f.lat, f.lon, nlat, nlon);
    final e1 = geo.dem.elevation(f.lat, f.lon) ?? 0;
    final e2 = geo.dem.elevation(nlat, nlon) ?? 0;
    final grade = ((e2 - e1) / math.max(1, snap) * 100).round();
    final slope = grade > 15
        ? 'steep uphill, ~${grade.abs()}% grade'
        : grade < -15
        ? 'steep downhill'
        : 'gentle slope';
    return (snap, b, slope);
  }

  // ---------- slope-coded trail polylines ----------
  List<Polyline> _slopeCodedTrails(GeoData geo, List<Polyline> base) {
    final out = <Polyline>[];
    for (final poly in base) {
      if (poly.points.length < 2) continue;
      for (var i = 1; i < poly.points.length; i++) {
        final pa = poly.points[i - 1], pb = poly.points[i];
        final ea = geo.dem.elevation(pa.latitude, pa.longitude);
        final eb = geo.dem.elevation(pb.latitude, pb.longitude);
        final dist = haversineM(
          pa.latitude,
          pa.longitude,
          pb.latitude,
          pb.longitude,
        );
        Color c = _cGradeEasy;
        if (ea != null && eb != null && dist > 1) {
          final g = (eb - ea).abs() / dist * 100;
          if (g > 20) {
            c = _cGradeHard;
          } else if (g > 8) {
            c = _cGradeMid;
          }
        }
        out.add(
          Polyline(points: [pa, pb], color: c, strokeWidth: poly.strokeWidth),
        );
      }
    }
    return out;
  }

  // ---------- direction chevron markers along route ----------
  List<Marker> _routeChevrons(List<LatLng> pts) {
    final out = <Marker>[];
    double acc = 0;
    for (var i = 1; i < pts.length; i++) {
      final pa = pts[i - 1], pb = pts[i];
      final d = haversineM(
        pa.latitude,
        pa.longitude,
        pb.latitude,
        pb.longitude,
      );
      acc += d;
      if (acc > 300) {
        acc = 0;
        final mid = LatLng(
          (pa.latitude + pb.latitude) / 2,
          (pa.longitude + pb.longitude) / 2,
        );
        final bearing = bearingDeg(
          pa.latitude,
          pa.longitude,
          pb.latitude,
          pb.longitude,
        );
        out.add(
          Marker(
            point: mid,
            width: 18,
            height: 18,
            child: Transform.rotate(
              angle: bearing * math.pi / 180,
              child: const Icon(
                Icons.navigation,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        );
      }
    }
    return out;
  }

  // ---------- decluttered POI markers ----------
  List<Marker> _declutteredPois(NpsLayers nps, Fix? f, int zoom) {
    // At a useful navigation scale, show only the closest real destinations.
    // Place-name labels are plentiful and obscure the route when shown together.
    if (f == null || zoom < 13) return const [];
    final scored = [
      for (final p in nps.points.where((p) => !p.isLabel))
        (p, haversineM(f.lat, f.lon, p.lat, p.lon)),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final picks = scored.where((s) => s.$2 < 6000).take(5).map((s) => s.$1);
    return [
      for (final p in picks)
        Marker(
          point: p.latLng,
          width: 42,
          height: 42,
          child: GestureDetector(
            onTap: () =>
                _openDetails(p.name, p.kind, p.lat, p.lon, p.description),
            child: Tooltip(
              message: p.name,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: kCard,
                  shape: BoxShape.circle,
                  border: Border.all(color: _style(p.kind).color, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 5),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(
                  _style(p.kind).icon,
                  size: 19,
                  color: _style(p.kind).color,
                ),
              ),
            ),
          ),
        ),
    ];
  }

  static ({IconData icon, Color color}) _style(String kind) {
    switch (kind) {
      case 'drinking water':
      case 'spring':
      case 'waterfall':
        return (icon: Icons.water_drop, color: kWater);
      case 'trailhead':
      case 'entrance station':
        return (icon: Icons.flag, color: kMoss);
      case 'ranger station':
      case 'first aid station':
        return (icon: Icons.local_hospital, color: _cSos);
      case 'shelter':
      case 'hut':
      case 'campground':
        return (icon: Icons.cabin, color: kTrail);
      case 'viewpoint':
      case 'peak':
        return (icon: Icons.landscape, color: kInkMuted);
      default:
        return (icon: Icons.place, color: kInkMuted);
    }
  }

  // ---------- details sheet ----------
  void _openDetails(
    String name,
    String kind,
    double lat,
    double lon,
    String? desc,
  ) {
    final f = loc.fix;
    final geo = a.geo;
    final elev = geo?.dem.elevation(lat, lon);
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_style(kind).icon, color: _style(kind).color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                kind,
                if (elev != null) '${elev.round()} m',
                if (f != null)
                  '${formatDistance(haversineM(f.lat, f.lon, lat, lon))} · bearing ${bearingDeg(f.lat, f.lon, lat, lon).round()}° (${compassWord(bearingDeg(f.lat, f.lon, lat, lon))})',
              ].join(' · '),
              style: const TextStyle(color: kInkMuted, fontSize: 13),
            ),
            if (desc != null) ...[
              const SizedBox(height: 10),
              Text(
                desc.replaceAll(RegExp(r'<[^>]+>'), ''),
                style: const TextStyle(height: 1.4, fontSize: 14),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                if (f != null)
                  FilledButton.icon(
                    icon: const Icon(Icons.navigation),
                    label: const Text('Route here'),
                    onPressed: () {
                      Navigator.pop(context);
                      final r = a.router?.routeToPlace(
                        f.lat,
                        f.lon,
                        name,
                        lat,
                        lon,
                      );
                      a.activeRoute.value = r;
                      setState(() => _retrace = false);
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
                    final d = f == null
                        ? ''
                        : ' It is ${spokenDistance(haversineM(f.lat, f.lon, lat, lon))} to the ${compassWord(bearingDeg(f.lat, f.lon, lat, lon))}.';
                    Navigator.pop(context);
                    a.speak(
                      '$name, $kind.$d ${desc?.replaceAll(RegExp(r'<[^>]+>'), '') ?? ''}',
                      source: 'map',
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- build ----------
  @override
  Widget build(BuildContext context) {
    final geo = a.geo;
    final nps = a.nps;
    if (!_dataLoaded || geo == null || nps == null) {
      return const Scaffold(body: Center(child: Text('Loading offline map…')));
    }
    final c = MapLayerCache.of(nps);
    final bounds = LatLngBounds(
      geo.dem.hillshadeNorthWest,
      geo.dem.hillshadeSouthEast,
    );
    final s = Situation.build(loc, geo, a.router);
    final route = _activeRoute(s, geo);
    final f = loc.fix;
    final offTrail = f != null ? _offTrailGuide(geo, f) : null;
    final until = s.untilSunset;
    final daylightWarn =
        until != null &&
        !until.isNegative &&
        (until.inMinutes < 120 || (route != null && route.walkTime > until));
    final nightTime =
        s.sun.sunset != null && DateTime.now().isAfter(s.sun.sunset!);
    // MapController.camera is unavailable until FlutterMap attaches its first frame.
    final mapRotation = _ready ? _map.camera.rotation : 0.0;

    return Scaffold(
      backgroundColor: kGround,
      body: Stack(
        children: [
          // ---- the full-screen map ----
          RepaintBoundary(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: f == null
                    ? const LatLng(37.7456, -119.5936)
                    : LatLng(f.lat, f.lon),
                initialZoom: 14.5,
                minZoom: 9.0,
                maxZoom: 18.0,
                onMapReady: () {
                  _ready = true;
                  _fitPending();
                },
                onPositionChanged: (pos, _) {
                  final z = pos.zoom.round();
                  if (z != _zoomBucket) setState(() => _zoomBucket = z);
                },
                onLongPress: (_, ll) => loc.simulate(ll.latitude, ll.longitude),
              ),
              children: [
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(
                      bounds: bounds,
                      opacity: 0.55,
                      imageProvider: const AssetImage(
                        'assets/geo/hillshade.png',
                      ),
                    ),
                  ],
                ),
                PolygonLayer(polygons: c.park),
                if (_zoomBucket >= 11) PolygonLayer(polygons: c.water),
                if (_zoomBucket >= 13) PolylineLayer(polylines: c.streams),
                if (_zoomBucket >= 14) PolygonLayer(polygons: c.parking),
                if (_zoomBucket >= 15) PolygonLayer(polygons: c.buildings),
                PolylineLayer(polylines: c.roads),
                if (_zoomBucket >= 11)
                  PolylineLayer(polylines: _slopeCodedTrails(geo, c.trails)),
                ListenableBuilder(
                  listenable: loc,
                  builder: (_, _) {
                    final crumbs = [
                      for (final b in loc.breadcrumbs) LatLng(b.lat, b.lon),
                    ];
                    return crumbs.length < 2
                        ? const SizedBox.shrink()
                        : PolylineLayer(
                            polylines: [
                              Polyline(
                                points: crumbs,
                                color: Colors.white,
                                strokeWidth: 8,
                              ),
                              Polyline(
                                points: crumbs,
                                color: _cCrumbs,
                                strokeWidth: 4,
                              ),
                            ],
                          );
                  },
                ),
                if (route != null) ...[
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: route.points,
                        color: Colors.white,
                        strokeWidth: 14,
                      ),
                      Polyline(
                        points: route.points,
                        color: _cRouteGlow,
                        strokeWidth: 10,
                      ),
                      Polyline(
                        points: route.points,
                        color: _cRoute,
                        strokeWidth: 6,
                        pattern: route.offTrail
                            ? StrokePattern.dashed(segments: const [10, 8])
                            : const StrokePattern.solid(),
                      ),
                    ],
                  ),
                  MarkerLayer(markers: _routeChevrons(route.points)),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: route.target.latLng,
                        width: 44,
                        height: 44,
                        child: const Icon(
                          Icons.flag_rounded,
                          color: _cSos,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
                ],
                MarkerLayer(markers: _declutteredPois(nps, f, _zoomBucket)),
                if (f != null) ...[
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: LatLng(f.lat, f.lon),
                        radius: math.max(16, f.accuracy.clamp(16.0, 60.0)),
                        useRadiusInMeter: false,
                        color: _cHiker.withValues(alpha: 0.12),
                        borderColor: _cHiker.withValues(alpha: 0.4),
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(f.lat, f.lon),
                        width: 54,
                        height: 54,
                        child: _HikerMarker(
                          heading: _compass.heading,
                          simulated: f.simulated,
                          targetBearing: route?.initialBearing,
                        ),
                      ),
                    ],
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 210),
                  child: const SimpleAttributionWidget(
                    alignment: Alignment.bottomRight,
                    backgroundColor: Color(0xD9FFFDF8),
                    source: Text(
                      'NPS · USGS · offline terrain',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---- TOP SURVIVAL BANNER ----
          Positioned(
            left: 10,
            right: 10,
            top: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (loc.demoMode)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD9CC),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.science, color: _cSos, size: 16),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'DEMO: simulated hiker. Long-press the map to move.',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () {
                            loc.clearSimulation();
                          },
                          child: const Text(
                            'Use GPS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: _cSos,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                _SurvivalCard(
                  route: route,
                  compass: _compass,
                  mapRotation: mapRotation,
                  sunset: s.sun,
                  untilSunset: until,
                  nightTime: nightTime,
                  daylightWarn: daylightWarn,
                  targetMode: _targetMode,
                  retrace: _retrace,
                  onMode: (m) => setState(() {
                    _targetMode = m;
                    _retrace = false;
                    a.activeRoute.value = null;
                  }),
                  onRetraceToggle: () => setState(() => _retrace = !_retrace),
                ),
                if (offTrail != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3CD),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _cSunAmber),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: _cSos,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'OFF TRAIL — ${offTrail.$1.round()} m to trail on bearing ${offTrail.$2.round()}° · ${offTrail.$3}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ---- RIGHT ACTION RAIL ----
          Positioned(
            right: 10,
            bottom: 220,
            child: Column(
              children: [
                _RailButton(
                  tooltip: _compassLock ? 'Free map' : 'Compass lock',
                  icon: Icons.explore,
                  active: _compassLock,
                  color: _cRoute,
                  onTap: () => setState(() => _compassLock = !_compassLock),
                ),
                const SizedBox(height: 8),
                _RailButton(
                  tooltip: 'Center on me',
                  icon: Icons.my_location,
                  onTap: _centerOnMe,
                ),
                const SizedBox(height: 8),
                _RailButton(
                  tooltip: 'Zoom in',
                  icon: Icons.add,
                  onTap: () => _zoomBy(1),
                ),
                const SizedBox(height: 8),
                _RailButton(
                  tooltip: 'Zoom out',
                  icon: Icons.remove,
                  onTap: () => _zoomBy(-1),
                ),
                const SizedBox(height: 8),
                _RailButton(
                  tooltip: 'Full offline 3D map',
                  icon: Icons.view_in_ar,
                  onTap: () => _open3D(),
                ),
              ],
            ),
          ),

          // ---- BOTTOM COMPASS + DRAWER ----
          Positioned(
            left: 10,
            right: 10,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CompassRoseBar(
                  compass: _compass,
                  targetBearing: route?.initialBearing,
                  locked: _compassLock,
                  onLock: () => setState(() => _compassLock = !_compassLock),
                ),
                const SizedBox(height: 8),
                _BottomBar(
                  onSos: () => _openSosSheet(s),
                  onAlternatives: () => _openAlternatives(geo, f, route),
                  onGuide: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GuideScreen(assistant: a),
                    ),
                  ),
                  onSpeakLocation: () => _speakLocation(geo, f),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _open3D() async {
    final ok = await Map3d.open();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '3D tiles unavailable. Build them with: build_android_assets.py --tiles --terrain --imagery',
          ),
        ),
      );
    }
  }

  void _speakLocation(GeoData geo, Fix? f) {
    if (f == null) {
      a.speak(
        'No GPS fix yet. Move to an open area with a clear view of the sky.',
        source: 'map',
      );
      return;
    }
    final elev = geo.dem.elevation(f.lat, f.lon)?.round();
    final near = geo.nearest(null, f.lat, f.lon, limit: 1).firstOrNull;
    final rel = near == null
        ? ''
        : ' About ${spokenDistance(near.$2)} ${compassWord(bearingDeg(f.lat, f.lon, near.$1.lat, near.$1.lon))} of ${near.$1.name}.';
    a.speak(
      'Position: latitude ${f.lat.toStringAsFixed(4)} degrees north, longitude ${(-f.lon).toStringAsFixed(4)} degrees west.${elev != null ? ' Elevation $elev meters.' : ''}$rel Accuracy ${f.accuracy.round()} meters.',
      source: 'map',
    );
  }

  void _openSosSheet(Situation s) {
    final f = loc.fix;
    final geo = a.geo;
    final elev = f == null ? null : geo?.dem.elevation(f.lat, f.lon)?.round();
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD9D9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.sos_rounded, color: _cSos, size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'EMERGENCY MODE',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: _cSos,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '1. Stop, sit down, breathe. You are more capable than you feel right now.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
            ),
            const SizedBox(height: 6),
            const Text(
              '2. If anyone is injured or missing, call 911 — calls roam onto other networks. With no bars, use Satellite SOS with a clear view of the sky.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              '3. Stay together, put on your warmest layers, and do not move in the dark unless you have a trail.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (f != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F3F3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Radio readout: ${f.lat.toStringAsFixed(4)}°N  ${(-f.lon).toStringAsFixed(4)}°W${elev != null ? ' · $elev m' : ''} · GPS ±${f.accuracy.round()} m',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: _cSos),
                    icon: const Icon(Icons.call),
                    label: const Text('Call 911'),
                    onPressed: () {
                      try {
                        launchUrl(Uri.parse('tel:911'));
                      } catch (_) {}
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Read location'),
                    onPressed: () {
                      Navigator.pop(context);
                      _speakLocation(geo!, f);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Tap the guide for first-aid instructions',
                style: TextStyle(color: kInkMuted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAlternatives(GeoData geo, Fix? f, RouteResult? current) {
    if (f == null) return;
    final exits = geo.nearest(
      null,
      f.lat,
      f.lon,
      limit: 12,
      where: (p) => p.isWayOut,
    );
    final water = geo.nearest(PoiType.water, f.lat, f.lon, limit: 4);
    final help = geo.nearest(PoiType.help, f.lat, f.lon, limit: 3);
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          children: [
            const Text(
              'WAYS OUT',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            for (final (p, d) in exits.take(4))
              _ExitTile(
                name: p.name,
                distanceM: d,
                bearing: bearingDeg(f.lat, f.lon, p.lat, p.lon),
                isCurrent: current != null && current.target.name == p.name,
                onTap: () {
                  Navigator.pop(context);
                  final r = a.router?.routeToPlace(
                    f.lat,
                    f.lon,
                    p.name,
                    p.lat,
                    p.lon,
                  );
                  a.activeRoute.value = r;
                  setState(() => _retrace = false);
                  if (r != null) {
                    _pendingFit = r.points;
                    _fitPending();
                  }
                },
              ),
            const SizedBox(height: 14),
            const Text(
              'NEARBY WATER — always filter or boil',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1,
                color: kWater,
              ),
            ),
            const SizedBox(height: 6),
            for (final (p, d) in water)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.water_drop, color: kWater),
                title: Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${formatDistance(d)} · bearing ${bearingDeg(f.lat, f.lon, p.lat, p.lon).round()}° (${compassWord(bearingDeg(f.lat, f.lon, p.lat, p.lon))})',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openDetails(p.name, 'water', p.lat, p.lon, null),
              ),
            const SizedBox(height: 10),
            const Text(
              'HELP / RANGER',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1,
                color: _cSos,
              ),
            ),
            const SizedBox(height: 6),
            for (final (p, d) in help)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.local_hospital, color: _cSos),
                title: Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${formatDistance(d)} · bearing ${bearingDeg(f.lat, f.lon, p.lat, p.lon).round()}°',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openDetails(p.name, 'help', p.lat, p.lon, null),
              ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Top survival card
// -----------------------------------------------------------------------------
class _SurvivalCard extends StatelessWidget {
  final RouteResult? route;
  final CompassController compass;
  final double mapRotation;
  final SunTimes? sunset;
  final Duration? untilSunset;
  final bool nightTime;
  final bool daylightWarn;
  final String targetMode;
  final bool retrace;
  final ValueChanged<String> onMode;
  final VoidCallback onRetraceToggle;

  const _SurvivalCard({
    required this.route,
    required this.compass,
    required this.mapRotation,
    required this.sunset,
    required this.untilSunset,
    required this.nightTime,
    required this.daylightWarn,
    required this.targetMode,
    required this.retrace,
    required this.onMode,
    required this.onRetraceToggle,
  });

  @override
  Widget build(BuildContext context) {
    final r = route;
    final bearing = r?.initialBearing ?? 0.0;
    final arrowAngle = ((bearing - mapRotation) % 360) * math.pi / 180;

    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: daylightWarn ? _cSunAmber : kLine,
          width: daylightWarn ? 2 : 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x30000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: daylightWarn ? _cSunAmber : _cRoute,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Transform.rotate(
                  angle: arrowAngle,
                  child: const Icon(
                    Icons.arrow_upward_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r == null
                          ? 'No route — find an open area for GPS'
                          : (retrace
                                ? 'RETRACE · ${r.target.name}'
                                : r.target.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    if (r != null)
                      Text(
                        '${formatDistance(r.distanceM)} · ~${formatDuration(r.walkTime)} · +${r.ascentM.round()} m / −${r.descentM.round()} m',
                        style: const TextStyle(fontSize: 12, color: kInkMuted),
                      ),
                  ],
                ),
              ),
              Text(
                r == null ? '' : compassWord(r.initialBearing),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                nightTime ? Icons.bedtime : Icons.wb_sunny_rounded,
                size: 15,
                color: nightTime ? _cSos : (daylightWarn ? _cSunAmber : kMoss),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  nightTime
                      ? 'Night — keep a light on and stay put unless following a trail'
                      : untilSunset != null
                      ? 'Sunset in ${formatDuration(untilSunset!)}${r != null && r.walkTime > untilSunset! ? ' · you will walk in the dark' : ''}'
                      : 'Daylight unknown (no GPS)',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: nightTime
                        ? _cSos
                        : (daylightWarn ? _cSunAmber : kMoss),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 11, color: kLine),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (k, label, icon) in [
                  ('wayOut', 'Way out', Icons.exit_to_app),
                  ('water', 'Water', Icons.water_drop),
                  ('help', 'Help', Icons.local_hospital),
                  ('road', 'Road', Icons.directions_car),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _ChipBtn(
                      label: label,
                      icon: icon,
                      active: !retrace && targetMode == k,
                      onTap: () => onMode(k),
                    ),
                  ),
                _ChipBtn(
                  label: 'Retrace',
                  icon: Icons.undo_rounded,
                  active: retrace,
                  color: _cCrumbs,
                  onTap: onRetraceToggle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final Color? color;
  final VoidCallback onTap;
  const _ChipBtn({
    required this.label,
    required this.icon,
    required this.active,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? _cRoute;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: active ? c : kInset,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? Colors.white : kInk),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: active ? Colors.white : kInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Compass rose bar
// -----------------------------------------------------------------------------
class _CompassRoseBar extends StatelessWidget {
  final CompassController compass;
  final double? targetBearing;
  final bool locked;
  final VoidCallback onLock;
  const _CompassRoseBar({
    required this.compass,
    required this.targetBearing,
    required this.locked,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: compass,
      builder: (_, _) {
        final h = compass.heading;
        final tb = targetBearing;
        int? delta;
        if (tb != null) {
          final raw = ((tb - h + 540) % 360) - 180;
          delta = raw.round();
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(color: Color(0x22000000), blurRadius: 8),
            ],
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: onLock,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: -h * math.pi / 180,
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: locked ? _cRoute : kOutline,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.topCenter,
                        child: Container(width: 4, height: 10, color: _cSos),
                      ),
                    ),
                    Text(
                      locked ? 'LOCK' : '',
                      style: const TextStyle(
                        fontSize: 7,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HEADING ${h.round()}° · ${compassWord(h)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (delta != null)
                      Text(
                        delta.abs() < 5
                            ? 'ON COURSE'
                            : (delta > 0
                                      ? 'Turn right $delta°'
                                      : 'Turn left ${(-delta)}°') +
                                  (tb != null
                                      ? ' · bearing ${tb.round()}°'
                                      : ''),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: delta.abs() < 10 ? kMoss : _cSunAmber,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: locked ? 'Free map' : 'Lock map to compass',
                icon: Icon(Icons.explore, color: locked ? _cRoute : kInkMuted),
                onPressed: onLock,
              ),
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Bottom bar: SOS / alternatives / guide / speak
// -----------------------------------------------------------------------------
class _BottomBar extends StatelessWidget {
  final VoidCallback onSos;
  final VoidCallback onAlternatives;
  final VoidCallback onGuide;
  final VoidCallback onSpeakLocation;
  const _BottomBar({
    required this.onSos,
    required this.onAlternatives,
    required this.onGuide,
    required this.onSpeakLocation,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _cSos,
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            icon: const Icon(Icons.warning_amber_rounded, size: 22),
            label: const Text(
              'SOS',
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5),
            ),
            onPressed: onSos,
          ),
        ),
        const SizedBox(width: 6),
        _IconBtn(
          icon: Icons.list_alt,
          tooltip: 'Ways out & water',
          onTap: onAlternatives,
        ),
        const SizedBox(width: 6),
        _IconBtn(
          icon: Icons.menu_book,
          tooltip: 'First-aid guide',
          onTap: onGuide,
        ),
        const SizedBox(width: 6),
        _IconBtn(
          icon: Icons.volume_up,
          tooltip: 'Read location aloud',
          onTap: onSpeakLocation,
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(color: Color(0x20000000), blurRadius: 6),
              ],
            ),
            child: Icon(icon, color: kInk),
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final Color? color;
  final VoidCallback onTap;
  const _RailButton({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? _cRoute;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: active ? c : kCard,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x30000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 20, color: active ? Colors.white : kInk),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Hiker marker: accuracy ring + bearing cone + pulsing dot
// -----------------------------------------------------------------------------
class _HikerMarker extends StatelessWidget {
  final double heading;
  final bool simulated;
  final double? targetBearing;
  const _HikerMarker({
    required this.heading,
    required this.simulated,
    this.targetBearing,
  });

  @override
  Widget build(BuildContext context) {
    final c = simulated ? _cSos : _cHiker;
    return CustomPaint(
      size: const Size(54, 54),
      painter: _HikerPainter(
        color: c,
        headingDeg: heading,
        targetBearing: targetBearing,
      ),
    );
  }
}

class _HikerPainter extends CustomPainter {
  final Color color;
  final double headingDeg;
  final double? targetBearing;
  _HikerPainter({
    required this.color,
    required this.headingDeg,
    this.targetBearing,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final cone = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final h = (headingDeg - 90) * math.pi / 180;
    final r = size.width / 2;
    final path = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: r),
        h - math.pi / 6,
        math.pi / 3,
        false,
      )
      ..close();
    canvas.drawPath(path, cone);
    final tb = targetBearing;
    if (tb != null) {
      final ta = (tb - 90) * math.pi / 180;
      final ray = Paint()
        ..color = _cRoute
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        center,
        center + Offset(math.cos(ta) * (r + 4), math.sin(ta) * (r + 4)),
        ray,
      );
    }
    canvas.drawCircle(center, 9, Paint()..color = Colors.white);
    canvas.drawCircle(center, 8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HikerPainter o) =>
      o.headingDeg != headingDeg ||
      o.targetBearing != targetBearing ||
      o.color != color;
}

// -----------------------------------------------------------------------------
// Exit alternative tile
// -----------------------------------------------------------------------------
class _ExitTile extends StatelessWidget {
  final String name;
  final double distanceM;
  final double bearing;
  final bool isCurrent;
  final VoidCallback onTap;
  const _ExitTile({
    required this.name,
    required this.distanceM,
    required this.bearing,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent ? const Color(0xFFFFECE0) : kInset,
          borderRadius: BorderRadius.circular(8),
          border: isCurrent ? Border.all(color: _cRoute) : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.exit_to_app,
              color: isCurrent ? _cRoute : kInkMuted,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: isCurrent ? _cRoute : kInk,
                ),
              ),
            ),
            Text(
              '${formatDistance(distanceM)} · ${bearing.round()}°',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            if (isCurrent) ...const [
              SizedBox(width: 6),
              Icon(Icons.check, size: 16, color: _cRoute),
            ],
          ],
        ),
      ),
    );
  }
}
