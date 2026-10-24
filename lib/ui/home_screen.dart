import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_data.dart';
import '../geo/geo_math.dart';
import '../location/location_service.dart';
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.location]),
      builder: (context, _) {
        final a = widget.assistant;
        final s = Situation.build(widget.location, a.geo, a.router);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        final chatting = a.messages.isNotEmpty;
        return Column(
          children: [
            _StatusBar(s: s, location: widget.location, onBack: chatting ? a.clearChat : null),
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
            _Composer(a: a, text: _text),
            _StatusLine(a: a),
          ],
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  final Situation s;
  final LocationService location;
  final VoidCallback? onBack; // chat view: back to the dashboard
  const _StatusBar({required this.s, required this.location, this.onBack});

  @override
  Widget build(BuildContext context) {
    final t = s.now;
    final us = s.untilSunset;
    final sunText = s.isNight
        ? 'DARK'
        : us == null
        ? '--'
        : us.isNegative
        ? 'DUSK'
        : 'SUNSET ${formatDuration(us).toUpperCase()}';
    final sunWarn = s.isNight || (us != null && us < const Duration(hours: 1));
    final f = s.fix;
    final tierColor = switch (s.tier) {
      PowerTier.normal => kMoss,
      PowerTier.saver => kTrail,
      PowerTier.critical => kClay,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
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
          Text('${_hhmm(t)} LOCAL', style: label(kInk, size: 13).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: _Chip(icon: Icons.wb_twilight, text: sunText, warn: sunWarn)),
          ),
          const SizedBox(width: 6),
          _Chip(
            icon: f == null ? Icons.gps_off : Icons.gps_fixed,
            text: f == null ? 'NO FIX' : (f.simulated ? 'PINNED' : 'GPS ±${f.accuracy.round()} M'),
            warn: f == null,
          ),
          const SizedBox(width: 6),
          PopupMenuButton<PowerTier>(
            tooltip: 'Battery mode',
            onSelected: location.overrideTier,
            itemBuilder: (_) => [for (final p in PowerTier.values) PopupMenuItem(value: p, child: Text('Force ${p.name} mode'))],
            child: Row(
              children: [
                Icon(Icons.battery_std, size: 16, color: tierColor),
                Text('${s.battery}%', style: label(tierColor)),
              ],
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
  Widget build(BuildContext context) => m.user ? _user(context) : _answer();

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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final Assistant a;
  const _StatusLine({required this.a});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
    child: Row(
      children: [
        Icon(a.llmLoaded ? Icons.lock_outline : Icons.memory_outlined, size: 13, color: a.llmLoaded ? kMoss : kInkMuted),
        const SizedBox(width: 4),
        Expanded(
          child: Text(a.status.toUpperCase(), style: label(kInkMuted, size: 10), overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Text('ON-DEVICE · ${a.templateAnswers} QUICK · ${a.llmAnswers} GEMMA', style: label(kInkMuted, size: 10)),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Voice',
          icon: const Icon(Icons.record_voice_over, size: 18, color: kInkMuted),
          onPressed: () => showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => _VoiceSheet(a: a)),
        ),
      ],
    ),
  );
}

/// Pick the KittenTTS voice and pace; "Test voice" speaks a sample line.
class _VoiceSheet extends StatelessWidget {
  final Assistant a;
  const _VoiceSheet({required this.a});

  static String _label(String v) {
    final m = RegExp(r'expr-voice-(\d)-(m|f)').firstMatch(v);
    if (m == null) return v;
    return '${m.group(2) == 'f' ? 'Female' : 'Male'} ${int.parse(m.group(1)!) - 1}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: a,
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
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: Icon(a.speaking ? Icons.stop : Icons.play_arrow),
              label: Text(a.speaking ? 'STOP' : 'TEST VOICE'),
              onPressed: () async {
                if (a.speaking) return a.stopSpeaking();
                a.speak("Okay, I'm here with you. Take a slow breath. We'll find the way out together.", source: 'voice-test');
              },
            ),
          ]),
        ),
      );
}

class _Composer extends StatelessWidget {
  final Assistant a;
  final TextEditingController text;
  const _Composer({required this.a, required this.text});

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
    final stopMode = working || a.speaking;
    final loading = a.phase == Phase.loading;
    final color = loading
        ? kInset
        : listening
            ? kInk
            : stopMode
                ? kInkMuted
                : kClay;
    final caption = loading
        ? 'LOADING MODELS…'
        : listening
            ? 'LISTENING… RELEASE TO SEND'
            : stopMode
                ? 'TAP TO STOP'
                : 'HOLD TO TALK';
    final icon = listening
        ? Icons.graphic_eq
        : stopMode
            ? Icons.stop
            : Icons.mic;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: text,
                enabled: !working && !loading,
                textInputAction: TextInputAction.send,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Ask Gemma about navigation, wildlife',
                  hintStyle: TextStyle(color: Color(0xFF5C6E61), fontSize: 14),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(onPressed: working || loading ? null : _send, icon: const Icon(Icons.arrow_upward, color: kInk)),
          ]),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTapDown: stopMode || loading
              ? null
              : (_) {
                  HapticFeedback.mediumImpact();
                  a.pressTalk();
                },
          onTapUp: stopMode || loading ? null : (_) => a.releaseTalk(),
          onTapCancel: stopMode || loading ? null : () => a.releaseTalk(),
          onTap: stopMode ? a.stop : null,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: kInk, width: listening ? 5 : 2),
            ),
            child: Icon(icon, size: 58, color: kCard),
          ),
        ),
        const SizedBox(height: 6),
        Text(caption, style: label(listening ? kClay : kInkMuted, size: 12)),
      ]),
    );
  }
}
