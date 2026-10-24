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
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _Cards(s: s),
            ),
            Expanded(
              child: a.messages.isEmpty
                  ? _Hint(status: a.status)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: a.messages.length,
                      itemBuilder: (_, i) => _Bubble(m: a.messages[i]),
                    ),
            ),
            _StatusLine(a: a),
            _Composer(a: a, text: _text),
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
        ? 'Dark'
        : us == null
            ? '--'
            : us.isNegative
                ? 'Dusk'
                : 'Sunset ${formatDuration(us)}';
    final sunColor = s.isNight || (us != null && us < const Duration(hours: 1)) ? kDanger : kAccent;
    final f = s.fix;
    final tierColor = switch (s.tier) { PowerTier.normal => kGood, PowerTier.saver => kAccent, PowerTier.critical => kDanger };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Icon(Icons.wb_twilight, color: sunColor, size: 18),
          const SizedBox(width: 4),
          Text(sunText, style: TextStyle(color: sunColor, fontWeight: FontWeight.w600)),
          const Spacer(),
          Icon(f == null ? Icons.gps_off : Icons.gps_fixed, size: 16, color: f == null ? kDanger : (f.simulated ? kWater : kGood)),
          const SizedBox(width: 4),
          Text(f == null ? 'No fix' : (f.simulated ? 'Pinned' : '±${f.accuracy.round()} m'), style: const TextStyle(color: kMuted)),
          const SizedBox(width: 10),
          PopupMenuButton<PowerTier>(
            tooltip: 'Battery mode',
            onSelected: location.overrideTier,
            itemBuilder: (_) => [for (final p in PowerTier.values) PopupMenuItem(value: p, child: Text('Force ${p.name} mode'))],
            child: Row(children: [
              Icon(Icons.battery_std, size: 16, color: tierColor),
              Text('${s.battery}% ${s.tier.name}', style: TextStyle(color: tierColor)),
            ]),
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
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: _Card(
            icon: Icons.directions_walk,
            color: kAccent,
            title: 'Way out',
            main: r == null ? '—' : '${formatDistance(r.distanceM)} ${compassShort(r.initialBearing)}',
            sub: r == null ? (s.fix == null ? 'waiting for GPS' : 'no route') : '${r.target.name} · ${formatDuration(r.walkTime)}${r.offTrail ? ' · off trail' : ''}',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _Card(
            icon: Icons.water_drop,
            color: kWater,
            title: 'Water',
            main: w == null ? '—' : '${formatDistance(w.$2)} ${s.fix == null ? '' : compassShort(bearingDeg(s.fix!.lat, s.fix!.lon, w.$1.lat, w.$1.lon))}',
            sub: w?.$1.name ?? '',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _Card(
            icon: Icons.local_hospital,
            color: kDanger,
            title: 'Help',
            main: h == null ? '—' : formatDistance(h.$2),
            sub: h?.$1.name ?? '',
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, main, sub;
  const _Card({required this.icon, required this.color, required this.title, required this.main, required this.sub});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 4),
                Text(title, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 4),
              Text(main, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub, style: const TextStyle(color: kMuted, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );
}

class _Hint extends StatelessWidget {
  final String status;
  const _Hint({required this.status});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.forest, size: 48, color: kMuted),
            const SizedBox(height: 12),
            const Text('Hold the button and ask, for example:', style: TextStyle(color: kMuted)),
            const SizedBox(height: 8),
            for (final q in const ['"Where is the nearest water?"', '"How do I get out of here?"', '"I am cold and it is getting dark."', '"There is a bear near me."'])
              Text(q, style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 16),
            Text(status, style: const TextStyle(color: kMuted, fontSize: 12), textAlign: TextAlign.center),
          ]),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  const _Bubble({required this.m});

  @override
  Widget build(BuildContext context) => Align(
        alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
          decoration: BoxDecoration(
            color: m.user ? kSurfaceHigh : kSurface,
            borderRadius: BorderRadius.circular(12),
            border: m.user ? null : Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.text.isEmpty ? '…' : m.text, style: const TextStyle(fontSize: 16, height: 1.3)),
            if (m.meta != null) ...[
              const SizedBox(height: 4),
              Text(m.meta!, style: const TextStyle(color: kMuted, fontSize: 10)),
            ],
          ]),
        ),
      );
}

class _StatusLine extends StatelessWidget {
  final Assistant a;
  const _StatusLine({required this.a});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(children: [
          Icon(a.llmLoaded ? Icons.memory : Icons.memory_outlined, size: 14, color: a.llmLoaded ? kAccent : kMuted),
          const SizedBox(width: 4),
          Expanded(child: Text(a.status, style: const TextStyle(color: kMuted, fontSize: 12), overflow: TextOverflow.ellipsis)),
          Text('templates ${a.templateAnswers} · gemma ${a.llmAnswers}', style: const TextStyle(color: kMuted, fontSize: 11)),
        ]),
      );
}

class _Composer extends StatelessWidget {
  final Assistant a;
  final TextEditingController text;
  const _Composer({required this.a, required this.text});

  @override
  Widget build(BuildContext context) {
    final listening = a.phase == Phase.listening;
    final working = a.busy && !listening;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: text,
            enabled: !working && a.phase != Phase.loading,
            textInputAction: TextInputAction.send,
            decoration: const InputDecoration(
              hintText: 'Or type a question',
              filled: true,
              fillColor: kSurface,
              border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              a.ask(v.trim());
              text.clear();
            },
          ),
        ),
        const SizedBox(width: 10),
        if (working || a.phase == Phase.speaking)
          IconButton.filledTonal(iconSize: 32, onPressed: a.stop, icon: const Icon(Icons.stop))
        else
          GestureDetector(
            onTapDown: (_) => a.pressTalk(),
            onTapUp: (_) => a.releaseTalk(),
            onTapCancel: () => a.releaseTalk(),
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(shape: BoxShape.circle, color: listening ? kDanger : kAccent),
              child: Icon(listening ? Icons.graphic_eq : Icons.mic, size: 36, color: Colors.black),
            ),
          ),
      ]),
    );
  }
}
