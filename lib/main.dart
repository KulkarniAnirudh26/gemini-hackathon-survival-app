import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai/assistant.dart';
import 'ai/situation.dart';
import 'location/location_service.dart';
import 'ui/here_card.dart';
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
      // the map is only built while visible (battery: no rendering in the background)
      if (_tab == 0) MapScreen(assistant: widget.assistant, location: widget.location) else const SizedBox(),
      HomeScreen(assistant: widget.assistant, location: widget.location),
      // SOS & Aid tab (GuideScreen) hidden for the demo; emergency answers in chat still open the takeover
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // the map gets the full height
            if (_tab != 0) _Header(assistant: widget.assistant, location: widget.location),
            Expanded(
              child: IndexedStack(index: _tab, children: pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kLine)),
        ),
        // keep only part of the home-indicator inset: the full inset left a tall empty band under the labels
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: Padding(
            padding: EdgeInsets.only(bottom: math.max(0, MediaQuery.paddingOf(context).bottom - 20)),
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
                  icon: Icon(Icons.auto_awesome_outlined, color: kInkMuted),
                  selectedIcon: Icon(Icons.auto_awesome, color: kMoss),
                  label: 'AI',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Assistant assistant;
  final LocationService location;
  const _Header({required this.assistant, required this.location});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([assistant, location]),
    builder: (context, _) => Container(
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
          const SizedBox(width: 10),
          // way out / water / help, shrunk to fit if the screen is narrow
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: NearbyRow(s: Situation.build(location, assistant.geo, assistant.router)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
