import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'dem.dart';
import 'geo_math.dart';

enum PoiType { trailhead, exit, water, help, shelter }

class Poi {
  final String name;
  final PoiType type;
  final double lat, lon;
  final double? elev;
  final int node; // nearest trail-graph node, -1 if none within 400 m
  const Poi(this.name, this.type, this.lat, this.lon, this.elev, this.node);

  LatLng get latLng => LatLng(lat, lon);

  /// Trailheads, road access and entrance stations all count as a way out.
  bool get isWayOut => type == PoiType.trailhead || type == PoiType.exit;
}

class TrailEdge {
  final int a, b, way;
  final double length, up, down;
  final List<double> geom; // interior points, flat [lat, lon, ...]
  const TrailEdge(this.a, this.b, this.length, this.up, this.down, this.way, this.geom);
}

class TrailWay {
  final String name, kind, sac;
  const TrailWay(this.name, this.kind, this.sac);
  bool get isTrail => kind == 'trail';
}

class TrailGraph {
  final Float64List nodeLat, nodeLon, nodeElev;
  final List<TrailEdge> edges;
  final List<TrailWay> ways;
  final List<List<int>> adjacency; // node -> edge indices
  final Map<int, List<int>> _cells; // spatial grid for snapping

  TrailGraph(this.nodeLat, this.nodeLon, this.nodeElev, this.edges, this.ways, this.adjacency, this._cells);

  static const double cell = 0.01;
  static int _key(double lat, double lon) => (lat / cell).floor() * 100000 + (lon / cell).floor();

  int get nodeCount => nodeLat.length;

  /// Nearest graph node and its distance, searching the 3x3 neighbouring cells.
  (int, double) nearestNode(double lat, double lon) {
    var best = -1;
    var bestD = double.infinity;
    final ky = (lat / cell).floor(), kx = (lon / cell).floor();
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        for (final i in _cells[(ky + dy) * 100000 + kx + dx] ?? const <int>[]) {
          final d = haversineM(lat, lon, nodeLat[i], nodeLon[i]);
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        }
      }
    }
    return (best, bestD);
  }

  /// Polyline of one edge travelled from [from].
  List<LatLng> edgePoints(int edgeIndex, int from) {
    final e = edges[edgeIndex];
    final pts = <LatLng>[LatLng(nodeLat[e.a], nodeLon[e.a])];
    for (var i = 0; i + 1 < e.geom.length; i += 2) {
      pts.add(LatLng(e.geom[i], e.geom[i + 1]));
    }
    pts.add(LatLng(nodeLat[e.b], nodeLon[e.b]));
    return from == e.a ? pts : pts.reversed.toList();
  }
}

/// All bundled geo data, parsed off the UI isolate.
class GeoData {
  final List<Poi> pois;
  final TrailGraph graph;
  final Dem dem;
  GeoData(this.pois, this.graph, this.dem);

  static Future<GeoData> load() async {
    final poisRaw = await rootBundle.loadString('assets/geo/pois.json');
    final trailsRaw = await rootBundle.loadString('assets/geo/trails.json');
    final dem = await Dem.load();
    final parsed = await compute(_parse, [poisRaw, trailsRaw]);
    return GeoData(parsed.$1, parsed.$2, dem);
  }

  static (List<Poi>, TrailGraph) _parse(List<String> raw) {
    final pois = [
      for (final p in jsonDecode(raw[0]) as List)
        Poi(
          (p['name'] as String?) ?? 'Unnamed',
          PoiType.values.byName(p['type'] as String),
          (p['lat'] as num).toDouble(),
          (p['lon'] as num).toDouble(),
          (p['elev'] as num?)?.toDouble(),
          (p['node'] as num?)?.toInt() ?? -1,
        ),
    ];
    final t = jsonDecode(raw[1]) as Map<String, dynamic>;
    final nodes = t['nodes'] as List;
    final lat = Float64List(nodes.length), lon = Float64List(nodes.length), elev = Float64List(nodes.length);
    final cells = <int, List<int>>{};
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i] as List;
      lat[i] = (n[0] as num).toDouble();
      lon[i] = (n[1] as num).toDouble();
      elev[i] = (n[2] as num).toDouble();
      cells.putIfAbsent(TrailGraph._key(lat[i], lon[i]), () => []).add(i);
    }
    final geom = (t['geom'] as Map<String, dynamic>);
    final edgesRaw = t['edges'] as List;
    final adjacency = List.generate(nodes.length, (_) => <int>[]);
    final edges = <TrailEdge>[];
    for (var i = 0; i < edgesRaw.length; i++) {
      final e = edgesRaw[i] as List;
      final g = (geom['$i'] as List?)?.map((v) => (v as num).toDouble()).toList() ?? const <double>[];
      final edge = TrailEdge(e[0] as int, e[1] as int, (e[2] as num).toDouble(), (e[3] as num).toDouble(),
          (e[4] as num).toDouble(), e[5] as int, g);
      edges.add(edge);
      adjacency[edge.a].add(i);
      adjacency[edge.b].add(i);
    }
    final ways = [
      for (final w in t['ways'] as List)
        TrailWay((w['name'] as String?) ?? '', (w['kind'] as String?) ?? 'trail', (w['sac'] as String?) ?? ''),
    ];
    return (pois, TrailGraph(lat, lon, elev, edges, ways, adjacency, cells));
  }

  /// Nearest POIs of a type, closest first.
  List<(Poi, double)> nearest(PoiType? type, double lat, double lon, {int limit = 3, bool Function(Poi)? where}) {
    final list = <(Poi, double)>[];
    for (final p in pois) {
      if (type != null && p.type != type) continue;
      if (where != null && !where(p)) continue;
      list.add((p, haversineM(lat, lon, p.lat, p.lon)));
    }
    list.sort((a, b) => a.$2.compareTo(b.$2));
    return list.take(limit).toList();
  }
}
