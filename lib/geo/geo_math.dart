import 'dart:math' as math;

const double _earthRadiusM = 6371000.0;

double _rad(double d) => d * math.pi / 180.0;
double _deg(double r) => r * 180.0 / math.pi;

/// Great-circle distance in metres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.sqrt(a));
}

/// Initial bearing in degrees, 0 = north, clockwise.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final y = math.sin(_rad(lon2 - lon1)) * math.cos(_rad(lat2));
  final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
      math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(_rad(lon2 - lon1));
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

const _compass = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'];
const _compassShort = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

String compassWord(double bearing) => _compass[((bearing + 22.5) % 360 ~/ 45)];
String compassShort(double bearing) => _compassShort[((bearing + 22.5) % 360 ~/ 45)];

String formatDistance(double m) {
  if (m < 1000) return '${(m / 10).round() * 10} m';
  return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';
}

/// Spoken form: "1.4 kilometers", "300 meters".
String spokenDistance(double m) {
  if (m < 1000) return '${(m / 10).round() * 10} meters';
  return '${(m / 1000).toStringAsFixed(1)} kilometers';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '$m min';
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}

String spokenDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '$m minutes';
  if (m == 0) return h == 1 ? 'one hour' : '$h hours';
  return '${h == 1 ? 'one hour' : '$h hours'} and $m minutes';
}

/// Naismith's rule: 5 km/h plus one hour per 600 m of ascent; tired/lost hikers go slower.
Duration naismith(double distanceM, double ascentM, {double paceFactor = 1.3}) {
  final hours = (distanceM / 5000.0 + ascentM / 600.0) * paceFactor;
  return Duration(minutes: (hours * 60).round());
}
