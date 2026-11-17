import 'dart:math' as math;

/// Sunrise / sunset / civil dusk for a day and place (NOAA solar position algorithm).
class SunTimes {
  final DateTime? sunrise;
  final DateTime? sunset;
  final DateTime? civilDusk;
  const SunTimes(this.sunrise, this.sunset, this.civilDusk);

  static SunTimes compute(DateTime day, double lat, double lon) {
    final local = DateTime(day.year, day.month, day.day);
    return SunTimes(
      _event(local, lat, lon, 90.833, rising: true),
      _event(local, lat, lon, 90.833, rising: false),
      _event(local, lat, lon, 96.0, rising: false),
    );
  }

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;

  static DateTime? _event(DateTime day, double lat, double lon, double zenith, {required bool rising}) {
    final n = day.difference(DateTime(day.year, 1, 1)).inDays + 1;
    final lngHour = lon / 15;
    final t = n + ((rising ? 6 : 18) - lngHour) / 24;
    final m = 0.9856 * t - 3.289;
    var l = m + 1.916 * math.sin(_rad(m)) + 0.020 * math.sin(_rad(2 * m)) + 282.634;
    l = (l % 360 + 360) % 360;
    var ra = _deg(math.atan(0.91764 * math.tan(_rad(l))));
    ra = (ra % 360 + 360) % 360;
    ra += (l ~/ 90) * 90 - (ra ~/ 90) * 90;
    ra /= 15;
    final sinDec = 0.39782 * math.sin(_rad(l));
    final cosDec = math.cos(math.asin(sinDec));
    final cosH = (math.cos(_rad(zenith)) - sinDec * math.sin(_rad(lat))) / (cosDec * math.cos(_rad(lat)));
    if (cosH > 1 || cosH < -1) return null;
    var h = rising ? 360 - _deg(math.acos(cosH)) : _deg(math.acos(cosH));
    h /= 15;
    final localMean = h + ra - 0.06571 * t - 6.622;
    var ut = (localMean - lngHour) % 24;
    if (ut < 0) ut += 24;
    // Approximate local solar noon expressed in UTC for the requested day.
    final solarNoonUtc = DateTime.utc(day.year, day.month, day.day, 12)
        .add(Duration(milliseconds: ((-lngHour) * 3600000).round()));
    final baseUtc = DateTime.utc(solarNoonUtc.year, solarNoonUtc.month, solarNoonUtc.day);
    final eventUtcOfBase = baseUtc.add(Duration(milliseconds: (ut * 3600000).round()));
    // Pick the occurrence within ±12 hours of local solar noon (anchors sunrise < sunset).
    var best = eventUtcOfBase;
    var bestDelta = (eventUtcOfBase.difference(solarNoonUtc).inSeconds).abs();
    for (final shift in const [-1, 0, 1]) {
      final cand = eventUtcOfBase.add(Duration(days: shift));
      final d = (cand.difference(solarNoonUtc).inSeconds).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = cand;
      }
    }
    return best.toLocal();
  }
}
