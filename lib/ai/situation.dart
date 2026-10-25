import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../geo/sun.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import '../rag/guide.dart';

class _Cache {
  final GeoData geo;
  final double lat, lon;
  final double? elev;
  final RouteResult? route;
  final (Poi, double)? water, help, shelter;
  _Cache(this.geo, this.lat, this.lon, this.elev, this.route, this.water, this.help, this.shelter);
}

/// Everything the assistant knows about the user's situation, computed once per turn.
class Situation {
  final DateTime now;
  final SunTimes sun;
  final Fix? fix;
  final double? elevation;
  final int battery;
  final PowerTier tier;
  final double movedLastHourM;
  final RouteResult? routeOut;
  final (Poi, double)? water;
  final (Poi, double)? help;
  final (Poi, double)? shelter;

  Situation._(this.now, this.sun, this.fix, this.elevation, this.battery, this.tier, this.movedLastHourM,
      this.routeOut, this.water, this.help, this.shelter);

  static Situation build(LocationService loc, GeoData? geo, TrailRouter? router) {
    final now = DateTime.now();
    final f = loc.fix;
    // Yosemite Valley as the default place for sun times if there is no fix yet
    final lat = f?.lat ?? 37.7456, lon = f?.lon ?? -119.5936;
    final sun = SunTimes.compute(now, lat, lon);
    double? elev;
    RouteResult? route;
    (Poi, double)? water, help, shelter;
    if (f != null && geo != null) {
      // routing and nearest-POI search only rerun when the user has moved (UI rebuilds are frequent)
      final c = _cache;
      if (c != null && identical(c.geo, geo) && haversineM(c.lat, c.lon, f.lat, f.lon) < 15) {
        (elev, route, water, help, shelter) = (c.elev, c.route, c.water, c.help, c.shelter);
      } else {
        elev = geo.dem.elevation(f.lat, f.lon) ?? f.altitude;
        route = router?.routeOut(f.lat, f.lon);
        water = _first(geo.nearest(PoiType.water, f.lat, f.lon, limit: 1));
        help = _first(geo.nearest(PoiType.help, f.lat, f.lon, limit: 1));
        shelter = _first(geo.nearest(PoiType.shelter, f.lat, f.lon, limit: 1));
        _cache = _Cache(geo, f.lat, f.lon, elev, route, water, help, shelter);
      }
    }
    return Situation._(now, sun, f, elev, loc.batteryLevel, loc.tier, loc.movedInLast(const Duration(hours: 1)),
        route, water, help, shelter);
  }

  static _Cache? _cache;

  static (Poi, double)? _first(List<(Poi, double)> l) => l.isEmpty ? null : l.first;

  Duration? get untilSunset => sun.sunset?.difference(now);
  Duration? get untilDark => sun.civilDusk?.difference(now);
  bool get isNight => sun.sunset != null && sun.sunrise != null && (now.isAfter(sun.civilDusk ?? sun.sunset!) || now.isBefore(sun.sunrise!));

  String _hm(DateTime? t) => t == null ? '--:--' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String bearingTo(Poi p) {
    final f = fix!;
    return compassWord(bearingDeg(f.lat, f.lon, p.lat, p.lon));
  }

  /// One line for general questions: enough to ground "today" and "here" without steering Gemma.
  String briefContext() {
    final us = untilSunset;
    return 'Hiker in Yosemite National Park. Local time ${_hm(now)}, sunset ${_hm(sun.sunset)}'
        '${us != null && !us.isNegative ? ' (in ${formatDuration(us)})' : ''}.';
  }

  /// Compact block prepended to Gemma's prompt.
  String contextBlock(List<GuideHit> guide) {
    final b = StringBuffer();
    final us = untilSunset;
    b.write('[SITUATION] Time ${_hm(now)}. Sunset ${_hm(sun.sunset)}');
    if (us != null && !us.isNegative) b.write(' (in ${formatDuration(us)})');
    if (isNight) b.write(', it is dark now');
    b.write('. Battery $battery%.');
    if (fix != null) {
      b.write(' Position ${fix!.lat.toStringAsFixed(4)},${fix!.lon.toStringAsFixed(4)} ±${fix!.accuracy.round()} m');
      if (elevation != null) b.write(', elevation ${elevation!.round()} m');
      b.write('. Moved ${formatDistance(movedLastHourM)} in the last hour.');
    } else {
      b.write(' No GPS fix yet.');
    }
    final r = routeOut;
    if (r != null) {
      b.write('\n[ROUTE] Nearest way out: ${r.target.name}${r.viaText}, ${formatDistance(r.distanceM)}, '
          '+${r.ascentM.round()} m / -${r.descentM.round()} m, about ${formatDuration(r.walkTime)} walking, '
          'start heading ${compassWord(r.initialBearing)}${r.offTrail ? ' (off trail, straight line)' : ''}.');
    }
    if (water != null || help != null) {
      b.write('\n[NEAREST]');
      if (water != null) b.write(' Water: ${water!.$1.name} ${formatDistance(water!.$2)} ${bearingTo(water!.$1)}.');
      if (help != null) b.write(' Help: ${help!.$1.name} ${formatDistance(help!.$2)} ${bearingTo(help!.$1)}.');
    }
    for (final h in guide) {
      b.write('\n[GUIDE: ${h.section.title}] ${h.section.summary}');
      final bullets = h.section.body.split('\n').where((l) => l.startsWith('- ')).take(4).join(' ');
      if (bullets.isNotEmpty) b.write(' $bullets');
    }
    return b.toString();
  }
}
