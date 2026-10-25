import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../geo/compass_controller.dart';
import '../location/location_service.dart';

/// Renders a tactical isometric 3D topological viewport matching the user's design:
/// - Isometric 3D boundary wireframe grid
/// - 3D GPS trail ribbon with elevation heat gradient
/// - Phone sensor compass badge (N 45°)
/// - Live HUD readout (3D PITCH & ZOOM)
/// - Floating tactical buttons (sensor lock, zoom +, zoom -, reset)
class Topo3DViewport extends StatefulWidget {
  final List<Fix> breadcrumbs;
  final CompassController compass;
  final VoidCallback? onReset;

  const Topo3DViewport({
    super.key,
    required this.breadcrumbs,
    required this.compass,
    this.onReset,
  });

  @override
  State<Topo3DViewport> createState() => _Topo3DViewportState();
}

class _Topo3DViewportState extends State<Topo3DViewport> {
  Offset? _lastPan;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.compass,
      builder: (context, _) {
        final heading = widget.compass.heading;
        final pitch = widget.compass.pitch;
        final zoom = widget.compass.zoom;
        final sensorLocked = widget.compass.sensorLocked;

        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: const Color(0xFF0D1217),
            child: Stack(
              children: [
                // 3D Gesture detector for manual tilt / rotation / zoom
                GestureDetector(
                  onPanStart: (details) => _lastPan = details.localPosition,
                  onPanUpdate: (details) {
                    if (_lastPan != null) {
                      final dx = details.localPosition.dx - _lastPan!.dx;
                      final dy = details.localPosition.dy - _lastPan!.dy;
                      widget.compass.setManualRotation(-dx * 0.5, -dy * 0.3);
                      _lastPan = details.localPosition;
                    }
                  },
                  onPanEnd: (_) => _lastPan = null,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _Topo3DPainter(
                      breadcrumbs: widget.breadcrumbs,
                      headingDeg: heading,
                      pitchDeg: pitch,
                      zoom: zoom,
                    ),
                  ),
                ),

                // Top Left: Compass Rose Badge (e.g. N 45°)
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x99161F28),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF263543), width: 1.2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.rotate(
                          angle: -heading * math.pi / 180,
                          child: const Icon(
                            Icons.navigation,
                            size: 15,
                            color: Color(0xFFFF5252),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_cardinal(heading)} ${heading.toStringAsFixed(0)}°',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Top Center: Pitch & Zoom HUD Pill
                Positioned(
                  top: 14,
                  left: 110,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x66161F28),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF1E2C37)),
                    ),
                    child: Text(
                      '3D PITCH ${pitch.toStringAsFixed(0)}°  ·  ZOOM ${zoom.toStringAsFixed(1)}x',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF4EEBA2),
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),

                // Right Floating Tool Controls
                Positioned(
                  top: 14,
                  right: 14,
                  child: Column(
                    children: [
                      _TacticalCircleButton(
                        icon: sensorLocked ? Icons.sensors : Icons.sensors_off,
                        color: sensorLocked ? const Color(0xFF4EEBA2) : Colors.white60,
                        tooltip: 'Sensor Orient Lock',
                        onTap: widget.compass.toggleSensorLock,
                      ),
                      const SizedBox(height: 8),
                      _TacticalCircleButton(
                        icon: Icons.zoom_in,
                        tooltip: 'Zoom In',
                        onTap: widget.compass.zoomIn,
                      ),
                      const SizedBox(height: 8),
                      _TacticalCircleButton(
                        icon: Icons.zoom_out,
                        tooltip: 'Zoom Out',
                        onTap: widget.compass.zoomOut,
                      ),
                      const SizedBox(height: 8),
                      _TacticalCircleButton(
                        icon: Icons.refresh,
                        tooltip: 'Reset View',
                        onTap: widget.compass.resetOrientation,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _cardinal(double deg) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW', 'N'];
    return dirs[((deg % 360) / 45).round()];
  }
}

class _TacticalCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color color;

  const _TacticalCircleButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.color = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xCC16222C),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF263847), width: 1.2),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

class _Topo3DPainter extends CustomPainter {
  final List<Fix> breadcrumbs;
  final double headingDeg;
  final double pitchDeg;
  final double zoom;

