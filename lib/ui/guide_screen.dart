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
            padding: const EdgeInsets.all(12),
            children: [
              const Text('Survival guide', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Works offline. Tap the speaker to hear a section.', style: TextStyle(color: kMuted)),
              const SizedBox(height: 12),
              for (final s in g.sections)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ExpansionTile(
                    title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(s.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
                    trailing: assistant.speaking && assistant.speakingSource == 'guide:${s.id}'
                        ? IconButton(
                            tooltip: 'Stop',
                            icon: const Icon(Icons.stop_circle, color: kDanger, size: 32),
                            onPressed: assistant.stopSpeaking,
                          )
                        : IconButton(
                            tooltip: 'Read aloud',
                            icon: const Icon(Icons.volume_up, color: kAccent),
                            onPressed: () async {
                              if (assistant.speaking) await assistant.stopSpeaking();
                              assistant.speak('${s.title}. ${s.summary}', source: 'guide:${s.id}');
                            },
                          ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    children: [
                      Text(s.summary, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
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
