import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../location/location_service.dart';
import '../ui/theme.dart';

/// The offline 3D map: aerial imagery (or the printed NPS park map) draped over real Yosemite
/// terrain. It is a native Android screen (android/.../map3d/Map3dActivity.kt) that serves its
/// page and tiles from the app, so it needs no network.
class Map3d {
  static const _channel = MethodChannel('survival/map3d');

  /// False when the 3D tilesets aren't bundled in this build
  /// (scripts/build_android_assets.py --tiles --terrain --imagery).
  static Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false; // not on Android
    }
  }

  /// Opens the 3D map, showing [lat]/[lon] (the current fix) when given. Completes when it
  /// closes: true if the user tapped "Home" (go to the home dashboard), false for Back.
  static Future<bool> open({double? lat, double? lon}) async =>
      await _channel.invokeMethod<bool>('open', {'lat': lat, 'lon': lon}) ?? false;
}

/// "3D MAP" button for the top of the home screen: opens the 3D map at the latest fix.
class Map3dButton extends StatelessWidget {
  final LocationService location;

  /// Called when the user leaves the 3D map with its "Home" button.
  final VoidCallback? onHome;
  const Map3dButton({super.key, required this.location, this.onHome});

  Future<void> _open(BuildContext context) async {
    if (!await Map3d.available()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("The 3D map data isn't included in this build.")),
        );
      }
      return;
    }
    final f = location.fix;
    if (await Map3d.open(lat: f?.lat, lon: f?.lon)) onHome?.call();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Open 3D map',
        child: InkWell(
          onTap: () => _open(context),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: kInk,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terrain, size: 16, color: kCard),
                const SizedBox(width: 6),
                Text('3D MAP', style: label(kCard, size: 12)),
              ],
            ),
          ),
        ),
      );
}
