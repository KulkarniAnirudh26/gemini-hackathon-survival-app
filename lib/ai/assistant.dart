import 'dart:async';

import 'package:flutter/foundation.dart';

import '../geo/geo_data.dart';
import '../geo/nps_layers.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import '../rag/guide.dart';
import '../services/settings_service.dart';
import 'ai_bridge.dart';
import 'router.dart';
import 'situation.dart';
import 'templates.dart';

enum Phase { loading, ready, listening, transcribing, routing, loadingLlm, thinking, speaking }

class ChatMessage {
  final bool user;
  String text;
  String? meta;
  final DateTime at = DateTime.now();
  ChatMessage(this.user, this.text, {this.meta});
}

const systemPrompt = '''You are a calm, practical wilderness survival guide inside an offline phone app in Yosemite National Park.
The user may be lost, injured, cold, scared or low on battery. Speak to them directly.
Rules: answer in one to three short spoken sentences, most important action first. No markdown, no lists.
Use the SITUATION, ROUTE, NEAREST and GUIDE data given with the question; never invent trails, places or distances.
If anything sounds life-threatening, tell them to call 911 or use Satellite SOS.''';

class LogEntry {
  final DateTime time;
  final String tag;
  final String message;
  final bool isError;
  LogEntry(this.tag, this.message, {this.isError = false}) : time = DateTime.now();
}

class LlmCallRecord {
  final DateTime time;
  final String query;
  final String route;
  final int ttftMs;
  final double tokensPerSec;
  final int tokenCount;
  final int durationMs;
  final bool isError;
  final String? errorMessage;

  LlmCallRecord({
    required this.time,
    required this.query,
    required this.route,
    required this.ttftMs,
    required this.tokensPerSec,
    required this.tokenCount,
    required this.durationMs,
    this.isError = false,
    this.errorMessage,
  });
}

/// Orchestrates: mic -> Zipformer -> Laya router -> template | guide | Gemma -> KittenTTS.
class Assistant extends ChangeNotifier {
  final AiBridge ai = AiBridge();
  final LocationService location;
  late final SettingsService settings = SettingsService(ai);
  GeoData? geo;
  TrailRouter? router;
  NpsLayers? nps;
  Guide? guide;
  late final QuestionRouter questionRouter = QuestionRouter(ai);

  Phase phase = Phase.loading;
  String status = 'Starting…';
  Map<String, dynamic> models = {};
  bool llmLoaded = false;
  final List<ChatMessage> messages = [];
  final List<LogEntry> logs = [];
  final List<LlmCallRecord> recentCalls = [];
  ChatMessage? _streaming;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  int templateAnswers = 0, llmAnswers = 0;

  // Performance Telemetry
  DateTime? _llmStartTime;
  String _currentQuery = '';
  String _currentRoute = 'llm';
  int lastTtftMs = 0;
  double lastTokensPerSec = 0.0;
  int lastTokenCount = 0;
  int lastRouterLatencyMs = 0;
  int lastAsrLatencyMs = 0;

  double get avgTtftMs {
    final valid = recentCalls.where((c) => !c.isError && c.ttftMs > 0);
    if (valid.isEmpty) return 0;
    return valid.map((c) => c.ttftMs).reduce((a, b) => a + b) / valid.length;
  }

  double get avgTokensPerSec {
    final valid = recentCalls.where((c) => !c.isError && c.tokensPerSec > 0);
    if (valid.isEmpty) return 0;
    return valid.map((c) => c.tokensPerSec).reduce((a, b) => a + b) / valid.length;
  }

