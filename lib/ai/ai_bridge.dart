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
  Future<String> stopListening() async => (await _method.invokeMethod<String>('stopListening')) ?? '';

  /// Laya zero-shot: [questions] is `{id: {type, instructions, criteria}}`.
  Future<Map<String, dynamic>> classify(String text, Map<String, dynamic> questions) async {
    final raw = await _method.invokeMethod<String>('classify', {'text': text, 'questions': jsonEncode(questions)});
    return jsonDecode(raw!) as Map<String, dynamic>;
  }

  Future<void> generate(String system, String prompt, {bool speak = true}) =>
      _method.invokeMethod('generate', {'system': system, 'prompt': prompt, 'speak': speak});
  Future<void> cancelGenerate() => _method.invokeMethod('cancelGenerate');
  Future<void> speak(String text) => _method.invokeMethod('speak', {'text': text});
  Future<void> stopSpeaking() => _method.invokeMethod('stopSpeaking');
  Future<void> setVoice(String? voice, double speed) =>
      _method.invokeMethod('setVoice', {'voice': voice, 'speed': speed});
  Future<void> unloadLlm() => _method.invokeMethod('unloadLlm');
}
