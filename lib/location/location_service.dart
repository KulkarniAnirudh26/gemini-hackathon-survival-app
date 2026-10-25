import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import '../geo/geo_math.dart';

enum PowerTier { normal, saver, critical }

class Fix {
  final double lat, lon, accuracy;
  final double? altitude;
  final DateTime time;
  final bool simulated;
  const Fix(this.lat, this.lon, this.accuracy, this.altitude, this.time, {this.simulated = false});
}

/// GPS with battery tiers and batched breadcrumbs.
///
/// normal  (>50%):  fused high accuracy, 60 s interval, 25 m distance filter
/// saver   (20-50%): 5 min interval
/// critical (<20%): no stream; a single fix only when the user asks
class LocationService extends ChangeNotifier {
  final _battery = Battery();
  StreamSubscription<Position>? _sub;
  Timer? _batteryTimer;

  Fix? fix;
  int batteryLevel = 100;
  PowerTier tier = PowerTier.normal;
  bool permissionDenied = false;
  final List<Fix> breadcrumbs = [];
  final List<Fix> _unsaved = [];
  Fix? _simulated;
  bool isRecording = true;

  /// Starts or resumes recording user GPS trail.
  void toggleRecording() {
    isRecording = !isRecording;
    notifyListeners();
  }

  /// Clears recorded breadcrumbs.
  void clearBreadcrumbs() {
    breadcrumbs.clear();
    _unsaved.clear();
    notifyListeners();
  }

  /// The real GPS fix is outside Yosemite: the app shows a demo position instead (Mirror Lake trail),
  /// until the user taps "use real GPS".
  bool demoMode = false;
  bool _demoDismissed = false;
  Fix? realFix;

  /// Demo hiker: on the Mist Trail at Clark Point, having walked up from Happy Isles.
  static const demoLat = 37.7258, demoLon = -119.5413;
  static const demoStartLat = 37.7323, demoStartLon = -119.5577;
  static const demoStartName = 'Happy Isles Trailhead';

  /// Name of the place the current track started at (demo: the trailhead), shown as "walked from".
  String? trackStartName;
  bool demoTrackReady = false;

  /// Demo: replace the breadcrumbs with [points] (start → current position), walked over the last
  /// [duration]. Not saved to disk.
  void setDemoTrack(List<(double, double)> points, {Duration duration = const Duration(minutes: 75)}) {
    if (points.length < 2) return;
    final now = DateTime.now();
    breadcrumbs
      ..clear()
      ..addAll([
        for (var i = 0; i < points.length; i++)
          Fix(points[i].$1, points[i].$2, 5, null,
              now.subtract(duration * (1 - i / (points.length - 1))), simulated: true),
      ]);
    trackStartName = demoStartName;
    demoTrackReady = true;
    _simulated = Fix(points.last.$1, points.last.$2, 5, null, now, simulated: true);
    fix = _simulated;
    notifyListeners();
  }

  /// Distance walked along the breadcrumbs since [since] (default: the whole track).
  double trackDistance() {
    var d = 0.0;
    for (var i = 1; i < breadcrumbs.length; i++) {
      d += haversineM(breadcrumbs[i - 1].lat, breadcrumbs[i - 1].lon, breadcrumbs[i].lat, breadcrumbs[i].lon);
    }
    return d;
  }
  static bool inPark(double lat, double lon) => lat > 37.49 && lat < 38.19 && lon > -119.89 && lon < -119.20;

