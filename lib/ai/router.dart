import 'ai_bridge.dart';

enum Intent { findWater, wayOut, timeDaylight, whichDirection, findHelp, emergency, survivalHowto, other }

enum Route { template, guide, llm, emergency }

class RouteDecision {
  final Intent intent;
  final double intentConfidence;
  final String? topic;
  final double topicConfidence;
  final double urgency; // 0..3
  final double needsReasoning; // 0..1
  final Route route;
  final String source; // laya | keywords
  final int ms;

  const RouteDecision({
    required this.intent,
    required this.intentConfidence,
    required this.topic,
    required this.topicConfidence,
    required this.urgency,
    required this.needsReasoning,
    required this.route,
    required this.source,
    required this.ms,
  });

  @override
  String toString() =>
      'intent ${intent.name} ${(intentConfidence * 100).round()}% · topic ${topic ?? '-'} ${(topicConfidence * 100).round()}% '
      '· urgency ${urgency.toStringAsFixed(1)}/3 · needs reasoning ${(needsReasoning * 100).round()}% · $source $ms ms';
}

/// Laya decides whether a question can be answered from data (template), from the guide, or
/// needs Gemma. Falls back to keywords if Laya is not available.
class QuestionRouter {
  final AiBridge ai;
  bool layaReady;
  QuestionRouter(this.ai, {this.layaReady = false});

  static const topics = <String, String>{
    'lost_stop': 'being lost, not knowing where you are',
    'water_purify': 'finding or purifying drinking water, thirst',
    'hypothermia': 'cold, freezing, wet, shivering',
    'heat': 'heat, sun, overheating',
    'bear': 'a bear',
    'mountain_lion': 'a mountain lion or cougar',
    'injury': 'injury, sprain, broken bone, fall',
    'bleeding': 'bleeding or a cut',
    'signaling': 'signaling rescuers, being found, whistle',
    'shelter': 'building a shelter',
    'night': 'darkness, spending the night',
    'river_crossing': 'crossing a river or stream',
    'lightning': 'thunderstorm or lightning',
    'fire': 'making a fire or wildfire',
    'altitude': 'altitude sickness, headache at elevation',
  };

  static final Map<String, dynamic> _questions = {
    'intent': {
      'type': 'choice',
      'instructions': 'What does the hiker want right now?',
      'criteria': {
        'find_water': 'where to find water nearby',
        'way_out': 'the way out, nearest trail, trailhead or road, how to get back',
        'time_daylight': 'what time it is or how long until sunset or dark',
        'which_direction': 'which direction to walk or which way they are facing',
        'find_help': 'the nearest ranger, visitor center or people',
        'emergency': 'an emergency: someone is seriously hurt, bleeding, unconscious or in danger',
        'survival_howto': 'how to handle a survival situation such as cold, animals, injury or shelter',
        'other': 'something else or a general question',
      },
    },
    'topic': {
      'type': 'choice',
      'instructions': 'Which survival topic is this about?',
      'criteria': topics,
    },
    'urgency': {
      'type': 'score',
      'instructions': 'How urgent is the hiker\'s situation?',
      'criteria': ['calm, just asking', 'worried or uncomfortable', 'hurt or at risk', 'life-threatening'],
    },
    'needs_reasoning': {
      'type': 'noul',
      'instructions': 'Does answering need advice or explanation, not just a simple fact like a distance or a time?',
    },
  };

  static const _intentByLabel = {
    'find_water': Intent.findWater,
    'way_out': Intent.wayOut,
    'time_daylight': Intent.timeDaylight,
    'which_direction': Intent.whichDirection,
    'find_help': Intent.findHelp,
    'emergency': Intent.emergency,
    'survival_howto': Intent.survivalHowto,
    'other': Intent.other,
  };

  static const _lookup = {Intent.findWater, Intent.wayOut, Intent.timeDaylight, Intent.whichDirection, Intent.findHelp};

