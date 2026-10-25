import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

// Offline place search and safety guidance from the official NPS park map (a GeoPDF), loaded
// from a map pack exported by tool/geopdf (`geopdf_locator.export`). Ported from PR #5's
// Kotlin `MapPack.kt` (Chengjiang Long); test/map_pack_test.dart checks it against the Python
// reference answers in test/fixtures/parity.json.

enum Severity { warning, info }

class MapNote {
  final int id;
  final String text;
  final Severity severity;
  final bool parkWide;
  final String? feature; // road or trail the note is about, e.g. "Tioga Road"
  final String? direction; // "east" in "closed east of this point"
  final LatLng? anchor; // where the note points on the map; null for park-wide notes
  const MapNote(this.id, this.text, this.severity, this.parkWide, this.feature, this.direction, this.anchor);
}

class Advisory {
  final MapNote note;
  final String reason;
  final double? distanceKm;
  const Advisory(this.note, this.reason, this.distanceKm);
}

class MapPlace {
  final String text;
  final LatLng location;
  final double pageX, pageY; // where the location was taken from on the page
  final double fontSize;
  final bool snapped; // anchored to a map symbol rather than the label's centre
  final bool viaLeader;
  final bool area; // all-caps area name ("TUOLUMNE MEADOWS")
  final String norm;
  final List<(int, String, double?)> _guidance; // (note index, reason, km), precomputed

  const MapPlace(this.text, this.location, this.pageX, this.pageY, this.fontSize, this.snapped, this.viaLeader,
      this.area, this.norm, this._guidance);
}

class PlaceHit {
  final MapPlace place;
  final bool exact;
  final double score;
  const PlaceHit(this.place, this.exact, this.score);
}

class _NotePath {
  final int path;
  final List<double>? section;
  const _NotePath(this.path, this.section);
}

class MapPack {
  static const supportedVersion = 1;

  final List<MapNote> notes;
  final List<MapPlace> places;
  final double pageWidth, pageHeight;
  final int imageWidth, imageHeight;
  final double pxPerPt;
  final String imageFile;

  final List<List<double>> _pageToMercator, _mercatorToPage;
  final double _radius;
  final double _kmPerPt, _corridorKm, _nearbyKm;
  final List<_Polyline> _paths;
  final List<List<_NotePath>> _notePaths;
  final List<(double, double)?> _noteXY;

  MapPack._(
    this.notes,
    this.places,
    this.pageWidth,
    this.pageHeight,
    this.imageWidth,
    this.imageHeight,
    this.pxPerPt,
    this.imageFile,
    this._pageToMercator,
    this._mercatorToPage,
    this._radius,
    this._kmPerPt,
    this._corridorKm,
    this._nearbyKm,
    this._paths,
    this._notePaths,
    this._noteXY,
  );

  /// The bundled Yosemite park map (assets/park_map/).
  static Future<MapPack> load() async => parse(await rootBundle.loadString('assets/park_map/mappack.json'));