  void log(String tag, String msg, {bool isError = false}) {
    logs.add(LogEntry(tag, msg, isError: isError));
    if (logs.length > 200) logs.removeAt(0);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  Assistant(this.location);

  Future<void> init() async {
    _eventsSub = ai.events.listen(_onEvent);
    status = 'Loading map, trails and guide…';
    notifyListeners();
    try {
      guide = await Guide.load();
      geo = await GeoData.load();
      router = TrailRouter(geo!);
      nps = await NpsLayers.load();
    } catch (e) {
      status = 'Map data missing: $e';
    }
    await ai.requestMic();
    unawaited(location.start());
    status = 'Loading speech, router and voice models…';
    notifyListeners();
    try {
      final dir = await ai.modelsDir();
      models = await ai.init(dir!);
      questionRouter.layaReady = models['laya'] == true;
      final missing = [
        if (models['zipformer'] != true) 'speech',
        if (models['laya'] != true) 'router',
        if (models['kitten'] != true) 'voice',
        if (models['gemmaPresent'] != true) 'gemma',
      ];
      status = missing.isEmpty ? 'Ready. Hold the button and talk.' : 'Ready (missing: ${missing.join(', ')})';
      await settings.refreshHardwareInfo();
    } catch (e) {
      status = 'AI models failed to load: $e';
    }
    phase = Phase.ready;
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'llm_loading':
        phase = Phase.loadingLlm;
        status = 'Waking up Gemma…';
        log('LLM', 'Loading Gemma into memory...');
      case 'llm_ready':
        llmLoaded = true;
        phase = Phase.thinking;
        status = 'Thinking…';
        log('LLM', 'Gemma model ready');
      case 'llm_unloaded':
        llmLoaded = false;
        log('LLM', 'Gemma model unloaded from memory');
      case 'llm_chunk':
        final chunk = e['text'] as String;
        if (lastTtftMs == 0 && _llmStartTime != null) {
          lastTtftMs = DateTime.now().difference(_llmStartTime!).inMilliseconds;
          log('PERF', 'TTFT: $lastTtftMs ms');
        }
        lastTokenCount++;
        _streaming?.text += chunk;
        phase = Phase.thinking;
      case 'llm_done':
        _streaming = null;
        if (_llmStartTime != null) {
          final now = DateTime.now();
          final durMs = now.difference(_llmStartTime!).inMilliseconds;
          final durSec = durMs / 1000.0;
          if (durSec > 0) {
            lastTokensPerSec = lastTokenCount / durSec;
            log('PERF', 'Decode speed: ${lastTokensPerSec.toStringAsFixed(1)} tok/s ($lastTokenCount tokens in ${durSec.toStringAsFixed(1)}s)');
          }
          recentCalls.insert(
            0,
            LlmCallRecord(
              time: now,
              query: _currentQuery,
              route: _currentRoute,
              ttftMs: lastTtftMs,
              tokensPerSec: lastTokensPerSec,
              tokenCount: lastTokenCount,
              durationMs: durMs,
            ),
          );
          if (recentCalls.length > 25) recentCalls.removeLast();
        }
        if (phase == Phase.thinking) phase = Phase.ready;
        status = 'Ready.';
        log('LLM', 'Generation complete');
      case 'tts_start':
        phase = Phase.speaking;
        log('TTS', 'Playback started');
      case 'tts_done':
        if (_streaming == null) phase = Phase.ready;
        log('TTS', 'Playback done');
      case 'error':
        status = 'Error: ${e['message']}';
        log('ERR', '${e['message']}', isError: true);
        if (_llmStartTime != null) {
          recentCalls.insert(
            0,
            LlmCallRecord(
              time: DateTime.now(),
              query: _currentQuery,
              route: _currentRoute,
              ttftMs: lastTtftMs,
              tokensPerSec: 0,
              tokenCount: lastTokenCount,
              durationMs: DateTime.now().difference(_llmStartTime!).inMilliseconds,
              isError: true,
              errorMessage: e['message'] as String?,
            ),
          );
        }
        _streaming = null;
        phase = Phase.ready;
    }
    notifyListeners();
  }

  bool get busy => phase != Phase.ready && phase != Phase.speaking;

