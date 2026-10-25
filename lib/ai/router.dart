import 'ai_bridge.dart';

enum Intent { findWater, wayOut, timeDaylight, whichDirection, findHelp, emergency, survivalHowto, general, other }

enum Route { template, guide, llm, emergency }

class RouteDecision {
  final Intent intent;
  final double intentConfidence;
  final String? topic; // guide section id, null when none fits
  final double topicConfidence;
  final double onTopic; // 0..1: lookup or survival situation vs. anything else
  final double urgency; // 0..3
  final double needsReasoning; // 0..1
  final Route route;
  final String reason; // why this route (shown in the debug sheet, logged)
  final String source; // laya | keywords | forced
  final int ms;
  final int textTokens, seqTokens; // Laya: tokens of the question alone vs. the longest prompt built

  const RouteDecision({
    required this.intent,
    required this.intentConfidence,
    required this.topic,
    required this.topicConfidence,
    required this.onTopic,
    required this.urgency,
    required this.needsReasoning,
    required this.route,
    required this.reason,
    required this.source,
    required this.ms,
    this.textTokens = 0,
    this.seqTokens = 0,
  });

  /// The user asked for Gemma explicitly ("Ask Gemma" on a quick answer).
  factory RouteDecision.forced() => const RouteDecision(
        intent: Intent.general,
        intentConfidence: 1,
        topic: null,
        topicConfidence: 0,
        onTopic: 0.5,
        urgency: 0,
        needsReasoning: 1,
        route: Route.llm,
        reason: 'asked for Gemma',
        source: 'forced',
        ms: 0,
      );

  Map<String, dynamic> toJson() => {
        'route': route.name,
        'reason': reason,
        'intent': intent.name,
        'intent_conf': intentConfidence,
        'topic': topic,
        'topic_conf': topicConfidence,
        'on_topic': onTopic,
        'urgency': urgency,
        'needs_reasoning': needsReasoning,
        'source': source,
        'ms': ms,
        'text_tokens': textTokens,
        'seq_tokens': seqTokens,
      };

  @override
  String toString() =>
      '${route.name} ($reason) · intent ${intent.name} ${(intentConfidence * 100).round()}% · topic ${topic ?? 'none'} '
      '${(topicConfidence * 100).round()}% · on-topic ${(onTopic * 100).round()}% · urgency ${urgency.toStringAsFixed(1)}/3 '
      '· reasoning ${(needsReasoning * 100).round()}% · $source $ms ms · tokens $textTokens/$seqTokens';
}

/// Laya (zero-shot classifier) proposes a quick path; the question's own words must confirm it;
/// everything else goes to Gemma. Falls back to keywords if Laya is not available.
class QuestionRouter {
  final AiBridge ai;
  bool layaReady;
  QuestionRouter(this.ai, {this.layaReady = false});

  // Thresholds, tuned with assets/calibration/questions.json (adb ... --ez calibrate true).
  // Calibration on the Pixel (50 questions) showed Laya's topic choice is reliable (0.9+), its
  // intent and needs-reasoning scores are noisy, and a long survival question always "needs
  // reasoning". So the question's own words decide the path; Laya picks the topic, and its
  // reasoning score only vetoes instant map answers.
  static double emergencyUrgency = 2.5;
  static double templateReasoning = 0.55;
  static double guideTopicConf = 0.6;

  /// A person is hurt or missing: emergency script + takeover.
  static const emergencyCues = [
    'bleed', 'blood', 'not breathing', 'breathing', 'unconscious', "won't wake", 'not waking', 'broke', 'broken',
    'fracture', "can't move", 'cannot move', 'missing', 'dying', 'heart attack', 'seizure', 'allerg', 'choking',
    'drowning', 'fell', 'collapsed', 'badly hurt', 'seriously hurt',
  ];

  /// Judgement, explanation or feelings: Gemma, even if a lookup word appears ("should I go back").
  static const gemmaCues = [
    'should i', 'should we', 'worth', 'compare', 'versus', ' vs', 'better', 'which is more', 'explain', 'why',
    'how was', 'how did', 'who ', 'history', 'tell me about', 'tell me a', 'write', 'talk to me', 'anxious', 'scared',
    'alone', 'afraid', 'feel', 'joke', 'what if', 'can you',
  ];

  /// Guide sections and the words that must appear for a guide answer.
  static const topicKeywords = <String, List<String>>{
    'bear': ['bear'],
    'mountain_lion': ['mountain lion', 'cougar', 'puma', 'lion'],
    'hypothermia': ['cold', 'freez', 'shiver', 'hypotherm', 'wet'],
    'heat': ['heat', 'hot', 'overheat', 'sunstroke'],
    'bleeding': ['bleed', 'blood', 'cut', 'wound'],
    'injury': ['broke', 'broken', 'sprain', 'injur', 'fell', 'fall', 'ankle', 'fracture'],
    'shelter': ['shelter'],
    'fire': ['fire', 'wildfire', 'smoke'],
    'river_crossing': ['river', 'cross', 'stream'],
    'lightning': ['lightning', 'thunder', 'storm'],
    'altitude': ['altitude', 'headache', 'dizzy', 'nause'],
    'signaling': ['signal', 'rescue', 'whistle', 'found'],
    'night': ['dark', 'night'],
    'water_purify': ['purif', 'filter', 'boil', 'treat'],
    'lost_stop': ['lost'],
  };

