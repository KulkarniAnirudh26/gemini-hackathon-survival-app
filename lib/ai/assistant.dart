import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../geo/geo_data.dart';
import '../geo/nps_layers.dart';
import '../geo/trail_router.dart';
import '../location/location_service.dart';
import '../rag/guide.dart';
import 'ai_bridge.dart';
import 'router.dart';
import 'situation.dart';
import 'templates.dart';

enum Phase { loading, ready, listening, transcribing, routing, loadingLlm, thinking, speaking }

class ChatMessage {
  final bool user;
  String text;
  String? meta;
  ChatMessage(this.user, this.text, {this.meta});
}

const systemPrompt = '''You are a calm, warm and practical wilderness survival guide inside an offline phone app in Yosemite National Park.
The user may be lost, injured, cold, scared or low on battery. Speak to them gently and directly, like a steady friend beside them.
Start with a few words of reassurance (for example "You're doing the right thing." or "Okay, we'll handle this together."), then give the single most important action.
Rules: answer in two to four short, simple spoken sentences. Use calm, plain words; never sound alarmed. No markdown, no lists.
Use the SITUATION, ROUTE, NEAREST and GUIDE data given with the question; never invent trails, places or distances.
If anything sounds life-threatening, tell them to call 911 or use Satellite SOS.''';

/// Orchestrates: mic -> Zipformer -> Laya router -> template | guide | Gemma -> KittenTTS.
class Assistant extends ChangeNotifier {
  final AiBridge ai = AiBridge();
  final LocationService location;
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
  double speed = 0.85;

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
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'llm_loading':
        phase = Phase.loadingLlm;
        status = 'Waking up Gemma…';
      case 'llm_ready':
        llmLoaded = true;
        phase = Phase.thinking;
        status = 'Thinking…';
      case 'llm_unloaded':
        llmLoaded = false;
      case 'llm_chunk':
        _streaming?.text += e['text'] as String;
        phase = Phase.thinking;
      case 'llm_done':
        _streaming = null;
        if (phase == Phase.thinking) phase = Phase.ready;
        status = 'Ready.';
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
        _say(Templates.emergency(decision, g), decision, '🚨 Laya → emergency script, then Gemma');
        // then let Gemma add situation-specific advice, unless the battery is critical
        if (!critical && models['gemmaPresent'] == true) await _llm(text, decision, s);
      case Route.template:
        templateAnswers++;
        _say(Templates.calm(decision) + Templates.answer(decision.intent, s), decision, '⚡ Laya → instant answer from map data (no LLM)');
      case Route.guide:
        templateAnswers++;
        final topic = decision.topicConfidence >= 0.5 ? decision.topic : g.search(text, k: 1).firstOrNull?.section.id;
        final title = g.byId(topic ?? 'lost_stop')?.title ?? 'guide';
        _say(Templates.calm(decision) + Templates.guideSummary(topic ?? 'lost_stop', g), decision,
            '⚡ Laya → survival guide: $title (no LLM)');
      case Route.llm:
        await _llm(text, decision, s);
    }
  }

  void _say(String text, RouteDecision d, String how) {
    messages.add(ChatMessage(false, text, meta: '$how\n$d'));
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
      await p.setDouble('speed', s);
    } catch (_) {}
  }

  Future<void> _loadVoicePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      voice = p.getString('voice') ?? (voices.contains('expr-voice-2-f') ? 'expr-voice-2-f' : null);
      speed = p.getDouble('speed') ?? 0.85;
    } catch (_) {}
    await ai.setVoice(voice, speed);
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
    final msg = ChatMessage(false, '',
        meta: '🧠 Laya → Gemma 4 E2B (needs reasoning) · guide: ${hits.map((h) => h.section.id).join(', ')}\n$d');
    messages.add(msg);
    _streaming = msg;
    phase = llmLoaded ? Phase.thinking : Phase.loadingLlm;
    status = llmLoaded ? 'Thinking…' : 'Waking up Gemma…';
    notifyListeners();
    if (!llmLoaded) speak("Okay. Give me a moment to think about that.", source: 'chat');
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

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}
