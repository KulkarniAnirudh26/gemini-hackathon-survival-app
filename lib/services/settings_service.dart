import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ai/ai_bridge.dart';

const defaultSystemPrompt = '''You are a calm, practical wilderness survival guide inside an offline phone app in Yosemite National Park.
The user may be lost, injured, cold, scared or low on battery. Speak to them directly.
Rules: answer in one to three short spoken sentences, most important action first. No markdown, no lists.
Use the SITUATION, ROUTE, NEAREST and GUIDE data given with the question; never invent trails, places or distances.
If anything sounds life-threatening, tell them to call 911 or use Satellite SOS.''';

class SettingsService extends ChangeNotifier {
  static const _keySystemPrompt = 'settings_system_prompt';
  static const _keyMaxTokens = 'settings_max_tokens';
  static const _keySpeakAnswers = 'settings_speak_answers';
  static const _keyEnableThinking = 'settings_enable_thinking';
  static const _keyEnableLaya = 'settings_enable_laya';
  static const _keySelectedModel = 'settings_selected_model';
  static const _keySelectedBackend = 'settings_selected_backend';
  static const _keyTtsEngine = 'settings_tts_engine';
  static const _keyTtsVoice = 'settings_tts_voice';
  static const _keyTtsSpeed = 'settings_tts_speed';

  final AiBridge? _bridge;

  String _systemPrompt = defaultSystemPrompt;
  int _maxTokens = 256;
  bool _speakAnswers = true;
  bool _enableThinking = false;
  bool _enableLaya = true;

  String _selectedModel = 'gemma-4-E2B-it_Google_Tensor_G5.litertlm';
  String _selectedBackend = 'NPU';
  String _ttsEngine = 'kitten'; // 'kitten' or 'system'
  String _ttsVoice = 'expr-voice-2-m';
  double _ttsSpeed = 1.0;

  List<Map<String, dynamic>> _availableModels = [];
  Map<String, List<String>> _availableVoices = {'kitten': [], 'system': []};

  String get systemPrompt => _systemPrompt;
  int get maxTokens => _maxTokens;
  bool get speakAnswers => _speakAnswers;
  bool get enableThinking => _enableThinking;
  bool get enableLaya => _enableLaya;

  String get selectedModel => _selectedModel;
  String get selectedBackend => _selectedBackend;
  String get ttsEngine => _ttsEngine;
  String get ttsVoice => _ttsVoice;
  double get ttsSpeed => _ttsSpeed;

  List<Map<String, dynamic>> get availableModels => _availableModels;
  Map<String, List<String>> get availableVoices => _availableVoices;

  SettingsService([this._bridge]) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _systemPrompt = prefs.getString(_keySystemPrompt) ?? defaultSystemPrompt;
      _maxTokens = prefs.getInt(_keyMaxTokens) ?? 256;
      _speakAnswers = prefs.getBool(_keySpeakAnswers) ?? true;
      _enableThinking = prefs.getBool(_keyEnableThinking) ?? false;
      _enableLaya = prefs.getBool(_keyEnableLaya) ?? true;
      _selectedModel = prefs.getString(_keySelectedModel) ?? _selectedModel;
      _selectedBackend = prefs.getString(_keySelectedBackend) ?? _selectedBackend;
      _ttsEngine = prefs.getString(_keyTtsEngine) ?? 'kitten';
      _ttsVoice = prefs.getString(_keyTtsVoice) ?? 'expr-voice-2-m';
      _ttsSpeed = prefs.getDouble(_keyTtsSpeed) ?? 1.0;
      notifyListeners();

      await refreshHardwareInfo();
    } catch (_) {}
  }

  Future<void> refreshHardwareInfo() async {
    final b = _bridge;
    if (b == null) return;
    try {
      final models = await b.listModels();
      if (models.isNotEmpty) {
        _availableModels = models;
        // If current model not set or doesn't exist, pick the first or TPU
        if (!_availableModels.any((m) => m['name'] == _selectedModel)) {
          final tpu = _availableModels.firstWhere(
            (m) => m['isTpu'] == true,
            orElse: () => _availableModels.first,
          );
          _selectedModel = tpu['name'] as String;
          _selectedBackend = tpu['recommendedBackend'] as String;
        }
      }

      final voices = await b.listTtsVoices();
      _availableVoices = voices;

      // Apply initial settings to native layer
      await b.setModel(_selectedModel, _selectedBackend);
      await b.setTtsEngine(_ttsEngine);
      await b.setTtsVoice(_ttsVoice);
      await b.setTtsSpeed(_ttsSpeed);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setSelectedModel(String model, [String? backend]) async {
    _selectedModel = model;
    if (backend != null) {
      _selectedBackend = backend;
    } else {
      final match = _availableModels.firstWhere((m) => m['name'] == model, orElse: () => {});
      _selectedBackend = match['recommendedBackend'] as String? ?? 'GPU';
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySelectedModel, _selectedModel);
    await prefs.setString(_keySelectedBackend, _selectedBackend);
    await _bridge?.setModel(_selectedModel, _selectedBackend);
  }

  Future<void> setSelectedBackend(String backend) async {
    _selectedBackend = backend;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySelectedBackend, _selectedBackend);
    await _bridge?.setModel(_selectedModel, _selectedBackend);
  }

  Future<void> setTtsEngine(String engine) async {
    _ttsEngine = engine;
    final voices = _availableVoices[_ttsEngine] ?? [];
    if (voices.isNotEmpty && !voices.contains(_ttsVoice)) {
      _ttsVoice = voices.first;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTtsEngine, _ttsEngine);
    await prefs.setString(_keyTtsVoice, _ttsVoice);
    await _bridge?.setTtsEngine(_ttsEngine);
    await _bridge?.setTtsVoice(_ttsVoice);
  }

  Future<void> setTtsVoice(String voice) async {
    _ttsVoice = voice;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTtsVoice, _ttsVoice);
    await _bridge?.setTtsVoice(_ttsVoice);
  }

  Future<void> setTtsSpeed(double speed) async {
    _ttsSpeed = speed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTtsSpeed, _ttsSpeed);
    await _bridge?.setTtsSpeed(_ttsSpeed);
  }

  Future<void> setSystemPrompt(String val) async {
    _systemPrompt = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySystemPrompt, val);
  }

  Future<void> setMaxTokens(int val) async {
    _maxTokens = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMaxTokens, val);
  }

  Future<void> setSpeakAnswers(bool val) async {
    _speakAnswers = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySpeakAnswers, val);
  }

  Future<void> setEnableThinking(bool val) async {
    _enableThinking = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableThinking, val);
  }

  Future<void> setEnableLaya(bool val) async {
    _enableLaya = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableLaya, val);
  }

  Future<void> resetToDefaults() async {
    _systemPrompt = defaultSystemPrompt;
    _maxTokens = 256;
    _speakAnswers = true;
    _enableThinking = false;
    _enableLaya = true;
    _ttsEngine = 'kitten';
    _ttsVoice = 'expr-voice-2-m';
    _ttsSpeed = 1.0;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySystemPrompt);
    await prefs.remove(_keyMaxTokens);
    await prefs.remove(_keySpeakAnswers);
    await prefs.remove(_keyEnableThinking);
    await prefs.remove(_keyEnableLaya);
    await prefs.remove(_keyTtsEngine);
    await prefs.remove(_keyTtsVoice);
    await prefs.remove(_keyTtsSpeed);
  }
}