  /// Words that must appear for each instant map-data answer.
  static const lookupKeywords = <Intent, List<String>>{
    Intent.findWater: ['water', 'drink', 'thirst', 'stream', 'spring', 'creek'],
    Intent.wayOut: ['out', 'exit', 'back', 'trailhead', 'road', 'car', 'lost', 'leave', 'parking'],
    Intent.timeDaylight: ['time', 'sunset', 'dark', 'daylight', 'light', 'sunrise'],
    Intent.whichDirection: ['which way', 'direction', 'north', 'south', 'east', 'west', 'heading'],
    Intent.findHelp: ['ranger', 'help', 'visitor', 'rescue', 'people', 'station'],
  };

  // Short option labels: the Laya window is 256 tokens and options come before the question,
  // so long descriptions crowded the question out.
  static final Map<String, dynamic> _firstPass = {
    'intent': {
      'type': 'choice',
      'instructions': 'What does the hiker want?',
      'criteria': {
        'find_water': 'water nearby',
        'way_out': 'the way out',
        'time_daylight': 'time or sunset',
        'which_direction': 'which direction to go',
        'find_help': 'a ranger or help',
        'emergency': 'emergency: someone badly hurt',
        'survival_howto': 'how to handle a danger',
        'general': 'something else',
      },
    },
    'on_topic': {'type': 'noul', 'instructions': 'Is this about finding something nearby or staying safe outdoors?'},
    'urgency': {
      'type': 'score',
      'instructions': 'How urgent is it?',
      'criteria': ['calm', 'worried', 'at risk', 'life-threatening'],
    },
    'needs_reasoning': {'type': 'noul', 'instructions': 'Does it need advice or explanation, not just a fact?'},
  };

