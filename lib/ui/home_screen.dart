import 'package:flutter/material.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../geo/geo_math.dart';
import '../location/location_service.dart';
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
        return Column(
          children: [
            _StatusBar(s: s, location: widget.location),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _Cards(s: s),
            ),
            _QuickPrompts(a: a),
            Expanded(
              child: a.messages.isEmpty
                  ? _Hint(status: a.status)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: a.messages.length,
                      itemBuilder: (_, i) => _Bubble(m: a.messages[i]),
                    ),
            ),
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
  const _StatusBar({required this.s, required this.location});

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
  const _Cards({required this.s});

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
  const _Card({required this.icon, required this.color, required this.title, required this.main, required this.sub});

  @override
  Widget build(BuildContext context) => Container(
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

class _Hint extends StatelessWidget {
  final String status;
  const _Hint({required this.status});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 40, color: kMoss),
          const SizedBox(height: 12),
          const Text(
            'Hold the mic and ask, type below, or tap a prompt above.',
            style: TextStyle(color: kInkMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(status, style: label(kInkMuted, size: 10), textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  const _Bubble({required this.m});

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
    final meta = m.meta ?? '';
    final gemma = meta.startsWith('Gemma');
    final emergency = meta.startsWith('emergency');
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
                  gemma ? 'GEMMA TACTICAL BRIEF' : (emergency ? 'EMERGENCY SCRIPT' : 'OFFLINE GUIDE'),
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
                  if (meta.isNotEmpty) ...[const SizedBox(height: 6), Text(meta, style: const TextStyle(color: kInkMuted, fontSize: 10))],
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
        Text('ON-DEVICE · ${a.templateAnswers} SCRIPTED · ${a.llmAnswers} GEMMA', style: label(kInkMuted, size: 10)),
      ],
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Row(
        children: [
          // hold to talk
          GestureDetector(
            onTapDown: (_) => a.pressTalk(),
            onTapUp: (_) => a.releaseTalk(),
            onTapCancel: () => a.releaseTalk(),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: listening ? kClay : const Color(0xFFF0F4F1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: listening ? kClay : const Color(0xFFD8E0D9)),
              ),
              child: Icon(listening ? Icons.graphic_eq : Icons.mic, size: 24, color: listening ? kCard : kClay),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: text,
              enabled: !working && a.phase != Phase.loading,
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
            child: working || a.phase == Phase.speaking
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
