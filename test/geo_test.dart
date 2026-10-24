import 'package:flutter_test/flutter_test.dart';
import 'package:yosemite_survival/geo/geo_data.dart';
import 'package:yosemite_survival/geo/sun.dart';
import 'package:yosemite_survival/geo/trail_router.dart';
import 'package:yosemite_survival/rag/guide.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DEM matches known summits', () async {
    final geo = await GeoData.load();
    expect(geo.dem.elevation(37.7459, -119.5332)!, closeTo(2693, 40)); // Half Dome
    expect(geo.dem.elevation(37.7456, -119.5936)!, closeTo(1210, 40)); // Valley floor
    expect(geo.pois.where((p) => p.isWayOut).length, greaterThan(50));
  });

  test('routes from Mirror Lake trail to a way out', () async {
    final geo = await GeoData.load();
    final sw = Stopwatch()..start();
    final r = TrailRouter(geo).routeOut(37.7445, -119.5510)!;
    // ignore: avoid_print
    print('route: ${r.target.name} ${r.distanceM.round()} m +${r.ascentM.round()} ${r.walkTime} via ${r.trailNames} '
        'offTrail=${r.offTrail} in ${sw.elapsedMilliseconds} ms');
    expect(r.offTrail, isFalse);
    expect(r.distanceM, lessThan(5000));
    expect(r.points.length, greaterThan(2));
  });

  test('routes from the high country (Cathedral Lakes area)', () async {
    final geo = await GeoData.load();
    final r = TrailRouter(geo).routeOut(37.8460, -119.4170)!;
    // ignore: avoid_print
    print('route: ${r.target.name} ${r.distanceM.round()} m +${r.ascentM.round()} ${r.walkTime} via ${r.trailNames}');
    expect(r.distanceM, lessThan(15000));
  });

  test('sunset in Yosemite in October is around 18:10-18:40 PDT', () {
    final s = SunTimes.compute(DateTime(2026, 10, 24), 37.7456, -119.5936);
    final utc = s.sunset!.toUtc();
    // 18:10-18:40 PDT = 01:10-01:40 UTC next day
    final minutes = (utc.hour * 60 + utc.minute + 24 * 60 - 60) % (24 * 60);
    expect(minutes, inInclusiveRange(10, 40));
    expect(s.sunrise!.isBefore(s.sunset!), isTrue);
  });

  test('BM25 retrieves the right guide section', () async {
    final g = await Guide.load();
    expect(g.sections.length, greaterThanOrEqualTo(14));
    expect(g.search('a bear is near our camp').first.section.id, 'bear');
    expect(g.search('my friend is shivering and wet').first.section.id, 'hypothermia');
    expect(g.search('how do I cross this river').first.section.id, 'river_crossing');
  });
}
