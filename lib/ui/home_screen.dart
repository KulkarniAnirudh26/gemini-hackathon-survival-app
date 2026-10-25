import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../location/location_service.dart';
import 'guide_screen.dart';
import 'route_mini_map.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const HomeScreen({super.key, required this.assistant, required this.location});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  int _seen = 0;
  bool _typing = false;

  /// An emergency answer takes over the screen at once, before Gemma adds anything.
  void _checkEmergency(Assistant a) {
    if (a.messages.length < _seen) _seen = 0; // chat was cleared
    if (a.messages.length <= _seen) return;
    final fresh = a.messages.sublist(_seen);
    _seen = a.messages.length;
    for (final m in fresh) {
      if (!m.user && m.kind == AnswerKind.emergency) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          HapticFeedback.heavyImpact();
          Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _EmergencyTakeover(a: a, m: m)));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.location]),
      builder: (context, _) {
        final a = widget.assistant;
        _checkEmergency(a);
        final s = Situation.build(widget.location, a.geo, a.router);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        final chatting = a.messages.isNotEmpty;
        return Column(
          children: [
            _StatusBar(s: s, a: a, location: widget.location, onBack: chatting ? a.clearChat : null),
            if (!chatting)
              // dashboard: the essentials, big; asking anything switches to the chat view
              Expanded(child: _Dashboard(s: s, a: a))
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: _Cards(s: s, a: a),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: a.messages.length,
                  itemBuilder: (_, i) => _Bubble(m: a.messages[i], a: a),
                ),
              ),
            ],
            if (_typing)
              _Composer(a: a, text: _text, onClose: () => setState(() => _typing = false))
            else
              _VoiceBar(a: a, onKeyboard: () => setState(() => _typing = true)),
          ],
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  final Situation s;
  final Assistant a;
  final LocationService location;
  final VoidCallback? onBack; // chat view: back to the dashboard
  const _StatusBar({required this.s, required this.a, required this.location, this.onBack});

  @override
  Widget build(BuildContext context) {
    // no clock or battery here: the phone's own status bar already shows them
    final us = s.untilSunset;
    final sunText = s.isNight
        ? 'DARK'
        : us == null
            ? '--'
            : us.isNegative
                ? 'DUSK'
                : 'SUNSET IN ${formatDuration(us).toUpperCase()}';
    final sunWarn = s.isNight || (us != null && us < const Duration(hours: 1));
    final f = s.fix;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          if (onBack != null) ...[
            InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.dashboard_outlined, size: 20, color: kInk)),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: _Chip(icon: Icons.wb_twilight, text: sunText, warn: sunWarn)),
          const SizedBox(width: 8),
          Flexible(
            child: _Chip(
              icon: f == null ? Icons.gps_off : Icons.gps_fixed,
              text: f == null ? 'FINDING GPS' : (f.simulated ? 'PINNED POSITION' : 'GPS ±${f.accuracy.round()} M'),
              warn: f == null,
            ),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Voice and battery',
            icon: const Icon(Icons.tune, size: 20, color: kInkMuted),
            onPressed: () => showModalBottomSheet(
              context: context,
              showDragHandle: true,
              builder: (_) => _SettingsSheet(a: a, location: location),
            ),
          ),
        ],
      ),
    );
  }
}

/// The home screen before any question: big, glanceable tiles. Tapping one asks about it.
class _Dashboard extends StatelessWidget {
  final Situation s;
  final Assistant a;
  const _Dashboard({required this.s, required this.a});

  void _ask(String q) {
    if (!a.busy && a.phase != Phase.loading) a.ask(q, input: 'card');
  }

