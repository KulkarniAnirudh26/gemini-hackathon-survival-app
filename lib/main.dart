import 'package:flutter/material.dart';

import 'ai/assistant.dart';
import 'location/location_service.dart';
import 'ui/guide_screen.dart';
import 'ui/home_screen.dart';
import 'ui/map_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final location = LocationService();
  final assistant = Assistant(location)..init();
  runApp(SurvivalApp(assistant: assistant, location: location));
}

class SurvivalApp extends StatelessWidget {
  final Assistant assistant;
  final LocationService location;
  const SurvivalApp({super.key, required this.assistant, required this.location});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sherpa',
    debugShowCheckedModeBanner: false,
    theme: survivalTheme(),
    home: Shell(assistant: assistant, location: location),
  );
}

class Shell extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const Shell({super.key, required this.assistant, required this.location});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _tab = 1; // open on the assistant

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.assistant.mapFocus.addListener(_openMap);
  }

  /// A chat mini map was tapped: show the full map (MapScreen picks up the route).
  void _openMap() {
    if (widget.assistant.mapFocus.value != null && _tab != 0) setState(() => _tab = 0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.location.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.assistant.mapFocus.removeListener(_openMap);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      // the map is only built while visible (battery: no rendering in the background)
      if (_tab == 0) MapScreen(assistant: widget.assistant, location: widget.location) else const SizedBox(),
      HomeScreen(assistant: widget.assistant, location: widget.location),
      GuideScreen(assistant: widget.assistant),
      SettingsScreen(assistant: widget.assistant, location: widget.location),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_tab == 1) const _Header(), // brand only on Home
            Expanded(
              child: IndexedStack(index: _tab, children: pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        // speech can be stopped from every tab
        ListenableBuilder(
          listenable: widget.assistant,
          builder: (_, _) => widget.assistant.speaking
              ? Material(
                  color: kClay,
                  child: InkWell(
                    onTap: widget.assistant.stopSpeaking,
                    child: SizedBox(
                      height: 52,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.stop_circle, color: kCard, size: 28),
                        const SizedBox(width: 10),
                        Text('STOP SPEAKING', style: label(kCard, size: 16)),
                      ]),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kLine)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.explore_outlined, color: kInkMuted),
              selectedIcon: Icon(Icons.explore, color: kInk),
              label: 'TRAIL MAP',
            ),
            NavigationDestination(
              icon: Icon(Icons.home_outlined, color: kInkMuted),
              selectedIcon: Icon(Icons.home, color: kInk),
              label: 'HOME',
            ),
            NavigationDestination(
              icon: Icon(Icons.emergency_outlined, color: kClay),
              selectedIcon: Icon(Icons.emergency, color: kClay),
              label: 'SOS & AID',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined, color: kInkMuted),
              selectedIcon: Icon(Icons.tune, color: kMoss),
              label: 'SETTINGS',
            ),
          ],
        ),
      ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: kLine)),
    ),
    child: Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.landscape, color: kClay, size: 22),
        ),
        const SizedBox(width: 8),
        Text('SHERPA', style: label(kInk, size: 20).copyWith(letterSpacing: 0.4)),
      ],
    ),
  );
}
