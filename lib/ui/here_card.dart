import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/situation.dart';
import '../geo/dem.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import 'theme.dart';

/// "Where you are" hero: a greeting, daylight left, the nearest named place and a terrain
/// silhouette drawn from the region's own elevation data, so nothing here is park-specific.
class HereCard extends StatelessWidget {
  final Situation s;
  final GeoData? geo;
  const HereCard({super.key, required this.s, required this.geo});

  @override
  Widget build(BuildContext context) {
    final f = s.fix;
    final region = geo?.dem.region;
    final place = f == null ? null : _Place.near(geo, f.lat, f.lon);
    final (light, lightWarn) = _daylight(s);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSky,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kInk, width: 2),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            top: null,
            child: SizedBox(
              height: 64,
              child: CustomPaint(painter: _RidgePainter(f == null ? null : _profile(geo?.dem, f.lat, f.lon))),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 70),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(_greeting(s.now), style: label(kInkMuted, size: 11))),
                    _RegionBadge(region: region),
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  light,
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.15, color: lightWarn ? kClay : kInk),
                ),
                const SizedBox(height: 8),
                if (f == null)
                  const _Searching()
                else
                  Row(
                    children: [
                      Icon(f.simulated ? Icons.push_pin : Icons.my_location, size: 15, color: kMoss),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          [
                            if (place != null) 'Near $place',
                            if (s.elevation != null) '${_thousands(s.elevation!.round())} m',
                            f.simulated ? 'demo position' : '±${f.accuracy.round()} m',
                          ].join(' · '),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kInk),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Positioned(left: 16, right: 16, bottom: 10, child: _DaylightBar(s: s)),
        ],
      ),
    );
  }

  static String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 5) return 'STILL DARK OUT';
    if (h < 12) return 'GOOD MORNING';
    if (h < 17) return 'GOOD AFTERNOON';
    if (h < 21) return 'GOOD EVENING';
    return 'GOOD NIGHT';
  }

  /// Daylight left in plain words, and whether it is worth a warning colour.
  static (String, bool) _daylight(Situation s) {
    final us = s.untilSunset;
    final ud = s.untilDark;
    if (s.isNight) return ('It\'s dark. Sunrise at ${_hm(s.sun.sunrise)}.', true);
    if (us == null) return ('Daylight unknown here.', false);
    if (us.isNegative) {
      return (ud == null || ud.isNegative ? 'The sun is down.' : 'Sun\'s down. ${formatDuration(ud)} of dusk light left.', true);
    }
    if (us < const Duration(hours: 1)) return ('${formatDuration(us)} of light left.', true);
    if (us < const Duration(hours: 3)) return ('${formatDuration(us)} of daylight left.', false);
    return ('Plenty of daylight. Sunset at ${_hm(s.sun.sunset)}.', false);
  }

  static String _hm(DateTime? t) => t == null ? '--:--' : '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

  static String _thousands(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  /// East-west elevation profile through the user (±4 km), as two ridgelines: near and one
  /// 3 km north for depth. Null when the position is outside the region's elevation grid.
  static (List<double>, List<double>)? _profile(Dem? dem, double lat, double lon) {
    if (dem == null) return null;
    const n = 48, spanKm = 4.0;
    final dLon = spanKm / (111.32 * math.cos(lat * math.pi / 180));
    List<double>? line(double la) {
      final out = <double>[];
      for (var i = 0; i < n; i++) {
        final e = dem.elevation(la, lon - dLon + 2 * dLon * i / (n - 1));
        if (e == null) return null;
        out.add(e);
      }
      return out;
    }

    final near = line(lat), far = line(lat + 3 / 111.32);
    if (near == null) return null;
    return (near, far ?? near);
  }
}

/// Nearest named place, cached per position (thousands of POIs; the UI rebuilds often).
class _Place {
  static (double, double, String?)? _last;

  static String? near(GeoData? geo, double lat, double lon) {
    final c = _last;
    if (c != null && haversineM(c.$1, c.$2, lat, lon) < 50) return c.$3;
    if (geo == null) return null;
    final hit = geo.nearest(null, lat, lon, limit: 1);
    final name = hit.isEmpty || hit.first.$2 > 3000 ? null : hit.first.$1.name;
    _last = (lat, lon, name);
    return name;
  }
}

class _RegionBadge extends StatelessWidget {
  final String? region;
  const _RegionBadge({required this.region});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.offline_pin, size: 13, color: kSun),
        const SizedBox(width: 4),
        Text((region ?? 'Region').toUpperCase(), style: label(kCard, size: 10)),
      ],
    ),
  );
}

/// Shown until the first fix: a slowly turning compass instead of empty dashes.
class _Searching extends StatefulWidget {
  const _Searching();

  @override
  State<_Searching> createState() => _SearchingState();
}

class _SearchingState extends State<_Searching> with SingleTickerProviderStateMixin {
  // only runs while there is no fix, then this widget is gone
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      RotationTransition(
        turns: _spin,
        child: const Icon(Icons.explore, size: 16, color: kClay),
      ),
      const SizedBox(width: 6),
      const Text(
        'Getting your bearings…',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kInkMuted),
      ),
    ],
  );
}

/// Sunrise-to-sunset track with the sun's current position.
class _DaylightBar extends StatelessWidget {
  final Situation s;
  const _DaylightBar({required this.s});

