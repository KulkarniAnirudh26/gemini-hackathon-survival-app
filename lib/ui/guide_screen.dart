import 'package:flutter/material.dart';

import '../ai/assistant.dart';
import 'theme.dart';

class GuideScreen extends StatelessWidget {
  final Assistant assistant;
  const GuideScreen({super.key, required this.assistant});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: assistant,
    builder: (context, _) {
      final g = assistant.guide;
      if (g == null) return const Center(child: Text('Loading guide…'));
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Icon(Icons.emergency, color: kClay),
              const SizedBox(width: 8),
              Text('SOS & AID', style: label(kInk, size: 22).copyWith(letterSpacing: 0.4)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Vetted survival guide. Works offline. Tap the speaker to hear a section.', style: TextStyle(color: kInkMuted)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kClay,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kInk, width: 2),
            ),
            child: const Text(
              'Life-threatening? Call 911, or use Satellite SOS if you have no signal.',
              style: TextStyle(color: kCard, fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          for (final s in g.sections)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  s.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kInkMuted),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.volume_up, color: kInk),
                  onPressed: () => assistant.ai.speak(s.summary),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  Text(s.summary, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(s.body.replaceAll('**', ''), style: const TextStyle(height: 1.4)),
                ],
              ),
            ),
        ],
      );
    },
  );
}
