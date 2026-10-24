import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// Offline elevation grid (Web Mercator pixels at zoom [z]), built by tool/build_geo.py.
class Dem {
  final int z, px0, py0, width, height;
  final Int16List data;
  final LatLng hillshadeNorthWest;
  final LatLng hillshadeSouthEast;

  Dem._(this.z, this.px0, this.py0, this.width, this.height, this.data, this.hillshadeNorthWest,
      this.hillshadeSouthEast);

  static Future<Dem> load() async {
    final meta = jsonDecode(await rootBundle.loadString('assets/geo/dem.json')) as Map<String, dynamic>;
    final bytes = await rootBundle.load('assets/geo/dem.bin');
    final data = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    final hs = meta['hillshade'] as Map<String, dynamic>;
    return Dem._(
      meta['z'] as int,
      meta['px0'] as int,
      meta['py0'] as int,
      meta['width'] as int,
      meta['height'] as int,
      data,
      LatLng((hs['north'] as num).toDouble(), (hs['west'] as num).toDouble()),
      LatLng((hs['south'] as num).toDouble(), (hs['east'] as num).toDouble()),
    );
  }

  bool contains(double lat, double lon) {
    final p = _px(lat, lon);
    return p.$1 >= 0 && p.$2 >= 0 && p.$1 < width - 1 && p.$2 < height - 1;
  }

  (double, double) _px(double lat, double lon) {
    final n = 256.0 * (1 << z);
    final x = (lon + 180.0) / 360.0 * n;
    final s = math.sin(lat * math.pi / 180);
    final y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n;
    return (x - px0, y - py0);
  }

  /// Bilinear elevation in metres, or null outside the grid.
  double? elevation(double lat, double lon) {
    final (x, y) = _px(lat, lon);
    if (x < 0 || y < 0 || x >= width - 1 || y >= height - 1) return null;
    final ix = x.floor(), iy = y.floor();
    final fx = x - ix, fy = y - iy;
    double g(int xx, int yy) => data[yy * width + xx].toDouble();
    return g(ix, iy) * (1 - fx) * (1 - fy) +
        g(ix + 1, iy) * fx * (1 - fy) +
        g(ix, iy + 1) * (1 - fx) * fy +
        g(ix + 1, iy + 1) * fx * fy;
  }
}
