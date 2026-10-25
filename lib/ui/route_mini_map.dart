import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../ai/assistant.dart';
import '../geo/geo_math.dart';
import '../geo/trail_router.dart';
import 'map_layers.dart';
import 'theme.dart';

/// A small, non-interactive map under a chat answer: you, the destination and the route.
/// Tapping it opens the Map tab focused on the same route.
class RouteMiniMap extends StatelessWidget {
  final Assistant assistant;
  final RouteResult route;
  const RouteMiniMap({super.key, required this.assistant, required this.route});

  @override
  Widget build(BuildContext context) {
    final geo = assistant.geo;
    final nps = assistant.nps;
    if (geo == null || nps == null || route.points.length < 2) return const SizedBox.shrink();
    final layers = MapLayerCache.of(nps);
    final bounds = LatLngBounds(geo.dem.hillshadeNorthWest, geo.dem.hillshadeSouthEast);
    return GestureDetector(
      onTap: () => assistant.mapFocus.value = route,
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kInk, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          SizedBox(
            height: 180,
            // the map swallows taps; let the GestureDetector above handle them
            child: IgnorePointer(
              child: FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.coordinates(
                    coordinates: route.points,
                    padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
                    maxZoom: 16,
                  ),
                  backgroundColor: kGround,
                  interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                ),
                children: [
                  OverlayImageLayer(overlayImages: [
                    OverlayImage(bounds: bounds, imageProvider: const AssetImage('assets/geo/hillshade.png')),
                  ]),
                  PolygonLayer(polygons: layers.water),
                  PolylineLayer(polylines: layers.roads),
                  PolylineLayer(polylines: layers.trails),
                  PolylineLayer(polylines: [
                    Polyline(points: route.points, color: kCard, strokeWidth: 8),
                    Polyline(
                      points: route.points,
                      color: kMoss,
                      strokeWidth: 5,
                      pattern: route.offTrail ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid(),
                    ),
                  ]),
                  MarkerLayer(markers: [
                    Marker(
                      point: route.points.first,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kWater,
                          border: Border.all(color: kCard, width: 3),
                        ),
                      ),
                    ),
                    Marker(
                      point: route.target.latLng,
                      width: 34,
                      height: 34,
                      child: const Icon(Icons.flag_circle, color: kClay, size: 32),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: kInk.withValues(alpha: 0.85),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${route.target.name} · ${formatDistance(route.distanceM)} · ~${formatDuration(route.walkTime)}',
                    style: label(kCard, size: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('OPEN MAP', style: label(kCard, size: 11)),
                const Icon(Icons.chevron_right, color: kCard, size: 16),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