  Future<void> start() async {
    await _loadBreadcrumbs();
    await _refreshBattery();
    _batteryTimer = Timer.periodic(const Duration(minutes: 2), (_) => _refreshBattery());
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      permissionDenied = true;
      _maybeDemo();
      notifyListeners();
      return;
    }
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      _onPosition(last);
    } else {
      _maybeDemo();
      notifyListeners();
    }
    _restartStream();
  }

  Future<void> _refreshBattery() async {
    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {}
    final next = batteryLevel > 50
        ? PowerTier.normal
        : batteryLevel >= 20
            ? PowerTier.saver
            : PowerTier.critical;
    if (next != tier) {
      tier = next;
      _restartStream();
    }
    notifyListeners();
  }

  /// Lets the demo force a tier.
  void overrideTier(PowerTier t) {
    tier = t;
    _restartStream();
    notifyListeners();
  }

  void _restartStream() {
    _sub?.cancel();
    _sub = null;
    if (permissionDenied || tier == PowerTier.critical) return;
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high, // offline wilderness: only GNSS works, "balanced" may never fix
      distanceFilter: 25,
      intervalDuration: tier == PowerTier.normal ? const Duration(seconds: 60) : const Duration(minutes: 5),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition, onError: (_) {});
  }

  /// One fix on demand (critical tier, or the "locate me" button).
  Future<Fix?> fixNow() async {
    if (_simulated != null) return _simulated;
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 45)),
      );
      _onPosition(p);
    } catch (_) {}
    return fix;
  }

  /// Demo / testing: pin a position (long-press on the map).
  void simulate(double lat, double lon) {
    demoMode = false;
    demoTrackReady = false;
    trackStartName = null;
    _simulated = Fix(lat, lon, 5, null, DateTime.now(), simulated: true);
    fix = _simulated;
    _addCrumb(fix!);
    notifyListeners();
  }

  /// Back to the real GPS (also ends demo mode, even outside the park).
  void clearSimulation() {
    _simulated = null;
    demoMode = false;
    demoTrackReady = false;
    trackStartName = null;
    _demoDismissed = true;
    fix = realFix;
    notifyListeners();
  }

  void _maybeDemo() {
    if (_simulated != null || _demoDismissed) return;
    final r = realFix;
    if (r == null || !inPark(r.lat, r.lon)) {
      demoMode = true;
      _simulated = Fix(demoLat, demoLon, 5, null, DateTime.now(), simulated: true);
      fix = _simulated;
    }
  }

  void _onPosition(Position p) {
    realFix = Fix(p.latitude, p.longitude, p.accuracy, p.altitude, p.timestamp);
    if (demoMode && inPark(p.latitude, p.longitude)) {
      // a real fix inside the park ends the demo automatically
      demoMode = false;
      demoTrackReady = false;
      trackStartName = null;
      _simulated = null;
    }
    _maybeDemo();
    if (_simulated != null) {
      notifyListeners();
      return;
    }
    fix = realFix;
    _addCrumb(fix!);
    notifyListeners();
  }

  void _addCrumb(Fix f) {
    if (!isRecording) return;
    final last = breadcrumbs.isEmpty ? null : breadcrumbs.last;
    if (last != null &&
        haversineM(last.lat, last.lon, f.lat, f.lon) < 25 &&
        f.time.difference(last.time) < const Duration(minutes: 2)) {
      return;
    }
    breadcrumbs.add(f);
    _unsaved.add(f);
    if (_unsaved.length >= 10) _saveBreadcrumbs();
  }

  /// Distance walked in the last [window].
  double movedInLast(Duration window) {
    final since = DateTime.now().subtract(window);
    var d = 0.0;
    for (var i = 1; i < breadcrumbs.length; i++) {
      if (breadcrumbs[i].time.isBefore(since)) continue;
      d += haversineM(breadcrumbs[i - 1].lat, breadcrumbs[i - 1].lon, breadcrumbs[i].lat, breadcrumbs[i].lon);
    }
    return d;
  }

  Future<File> _crumbFile() async => File('${(await getApplicationDocumentsDirectory()).path}/breadcrumbs.jsonl');

  Future<void> _saveBreadcrumbs() async {
    if (_unsaved.isEmpty) return;
    final lines = _unsaved
        .map((f) => jsonEncode({'lat': f.lat, 'lon': f.lon, 't': f.time.millisecondsSinceEpoch}))
        .join('\n');
    _unsaved.clear();
    try {
      await (await _crumbFile()).writeAsString('$lines\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<void> _loadBreadcrumbs() async {
    try {
      final f = await _crumbFile();
      if (!await f.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 2));
      for (final line in await f.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line) as Map<String, dynamic>;
        final t = DateTime.fromMillisecondsSinceEpoch(m['t'] as int);
        if (t.isBefore(cutoff)) continue;
        breadcrumbs.add(Fix((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble(), 0, null, t));
      }
    } catch (_) {}
  }

  Future<void> flush() => _saveBreadcrumbs();

  @override
  void dispose() {
    _saveBreadcrumbs();
    _sub?.cancel();
    _batteryTimer?.cancel();
    super.dispose();
  }
}
