import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:yosemite_survival/geo/compass_controller.dart';
import 'package:yosemite_survival/geo/geo_data.dart';
import 'package:yosemite_survival/geo/geo_math.dart';
import 'package:yosemite_survival/location/location_service.dart';
import 'package:yosemite_survival/map3d/map3d.dart';
import 'package:yosemite_survival/ui/topo_3d_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Map3d.available returns false when native channel is unavailable', () async {
    final available = await Map3d.available();
    expect(available, isFalse);
  });

  test('Map3d.open returns false when native channel is unavailable', () async {
    final ok = await Map3d.open(lat: 37.7456, lon: -119.5936);
    expect(ok, isFalse);
  });

  test('CompassController initializes with default pitch and zoom', () {
    final c = CompassController();
    expect(c.heading, 0.0);
    expect(c.pitch, closeTo(42.0, 0.001));
    expect(c.zoom, closeTo(1.0, 0.001));
    expect(c.sensorLocked, isTrue);
    c.zoomIn();
    expect(c.zoom, closeTo(1.2, 0.001));
    c.zoomOut();
    expect(c.zoom, closeTo(1.0, 0.001));
    c.setManualRotation(10, -5);
    expect(c.sensorLocked, isFalse);
    expect(c.heading, closeTo(10.0, 0.001));
    expect(c.pitch, closeTo(37.0, 0.001));
    c.resetOrientation();
    expect(c.pitch, closeTo(42.0, 0.001));
    expect(c.zoom, closeTo(1.0, 0.001));
    expect(c.sensorLocked, isTrue);
    c.dispose();
  });

  testWidgets('Topo3DViewport renders without errors with breadcrumbs', (tester) async {
    final c = CompassController();
    final now = DateTime.now();
    final crumbs = [
      Fix(37.7323, -119.5577, 5, 1220, now.subtract(const Duration(hours: 1))),
      Fix(37.7290, -119.5490, 5, 1280, now.subtract(const Duration(minutes: 30))),
      Fix(37.7258, -119.5413, 5, 1400, now),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(child: Topo3DViewport(breadcrumbs: crumbs, compass: c)),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('3D PITCH'), findsOneWidget);
    c.dispose();
  });

  test('heading delta math gives correct turn direction and bearing', () {
    double delta(double tb, double h) => ((tb - h + 540) % 360) - 180;
    expect(delta(90, 45), 45);
    expect(delta(0, 45), -45);
    expect(delta(10, 350), 20);
    expect(delta(350, 10), -20);
    expect(delta(180, 180), 0);
  });

  test('arrowAngle keeps direction arrow pointing at target regardless of map rotation', () {
    double arrow(double bearing, double rotation) => (bearing - rotation) % 360;
    expect(arrow(90, 0), 90);
    expect(arrow(90, 90), 0);
    expect(arrow(90, 180), 270);
  });

  test('retrace route reverses breadcrumbs with correct distance and bearing', () {
    final now = DateTime.now();
    final crumbs = [
      Fix(37.740, -119.600, 5, 1200, now),
      Fix(37.745, -119.605, 5, 1220, now.add(const Duration(minutes: 30))),
      Fix(37.750, -119.610, 5, 1260, now.add(const Duration(hours: 1))),
    ];
    final pts = [for (final b in crumbs.reversed) LatLng(b.lat, b.lon)];
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      d += haversineM(pts[i - 1].latitude, pts[i - 1].longitude, pts[i].latitude, pts[i].longitude);
    }
    expect(d, greaterThan(1200));
    final bearing = bearingDeg(pts[0].latitude, pts[0].longitude, pts[1].latitude, pts[1].longitude);
    expect(bearing, closeTo(145, 15));
  });

  test('off-trail guide computes snap distance and escape bearing to nearest trail node', () async {
    final geo = await GeoData.load();
    final (node, snap) = geo.graph.nearestNode(37.7600, -119.5800);
    expect(node, greaterThanOrEqualTo(0));
    expect(snap, greaterThan(200));
    final nlat = geo.graph.nodeLat[node], nlon = geo.graph.nodeLon[node];
    final b = bearingDeg(37.7600, -119.5800, nlat, nlon);
    expect(b, inInclusiveRange(0, 360));
  });

  test('slope classification marks flat trails easy and cliffs hard', () {
    String grade(double rise, double run) {
      final g = (rise / run).abs() * 100;
      return g > 20 ? 'hard' : g > 8 ? 'mid' : 'easy';
    }
    expect(grade(2, 100), 'easy');
    expect(grade(12, 100), 'mid');
    expect(grade(30, 100), 'hard');
    expect(grade(-40, 100), 'hard');
  });

  test('sunset warning fires when walkTime exceeds remaining daylight', () {
    bool warn(Duration until, Duration walk) => !until.isNegative && (until.inMinutes < 120 || walk > until);
    expect(warn(const Duration(hours: 4), const Duration(hours: 2)), isFalse);
    expect(warn(const Duration(minutes: 90), const Duration(minutes: 40)), isTrue);
    expect(warn(const Duration(hours: 3), const Duration(hours: 4)), isTrue);
  });
}