  Future<RouteDecision> decide(String text) async {
    final sw = Stopwatch()..start();
    if (layaReady) {
      try {
        final a = await ai.classify(text, _questions);
        final intentA = a['intent'] as Map<String, dynamic>;
        final topicA = a['topic'] as Map<String, dynamic>;
        final urgencyA = a['urgency'] as Map<String, dynamic>;
        final reasonA = a['needs_reasoning'] as Map<String, dynamic>;
        final intent = _intentByLabel[intentA['choice']] ?? Intent.other;
        final intentConf = _topProb(intentA);
        final topic = topicA['choice'] as String?;
        final topicConf = _topProb(topicA);
        final urgency = (urgencyA['score'] as num?)?.toDouble() ?? 0;
        final reasoning = (reasonA['noul'] as num?)?.toDouble() ?? 0.5;
        return RouteDecision(
          intent: intent,
          intentConfidence: intentConf,
          topic: topic,
          topicConfidence: topicConf,
          urgency: urgency,
          needsReasoning: reasoning,
          route: _policy(intent, intentConf, topicConf, urgency, reasoning),
          source: 'laya',
          ms: sw.elapsedMilliseconds,
        );
      } catch (_) {
        // fall through to keywords
      }
    }
    return _keywords(text, sw.elapsedMilliseconds);
  }

  static double _topProb(Map<String, dynamic> a) {
    final p = a['probabilities'];
    if (p is Map && p.isNotEmpty) {
      return p.values.map((v) => (v as num).toDouble()).reduce((x, y) => x > y ? x : y);
    }
    return (a['confidence'] as num?)?.toDouble() ?? 0;
  }

  static Route _policy(Intent intent, double conf, double topicConf, double urgency, double reasoning) {
    if (intent == Intent.emergency || urgency >= 2.5) return Route.emergency;
    if (_lookup.contains(intent) && conf >= 0.55 && reasoning < 0.5) return Route.template;
    if (intent == Intent.survivalHowto && conf >= 0.6 && topicConf >= 0.5 && reasoning < 0.5) return Route.guide;
    // "there is a bear near me": Laya may call the intent "other" but is sure of the topic
    if ((intent == Intent.other || intent == Intent.survivalHowto) && topicConf >= 0.6 && reasoning < 0.5) {
      return Route.guide;
    }
    return Route.llm;
  }

  RouteDecision _keywords(String text, int ms) {
    final t = text.toLowerCase();
    bool has(List<String> w) => w.any(t.contains);
    Intent intent;
    if (has(['bleed', 'unconscious', 'not breathing', 'broken', 'emergency', 'dying', 'help me'])) {
      intent = Intent.emergency;
    } else if (has(['water', 'thirst', 'drink'])) {
      intent = Intent.findWater;
    } else if (has(['way out', 'get out', 'exit', 'trailhead', 'road', 'back to', 'nearest trail'])) {
      intent = Intent.wayOut;
    } else if (has(['sunset', 'dark', 'time is it', 'daylight', 'how long until'])) {
      intent = Intent.timeDaylight;
    } else if (has(['which way', 'direction', 'north', 'south', 'east', 'west'])) {
      intent = Intent.whichDirection;
    } else if (has(['ranger', 'visitor center', 'people', 'rescue'])) {
      intent = Intent.findHelp;
    } else {
      intent = Intent.other;
    }
    String? topic;
    for (final e in topics.entries) {
      if (e.value.split(RegExp(r'[ ,]+')).where((w) => w.length > 3).any(t.contains)) {
        topic = e.key;
        break;
      }
    }
    final route = intent == Intent.emergency
        ? Route.emergency
        : intent == Intent.other
            ? Route.llm
            : Route.template;
    return RouteDecision(
      intent: intent,
      intentConfidence: intent == Intent.other ? 0 : 0.7,
      topic: topic,
      topicConfidence: topic == null ? 0 : 0.6,
      urgency: intent == Intent.emergency ? 3 : 0,
      needsReasoning: route == Route.llm ? 1 : 0,
      route: route,
      source: 'keywords',
      ms: ms,
    );
  }
}