  static Map<String, dynamic> _topicQuestion(Iterable<String> candidates) => {
        'topic': {
          'type': 'choice',
          'instructions': 'Which danger is this about?',
          'criteria': {for (final c in candidates) c: c.replaceAll('_', ' '), 'none': 'none of these'},
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
    'general': Intent.general,
  };

  static const lookups = {Intent.findWater, Intent.wayOut, Intent.timeDaylight, Intent.whichDirection, Intent.findHelp};

  static final Map<String, RegExp> _wordRe = {};

  /// Short keywords match whole words (plural ok): "out" must not hit "about", "car" not "careful".
  /// Longer ones are stems: "freez" matches "freezing".
  static bool hasWord(String lowerText, String kw) {
    if (kw.contains(' ')) return lowerText.contains(kw);
    final re = _wordRe.putIfAbsent(
        kw, () => RegExp(kw.length <= 4 ? r'\b' + RegExp.escape(kw) + r'(s|es)?\b' : r'\b' + RegExp.escape(kw)));
    return re.hasMatch(lowerText);
  }

  static List<String> topicsMentioned(String text) {
    final t = text.toLowerCase();
    return [
      for (final e in topicKeywords.entries)
        if (e.value.any((k) => hasWord(t, k))) e.key,
    ];
  }

  static bool mentionsLookup(Intent intent, String text) {
    final t = text.toLowerCase();
    return (lookupKeywords[intent] ?? const []).any((k) => hasWord(t, k));
  }

  Future<RouteDecision> decide(String text) async {
    final sw = Stopwatch()..start();
    if (layaReady) {
      try {
        final a = await ai.classify(text, _firstPass);
        final intentA = a['intent'] as Map<String, dynamic>;
        final intent = _intentByLabel[intentA['choice']] ?? Intent.other;
        final intentConf = _topProb(intentA);
        final onTopic = ((a['on_topic'] as Map?)?['noul'] as num?)?.toDouble() ?? 0.5;
        final urgency = ((a['urgency'] as Map?)?['score'] as num?)?.toDouble() ?? 0;
        final reasoning = ((a['needs_reasoning'] as Map?)?['noul'] as num?)?.toDouble() ?? 0.5;
        var seqTokens = _maxTokens(a, 'seq_tokens');
        final textTokens = _maxTokens(a, 'text_tokens');

        // second pass (topic) only when the question names a danger the guide covers
        String? topic;
        var topicConf = 0.0;
        final mentioned = topicsMentioned(text);
        if (mentioned.isNotEmpty) {
          final t = await ai.classify(text, _topicQuestion(mentioned));
          final topicA = t['topic'] as Map<String, dynamic>;
          final label = topicA['choice'] as String?;
          topic = label == 'none' ? null : label;
          topicConf = _topProb(topicA);
          final s2 = _maxTokens(t, 'seq_tokens');
          if (s2 > seqTokens) seqTokens = s2;
        }
        final (route, reason, routedIntent) = policy(
          text: text,
          intent: intent,
          conf: intentConf,
          topic: topic,
          topicConf: topicConf,
          urgency: urgency,
          reasoning: reasoning,
        );
        return RouteDecision(
          intent: routedIntent,
          intentConfidence: intentConf,
          topic: topic,
          topicConfidence: topicConf,
          onTopic: onTopic,
          urgency: urgency,
          needsReasoning: reasoning,
          route: route,
          reason: reason,
          source: 'laya',
          ms: sw.elapsedMilliseconds,
          textTokens: textTokens,
          seqTokens: seqTokens,
        );
      } catch (_) {
        // fall through to keywords
      }
    }
    return _keywords(text, sw.elapsedMilliseconds);
  }

  static int _maxTokens(Map<String, dynamic> answers, String key) {
    var m = 0;
    for (final v in answers.values) {
      final n = (v is Map ? v[key] as num? : null)?.toInt() ?? 0;
      if (n > m) m = n;
    }
    return m;
  }

  static double _topProb(Map<String, dynamic> a) {
    final p = a['probabilities'];
    if (p is Map && p.isNotEmpty) {
      return p.values.map((v) => (v as num).toDouble()).reduce((x, y) => x > y ? x : y);
    }
    return (a['confidence'] as num?)?.toDouble() ?? 0;
  }

  static bool _anyCue(String lower, List<String> cues) =>
      cues.any((c) => c.length <= 4 && !c.contains(' ') ? hasWord(lower, c) : lower.contains(c));

  /// The intent named by the question's words; Laya's own guess wins when both fit.
  static Intent? lookupFromWords(String text, Intent layaIntent) {
    final matches = [for (final i in lookups) if (mentionsLookup(i, text)) i];
    if (matches.isEmpty) return null;
    return matches.contains(layaIntent) ? layaIntent : matches.first;
  }

  /// Order: emergency cue -> judgement/feelings (Gemma) -> named danger (guide) -> lookup words
  /// (instant map answer) -> Gemma. Returns the route, why, and the intent the answer should use.
  static (Route, String, Intent) policy({
    required String text,
    required Intent intent,
    required double conf,
    required String? topic,
    required double topicConf,
    required double urgency,
    required double reasoning,
  }) {
    final t = text.toLowerCase();
    if (_anyCue(t, emergencyCues)) return (Route.emergency, 'someone hurt or missing', Intent.emergency);
    if (urgency >= emergencyUrgency) return (Route.emergency, 'urgency ${urgency.toStringAsFixed(1)}', Intent.emergency);
    if (_anyCue(t, gemmaCues)) return (Route.llm, 'judgement or feelings', intent);
    if (topic != null && topicConf >= guideTopicConf && topicsMentioned(text).contains(topic)) {
      return (Route.guide, 'guide: $topic ${(topicConf * 100).round()}%', Intent.survivalHowto);
    }
    final mentionedTopics = topicsMentioned(text);
    if (mentionedTopics.length == 1) {
      final t = mentionedTopics.first;
      return (Route.guide, 'guide keyword: $t', Intent.survivalHowto);
    }
    final lookup = lookupFromWords(text, intent);
    if (lookup != null) {
      if (reasoning >= templateReasoning) return (Route.llm, 'needs reasoning ${(reasoning * 100).round()}%', lookup);
      return (Route.template, '${lookup.name} (Laya: ${intent.name} ${(conf * 100).round()}%)', lookup);
    }
    return (Route.llm, intent == Intent.general ? 'general question' : 'open question', intent);
  }

  RouteDecision _keywords(String text, int ms) {
    final t = text.toLowerCase();
    bool has(List<String> w) => w.any(t.contains);
    Intent intent;
    if (has(['bleed', 'unconscious', 'not breathing', 'broken', 'emergency', 'dying', 'help me'])) {
      intent = Intent.emergency;
    } else {
      intent = Intent.other;
      for (final e in lookupKeywords.entries) {
        if (e.value.any((k) => hasWord(t, k)) && t.split(' ').length <= 10) {
          intent = e.key;
          break;
        }
      }
    }
    final topics = topicsMentioned(text);
    final route = intent == Intent.emergency
        ? Route.emergency
        : lookups.contains(intent)
            ? Route.template
            : Route.llm;
    return RouteDecision(
      intent: intent,
      intentConfidence: intent == Intent.other ? 0 : 0.7,
      topic: topics.isEmpty ? null : topics.first,
      topicConfidence: topics.isEmpty ? 0 : 0.6,
      onTopic: intent == Intent.other ? 0 : 1,
      urgency: intent == Intent.emergency ? 3 : 0,
      needsReasoning: route == Route.llm ? 1 : 0,
      route: route,
      reason: 'keywords (Laya unavailable)',
      source: 'keywords',
      ms: ms,
    );
  }
}