  @override
  Widget build(BuildContext context) {
    final r = s.routeOut;
    final w = s.water;
    final h = s.help;
    final f = s.fix;
    final us = s.untilSunset;
    final sunset = s.sun.sunset;
    final dark = s.isNight || (us != null && us.isNegative);
    final lowLight = us != null && !us.isNegative && us < const Duration(hours: 1);
    String dir((Poi, double)? p) => p == null || f == null ? '' : compassShort(bearingDeg(f.lat, f.lon, p.$1.lat, p.$1.lon));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      children: [
        Row(children: [
          Expanded(
            child: _BigTile(
              icon: Icons.exit_to_app,
              color: r != null && r.offTrail ? kClay : kMoss,
              title: 'WAY OUT',
              value: r == null ? '—' : formatDistance(r.distanceM),
              unit: r == null ? '' : compassShort(r.initialBearing),
              lines: [
                r == null ? (f == null ? 'Waiting for GPS' : 'No route found') : r.target.name,
                if (r != null) '~${formatDuration(r.walkTime)} walk · +${r.ascentM.round()} m${r.offTrail ? ' · off trail' : ''}',
              ],
              onTap: () => _ask('How do I get out of here?'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _BigTile(
              icon: Icons.water_drop,
              color: kWater,
              title: 'WATER',
              value: w == null ? '—' : formatDistance(w.$2),
              unit: dir(w),
              lines: [w?.$1.name ?? 'None mapped nearby', 'Treat before drinking'],
              onTap: () => _ask('Where is the nearest water?'),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _BigTile(
              icon: dark ? Icons.nights_stay : Icons.wb_twilight,
              color: dark || lowLight ? kClay : kTrail,
              title: 'DAYLIGHT',
              value: dark ? 'Dark' : (us == null ? '—' : formatDuration(us)),
              unit: dark ? '' : 'left',
              lines: [
                'Now ${_hhmm(s.now)}',
                if (sunset != null) 'Sunset ${_hhmm(sunset)}',
              ],
              onTap: () => _ask('How long until sunset?'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _BigTile(
              icon: Icons.local_hospital,
              color: kClay,
              title: 'HELP',
              value: h == null ? '—' : formatDistance(h.$2),
              unit: dir(h),
              lines: [h?.$1.name ?? 'None mapped nearby', 'SOS: 911 / Satellite'],
              onTap: () => _ask('Where is the nearest ranger station or help?'),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        _QuickPrompts(a: a),
        const SizedBox(height: 8),
        Text(a.status, style: label(kInkMuted, size: 10), textAlign: TextAlign.center),
      ],
    );
  }
}

class _BigTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, value, unit;
  final List<String> lines;
  final VoidCallback onTap;
  const _BigTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.unit,
    required this.lines,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 2)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 168,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, color: color, size: 26),
                  const SizedBox(width: 6),
                  Text(title, style: label(color, size: 13)),
                ]),
                const Spacer(),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.0, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(unit, style: label(kInkMuted, size: 15)),
                  ],
                ]),
                const SizedBox(height: 6),
                for (final l in lines)
                  Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kInkMuted, fontSize: 12.5)),
              ]),
            ),
          ),
        ),
      );
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Pill status chip: inset fill, moss (nominal) or clay (warning) border, solid pip.
class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warn;
  const _Chip({required this.icon, required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final c = warn ? kClay : kMoss;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kInset,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 3),
          Flexible(
            child: Text(text, style: label(kInk, size: 10), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _Cards extends StatelessWidget {
  final Situation s;
  final Assistant a;
  const _Cards({required this.s, required this.a});

  void _ask(String q) {
    if (!a.busy && a.phase != Phase.loading) a.ask(q, input: 'card');
  }

  @override
  Widget build(BuildContext context) {
    final r = s.routeOut;
    final w = s.water;
    final h = s.help;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: _Card(
              onTap: () => _ask('How do I get out of here?'),
              icon: Icons.directions_walk,
              color: r != null && r.offTrail ? kClay : kMoss,
              title: 'WAY OUT',
              main: r == null ? '—' : '${formatDistance(r.distanceM)} ${compassShort(r.initialBearing)}',
              sub: r == null
                  ? (s.fix == null ? 'waiting for GPS' : 'no route')
                  : '${r.target.name} · ${formatDuration(r.walkTime)}${r.offTrail ? ' · off trail' : ''}',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Card(
              onTap: () => _ask('Where is the nearest water?'),
              icon: Icons.water_drop,
              color: kWater,
              title: 'WATER',
              main: w == null
                  ? '—'
                  : '${formatDistance(w.$2)} ${s.fix == null ? '' : compassShort(bearingDeg(s.fix!.lat, s.fix!.lon, w.$1.lat, w.$1.lon))}',
              sub: w?.$1.name ?? '',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Card(
              onTap: () => _ask('Where is the nearest ranger station or help?'),
              icon: Icons.local_hospital,
              color: kClay,
              title: 'HELP',
              main: h == null ? '—' : formatDistance(h.$2),
              sub: h?.$1.name ?? '',
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, main, sub;
  final VoidCallback? onTap;
  const _Card({required this.icon, required this.color, required this.title, required this.main, required this.sub, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: _body());

  Widget _body() => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: kCard,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: kOutline, width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 4),
            Text(title, style: label(color, size: 10)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          main,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          sub,
          style: const TextStyle(color: kInkMuted, fontSize: 11),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

/// One-tap questions that go through the same router as typed or spoken ones.
class _QuickPrompts extends StatelessWidget {
  final Assistant a;
  const _QuickPrompts({required this.a});

  static const _prompts = [
    (Icons.water_drop_outlined, 'Nearest water', 'Where is the nearest water?'),
    (Icons.directions_walk, 'Way out', 'How do I get out of here?'),
    (Icons.nights_stay_outlined, 'Getting dark', 'I am cold and it is getting dark.'),
    (Icons.pets, 'Bear nearby', 'There is a bear near me.'),
  ];

  @override
  Widget build(BuildContext context) {
    final enabled = !a.busy && a.phase != Phase.loading;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: _prompts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (icon, text, question) = _prompts[i];
          return ActionChip(
            avatar: Icon(icon, size: 16, color: kInk),
            label: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            backgroundColor: kCard,
            side: const BorderSide(color: kLine),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onPressed: enabled ? () => a.ask(question) : null,
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  final Assistant a;
  const _Bubble({required this.m, required this.a});

  @override
  Widget build(BuildContext context) => m.user ? _user(context) : GestureDetector(onLongPress: () => _debug(context), child: _answer());

  Widget _user(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_hhmm(m.at)} Local', style: label(kInkMuted, size: 10).copyWith(letterSpacing: 0)),
                const SizedBox(width: 6),
                Text('YOU', style: label(kMoss, size: 10)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
            decoration: BoxDecoration(
              color: kUserBubble,
              border: Border.all(color: kUserBorder),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Text(m.text, style: const TextStyle(fontSize: 15, height: 1.35)),
          ),
        ],
      ),
    ),
  );

  /// Long-press: how this answer was routed and, for Gemma, the exact prompt.
  void _debug(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
            Text('WHY THIS ANSWER', style: label(kInk, size: 14)),
            const SizedBox(height: 8),
            SelectableText(m.debug ?? '—', style: const TextStyle(fontSize: 13, height: 1.4)),
            if (m.prompt != null) ...[
              const SizedBox(height: 16),
              Text('PROMPT SENT TO GEMMA', style: label(kInk, size: 14)),
              const SizedBox(height: 8),
              SelectableText(m.prompt!, style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.35)),
            ],
          ]),
        ),
      );

  Widget _answer() {
    final gemma = m.kind == AnswerKind.gemma;
    final emergency = m.kind == AnswerKind.emergency;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Icon(gemma ? Icons.auto_awesome : Icons.verified_outlined, size: 16, color: emergency ? kClay : kMoss),
                const SizedBox(width: 6),
                Text(
                  gemma
                      ? 'GEMMA TACTICAL BRIEF'
                      : emergency
                          ? 'EMERGENCY SCRIPT'
                          : m.kind == AnswerKind.quick
                              ? 'OFFLINE MAP DATA'
                              : 'OFFLINE GUIDE',
                  style: label(emergency ? kClay : kMoss, size: 11),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: emergency ? kClay : kLine, width: emergency ? 1.5 : 1),
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kWell,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E9E3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Gemma answers are generated; only the scripted ones are vetted text
                  if (!gemma) ...[Text('VERIFIED OFFLINE ACTION', style: label(kClay, size: 10)), const SizedBox(height: 4)],
                  Text(m.text.isEmpty ? '…' : m.text, style: const TextStyle(fontSize: 15, height: 1.4)),
                  if (m.map != null) RouteMiniMap(assistant: a, route: m.map!),
                  // quick answers come from Laya + templates; one tap re-asks Gemma instead
                  if (!gemma && m.question != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: kMoss, visualDensity: VisualDensity.compact),
                        onPressed: a.busy ? null : () => a.ask(m.question!, forceLlm: true),
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: Text('ASK GEMMA', style: label(kMoss, size: 11)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Voice, pace and battery mode (the battery mode can be forced for demos).
class _SettingsSheet extends StatelessWidget {
  final Assistant a;
  final LocationService location;
  const _SettingsSheet({required this.a, required this.location});

  static String _label(String v) {
    final m = RegExp(r'expr-voice-(\d)-(m|f)').firstMatch(v);
    if (m == null) return v;
    return '${m.group(2) == 'f' ? 'Female' : 'Male'} ${int.parse(m.group(1)!) - 1}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([a, location]),
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('VOICE', style: label(kInk, size: 16)),
            const SizedBox(height: 4),
            const Text('KittenTTS, on-device.', style: TextStyle(color: kInkMuted)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final v in a.voices)
                ChoiceChip(
                  label: Text(_label(v)),
                  selected: (a.voice ?? (a.voices.isEmpty ? null : a.voices.first)) == v,
                  onSelected: (_) => a.setVoice(v, a.speed),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Pace'),
              Expanded(
                child: Slider(
                  value: a.speed.clamp(0.7, 1.2),
                  min: 0.7,
                  max: 1.2,
                  divisions: 10,
                  label: '${a.speed.toStringAsFixed(2)}x',
                  onChanged: (v) => a.setVoice(a.voice, v),
                ),
              ),
              Text('${a.speed.toStringAsFixed(2)}x'),
            ]),
            FilledButton.icon(
              icon: Icon(a.speaking ? Icons.stop : Icons.play_arrow),
              label: Text(a.speaking ? 'STOP' : 'TEST VOICE'),
              onPressed: () async {
                if (a.speaking) return a.stopSpeaking();
                a.speak("Okay, I'm here with you. Take a slow breath. We'll find the way out together.", source: 'voice-test');
              },
            ),
            const SizedBox(height: 20),
            Text('BATTERY MODE · ${location.batteryLevel}%', style: label(kInk, size: 16)),
            const SizedBox(height: 4),
            const Text('Set automatically from the battery level; force one to demo it.', style: TextStyle(color: kInkMuted)),
            const SizedBox(height: 8),
            SegmentedButton<PowerTier>(
              segments: const [
                ButtonSegment(value: PowerTier.normal, label: Text('Normal')),
                ButtonSegment(value: PowerTier.saver, label: Text('Saver')),
                ButtonSegment(value: PowerTier.critical, label: Text('Critical')),
              ],
              selected: {location.tier},
              onSelectionChanged: (s) => location.overrideTier(s.first),
            ),
          ]),
        ),
      );
}

/// The main input: one big hold-to-talk button. Typing is the secondary path.
class _VoiceBar extends StatelessWidget {
  final Assistant a;
  final VoidCallback onKeyboard;
  const _VoiceBar({required this.a, required this.onKeyboard});

  @override
  Widget build(BuildContext context) {
    final listening = a.phase == Phase.listening;
    final loading = a.phase == Phase.loading;
    final working = a.busy && !listening && !loading;
    final stopMode = working || a.speaking;
    final caption = switch (a.phase) {
      Phase.loading => 'GETTING READY…',
      Phase.listening => 'LISTENING… RELEASE TO ASK',
      _ when stopMode => 'TAP TO STOP',
      Phase.ready => 'HOLD TO TALK',
      _ => a.status.toUpperCase(),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _RoundIcon(icon: Icons.keyboard_alt_outlined, tooltip: 'Type instead', onTap: onKeyboard),
          const Spacer(),
          GestureDetector(
            onTapDown: stopMode || loading
                ? null
                : (_) {
                    HapticFeedback.mediumImpact();
                    a.pressTalk();
                  },
            onTapUp: stopMode || loading
                ? null
                : (_) {
                    HapticFeedback.lightImpact();
                    a.releaseTalk();
                  },
            onTapCancel: stopMode || loading ? null : () => a.releaseTalk(),
            onTap: stopMode ? a.stop : null,
            child: _MicButton(listening: listening, enabled: !loading, stop: stopMode),
          ),
          const Spacer(),
          const SizedBox(width: 48),
        ]),
        const SizedBox(height: 6),
        Text(caption, style: label(listening ? kClay : kInkMuted, size: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

class _MicButton extends StatefulWidget {
  final bool listening, enabled, stop;
  const _MicButton({required this.listening, required this.enabled, required this.stop});

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    // the pulse only runs while recording (battery)
    if (widget.listening && !_pulse.isAnimating) _pulse.repeat();
    if (!widget.listening && _pulse.isAnimating) _pulse.reset();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? kOutline
        : widget.listening
            ? kInk
            : widget.stop
                ? kInkMuted
                : kClay;
    return SizedBox(
      width: 140,
      height: 140,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) => Stack(alignment: Alignment.center, children: [
          if (widget.listening)
            Container(
              width: 110 + 30 * _pulse.value,
              height: 110 + 30 * _pulse.value,
              decoration: BoxDecoration(shape: BoxShape.circle, color: kClay.withValues(alpha: 0.35 * (1 - _pulse.value))),
            ),
          child!,
        ]),
        child: Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: kInk, width: 2),
            boxShadow: const [BoxShadow(color: kInk, offset: Offset(0, 3))],
          ),
          child: Icon(widget.listening ? Icons.graphic_eq : (widget.stop ? Icons.stop : Icons.mic), size: 52, color: kCard),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap, this.color = kInk});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        iconSize: 24,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: kCard,
          foregroundColor: color,
          side: BorderSide(color: color == kInk ? kLine : color, width: 1.5),
        ),
        icon: Icon(icon),
      );
}