  static MapPack parse(String jsonText) {
    final j = jsonDecode(jsonText) as Map<String, dynamic>;
    if (j['format'] != 'geopdf-mappack') throw ArgumentError('not a map pack: ${j['format']}');
    if (j['version'] != supportedVersion) throw ArgumentError('unsupported map pack version ${j['version']}');
    final georef = j['georef'] as Map<String, dynamic>;
    if (georef['projection'] != 'EPSG:3857') throw ArgumentError('unsupported projection ${georef['projection']}');

    double d(Object? v) => (v as num).toDouble();
    List<List<double>> matrix(Object? m) => [
          for (final row in m as List) [for (final v in row as List) d(v)],
        ];

    final rawNotes = j['notes'] as List;
    final notes = <MapNote>[];
    final notePaths = <List<_NotePath>>[];
    final noteXY = <(double, double)?>[];
    for (var i = 0; i < rawNotes.length; i++) {
      final n = rawNotes[i] as Map<String, dynamic>;
      final lat = n['lat'], lon = n['lon'];
      notes.add(MapNote(
        i,
        n['text'] as String,
        n['severity'] == 'warning' ? Severity.warning : Severity.info,
        n['scope'] == 'park',
        n['feature'] as String?,
        n['direction'] as String?,
        lat != null && lon != null ? LatLng(d(lat), d(lon)) : null,
      ));
      notePaths.add([
        for (final p in (n['paths'] as List? ?? const []))
          _NotePath(
            (p as Map)['path'] as int,
            (p['section'] as List?)?.map(d).toList(),
          ),
      ]);
      noteXY.add(n['x'] != null && n['y'] != null ? (d(n['x']), d(n['y'])) : null);
    }

    final places = [
      for (final l in j['labels'] as List)
        MapPlace(
          l['text'] as String,
          LatLng(d(l['lat']), d(l['lon'])),
          d(l['x']),
          d(l['y']),
          d(l['size']),
          l['snapped'] as bool,
          l['via_leader'] as bool,
          l['area'] as bool,
          l['norm'] as String,
          [
            for (final a in l['guidance'] as List)
              ((a as Map)['note'] as int, a['reason'] as String, (a['distance_km'] as num?)?.toDouble()),
          ],
        ),
    ];

    final paths = [
      for (final pts in j['paths'] as List) _Polyline([for (final p in pts as List) (d((p as List)[0]), d(p[1]))]),
    ];
    final page = j['page'] as Map<String, dynamic>;
    final image = j['image'] as Map<String, dynamic>;
    final gp = j['guidance_params'] as Map<String, dynamic>;
    return MapPack._(
      notes,
      places,
      d(page['width']),
      d(page['height']),
      image['width'] as int,
      image['height'] as int,
      d(image['px_per_pt']),
      image['file'] as String,
      matrix(georef['page_to_mercator']),
      matrix(georef['mercator_to_page']),
      d(georef['earth_radius_m']),
      d(gp['km_per_pt']),
      d(gp['corridor_km']),
      d(gp['nearby_km']),
      paths,
      notePaths,
      noteXY,
    );
  }

  /// Guidance printed for the whole park (permits, hazards, road-conditions phone number).
  List<MapNote> get parkWide => [for (final n in notes) if (n.parkWide) n];

  // -- coordinates ------------------------------------------------------------------------

  static (double, double) _affine(List<List<double>> m, double x, double y) =>
      (x * m[0][0] + y * m[1][0] + m[2][0], x * m[0][1] + y * m[1][1] + m[2][1]);

  LatLng pageToLatLon(double x, double y) {
    final (mx, my) = _affine(_pageToMercator, x, y);
    final lat = (2 * math.atan(math.exp(my / _radius)) - math.pi / 2) * 180 / math.pi;
    return LatLng(lat, mx / _radius * 180 / math.pi);
  }

  (double, double) latLonToPage(double lat, double lon) {
    final mx = _radius * lon * math.pi / 180;
    final my = _radius * math.log(math.tan(math.pi / 4 + lat * math.pi / 180 / 2));
    return _affine(_mercatorToPage, mx, my);
  }

  bool isOnMap(double lat, double lon) {
    final (x, y) = latLonToPage(lat, lon);
    return x >= 0 && x <= pageWidth && y >= 0 && y <= pageHeight;
  }

  /// North-west and south-east corners of the map image, for drawing it as an overlay
  /// (the page has no rotation, so its edges are lines of latitude and longitude).
  (LatLng, LatLng) get imageBounds => (pageToLatLon(0, 0), pageToLatLon(pageWidth, pageHeight));

  // -- search ----------------------------------------------------------------------------