  _Topo3DPainter({
    required this.breadcrumbs,
    required this.headingDeg,
    required this.pitchDeg,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final radH = headingDeg * math.pi / 180;
    final radP = pitchDeg * math.pi / 180;

    // Center coordinates & bounds
    final points = _getNormalizedPoints();

    // 1. Draw 3D Isometric Diamond Floor & Wireframe Box
    _draw3DWireframeBox(canvas, cx, cy, radH, radP, size.width * 0.35 * zoom);

    // 2. Draw 3D Trail Ribbon & Ground Shadow
    if (points.isNotEmpty) {
      _draw3DTrail(canvas, cx, cy, radH, radP, points);
    }
  }

  List<({double x, double y, double z})> _getNormalizedPoints() {
    if (breadcrumbs.isEmpty) {
      // Default demo alpine ribbon if empty (e.g. Mirror Lake Trail)
      return List.generate(45, (i) {
        final t = i / 44.0;
        final x = math.sin(t * math.pi * 2.2) * 0.65;
        final y = (t - 0.5) * 1.6;
        final z = (math.sin(t * math.pi * 3.0) * 0.4 + t * 0.6);
        return (x: x, y: y, z: z);
      });
    }

    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    var minAlt = double.infinity, maxAlt = -double.infinity;

    for (final f in breadcrumbs) {
      if (f.lat < minLat) minLat = f.lat;
      if (f.lat > maxLat) maxLat = f.lat;
      if (f.lon < minLon) minLon = f.lon;
      if (f.lon > maxLon) maxLon = f.lon;
      final alt = f.altitude ?? 2000.0;
      if (alt < minAlt) minAlt = alt;
      if (alt > maxAlt) maxAlt = alt;
    }

    final dLat = (maxLat - minLat).abs();
    final dLon = (maxLon - minLon).abs();
    final dAlt = (maxAlt - minAlt).abs();
    final span = math.max(math.max(dLat, dLon), 0.0001);
    final altSpan = dAlt == 0 ? 1.0 : dAlt;

    final midLat = (minLat + maxLat) / 2;
    final midLon = (minLon + maxLon) / 2;

    return breadcrumbs.map((f) {
      final nx = ((f.lon - midLon) / span).clamp(-1.0, 1.0);
      final ny = ((f.lat - midLat) / span).clamp(-1.0, 1.0);
      final nz = (((f.altitude ?? minAlt) - minAlt) / altSpan).clamp(0.0, 1.0);
      return (x: nx, y: ny, z: nz);
    }).toList();
  }

  Offset _project(double x, double y, double z, double cx, double cy, double radH, double radP, double scale) {
    // Rotate around Z by heading
    final rx = x * math.cos(radH) - y * math.sin(radH);
    final ry = x * math.sin(radH) + y * math.cos(radH);

    // Tilt by pitch
    final px = rx * scale;
    final py = (ry * math.cos(radP) - z * 0.7 * math.sin(radP)) * scale;

    return Offset(cx + px, cy + py);
  }

  void _draw3DWireframeBox(Canvas canvas, double cx, double cy, double radH, double radP, double scale) {
    final floorPaint = Paint()
      ..color = const Color(0x1818A573)
      ..style = PaintingStyle.fill;

    final wirePaint = Paint()
      ..color = const Color(0xFF1B3D2F)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final gridPaint = Paint()
      ..color = const Color(0x144EEBA2)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // Diamond corners on ground (z = 0)
    final p0 = _project(-1, -1, 0, cx, cy, radH, radP, scale);
    final p1 = _project(1, -1, 0, cx, cy, radH, radP, scale);
    final p2 = _project(1, 1, 0, cx, cy, radH, radP, scale);
    final p3 = _project(-1, 1, 0, cx, cy, radH, radP, scale);

    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p3.dx, p3.dy)
      ..close();

    canvas.drawPath(path, floorPaint);
    canvas.drawPath(path, wirePaint);

    // Internal grid subdivisions
    for (var i = 1; i <= 3; i++) {
      final t = -1.0 + (i * 0.5);
      final ga = _project(t, -1, 0, cx, cy, radH, radP, scale);
      final gb = _project(t, 1, 0, cx, cy, radH, radP, scale);
      canvas.drawLine(ga, gb, gridPaint);

      final gc = _project(-1, t, 0, cx, cy, radH, radP, scale);
      final gd = _project(1, t, 0, cx, cy, radH, radP, scale);
      canvas.drawLine(gc, gd, gridPaint);
    }
  }

  void _draw3DTrail(
    Canvas canvas,
    double cx,
    double cy,
    double radH,
    double radP,
    List<({double x, double y, double z})> points,
  ) {
    final scale = 110.0 * zoom;

    // Project 3D points and their 2D floor shadows
    final screenPts = <Offset>[];
    final shadowPts = <Offset>[];

    for (final p in points) {
      screenPts.add(_project(p.x, p.y, p.z, cx, cy, radH, radP, scale));
      shadowPts.add(_project(p.x, p.y, 0, cx, cy, radH, radP, scale));
    }

    // Draw floor drop-shadow lines (tactical depth)
    final dropLinePaint = Paint()
      ..color = const Color(0x334EEBA2)
      ..strokeWidth = 1.0;

    for (var i = 0; i < screenPts.length; i += 4) {
      canvas.drawLine(shadowPts[i], screenPts[i], dropLinePaint);
    }

    // Shadow trail line
    final shadowPath = Path()..moveTo(shadowPts.first.dx, shadowPts.first.dy);
    for (var i = 1; i < shadowPts.length; i++) {
      shadowPath.lineTo(shadowPts[i].dx, shadowPts[i].dy);
    }
    canvas.drawPath(
      shadowPath,
      Paint()
        ..color = const Color(0x40163326)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );

    // Glowing 3D Trail Ribbon (Gradient based on altitude)
    for (var i = 0; i < screenPts.length - 1; i++) {
      final pA = screenPts[i];
      final pB = screenPts[i + 1];
      final altNorm = (points[i].z + points[i + 1].z) / 2.0;

      // Color from Teal/Cyan -> Orange -> Coral Red
      final segmentColor = Color.lerp(
        const Color(0xFF00E5FF),
        const Color(0xFFFF7A33),
        altNorm,
      )!;

      final trailPaint = Paint()
        ..color = segmentColor
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(pA, pB, trailPaint);
    }

    // Start Waypoint (Teal circle)
    final startPt = screenPts.first;
    canvas.drawCircle(
      startPt,
      5.0,
      Paint()..color = const Color(0xFF00E5FF),
    );
    canvas.drawCircle(
      startPt,
      2.0,
      Paint()..color = Colors.white,
    );

    // End/Current Waypoint (Pulsing Orange Dot)
    final endPt = screenPts.last;
    canvas.drawCircle(
      endPt,
      7.0,
      Paint()..color = const Color(0x66FF7A33),
    );
    canvas.drawCircle(
      endPt,
      4.5,
      Paint()..color = const Color(0xFFFF7A33),
    );
    canvas.drawCircle(
      endPt,
      2.0,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _Topo3DPainter oldDelegate) => true;
}
