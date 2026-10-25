import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai/assistant.dart';
import 'ai/situation.dart';
import 'location/location_service.dart';
import 'ui/here_card.dart';
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

  /// Opens the phone dialer with 911 filled in. Android does not let apps place emergency
  /// calls themselves, and the extra tap guards against a pocket dial.
  Future<void> _callSos() async {
    HapticFeedback.heavyImpact();
    final ok = await launchUrl(Uri(scheme: 'tel', path: '911'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the phone app. Dial 911.')));
    }
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
      // SOS & Aid tab (GuideScreen) hidden for the demo; emergency answers in chat still open the takeover
      SettingsScreen(assistant: widget.assistant, location: widget.location),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // the map gets the full height; settings has its own title
            if (_tab == 1) _Header(assistant: widget.assistant, location: widget.location),
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
        // keep only part of the home-indicator inset: the full inset left a tall empty band under the labels
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: Padding(
            padding: EdgeInsets.only(bottom: math.max(0, MediaQuery.paddingOf(context).bottom - 20)),
            child: NavigationBar(
              selectedIndex: _tab,
              // the last item is a call button, not a tab
              onDestinationSelected: (i) => i == 3 ? _callSos() : setState(() => _tab = i),
              destinations: [
                const NavigationDestination(icon: _MapIcon(), selectedIcon: _MapIcon(selected: true), label: 'TRAIL MAP'),
                const NavigationDestination(
                  icon: Icon(Icons.auto_awesome_outlined, color: kInkMuted),
                  selectedIcon: Icon(Icons.auto_awesome, color: kMoss),
                  label: 'AI',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.tune_outlined, color: kInkMuted),
                  selectedIcon: Icon(Icons.tune, color: kMoss),
                  label: 'SETTINGS',
                ),
                NavigationDestination(
                  icon: Container(
                    width: 48,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kClay, width: 2),
                    ),
                    child: const Icon(Icons.phone, color: kClay, size: 20),
                  ),
                  label: 'SOS 911',
                ),
              ],
            ),
          ),
        ),
      ),
      ]),
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

/// Trail Map tab icon: a water-to-moss gradient pill, the same size as the SOS button.
class _MapIcon extends StatelessWidget {
  final bool selected;
  const _MapIcon({this.selected = false});

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 32,
    decoration: BoxDecoration(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [kWater, kMoss]),
      borderRadius: BorderRadius.circular(16),
      border: selected ? Border.all(color: kInk, width: 2) : null,
    ),
    child: const Icon(Icons.explore, color: kCard, size: 20),
  );
}
