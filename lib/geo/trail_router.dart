import 'dart:collection';

import 'package:latlong2/latlong.dart';

import 'geo_data.dart';
import 'geo_math.dart';

class RouteResult {
  final Poi target;
  final List<LatLng> points;
  final double distanceM; // including the walk to the first trail node
  final double ascentM, descentM;
  final Duration walkTime;
  final double initialBearing;
  final List<String> trailNames; // in order, de-duplicated
  final bool offTrail; // true = straight-line fallback

  const RouteResult({
    required this.target,
    required this.points,
    required this.distanceM,
    required this.ascentM,
    required this.descentM,
    required this.walkTime,
    required this.initialBearing,
    required this.trailNames,
    required this.offTrail,
  });

  String get viaText => trailNames.isEmpty ? '' : ' via ${trailNames.take(2).join(' then ')}';
}

/// Dijkstra over the trail graph from the user's position to the nearest way out
/// (trailhead / road access), with an uphill penalty.
class TrailRouter {
  final GeoData geo;
  TrailRouter(this.geo);

  static const double maxSnapM = 500;
  static const double maxSearchM = 40000;

  /// [target] restricts the destination to POIs passing the filter; default: any way out.
  RouteResult? routeOut(double lat, double lon, {bool Function(Poi)? target}) {
    final g = geo.graph;
    final want = target ?? (Poi p) => p.isWayOut;
    final (start, snapD) = g.nearestNode(lat, lon);
    if (start < 0 || snapD > maxSnapM) return _straightLine(lat, lon, want);

    // destination node -> poi
    final goals = <int, Poi>{};
    for (final p in geo.pois) {
      if (p.node >= 0 && want(p)) goals.putIfAbsent(p.node, () => p);
    }
    if (goals.isEmpty) return _straightLine(lat, lon, want);

    final n = g.nodeCount;
    final dist = <int, double>{start: 0};
    final prevEdge = <int, int>{};
    final done = HashSet<int>();
    final heap = SplayTreeSet<(double, int)>((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    heap.add((0, start));
    int? reached;
    while (heap.isNotEmpty) {
      final cur = heap.first;
      heap.remove(cur);
      final u = cur.$2;
      if (!done.add(u)) continue;
      if (goals.containsKey(u)) {
        reached = u;
        break;
      }
      if (cur.$1 > maxSearchM * 2) break;
      for (final ei in g.adjacency[u]) {
        final e = g.edges[ei];
        final v = e.a == u ? e.b : e.a;
        if (v < 0 || v >= n || done.contains(v)) continue;
        final up = e.a == u ? e.up : e.down;
        // cost: length plus 8 m of effort per metre climbed (≈ Naismith), roads slightly preferred
        final roadBonus = g.ways[e.way].isTrail ? 1.0 : 0.9;
        final cost = cur.$1 + (e.length + up * 8.0) * roadBonus;
        if (cost < (dist[v] ?? double.infinity)) {
          dist[v] = cost;
          prevEdge[v] = ei;
          heap.add((cost, v));
        }
      }
    }
    if (reached == null) return _straightLine(lat, lon, want);

    // walk back
    final edgePath = <int>[];
    var node = reached;
    while (node != start) {
      final ei = prevEdge[node]!;
      edgePath.add(ei);
      final e = g.edges[ei];
      node = e.a == node ? e.b : e.a;
    }
    final pts = <LatLng>[LatLng(lat, lon)];
    var length = snapD, ascent = 0.0, descent = 0.0;
    final names = <String>[];
    var at = start;
    for (final ei in edgePath.reversed) {
      final e = g.edges[ei];
      pts.addAll(g.edgePoints(ei, at));
      length += e.length;
      ascent += e.a == at ? e.up : e.down;
      descent += e.a == at ? e.down : e.up;
      final name = g.ways[e.way].name;
      if (name.isNotEmpty && (names.isEmpty || names.last != name)) names.add(name);
      at = e.a == at ? e.b : e.a;
    }
    final firstAhead = pts.length > 2 ? pts[2] : pts.last;
    return RouteResult(
      target: goals[reached]!,
      points: pts,
      distanceM: length,
      ascentM: ascent,
      descentM: descent,
      walkTime: naismith(length, ascent),
      initialBearing: bearingDeg(lat, lon, firstAhead.latitude, firstAhead.longitude),
      trailNames: names.toSet().toList(),
      offTrail: false,
    );
  }

  RouteResult? _straightLine(double lat, double lon, bool Function(Poi) want) {
    final near = geo.nearest(null, lat, lon, limit: 1, where: want);
    if (near.isEmpty) return null;
    final (p, d) = near.first;
    final e0 = geo.dem.elevation(lat, lon) ?? 0;
    final e1 = p.elev ?? e0;
    final up = (e1 - e0).clamp(0, double.infinity).toDouble();
    return RouteResult(
      target: p,
      points: [LatLng(lat, lon), p.latLng],
      distanceM: d,
      ascentM: up,
      descentM: (e0 - e1).clamp(0, double.infinity).toDouble(),
      walkTime: naismith(d * 1.4, up, paceFactor: 1.6), // cross-country is slower
      initialBearing: bearingDeg(lat, lon, p.lat, p.lon),
      trailNames: const [],
      offTrail: true,
    );
  }
}
