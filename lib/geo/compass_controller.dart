import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// Smooths and delivers real-time magnetometer compass heading and tilt.
class CompassController extends ChangeNotifier {
  StreamSubscription<CompassEvent>? _sub;
  double _heading = 0.0;
  double _pitch = 42.0; // default 3D tilt pitch in degrees
  double _zoom = 1.0;
  bool _sensorLocked = true;

  double get heading => _heading;
  double get pitch => _pitch;
  double get zoom => _zoom;
  bool get sensorLocked => _sensorLocked;

  CompassController() {
    _init();
  }

  void _init() {
    _sub = FlutterCompass.events?.listen((event) {
      if (!_sensorLocked) return;
      final h = event.heading;
      if (h != null) {
        // Low-pass filter to prevent sensor jitter
        final diff = ((h - _heading + 540) % 360) - 180;
        _heading = (_heading + diff * 0.15) % 360;
        if (_heading < 0) _heading += 360;
        notifyListeners();
      }
    });
  }

  void toggleSensorLock() {
    _sensorLocked = !_sensorLocked;
    notifyListeners();
  }

  void setManualRotation(double deltaHeading, double deltaPitch) {
    _sensorLocked = false;
    _heading = (_heading + deltaHeading) % 360;
    if (_heading < 0) _heading += 360;
    _pitch = (_pitch + deltaPitch).clamp(15.0, 75.0);
    notifyListeners();
  }

  void zoomIn() {
    _zoom = (_zoom * 1.2).clamp(0.5, 3.5);
    notifyListeners();
  }

  void zoomOut() {
    _zoom = (_zoom / 1.2).clamp(0.5, 3.5);
    notifyListeners();
  }

  void resetOrientation() {
    _pitch = 42.0;
    _zoom = 1.0;
    _sensorLocked = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
