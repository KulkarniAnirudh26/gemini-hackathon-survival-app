import 'package:flutter/material.dart';

import '../ai/assistant.dart';
import '../rag/guide.dart';
import 'theme.dart';

/// First-aid and danger topics shown as big tiles, most urgent first. Everything else in the
/// guide is listed below them. All text comes from the bundled guide, nothing is generated.
const _tiles = [
  ('bleeding', Icons.bloodtype, 'Severe bleeding'),
  ('injury', Icons.personal_injury, 'Injury or fracture'),
  ('hypothermia', Icons.ac_unit, 'Too cold'),
  ('heat', Icons.wb_sunny, 'Heat stroke'),
  ('altitude', Icons.terrain, 'Altitude sickness'),
  ('lightning', Icons.thunderstorm, 'Lightning'),
  ('bear', Icons.pets, 'Bear'),
  ('mountain_lion', Icons.warning_amber, 'Mountain lion'),
  ('lost_stop', Icons.explore_off, 'Lost'),
  ('signaling', Icons.campaign, 'Signal for rescue'),
];

class GuideScreen extends StatelessWidget {
  final Assistant assistant;
  const GuideScreen({super.key, required this.assistant});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: assistant,
        builder: (context, _) {
          final g = assistant.guide;
          final tileIds = {for (final t in _tiles) t.$1};
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SosBanner(),
              const SizedBox(height: 16),
              Text('FIRST AID & DANGER', style: label(kInkMuted, size: 12)),
              const SizedBox(height: 8),
              if (g == null)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Loading guide…')))
              else ...[
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.45,
                  children: [
                    for (final (id, icon, name) in _tiles)
                      if (g.byId(id) case final s?) _Tile(icon: icon, name: name, urgent: _tiles.indexWhere((t) => t.$1 == id) < 6, onTap: () => openSteps(context, assistant, s, name)),
                  ],
                ),
                const SizedBox(height: 20),
                Text('MORE FROM THE GUIDE', style: label(kInkMuted, size: 12)),
                const SizedBox(height: 8),
                for (final s in g.sections.where((s) => !tileIds.contains(s.id)))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        minVerticalPadding: 12,
                        title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(s.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kInkMuted)),
                        trailing: const Icon(Icons.chevron_right, color: kInk),
                        onTap: () => openSteps(context, assistant, s, s.title),
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      );
}

/// The 911 / Satellite SOS call to action, first thing on the SOS tab and the emergency takeover.
class SosBanner extends StatelessWidget {
  final bool onClay;
  const SosBanner({super.key, this.onClay = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: onClay ? kCard : kClay,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kInk, width: 2),
          boxShadow: const [BoxShadow(color: kInk, offset: Offset(3, 3))],
        ),
        child: Row(children: [
          Icon(Icons.sos, size: 36, color: onClay ? kClay : kCard),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Life-threatening? Call 911. No signal: dial 911 anyway and use Satellite SOS with a clear view of the sky.',
              style: TextStyle(color: onClay ? kInk : kCard, fontSize: 15, fontWeight: FontWeight.w700, height: 1.3),
            ),
          ),
        ]),
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String name;
  final bool urgent;
  final VoidCallback onTap;
  const _Tile({required this.icon, required this.name, required this.urgent, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: urgent ? const Color(0xFFFFEDE6) : kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: urgent ? kClay : kOutline, width: urgent ? 2 : 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Icon(icon, size: 32, color: urgent ? kClay : kMoss),
              Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.15)),
            ]),
          ),
        ),
      );
}

void openSteps(BuildContext context, Assistant assistant, GuideSection s, String name) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StepsScreen(assistant: assistant, section: s, name: name)));

/// One guide section as numbered steps: the summary is step 1, each bullet a further step.
class StepsScreen extends StatelessWidget {
  final Assistant assistant;
  final GuideSection section;
  final String name;
  const StepsScreen({super.key, required this.assistant, required this.section, required this.name});

  @override
  Widget build(BuildContext context) {
    final steps = [
      section.summary,
      for (final l in section.body.split('\n'))
        if (l.trimLeft().startsWith('- ')) l.trimLeft().substring(2).replaceAll('**', '').trim(),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kClay,
        foregroundColor: kCard,
        title: Text(name.toUpperCase(), style: label(kCard, size: 18)),
        actions: [
          // speak / stop toggle; the global "Stop speaking" bar works here too
          ListenableBuilder(
            listenable: assistant,
            builder: (_, _) => assistant.speaking && assistant.speakingSource == 'guide:${section.id}'
                ? IconButton(tooltip: 'Stop', icon: const Icon(Icons.stop_circle, size: 30), onPressed: assistant.stopSpeaking)
                : IconButton(
                    tooltip: 'Read aloud',
                    icon: const Icon(Icons.volume_up),
                    onPressed: () async {
                      if (assistant.speaking) await assistant.stopSpeaking();
                      assistant.speak('$name. ${steps.join(' ')}', source: 'guide:${section.id}');
                    },
                  ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < steps.length; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: i == 0 ? kInk : kOutline, width: i == 0 ? 2 : 1.5),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: i == 0 ? kClay : kInk, borderRadius: BorderRadius.circular(6)),
                  child: Text('${i + 1}', style: const TextStyle(color: kCard, fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(steps[i], style: TextStyle(fontSize: i == 0 ? 18 : 16, fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500, height: 1.35)),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          const SosBanner(),
        ],
      ),
    );
  }
}