class _Composer extends StatelessWidget {
  final Assistant a;
  final TextEditingController text;
  final VoidCallback onClose;
  const _Composer({required this.a, required this.text, required this.onClose});

  void _send() {
    final v = text.text.trim();
    if (v.isEmpty) return;
    a.ask(v);
    text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final listening = a.phase == Phase.listening;
    final working = a.busy && !listening;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Row(
        children: [
          _RoundIcon(icon: Icons.mic, tooltip: 'Talk instead', onTap: onClose, color: kClay),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: text,
              enabled: !working && a.phase != Phase.loading,
              autofocus: true,
              textInputAction: TextInputAction.send,
              style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Ask Gemma about navigation, wildlife',
                hintStyle: TextStyle(color: Color(0xFF5C6E61), fontSize: 14),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 12),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 48,
            height: 48,
            child: working || a.speaking
                ? IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: kClay,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: a.stop,
                    icon: const Icon(Icons.stop, color: kCard),
                  )
                : IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: kInk,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _send,
                    icon: const Icon(Icons.arrow_upward, color: kCard),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen emergency card: the scripted answer, the 911 / SOS call to action and the
/// matching first-aid steps, shown the moment the router flags an emergency.
class _EmergencyTakeover extends StatelessWidget {
  final Assistant a;
  final ChatMessage m;
  const _EmergencyTakeover({required this.a, required this.m});

  @override
  Widget build(BuildContext context) {
    final topic = RegExp(r'topic (\w+)').firstMatch(m.debug ?? '')?.group(1);
    final section = topic == null || topic == 'none' ? null : a.guide?.byId(topic);
    return Scaffold(
      backgroundColor: kClay,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.emergency, color: kCard, size: 28),
              const SizedBox(width: 8),
              Expanded(child: Text('EMERGENCY', style: label(kCard, size: 22))),
              IconButton(
                tooltip: 'Back to chat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: kCard, size: 28),
              ),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(m.text, style: const TextStyle(color: kCard, fontSize: 22, fontWeight: FontWeight.w700, height: 1.35)),
              ),
            ),
            const SizedBox(height: 16),
            const SosBanner(onClay: true),
            const SizedBox(height: 12),
            if (section != null)
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                icon: const Icon(Icons.format_list_numbered),
                label: Text('STEP-BY-STEP: ${section.title.toUpperCase()}'),
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => StepsScreen(assistant: a, section: section, name: section.title)),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(context),
              child: const Text('BACK TO CHAT'),
            ),
          ]),
        ),
      ),
    );
  }
}
