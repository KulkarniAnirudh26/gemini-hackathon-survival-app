import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          Text('⚡ quick ${a.templateAnswers} · 🧠 gemma ${a.llmAnswers}', style: const TextStyle(color: kMuted, fontSize: 11)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Voice',
            icon: const Icon(Icons.record_voice_over, size: 18, color: kMuted),
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: kSurface,
              showDragHandle: true,
              builder: (_) => _VoiceSheet(a: a),
            ),
          ),
        ]),
      );
}

/// Pick the KittenTTS voice and pace; "Test" speaks a calm sample line.
class _VoiceSheet extends StatelessWidget {
  final Assistant a;
  const _VoiceSheet({required this.a});

  static String _label(String v) {
    final m = RegExp(r'expr-voice-(\d)-(m|f)').firstMatch(v);
    if (m == null) return v;
    return '${m.group(2) == 'f' ? 'Female' : 'Male'} voice ${int.parse(m.group(1)!) - 1}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: a,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Voice', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Text('KittenTTS, on-device. A slower pace sounds calmer.', style: TextStyle(color: kMuted)),
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
                  value: a.speed,
                  min: 0.7,
                  max: 1.1,
                  divisions: 8,
                  label: '${a.speed.toStringAsFixed(2)}x',
                  onChanged: (v) => a.setVoice(a.voice, v),
                ),
              ),
              Text('${a.speed.toStringAsFixed(2)}x'),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: Icon(a.speaking ? Icons.stop : Icons.play_arrow),
              label: Text(a.speaking ? 'Stop' : 'Test voice'),
              onPressed: () async {
                if (a.speaking) return a.stopSpeaking();
                a.speak("Okay, I'm here with you. Take a slow breath. We'll find the way out together, one step at a time.",
                    source: 'voice-test');
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
        ? kSurfaceHigh
        : listening
            ? kDanger
            : stopMode
                ? const Color(0xFF616161)
                : kAccent;
    final caption = loading
        ? 'Loading models…'
        : listening
            ? 'Listening… release to send'
            : stopMode
                ? 'Tap to stop'
                : 'Hold to talk';
    final icon = listening
        ? Icons.graphic_eq
        : stopMode
            ? Icons.stop
            : Icons.mic;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: text,
              enabled: !working && !loading,
              textInputAction: TextInputAction.send,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Or type a question',
                filled: true,
                fillColor: kSurface,
                border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(20))),
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          IconButton(onPressed: working || loading ? null : _send, icon: const Icon(Icons.send, color: kAccent)),
        ]),
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
              border: Border.all(color: listening ? Colors.white : Colors.transparent, width: 4),
            ),
            child: Icon(icon, size: 60, color: Colors.black),
          ),
        ),
        const SizedBox(height: 6),
        Text(caption, style: TextStyle(color: listening ? kDanger : kMuted, fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