  /// Same normalisation as the Python side: accents dropped, then [a-z0-9] only.
  static String normalize(String text) {
    const accents = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ù': 'u',
      'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ﬁ': 'fi', 'ﬂ': 'fl',
    };
    final b = StringBuffer();
    for (final ch in text.toLowerCase().split('')) {
      b.write(accents[ch] ?? ch);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  /// Places whose label contains [query], best first: exact labels, anchored to a map symbol
  /// (especially via a leader line), and in larger type rank higher. Same ranking as Python.
  List<PlaceHit> search(String query, {int limit = 20}) {
    final q = normalize(query);
    if (q.isEmpty) return const [];
    final hits = <PlaceHit>[
      for (final p in places)
        if (p.norm.contains(q))
          PlaceHit(
            p,
            p.norm == q,
            4.0 * (p.norm == q ? 1 : 0) + 2.0 * (p.snapped ? 1 : 0) + 0.5 * (p.viaLeader ? 1 : 0) + 0.25 * p.fontSize,
          ),
    ];
    // ties (a name printed more than once) go top to bottom, then left to right, as in Python
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      final y = a.place.pageY.compareTo(b.place.pageY);
      return y != 0 ? y : a.place.pageX.compareTo(b.place.pageX);
    });
    return hits.take(limit).toList();
  }

  // -- guidance --------------------------------------------------------------------------

  /// Local guidance that applies at a place (precomputed when the pack was built).
  List<Advisory> guidanceFor(MapPlace place) => [for (final (n, reason, km) in place._guidance) Advisory(notes[n], reason, km)];

  /// Local guidance at a GPS position, most relevant first: closures on the road the position
  /// is on (only inside the closed stretch), notes along that road, then notes printed nearby.
  /// Park-wide notes are in [parkWide]. Same rules as Python `Guidance.for_point`.
  List<Advisory> guidanceAt(double lat, double lon) {
    final (px, py) = latLonToPage(lat, lon);
    final corridorPt = _corridorKm / _kmPerPt;
    final out = <Advisory>[];
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      if (note.parkWide) continue;
      var matched = false;
      final refs = _notePaths[i];
      for (final ref in refs) {
        final (dist, s) = _paths[ref.path].project(px, py);
        if (dist > corridorPt) continue;
        if (note.direction != null) {
          final section = ref.section;
          if (section != null && s >= section[0] && s <= section[1]) {
            out.add(Advisory(note, 'on ${note.feature}, ${note.direction} of the marked point', dist * _kmPerPt));
            matched = true;
          }
        } else {
          out.add(Advisory(note, 'along ${note.feature}', dist * _kmPerPt));
          matched = true;
        }
        break;
      }
      final xy = _noteXY[i];
      if (!matched && !(refs.isNotEmpty && note.direction != null) && xy != null) {
        final km = math.sqrt(math.pow(px - xy.$1, 2) + math.pow(py - xy.$2, 2)) * _kmPerPt;
        if (km <= _nearbyKm) out.add(Advisory(note, 'nearby (${km.toStringAsFixed(1)} km)', km));
      }
    }
    int group(Advisory a) => a.reason.startsWith('on ') || a.reason.startsWith('along ') ? 1 : 2;
    // stable sort, like Kotlin's sortedWith
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((x, y) {
      final a = x.$2, b = y.$2;
      var c = group(a).compareTo(group(b));
      if (c != 0) return c;
      c = (a.note.severity == Severity.warning ? 0 : 1).compareTo(b.note.severity == Severity.warning ? 0 : 1);
      if (c != 0) return c;
      c = (a.distanceKm ?? 0).compareTo(b.distanceKm ?? 0);
      return c != 0 ? c : x.$1.compareTo(y.$1);
    });
    // the same note is often printed more than once along a road; keep the most relevant copy
    final seen = <String>{};
    return [
      for (final (_, a) in indexed)
        if (seen.add(a.note.text)) a,
    ];
  }
}

/// A road or trail line in page coordinates, with arc-length positions.
class _Polyline {
  final List<(double, double)> points;
  final List<double> _cumulative;

  _Polyline(this.points) : _cumulative = List.filled(points.length, 0.0) {
    for (var i = 1; i < points.length; i++) {
      _cumulative[i] = _cumulative[i - 1] +
          math.sqrt(math.pow(points[i].$1 - points[i - 1].$1, 2) + math.pow(points[i].$2 - points[i - 1].$2, 2));
    }
  }

  /// (distance from p to the line, arc-length position of the closest point).
  (double, double) project(double px, double py) {
    var bestD = double.infinity;
    var bestS = 0.0;
    for (var i = 0; i < points.length - 1; i++) {
      final (ax, ay) = points[i];
      final (bx, by) = points[i + 1];
      final dx = bx - ax, dy = by - ay;
      final seg2 = dx * dx + dy * dy;
      final t = seg2 == 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / seg2).clamp(0.0, 1.0);
      final d = math.sqrt(math.pow(px - (ax + t * dx), 2) + math.pow(py - (ay + t * dy), 2));
      if (d < bestD) {
        bestD = d;
        bestS = _cumulative[i] + t * math.sqrt(seg2);
      }
    }
    return (bestD, bestS);
  }
}
