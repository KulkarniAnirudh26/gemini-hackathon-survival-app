import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../ai/assistant.dart';
import '../geo/compass_controller.dart';
import '../geo/geo_math.dart';
import '../location/location_service.dart';
import 'topo_3d_viewport.dart';

/// Tactical 3D Topological Trail Map and Telemetry HUD matching the reference mockup:
/// - Header: AEGIS SURVIVAL / EDGE TENSOR ENGINE & GEMMA 4 E2B status pill
/// - 3D Topological Trail Map Viewport with phone sensor orientation
/// - Control bar: RECORD PATH, ALPINE TREK, and CLEAR buttons
/// - Telemetry HUD: Distance, Elevation Gain, Altitude Range, Waypoint count
/// - Recorded GPS Breadcrumbs feed
class MapScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;

  const MapScreen({
    super.key,
    required this.assistant,
    required this.location,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late final CompassController _compass;

  @override
  void initState() {
    super.initState();
    _compass = CompassController();
    _seedDemoTrailIfEmpty();
  }

  void _seedDemoTrailIfEmpty() {
    // If no breadcrumbs recorded yet, seed an initial Alpine Trail profile for immediate display
    if (widget.location.breadcrumbs.isEmpty) {
      final now = DateTime.now();
      const baseLat = 46.8770;
      const baseLon = -121.7304;
      for (var i = 0; i < 45; i++) {
        final t = i / 44.0;
        final lat = baseLat + (t * 0.0009) + (math.sin(t * math.pi * 3) * 0.0002);
        final lon = baseLon + (t * 0.0082) + (math.cos(t * math.pi * 2) * 0.0003);
        final alt = 1450.0 + (t * 1335.0);
        widget.location.breadcrumbs.add(
          Fix(lat, lon, 5, alt, now.subtract(Duration(minutes: 45 - i))),
        );
      }
    }
  }

  @override
  void dispose() {
    _compass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.location,
      builder: (context, _) {
        final crumbs = widget.location.breadcrumbs;
        final metrics = _calculateMetrics(crumbs);

        return Scaffold(
          backgroundColor: const Color(0xFF090D11),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Header: Aegis Survival & Gemma Status Pill
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E2833),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFE87A3E), width: 1.2),
                        ),
                        child: const Icon(Icons.shield, color: Color(0xFFE87A3E), size: 18),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'AEGIS SURVIVAL',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                          Text(
                            'EDGE TENSOR ENGINE',
                            style: TextStyle(
                              color: Color(0xFF6B8296),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      // Model Status Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0x33103B2B),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF18A573), width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.circle, size: 7, color: Color(0xFF4EEBA2)),
                            SizedBox(width: 6),
                            Text(
                              'GEMMA 4 E2B',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: Color(0xFF4EEBA2),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                            SizedBox(width: 4),
                            Icon(Icons.settings, size: 12, color: Color(0xFF4EEBA2)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Sub-header: 3D TOPOLOGICAL TRAIL MAP title & TRAIL READY badge
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.terrain, color: Color(0xFFE87A3E), size: 16),
                      const SizedBox(width: 8),
                      const Text(
                        '3D TOPOLOGICAL TRAIL MAP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0x33103B2B),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF18A573), width: 0.8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.circle, size: 6, color: Color(0xFF4EEBA2)),
                            SizedBox(width: 5),
                            Text(
                              'TRAIL READY',
                              style: TextStyle(
                                color: Color(0xFF4EEBA2),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // 3D Viewport Box
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 250,
                    child: Topo3DViewport(
                      breadcrumbs: crumbs,
                      compass: _compass,
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Tactical Control Row: RECORD PATH / ALPINE TREK / CLEAR
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: SizedBox(
                          height: 44,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: widget.location.isRecording
                                  ? const Color(0xFFE87A3E)
                                  : const Color(0xFF263543),
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: 0,
                            ),
                            icon: Icon(
                              widget.location.isRecording ? Icons.fiber_manual_record : Icons.play_arrow,
                              color: Colors.black,
                              size: 18,
                            ),
                            label: Text(
                              widget.location.isRecording ? 'PAUSE RECORD' : 'RECORD PATH',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                                letterSpacing: 0.8,
                              ),
                            ),
                            onPressed: widget.location.toggleRecording,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 5,
                        child: SizedBox(
                          height: 44,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: const Color(0xFF121B22),
                              foregroundColor: const Color(0xFF4EEBA2),
                              side: const BorderSide(color: Color(0xFF1B3D2F), width: 1.5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: const Icon(Icons.terrain, size: 16, color: Color(0xFF4EEBA2)),
                            label: const Text(
                              'ALPINE TREK',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                                letterSpacing: 0.8,
                              ),
                            ),
                            onPressed: () {
                              _seedDemoTrailIfEmpty();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Alpine Trek Route Loaded in 3D')),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 44,
                        width: 44,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF121B22),
                            side: const BorderSide(color: Color(0xFF263543)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Icon(Icons.delete_outline, color: Color(0xFF6B8296), size: 20),
                          onPressed: () {
                            widget.location.clearBreadcrumbs();
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 4-Column Telemetry Dashboard HUD
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F151B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF1E2B37)),
                    ),
                    child: Row(
                      children: [
                        _TelemetryCol(
                          title: 'DISTANCE',
                          value: '${metrics.distKm.toStringAsFixed(1)} km',
                          valColor: const Color(0xFFE87A3E),
                        ),
                        _divider(),
                        _TelemetryCol(
                          title: 'ELEV GAIN',
                          value: '+${metrics.elevGainM.toStringAsFixed(0)} m',
                          valColor: const Color(0xFF4EEBA2),
                        ),
                        _divider(),
                        _TelemetryCol(
                          title: 'ALT RANGE',
                          value: '${metrics.minAlt.toStringAsFixed(0)}-${metrics.maxAlt.toStringAsFixed(0)}m',
                          valColor: const Color(0xFF00E5FF),
                        ),
                        _divider(),
                        _TelemetryCol(
                          title: 'WAYPOINTS',
                          value: '${crumbs.length}',
                          valColor: const Color(0xFFFFD54F),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Recorded GPS Breadcrumbs Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'RECORDED GPS BREADCRUMBS (${crumbs.length})',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFF6B8296),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // Scrollable Breadcrumbs Cards List
                Expanded(
                  child: crumbs.isEmpty
                      ? const Center(
                          child: Text(
                            'No recorded breadcrumbs yet. Tap RECORD PATH.',
                            style: TextStyle(color: Color(0xFF556A7B), fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          itemCount: crumbs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, i) {
                            // Reverse order: newest on top
                            final f = crumbs[crumbs.length - 1 - i];
                            final alt = f.altitude ?? 2000.0;
                            final timeStr = _formatTime(f.time);

                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0D1217),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFF1B2631)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.circle, size: 7, color: Color(0xFFE87A3E)),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${f.lat.toStringAsFixed(4)}, ${f.lon.toStringAsFixed(4)}',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${alt.toStringAsFixed(0)}m alt',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: Color(0xFF4EEBA2),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    timeStr,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: Color(0xFF6B8296),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _divider() => Container(
        height: 28,
        width: 1,
        color: const Color(0xFF1E2B37),
        margin: const EdgeInsets.symmetric(horizontal: 4),
      );

  static String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static ({double distKm, double elevGainM, double minAlt, double maxAlt}) _calculateMetrics(List<Fix> crumbs) {
    if (crumbs.isEmpty) {
      return (distKm: 0.0, elevGainM: 0.0, minAlt: 0.0, maxAlt: 0.0);
    }

    var dist = 0.0;
    var gain = 0.0;
    var minAlt = double.infinity;
    var maxAlt = -double.infinity;

    for (var i = 0; i < crumbs.length; i++) {
      final alt = crumbs[i].altitude ?? 2000.0;
      if (alt < minAlt) minAlt = alt;
      if (alt > maxAlt) maxAlt = alt;

      if (i > 0) {
        final prev = crumbs[i - 1];
        dist += haversineM(prev.lat, prev.lon, crumbs[i].lat, crumbs[i].lon);
        final diff = alt - (prev.altitude ?? 2000.0);
        if (diff > 0) gain += diff;
      }
    }

    if (minAlt == double.infinity) minAlt = 0;
    if (maxAlt == -double.infinity) maxAlt = 0;

    return (
      distKm: dist / 1000.0,
      elevGainM: gain,
      minAlt: minAlt,
      maxAlt: maxAlt,
    );
  }
}

class _TelemetryCol extends StatelessWidget {
  final String title;
  final String value;
  final Color valColor;

  const _TelemetryCol({
    required this.title,
    required this.value,
    required this.valColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B8296),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: valColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
