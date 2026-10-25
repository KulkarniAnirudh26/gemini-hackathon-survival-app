import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../geo/geo_data.dart';
import '../geo/nps_layers.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import '../metrics/metrics_log.dart';
import '../rag/guide.dart';
import '../services/settings_service.dart';
import 'ai_bridge.dart';
import 'router.dart';
import 'situation.dart';
import 'templates.dart';

enum Phase { loading, ready, listening, transcribing, routing, loadingLlm, thinking, speaking }

/// Which path produced an answer (drives the bubble header).
enum AnswerKind { quick, guide, gemma, emergency }

class ChatMessage {
  final bool user;
  String text;
  final AnswerKind? kind;
  final String? debug; // router scores: logged to metrics, not shown
  final RouteResult? map; // in-chat mini map (way out / water / help)
  final DateTime at = DateTime.now();
  ChatMessage(this.user, this.text, {this.kind, this.debug, this.map});
}

const systemPrompt = '''You are a calm, warm and practical wilderness survival guide inside an offline phone app in Yosemite National Park.
The user may be lost, injured, cold, scared or low on battery. Speak to them gently and directly, like a steady friend beside them.
If they sound worried, start with a few words of reassurance, then give the single most important action.
If the question is general or not about survival, still answer it helpfully and briefly.
Rules: answer in two to four short, simple spoken sentences. Use calm, plain words. No markdown, no lists.
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
  final List<LogEntry> logs = [];
  final List<LlmCallRecord> recentCalls = [];
  DateTime? _llmStartTime;
  String _currentQuery = '';
  String _currentRoute = 'llm';
  int lastTtftMs = 0;
  double lastTokensPerSec = 0.0;
  int lastTokenCount = 0;

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
  ChatMessage? _streaming;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  int templateAnswers = 0, llmAnswers = 0;

  /// True while KittenTTS is speaking anything (chat, guide, map), so every screen can offer Stop.
  bool speaking = false;
  String? speakingSource; // e.g. 'guide:bear', 'chat', 'map'
  List<String> voices = const [];
  String? voice;
  double speed = 1.0;

  /// A route the Map tab should open on (set by tapping an in-chat mini map).
  final ValueNotifier<RouteResult?> mapFocus = ValueNotifier(null);

  /// The route the map draws (last answer with a destination, or "Route here"); null = way out.
  final ValueNotifier<RouteResult?> activeRoute = ValueNotifier(null);

  MetricsLog? _metrics;
  TurnMetrics? _turn;
  double? _pendingSttMs, _pendingAudioMs;

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
    location.addListener(_buildDemoTrack);
    unawaited(location.start());
    status = 'Loading speech, router and voice models…';
    notifyListeners();
    try {
      final dir = await ai.modelsDir();
      _metrics = MetricsLog.forModelsDir(dir!);
      models = await ai.init(dir);
      questionRouter.layaReady = models['laya'] == true;
      voices = [for (final v in (models['voices'] as List?) ?? const []) v as String];
      await _loadVoicePrefs();
      final missing = [
        if (models['zipformer'] != true) 'speech',
        if (models['laya'] != true) 'router',
        if (models['kitten'] != true) 'voice',
        if (models['gemmaPresent'] != true) 'gemma',
      ];
      status = missing.isEmpty ? 'Ready. Hold the button and talk.' : 'Ready (missing: ${missing.join(', ')})';
    } catch (e) {
      status = 'AI models failed to load: $e';
    }
    phase = Phase.ready;
    notifyListeners();
    try {
      if ((await ai.launchFlags())['calibrate'] == true) unawaited(runCalibration());
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> e) {
    final t = _turn;
    switch (e['type']) {
      case 'llm_loading':
        phase = Phase.loadingLlm;
        status = 'Waking up Gemma…';
      case 'llm_ready':
        llmLoaded = true;
        phase = Phase.thinking;
        status = 'Thinking…';
        t?.llmLoadMs = (e['load_ms'] as num?)?.toDouble();
      case 'llm_unloaded':
        llmLoaded = false;
      case 'llm_first_token':
        t?.ttftMs = (e['ttft_ms'] as num?)?.toDouble();
      case 'llm_chunk':
        final chunk = e['text'] as String;
        if (lastTtftMs == 0 && _llmStartTime != null) {
          lastTtftMs = DateTime.now().difference(_llmStartTime!).inMilliseconds;
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
        if (t != null) {
          t.chunks = (e['chunks'] as num?)?.toInt();
          t.chars = (e['chars'] as num?)?.toInt();
          t.decodeMs = (e['decode_ms'] as num?)?.toDouble();
          _finishTurn();
        }
      case 'tts_first_audio':
        if (t != null && t.ttsFirstAudioMs == null) {
          t.ttsFirstAudioMs = (e['ms'] as num?)?.toDouble();
          if (!t.route.contains('llm')) _finishTurn(); // quick paths end at first audio
        }
      case 'tts_start':
        speaking = true;
        if (phase == Phase.ready) phase = Phase.speaking;
      case 'tts_done':
        speaking = false;
        speakingSource = null;
        if (status == 'Speaking…') status = 'Ready.';
        if (_streaming == null && phase == Phase.speaking) phase = Phase.ready;
      case 'error':
        speaking = false;
        status = 'Error: ${e['message']}';
        _streaming = null;
        phase = Phase.ready;
        if (t != null) {
          t.route = '${t.route}:error';
          _finishTurn();
        }
    }
    notifyListeners();
  }

  /// Demo mode: put the hiker on the Mist Trail, walked up from Happy Isles along real trails.
  void _buildDemoTrack() {
    final r = router;
    if (!location.demoMode || location.demoTrackReady || r == null) return;
    final back = r.routeToPlace(LocationService.demoLat, LocationService.demoLon, LocationService.demoStartName,
        LocationService.demoStartLat, LocationService.demoStartLon);
    if (back == null || back.offTrail) return;
    final walked = back.points.reversed.map((p) => (p.latitude, p.longitude)).toList();
    location.setDemoTrack(walked);
  }

  /// Back to the dashboard.
  Future<void> clearChat() async {
    await stop();
    messages.clear();
    activeRoute.value = null;
    status = 'Ready.';
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
      final r = await ai.stopListening();
      text = (r['text'] as String?) ?? '';
      _pendingSttMs = (r['stt_ms'] as num?)?.toDouble();
      _pendingAudioMs = (r['audio_ms'] as num?)?.toDouble();
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
    await ask(text, input: 'voice');
  }

  Future<void> ask(String text, {String input = 'text'}) async {
    final turn = TurnMetrics(input, text)
      ..sttMs = input == 'voice' ? _pendingSttMs : null
      ..audioMs = input == 'voice' ? _pendingAudioMs : null;
    _pendingSttMs = _pendingAudioMs = null;
    _turn = turn;
    try {
      turn.before = await ai.metrics();
    } catch (_) {}

    messages.add(ChatMessage(true, text));
    phase = Phase.routing;
    status = 'Understanding…';
    notifyListeners();

    final decision = await questionRouter.decide(text);
    turn.layaMs = decision.ms.toDouble();
    turn.scores = decision.toString();
    final s = Situation.build(location, geo, router);
    final g = guide!;
    final critical = location.tier == PowerTier.critical;
    var route = decision.route;
    if (critical && route == Route.llm) route = Route.guide; // save battery: no Gemma when critical
    if (route == Route.llm && models['gemmaPresent'] != true) route = Route.guide;
    turn.route = route.name;

    switch (route) {
      case Route.emergency:
        _say(Templates.emergency(decision, g), AnswerKind.emergency, decision, map: _routeTo(s, s.help));
        // then let Gemma add situation-specific advice, unless the battery is critical
        if (!critical && models['gemmaPresent'] == true) {
          turn.route = 'emergency+llm';
          await _llm(text, decision, s);
        }
      case Route.template:
        templateAnswers++;
        _say(Templates.calm(decision) + Templates.answer(decision.intent, s), AnswerKind.quick, decision,
            map: _mapFor(decision.intent, s));
      case Route.guide:
        templateAnswers++;
        final topic = decision.topic ?? g.search(text, k: 1).firstOrNull?.section.id;
        _say(Templates.calm(decision) + Templates.guideSummary(topic ?? 'lost_stop', g), AnswerKind.guide, decision);
      case Route.llm:
        await _llm(text, decision, s);
    }
  }

  /// The route shown under way-out / water / help answers.
  RouteResult? _mapFor(Intent intent, Situation s) => switch (intent) {
        Intent.wayOut || Intent.whichDirection => s.routeOut,
        Intent.findWater => _routeTo(s, s.water),
        Intent.findHelp => _routeTo(s, s.help),
        _ => null,
      };

  RouteResult? _routeTo(Situation s, (Poi, double)? dest) {
    final f = s.fix;
    if (f == null || dest == null || router == null) return null;
    final p = dest.$1;
    return router!.routeToPlace(f.lat, f.lon, p.name, p.lat, p.lon);
  }

  void _say(String text, AnswerKind kind, RouteDecision d, {RouteResult? map}) {
    messages.add(ChatMessage(false, text, kind: kind, debug: d.toString(), map: map));
    if (map != null) activeRoute.value = map; // the map tab shows where the answer points
    phase = Phase.speaking;
    status = 'Speaking…';
    notifyListeners();
    speak(text, source: 'chat');
  }

  /// Speak from any screen; [source] lets a screen show its own stop toggle.
  void speak(String text, {required String source}) {
    speakingSource = source;
    speaking = true;
    notifyListeners();
    ai.speak(text);
  }

  Future<void> stopSpeaking() async {
    speaking = false;
    speakingSource = null;
    if (status == 'Speaking…') status = 'Ready.';
    if (phase == Phase.speaking) phase = Phase.ready;
    notifyListeners();
    await ai.stopSpeaking();
  }

  Future<void> setVoice(String? v, double s) async {
    voice = v;
    speed = s;
    notifyListeners();
    await ai.setVoice(v, s);
    try {
      final p = await SharedPreferences.getInstance();
      if (v == null) {
        await p.remove('voice');
      } else {
        await p.setString('voice', v);
      }
      await p.setDouble('speed_v2', s);
    } catch (_) {}
  }

  Future<void> _loadVoicePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      voice = p.getString('voice') ?? (voices.contains('expr-voice-2-f') ? 'expr-voice-2-f' : null);
      speed = p.getDouble('speed_v2') ?? 1.0; // v2: the publisher's own pace by default
    } catch (_) {}
    await ai.setVoice(voice, speed);
  }

  Future<void> _llm(String question, RouteDecision d, Situation s) async {
    llmAnswers++;
    _llmStartTime = DateTime.now();
    _currentQuery = question;
    _currentRoute = d.route.name;
    lastTtftMs = 0;
    lastTokenCount = 0;
    final g = guide!;
    final hits = <GuideHit>[];
    final topicSection = d.topic == null || d.topicConfidence < 0.35 ? null : g.byId(d.topic!);
    if (topicSection != null) hits.add(GuideHit(topicSection, 1));
    for (final h in g.search(question, k: 2)) {
      if (hits.length < 2 && hits.every((x) => x.section.id != h.section.id)) hits.add(h);
    }
    final prompt = '${s.contextBlock(hits)}\n\nQuestion: $question';
    final msg = ChatMessage(false, '', kind: AnswerKind.gemma, debug: '$d · guide: ${hits.map((h) => h.section.id).join(', ')}');
    messages.add(msg);
    _streaming = msg;
    phase = llmLoaded ? Phase.thinking : Phase.loadingLlm;
    status = llmLoaded ? 'Thinking…' : 'Waking up Gemma…';
    notifyListeners();
    if (!llmLoaded) speak('Okay. Give me a moment to think about that.', source: 'chat');
    speakingSource = 'chat';
    await ai.generate(systemPrompt, prompt);
  }

  Future<void> stop() async {
    await ai.cancelGenerate();
    await stopSpeaking();
    _streaming = null;
    phase = Phase.ready;
    status = 'Stopped.';
    notifyListeners();
  }

  void _finishTurn() {
    final t = _turn;
    if (t == null) return;
    _turn = null;
    final log = _metrics;
    if (log == null) return;
    () async {
      Map<String, dynamic> after = const {};
      try {
        after = await ai.metrics();
      } catch (_) {}
      await log.append('turns.jsonl', t.toJson(after));
    }();
  }

  /// Routes every labelled question in assets/calibration/questions.json through Laya (no TTS, no
  /// Gemma) and writes `metrics/calibration-<ts>.jsonl` with expected vs. actual routes.
  Future<void> runCalibration() async {
    final log = _metrics;
    if (log == null) return;
    final items = jsonDecode(await rootBundle.loadString('assets/calibration/questions.json')) as List;
    final file = 'calibration-${DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first}.jsonl';
    var ok = 0;
    final byExpect = <String, List<int>>{};
    for (var i = 0; i < items.length; i++) {
      final q = items[i]['q'] as String;
      final expect = items[i]['expect'] as String;
      status = 'Calibrating ${i + 1}/${items.length}…';
      notifyListeners();
      final d = await questionRouter.decide(q);
      final hit = d.route.name == expect;
      if (hit) ok++;
      (byExpect[expect] ??= [0, 0])
        ..[0] += hit ? 1 : 0
        ..[1] += 1;
      await log.append(file, {'q': q, 'expect': expect, 'ok': hit, ...d.toJson()});
    }
    final summary = {
      'summary': true,
      'accuracy': ok / items.length,
      'correct': ok,
      'total': items.length,
      for (final e in byExpect.entries) e.key: '${e.value[0]}/${e.value[1]}',
    };
    await log.append(file, summary);
    status = 'Calibration: $ok/${items.length} routed as expected (metrics/$file)';
    notifyListeners();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    mapFocus.dispose();
    activeRoute.dispose();
    location.removeListener(_buildDemoTrack);
    super.dispose();
  }
}
