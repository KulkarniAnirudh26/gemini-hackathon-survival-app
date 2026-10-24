import 'dart:convert';
import 'dart:io';

/// One record per assistant turn, appended as a JSON line to
/// `<app external files>/metrics/turns.jsonl` (pull with `tool/metrics_session.ps1`).
class TurnMetrics {
  final DateTime started = DateTime.now();
  final Stopwatch sw = Stopwatch()..start();
  String input; // voice | text | prompt
  String question;
  String route = '';
  double? sttMs, audioMs, layaMs, llmLoadMs, ttftMs, decodeMs, ttsFirstAudioMs;
  int? chunks, chars;
  Map<String, dynamic> before = const {};
  String scores = '';

  TurnMetrics(this.input, this.question);

  Map<String, dynamic> toJson(Map<String, dynamic> after) {
    double? d(String k) => (after[k] as num?)?.toDouble();
    double? b(String k) => (before[k] as num?)?.toDouble();
    return {
      'ts': started.toIso8601String(),
      'input': input,
      'question': question,
      'route': route,
      'stt_ms': sttMs,
      'audio_ms': audioMs,
      'laya_ms': layaMs,
      'llm_load_ms': llmLoadMs,
      'ttft_ms': ttftMs,
      'decode_ms': decodeMs,
      'chunks': chunks,
      'chars': chars,
      'tts_first_audio_ms': ttsFirstAudioMs,
      'total_ms': sw.elapsedMilliseconds,
      'battery_pct': after['battery_pct'],
      'current_ua': after['current_ua'],
      'voltage_mv': after['voltage_mv'],
      'temp_c': after['temp_c'],
      'charging': after['charging'],
      'pss_mb': d('pss_mb'),
      'cpu_ms_delta': (d('cpu_ms') != null && b('cpu_ms') != null) ? d('cpu_ms')! - b('cpu_ms')! : null,
      'llm_loaded': after['llm_loaded'],
      'scores': scores,
    };
  }
}

class MetricsLog {
  final Directory dir;
  MetricsLog(this.dir);

  /// [modelsDir] is `<external files>/models`; metrics live next to it.
  static MetricsLog forModelsDir(String modelsDir) => MetricsLog(Directory('${Directory(modelsDir).parent.path}/metrics'));

  Future<void> append(String file, Map<String, dynamic> record) async {
    try {
      await dir.create(recursive: true);
      await File('${dir.path}/$file').writeAsString('${jsonEncode(record)}\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // metrics must never break the assistant
    }
  }
}