  Future<void> pressTalk() async {
    if (phase == Phase.loading) return;
    await ai.stopSpeaking();
    await ai.startListening();
    phase = Phase.listening;
    status = 'Listening…';
    notifyListeners();
  }

  Future<void> releaseTalk() async {
    if (phase != Phase.listening) return;
    phase = Phase.transcribing;
    status = 'Transcribing…';
    notifyListeners();
    String text;
    try {
      text = await ai.stopListening();
    } catch (e) {
      status = 'Speech recognition failed: $e';
      phase = Phase.ready;
      notifyListeners();
      return;
    }
    if (text.trim().isEmpty) {
      status = 'I did not catch that. Hold the button while you speak.';
      phase = Phase.ready;
      notifyListeners();
      return;
    }
    await ask(text);
  }

  Future<void> ask(String text) async {
    messages.add(ChatMessage(true, text));
    phase = Phase.routing;
    status = 'Understanding…';
    notifyListeners();

    final decision = await questionRouter.decide(text);
    final s = Situation.build(location, geo, router);
    final g = guide!;
    final critical = location.tier == PowerTier.critical;
    var route = decision.route;
    if (critical && route == Route.llm) route = Route.guide; // save battery: no Gemma when critical
    if (route == Route.llm && models['gemmaPresent'] != true) route = Route.guide;

    switch (route) {
      case Route.emergency:
        _say(Templates.emergency(decision, g), decision, 'emergency script');
        // then let Gemma add situation-specific advice, unless the battery is critical
        if (!critical && models['gemmaPresent'] == true) await _llm(text, decision, s);
      case Route.template:
        templateAnswers++;
        _say(Templates.answer(decision.intent, s), decision, 'template, no LLM');
      case Route.guide:
        templateAnswers++;
        final topic = decision.topicConfidence >= 0.5 ? decision.topic : g.search(text, k: 1).firstOrNull?.section.id;
        _say(Templates.guideSummary(topic ?? 'lost_stop', g), decision, 'guide: ${topic ?? 'lost_stop'}');
      case Route.llm:
        await _llm(text, decision, s);
    }
  }

  void _say(String text, RouteDecision d, String how) {
    messages.add(ChatMessage(false, text, meta: '$how · $d'));
    phase = Phase.speaking;
    status = 'Speaking…';
    notifyListeners();
    ai.speak(text);
  }

  Future<void> _llm(String question, RouteDecision d, Situation s) async {
    llmAnswers++;
    final g = guide!;
    final hits = <GuideHit>[];
    final topicSection = d.topic == null || d.topicConfidence < 0.35 ? null : g.byId(d.topic!);
    if (topicSection != null) hits.add(GuideHit(topicSection, 1));
    for (final h in g.search(question, k: 2)) {
      if (hits.length < 2 && hits.every((x) => x.section.id != h.section.id)) hits.add(h);
    }
    final prompt = '${s.contextBlock(hits)}\n\nQuestion: $question';
    final msg = ChatMessage(false, '', meta: 'Gemma 4 E2B · $d · guide: ${hits.map((h) => h.section.id).join(', ')}');
    messages.add(msg);
    _streaming = msg;
    _llmStartTime = DateTime.now();
    _currentQuery = question;
    _currentRoute = d.route.name;
    lastTtftMs = 0;
    lastTokenCount = 0;
    phase = llmLoaded ? Phase.thinking : Phase.loadingLlm;
    status = llmLoaded ? 'Thinking…' : 'Waking up Gemma…';
    notifyListeners();
    if (!llmLoaded && settings.speakAnswers) ai.speak('Let me think about that.');
    await ai.generate(settings.systemPrompt, prompt, speak: settings.speakAnswers);
  }

  Future<void> stop() async {
    await ai.cancelGenerate();
    await ai.stopSpeaking();
    _streaming = null;
    phase = Phase.ready;
    status = 'Stopped.';
    notifyListeners();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}
