import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Dart side of the Kotlin AI core (android/.../AiCore.kt).
class AiBridge {
  static const _method = MethodChannel('survival/ai');
  static const _events = EventChannel('survival/ai/events');

  final Stream<Map<String, dynamic>> events =
      _events.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map)).asBroadcastStream();

  Future<String?> modelsDir() => _method.invokeMethod<String>('modelsDir');

  Future<Map<String, dynamic>> init(String modelsDir) async =>
      Map<String, dynamic>.from(await _method.invokeMethod('init', {'modelsDir': modelsDir}) as Map);

  Future<bool> requestMic() async => (await _method.invokeMethod<bool>('requestMic')) ?? false;

  Future<void> startListening() => _method.invokeMethod('startListening');
  /// `{text, stt_ms, audio_ms}`
  Future<Map<String, dynamic>> stopListening() async =>
      Map<String, dynamic>.from(await _method.invokeMethod('stopListening') as Map);

  /// Battery / memory / CPU snapshot from the Kotlin side.
  Future<Map<String, dynamic>> metrics() async => Map<String, dynamic>.from(await _method.invokeMethod('metrics') as Map);

  Future<Map<String, dynamic>> launchFlags() async =>
      Map<String, dynamic>.from(await _method.invokeMethod('launchFlags') as Map);

  /// Laya zero-shot: [questions] is `{id: {type, instructions, criteria}}`.
  Future<Map<String, dynamic>> classify(String text, Map<String, dynamic> questions) async {
    final raw = await _method.invokeMethod<String>('classify', {'text': text, 'questions': jsonEncode(questions)});
    return jsonDecode(raw!) as Map<String, dynamic>;
  }

  Future<void> generate(
    String system,
    String prompt, {
    bool speak = true,
    bool newConversation = false,
    String? imagePath,
  }) =>
      _method.invokeMethod('generate', {
        'system': system,
        'prompt': prompt,
        'speak': speak,
        'newConversation': newConversation,
        'imagePath': imagePath,
      });
  Future<void> resetConversation() => _method.invokeMethod('resetConversation');
  Future<void> cancelGenerate() => _method.invokeMethod('cancelGenerate');
  Future<void> speak(String text) => _method.invokeMethod('speak', {'text': text});
  Future<void> stopSpeaking() => _method.invokeMethod('stopSpeaking');
  Future<void> setVoice(String? voice, double speed) =>
      _method.invokeMethod('setVoice', {'voice': voice, 'speed': speed});
  Future<void> unloadLlm() => _method.invokeMethod('unloadLlm');

  Future<List<Map<String, dynamic>>> listModels() async {
    final list = await _method.invokeMethod<List>('listModels');
    return (list ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> setModel(String model, String backend) =>
      _method.invokeMethod('setModel', {'model': model, 'backend': backend});

  Future<void> setTtsEngine(String engine) =>
      _method.invokeMethod('setTtsEngine', {'engine': engine});

  Future<void> setTtsVoice(String? voice) =>
      _method.invokeMethod('setTtsVoice', {'voice': voice});

  Future<void> setTtsSpeed(double speed) =>
      _method.invokeMethod('setTtsSpeed', {'speed': speed});

  Future<Map<String, List<String>>> listTtsVoices() async {
    final res = await _method.invokeMethod<Map>('listTtsVoices');
    if (res == null) return {'kitten': [], 'system': []};
    return {
      'kitten': List<String>.from(res['kitten'] as List? ?? []),
      'system': List<String>.from(res['system'] as List? ?? []),
    };
  }
}