  @override
  Widget build(BuildContext context) {
    final rise = s.sun.sunrise, set = s.sun.sunset;
    if (rise == null || set == null) return const SizedBox();
    final t = (s.now.difference(rise).inSeconds / set.difference(rise).inSeconds).clamp(0.0, 1.0);
    return Row(
      children: [
        Text(HereCard._hm(rise), style: label(kCard, size: 10)),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (_, c) => SizedBox(
              height: 14,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(color: kCard.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(2)),
                  ),
                  Container(
                    width: c.maxWidth * t,
                    height: 3,
                    decoration: BoxDecoration(color: kSun, borderRadius: BorderRadius.circular(2)),
                  ),
                  Positioned(
                    left: (c.maxWidth - 14) * t,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: kSun,
                        shape: BoxShape.circle,
                        border: Border.all(color: kCard, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(HereCard._hm(set), style: label(kCard, size: 10)),
      ],
    );
  }
}

/// Two filled ridgelines from the elevation profile, with the user as a dot on the near one.
/// Without a profile (no fix yet, or outside the grid) it draws a generic skyline.
class _RidgePainter extends CustomPainter {
  final (List<double>, List<double>)? profile;
  _RidgePainter(this.profile);

  @override
  void paint(Canvas canvas, Size size) {
    final p = profile;
    final near = p?.$1 ?? List.generate(48, (i) => 40 * math.sin(i / 6) + 25 * math.sin(i / 2.3 + 1));
    final far = p?.$2 ?? List.generate(48, (i) => 50 * math.sin(i / 5 + 2) + 20 * math.sin(i / 1.7));
    final all = [...near, ...far];
    final lo = all.reduce(math.min), hi = all.reduce(math.max);
    final range = math.max(hi - lo, 60.0);
    // the bottom 28 px stay solid ground so the daylight bar on top of it always reads
    double y(double e, double top) => top + (size.height - 28 - top) * (1 - (e - lo) / range);

    Path ridge(List<double> v, double top) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < v.length; i++) {
        path.lineTo(size.width * i / (v.length - 1), y(v[i], top));
      }
      return path
        ..lineTo(size.width, size.height)
        ..close();
    }

    canvas.drawPath(ridge(far, 0), Paint()..color = kRidgeFar);
    canvas.drawPath(ridge(near, 14), Paint()..color = kRidgeNear);
    if (p != null) {
      final mid = near.length ~/ 2;
      final c = Offset(size.width / 2, y(near[mid], 14));
      canvas.drawCircle(c, 7, Paint()..color = kCard);
      canvas.drawCircle(c, 4.5, Paint()..color = kClay);
    }
  }

  @override
  bool shouldRepaint(_RidgePainter old) => old.profile != profile;
}

/// Way out / water / help as compact pills for the header, each with an arrow pointing at it (map north up).
class NearbyRow extends StatelessWidget {
  final Situation s;
  const NearbyRow({super.key, required this.s});

  @override
  Widget build(BuildContext context) {
    final f = s.fix;
    if (f == null) return const SizedBox();
    final r = s.routeOut, w = s.water, h = s.help;
    double to(Poi p) => bearingDeg(f.lat, f.lon, p.lat, p.lon);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Nearby(
          icon: Icons.hiking,
          color: r != null && r.offTrail ? kClay : kMoss,
          value: r == null ? '—' : formatDistance(r.distanceM),
          bearing: r?.initialBearing,
          title: 'WAY OUT',
          detail: r == null
              ? 'No route found from here.'
              : '${formatDistance(r.distanceM)} ${compassWord(r.initialBearing)} to ${r.target.name}\n'
                    'about ${formatDuration(r.walkTime)} walking${r.offTrail ? ' (off trail)' : ''}',
        ),
        const SizedBox(width: 6),
        _Nearby(
          icon: Icons.water_drop,
          color: kWater,
          value: w == null ? '—' : formatDistance(w.$2),
          bearing: w == null ? null : to(w.$1),
          title: 'NEAREST WATER',
          detail: w == null ? 'No mapped water nearby.' : '${formatDistance(w.$2)} ${compassWord(to(w.$1))}: ${w.$1.name}',
        ),
        const SizedBox(width: 6),
        _Nearby(
          icon: Icons.local_hospital,
          color: kClay,
          value: h == null ? '—' : formatDistance(h.$2),
          bearing: h == null ? null : to(h.$1),
          title: 'NEAREST HELP',
          detail: h == null
              ? 'No ranger station or help point nearby.'
              : '${formatDistance(h.$2)} ${compassWord(to(h.$1))}: ${h.$1.name}',
        ),
      ],
    );
  }
}

class _Nearby extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value, title, detail;
  final double? bearing;
  const _Nearby({
    required this.icon,
    required this.color,
    required this.value,
    required this.title,
    required this.detail,
    this.bearing,
  });

  // tap to spell out what the pill means
  @override
  Widget build(BuildContext context) => Tooltip(
    triggerMode: TooltipTriggerMode.tap,
    showDuration: const Duration(seconds: 4),
    preferBelow: true,
    verticalOffset: 22,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(10)),
    onTriggered: HapticFeedback.selectionClick,
    richMessage: TextSpan(
      children: [
        TextSpan(text: '$title\n', style: label(kSun, size: 11)),
        TextSpan(
          text: detail,
          style: const TextStyle(fontFamily: kFont, fontSize: 15, fontWeight: FontWeight.w600, color: kCard, height: 1.35),
        ),
      ],
    ),
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          if (bearing != null)
            // one-shot turn to the new bearing when the position changes
            TweenAnimationBuilder<double>(
              tween: Tween(end: bearing! * math.pi / 180),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (_, a, _) => Transform.rotate(
                angle: a,
                child: Icon(Icons.arrow_upward_rounded, size: 14, color: color),
              ),
            ),
        ],
      ),
    ),
  );
}
