import 'package:flutter/material.dart';

import 'ai/assistant.dart';
import 'location/location_service.dart';
import 'ui/guide_screen.dart';
import 'ui/home_screen.dart';
import 'ui/map_screen.dart';
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
        title: 'Yosemite Survival',
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
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.location.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(assistant: widget.assistant, location: widget.location),
      // the map is only built while visible (battery: no rendering in the background)
      if (_tab == 1) MapScreen(assistant: widget.assistant, location: widget.location) else const SizedBox(),
      GuideScreen(assistant: widget.assistant),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.mic_none), selectedIcon: Icon(Icons.mic), label: 'Talk'),
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'Guide'),
        ],
      ),
    );
  }
}
