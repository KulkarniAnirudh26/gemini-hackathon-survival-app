import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/assistant.dart';
import '../location/location_service.dart';
import '../services/settings_service.dart';

/// Clean Tactical Settings, Model/Backend Selector, Multi-Engine TTS, and LLM Calls Table Screen.
class SettingsScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;

  const SettingsScreen({
    super.key,
    required this.assistant,
    required this.location,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _promptController;

  static const _presetDefault = defaultSystemPrompt;
  static const _presetConcise = '''You are an expert backcountry Yosemite ranger.
Answer with extreme brevity in 1-2 direct sentences. Give the exact immediate action first.
No markdown or filler words. Use only verified facts.''';
  static const _presetMedical = '''You are a wilderness emergency first-aid specialist in Yosemite.
Prioritize patient stabilization, ABCs (Airway, Breathing, Circulation), and hypothermia prevention.
Be calm, direct, and explicit. Advise Satellite SOS or 911 for life threats.''';

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController(
      text: widget.assistant.settings.systemPrompt,
    );
    // No sample rows: these metrics only ever show real calls, so they can't be mistaken for
    // measured performance (CLAUDE.md: no fabricated facts).
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.assistant.settings, widget.location]),
      builder: (context, _) {
        final a = widget.assistant;
        final s = a.settings;
        final loc = widget.location;

        final avgTtft = a.avgTtftMs;
        final avgSpeed = a.avgTokensPerSec;

        return Scaffold(
          backgroundColor: const Color(0xFF090D11),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
            children: [
              // Clean Header Bar
              Row(
                children: [
                  const Icon(Icons.tune, color: Color(0xFFE87A3E), size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'SETTINGS & HARDWARE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: s.selectedBackend == 'NPU' ? const Color(0x33103B2B) : const Color(0x333A2B10),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: s.selectedBackend == 'NPU' ? const Color(0xFF18A573) : const Color(0xFFE87A3E),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      s.selectedBackend == 'NPU' ? 'TENSOR G5 TPU' : 'OPENCL GPU',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: s.selectedBackend == 'NPU' ? const Color(0xFF4EEBA2) : const Color(0xFFFFB74D),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // 4-Column Clean Performance HUD
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: Row(
                  children: [
                    _MetricItem(
                      title: 'AVG TTFT',
                      value: avgTtft == 0 ? '--' : '${avgTtft.toStringAsFixed(0)} ms',
                      valColor: const Color(0xFF4EEBA2),
                    ),
                    _verticalDivider(),
                    _MetricItem(
                      title: 'AVG SPEED',
                      value: avgSpeed == 0 ? '--' : '${avgSpeed.toStringAsFixed(1)} t/s',
                      valColor: const Color(0xFF00E5FF),
                    ),
                    _verticalDivider(),
                    _MetricItem(
                      title: 'INFERENCES',
                      value: '${a.recentCalls.length}',
                      valColor: const Color(0xFFFFD54F),
                    ),
                    _verticalDivider(),
                    _MetricItem(
                      title: 'POWER TIER',
                      value: loc.tier.name.toUpperCase(),
                      valColor: switch (loc.tier) {
                        PowerTier.normal => const Color(0xFF4EEBA2),
                        PowerTier.saver => const Color(0xFFFFD54F),
                        PowerTier.critical => const Color(0xFFFF5252),
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: ON-DEVICE LLM & ACCELERATOR SELECTION
              Row(
                children: [
                  const Icon(Icons.memory, size: 15, color: Color(0xFFE87A3E)),
                  const SizedBox(width: 6),
                  _sectionTitle('GEMMA MODEL & ACCELERATOR'),
                ],
              ),
              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ACTIVE MODEL BUNDLE (.litertlm)',
                      style: TextStyle(fontFamily: 'monospace', color: Color(0xFF8BA2B5), fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    // Model Dropdown
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141C24),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF22303D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: s.availableModels.any((m) => m['name'] == s.selectedModel)
                              ? s.selectedModel
                              : (s.availableModels.isNotEmpty ? s.availableModels.first['name'] as String : null),
                          isExpanded: true,
                          dropdownColor: const Color(0xFF141C24),
                          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF6B8296)),
                          items: s.availableModels.map((m) {
                            final name = m['name'] as String;
                            final isTpu = m['isTpu'] == true;
                            final sizeGb = ((m['size'] as num?) ?? 0) / (1024 * 1024 * 1024);
                            return DropdownMenuItem<String>(
                              value: name,
                              child: Row(
                                children: [
                                  Icon(
                                    isTpu ? Icons.speed : Icons.layers,
                                    size: 14,
                                    color: isTpu ? const Color(0xFF4EEBA2) : const Color(0xFFFFB74D),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(color: Colors.white, fontSize: 11.5, fontFamily: 'monospace'),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '${sizeGb.toStringAsFixed(1)} GB',
                                    style: const TextStyle(color: Color(0xFF6B8296), fontSize: 10.5, fontFamily: 'monospace'),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              s.setSelectedModel(val);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Backend Chips
                    const Text(
                      'ACCELERATION BACKEND',
                      style: TextStyle(fontFamily: 'monospace', color: Color(0xFF8BA2B5), fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _backendChip(
                          label: 'TPU / NPU (Tensor G5)',
                          backend: 'NPU',
                          selected: s.selectedBackend == 'NPU',
                          onTap: () => s.setSelectedBackend('NPU'),
                        ),
                        const SizedBox(width: 8),
                        _backendChip(
                          label: 'GPU (OpenCL)',
                          backend: 'GPU',
                          selected: s.selectedBackend == 'GPU',
                          onTap: () => s.setSelectedBackend('GPU'),
                        ),
                        const SizedBox(width: 8),
                        _backendChip(
                          label: 'CPU',
                          backend: 'CPU',
                          selected: s.selectedBackend == 'CPU',
                          onTap: () => s.setSelectedBackend('CPU'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          a.llmLoaded ? Icons.check_circle : Icons.radio_button_unchecked,
                          size: 12,
                          color: a.llmLoaded ? const Color(0xFF4EEBA2) : const Color(0xFF6B8296),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          a.llmLoaded ? 'Model Resident in RAM' : 'Model Standby (Loads on demand)',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10.5,
                            color: a.llmLoaded ? const Color(0xFF4EEBA2) : const Color(0xFF6B8296),
                          ),
                        ),
                        const Spacer(),
                        if (a.llmLoaded)
                          InkWell(
                            onTap: () {
                              a.ai.unloadLlm();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Model evicted from RAM')),
                              );
                            },
                            child: const Text(
                              'UNLOAD',
                              style: TextStyle(color: Color(0xFFFFB74D), fontSize: 10.5, fontWeight: FontWeight.w700, fontFamily: 'monospace'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: ROUTING & INTENT PIPELINE
              Row(
                children: [
                  const Icon(Icons.alt_route, size: 15, color: Color(0xFF4EEBA2)),
                  const SizedBox(width: 6),
                  _sectionTitle('DECISION & INTENT ROUTING'),
                ],
              ),
              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'LAYA ZERO-SHOT ROUTER',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            s.enableLaya
                                ? 'Active: Routes lookups to instant cards, deep questions to Gemma'
                                : 'Disabled: All queries bypass router and go directly to Gemma LLM',
                            style: const TextStyle(
                              color: Color(0xFF8BA2B5),
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: s.enableLaya,
                      activeTrackColor: const Color(0xFF4EEBA2),
                      activeThumbColor: const Color(0xFF090D11),
                      inactiveTrackColor: const Color(0xFF1B2631),
                      inactiveThumbColor: const Color(0xFF6B8296),
                      onChanged: (val) => s.setEnableLaya(val),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: SPEECH & VOICE SYNTHESIS (TTS)
              Row(
                children: [
                  const Icon(Icons.record_voice_over, size: 15, color: Color(0xFF4EEBA2)),
                  const SizedBox(width: 6),
                  _sectionTitle('VOICE AUDIO & SPEECH SYNTHESIS (TTS)'),
                ],
              ),
              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // TTS Engine Mode
                    const Text(
                      'SYNTHESIS ENGINE',
                      style: TextStyle(fontFamily: 'monospace', color: Color(0xFF8BA2B5), fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _backendChip(
                          label: 'KittenTTS (LiteRT Neural)',
                          backend: 'kitten',
                          selected: s.ttsEngine == 'kitten',
                          onTap: () => s.setTtsEngine('kitten'),
                        ),
                        const SizedBox(width: 8),
                        _backendChip(
                          label: 'Android System TTS',
                          backend: 'system',
                          selected: s.ttsEngine == 'system',
                          onTap: () => s.setTtsEngine('system'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Voice Picker
                    Text(
                      s.ttsEngine == 'kitten' ? 'KITTEN NEURAL VOICE' : 'SYSTEM VOICE',
                      style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF8BA2B5), fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141C24),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF22303D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: (s.ttsEngine == 'kitten'
                                  ? s.availableVoices['kitten']
                                  : s.availableVoices['system'])
                              ?.contains(s.ttsVoice) ==
                              true
                              ? s.ttsVoice
                              : ((s.ttsEngine == 'kitten'
                                      ? s.availableVoices['kitten']
                                      : s.availableVoices['system'])
                                  ?.firstOrNull),
                          isExpanded: true,
                          dropdownColor: const Color(0xFF141C24),
                          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF6B8296)),
                          items: (s.ttsEngine == 'kitten'
                                  ? s.availableVoices['kitten']
                                  : s.availableVoices['system'])
                              ?.map((voice) {
                            return DropdownMenuItem<String>(
                              value: voice,
                              child: Text(
                                voice,
                                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontFamily: 'monospace'),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) s.setTtsVoice(val);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Speed Slider
                    Row(
                      children: [
                        const Text(
                          'SPEECH RATE',
                          style: TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${s.ttsSpeed.toStringAsFixed(2)}x',
                          style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF4EEBA2), fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF4EEBA2),
                        inactiveTrackColor: const Color(0xFF22303D),
                        thumbColor: const Color(0xFF4EEBA2),
                        overlayColor: const Color(0x224EEBA2),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: s.ttsSpeed,
                        min: 0.6,
                        max: 1.5,
                        divisions: 9,
                        onChanged: s.setTtsSpeed,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Test Speech Button
                    SizedBox(
                      width: double.infinity,
                      height: 36,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF4EEBA2),
                          side: const BorderSide(color: Color(0xFF18A573), width: 1.0),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        icon: const Icon(Icons.volume_up, size: 15),
                        label: const Text('TEST VOICE PLAYBACK', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        onPressed: () {
                          a.ai.speak("Yosemite backcountry trail guide audio ready.");
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: RECENT LLM CALLS TABLE
              Row(
                children: [
                  const Icon(Icons.table_chart_outlined, size: 15, color: Color(0xFF6B8296)),
                  const SizedBox(width: 6),
                  _sectionTitle('RECENT LLM CALLS & BENCHMARKS'),
                  const Spacer(),
                  Text(
                    '${a.recentCalls.length} turns',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Color(0xFF6B8296),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Tabular Data Table Card
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: a.recentCalls.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: Text(
                          'No LLM calls yet. Real timings appear here after Gemma answers.',
                          style: TextStyle(color: Color(0xFF6B8296), fontSize: 11.5),
                        ),
                      )
                    : ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(const Color(0xFF141C24)),
                      headingRowHeight: 34,
                      dataRowMinHeight: 38,
                      dataRowMaxHeight: 44,
                      horizontalMargin: 12,
                      columnSpacing: 16,
                      dividerThickness: 0.6,
                      columns: const [
                        DataColumn(label: _TableHead('TIME')),
                        DataColumn(label: _TableHead('QUERY')),
                        DataColumn(label: _TableHead('TTFT')),
                        DataColumn(label: _TableHead('SPEED')),
                        DataColumn(label: _TableHead('TOKENS')),
                        DataColumn(label: _TableHead('STATUS')),
                      ],
                      rows: a.recentCalls.map((call) {
                        final timeStr =
                            '${call.time.hour.toString().padLeft(2, '0')}:${call.time.minute.toString().padLeft(2, '0')}:${call.time.second.toString().padLeft(2, '0')}';
                        final queryTrunc = call.query.length > 28
                            ? '${call.query.substring(0, 28)}…'
                            : call.query;

                        return DataRow(
                          cells: [
                            DataCell(Text(timeStr, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF6B8296)))),
                            DataCell(
                              SizedBox(
                                width: 170,
                                child: Text(
                                  queryTrunc,
                                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                call.ttftMs == 0 ? '<1ms' : '${call.ttftMs}ms',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: call.ttftMs < 350 ? const Color(0xFF4EEBA2) : const Color(0xFFFFD54F),
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                call.tokensPerSec == 0 ? 'instant' : '${call.tokensPerSec.toStringAsFixed(1)} t/s',
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF00E5FF)),
                              ),
                            ),
                            DataCell(Text('${call.tokenCount}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70))),
                            DataCell(
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: call.isError ? const Color(0x33FF5252) : const Color(0x224EEBA2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  call.isError ? 'FAIL' : 'OK',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: call.isError ? const Color(0xFFFF5252) : const Color(0xFF4EEBA2),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: PROMPT CONFIGURATION
              _sectionTitle('SYSTEM INSTRUCTION & REASONING'),
              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Preset pills
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _presetChip('Tactical Default', () {
                          _promptController.text = _presetDefault;
                          s.setSystemPrompt(_presetDefault);
                        }),
                        _presetChip('Ultra-Concise', () {
                          _promptController.text = _presetConcise;
                          s.setSystemPrompt(_presetConcise);
                        }),
                        _presetChip('First-Aid Medical', () {
                          _promptController.text = _presetMedical;
                          s.setSystemPrompt(_presetMedical);
                        }),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _promptController,
                      maxLines: 4,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.white,
                        height: 1.35,
                      ),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF141C24),
                        contentPadding: const EdgeInsets.all(10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF22303D)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF22303D)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFFE87A3E)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            s.resetToDefaults();
                            _promptController.text = s.systemPrompt;
                          },
                          child: const Text('RESET', style: TextStyle(color: Color(0xFF6B8296), fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE87A3E),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          onPressed: () {
                            s.setSystemPrompt(_promptController.text);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Prompt configuration saved')),
                            );
                          },
                          child: const Text('APPLY PROMPT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
                        ),
                      ],
                    ),
                    const Divider(color: Color(0xFF1B2631), height: 20),
                    // Output tokens slider
                    Row(
                      children: [
                        const Text(
                          'MAX OUTPUT LENGTH',
                          style: TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${s.maxTokens} tokens',
                          style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF4EEBA2), fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFFE87A3E),
                        inactiveTrackColor: const Color(0xFF22303D),
                        thumbColor: const Color(0xFFE87A3E),
                        overlayColor: const Color(0x22E87A3E),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: s.maxTokens.toDouble(),
                        min: 64,
                        max: 512,
                        divisions: 7,
                        onChanged: (v) => s.setMaxTokens(v.toInt()),
                      ),
                    ),
                    // Voice speech toggle
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Voice Audio Playback (TTS)',
                        style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'Speak responses automatically on completion',
                        style: TextStyle(color: Color(0xFF6B8296), fontSize: 11),
                      ),
                      value: s.speakAnswers,
                      activeTrackColor: const Color(0xFF4EEBA2),
                      onChanged: s.setSpeakAnswers,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // SECTION: LIVE EVENT LOG
              Row(
                children: [
                  _sectionTitle('LIVE SYSTEM EVENTS (${a.logs.length})'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 15, color: Color(0xFF6B8296)),
                    tooltip: 'Copy Logs',
                    onPressed: () {
                      final all = a.logs.map((e) => '[${e.tag}] ${e.message}').join('\n');
                      Clipboard.setData(ClipboardData(text: all));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Logs copied')),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear_all, size: 16, color: Color(0xFF6B8296)),
                    tooltip: 'Clear Logs',
                    onPressed: a.clearLogs,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 130,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF080C0F),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF1B2631)),
                ),
                child: a.logs.isEmpty
                    ? const Center(
                        child: Text('No events logged yet.', style: TextStyle(color: Color(0xFF445566), fontSize: 11, fontFamily: 'monospace')),
                      )
                    : ListView.builder(
                        itemCount: a.logs.length,
                        itemBuilder: (context, i) {
                          final e = a.logs[a.logs.length - 1 - i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1.5),
                            child: Row(
                              children: [
                                Text(
                                  '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}',
                                  style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF556677), fontSize: 9.5),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '[${e.tag}]',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: e.isError ? const Color(0xFFFF5252) : const Color(0xFF4EEBA2),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    e.message,
                                    style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: e.isError ? const Color(0xFFFF5252) : Colors.white70),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: 'monospace',
        color: Color(0xFF8BA2B5),
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _verticalDivider() {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color(0xFF1B2631),
    );
  }

  Widget _presetChip(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF141C24),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF22303D)),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Color(0xFFE87A3E), fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _backendChip({
    required String label,
    required String backend,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? (backend == 'NPU' ? const Color(0x33103B2B) : const Color(0x333A2B10)) : const Color(0xFF141C24),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? (backend == 'NPU' ? const Color(0xFF18A573) : const Color(0xFFE87A3E)) : const Color(0xFF22303D),
              width: selected ? 1.2 : 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: selected ? (backend == 'NPU' ? const Color(0xFF4EEBA2) : const Color(0xFFFFB74D)) : const Color(0xFF8BA2B5),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final String title;
  final String value;
  final Color valColor;

  const _MetricItem({
    required this.title,
    required this.value,
    required this.valColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B8296),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              color: valColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _TableHead extends StatelessWidget {
  final String title;
  const _TableHead(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        color: Color(0xFF8BA2B5),
        letterSpacing: 0.5,
      ),
    );
  }
}
