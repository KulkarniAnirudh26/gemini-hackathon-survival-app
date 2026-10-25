import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/assistant.dart';
import '../ai/situation.dart';
import '../location/location_service.dart';
import 'guide_screen.dart';
import 'here_card.dart';
import 'route_mini_map.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  const HomeScreen({super.key, required this.assistant, required this.location});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  int _seen = 0;
  bool _typing = false;
  String? _pendingImagePath;
  final _picker = ImagePicker();

  Future<void> _pickImage(ImageSource source) async {
    try {
      final photo = await _picker.pickImage(source: source, maxWidth: 640, maxHeight: 640, imageQuality: 75);
      if (photo != null) {
        setState(() {
          _pendingImagePath = photo.path;
          _typing = true; // Switch to composer to see preview and attach question
        });
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  /// An emergency answer takes over the screen at once, before Gemma adds anything.
  void _checkEmergency(Assistant a) {
    if (a.messages.length < _seen) _seen = 0; // chat was cleared
    if (a.messages.length <= _seen) return;
    final fresh = a.messages.sublist(_seen);
    _seen = a.messages.length;
    for (final m in fresh) {
      if (!m.user && m.kind == AnswerKind.emergency) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          HapticFeedback.heavyImpact();
          Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _EmergencyTakeover(a: a, m: m)));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.assistant, widget.location]),
      builder: (context, _) {
        final a = widget.assistant;
        _checkEmergency(a);
        final s = Situation.build(widget.location, a.geo, a.router);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: HereCard(s: s, geo: a.geo),
            ),
            if (a.messages.isNotEmpty) _QuickPrompts(a: a),
            Expanded(
              child: a.messages.isEmpty
                  ? _Welcome(a: a, s: s)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: a.messages.length,
                      itemBuilder: (_, i) => _Bubble(key: ObjectKey(a.messages[i]), m: a.messages[i], a: a),
                    ),
            ),
            if (_typing)
              _Composer(
                a: a,
                text: _text,
                pendingImagePath: _pendingImagePath,
                onClearImage: () => setState(() => _pendingImagePath = null),
                onPickImage: _pickImage,
                onClose: () => setState(() {
                  _typing = false;
                  _pendingImagePath = null;
                }),
              )
            else
              _VoiceBar(
                a: a,
                onKeyboard: () => setState(() => _typing = true),
                onPickImage: _pickImage,
              ),
          ],
        );
      },
    );
  }
}
String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One-tap questions that go through the same router as typed or spoken ones.
class _QuickPrompts extends StatelessWidget {
  final Assistant a;
  const _QuickPrompts({required this.a});

  static const _prompts = [
    (Icons.water_drop_outlined, 'Nearest water', 'Where is the nearest water?'),
    (Icons.directions_walk, 'Way out', 'How do I get out of here?'),
    (Icons.nights_stay_outlined, 'Getting dark', 'I am cold and it is getting dark.'),
    (Icons.pets, 'Bear nearby', 'There is a bear near me.'),
  ];

  @override
  Widget build(BuildContext context) {
    final enabled = !a.busy && a.phase != Phase.loading;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: _prompts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (icon, text, question) = _prompts[i];
          return ActionChip(
            avatar: Icon(icon, size: 16, color: kInk),
            label: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            backgroundColor: kCard,
            side: const BorderSide(color: kLine),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onPressed: enabled ? () => a.ask(question) : null,
          );
        },
      ),
    );
  }
}

/// Empty state: what the app can do, as big tappable tiles. The most urgent one comes first.
class _Welcome extends StatelessWidget {
  final Assistant a;
  final Situation s;
  const _Welcome({required this.a, required this.s});

  @override
  Widget build(BuildContext context) {
    final us = s.untilSunset;
    final dusk = s.isNight || (us != null && us < const Duration(hours: 1));
    final tiles = [
      (Icons.water_drop, kWater, 'Find water', 'Where is the nearest water?'),
      (Icons.hiking, kMoss, 'Get me out', 'How do I get out of here?'),
      (Icons.nights_stay, dusk ? kClay : kInk, 'Getting dark', 'I am cold and it is getting dark.'),
      (Icons.pets, kTrail, 'Wildlife', 'There is a bear near me.'),
    ];
    if (dusk) tiles.insert(0, tiles.removeAt(2));
    final loading = a.phase == Phase.loading;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What do you need?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(
          loading ? a.status : 'Tap one or hold the mic.',
          style: const TextStyle(color: kInkMuted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.1,
          children: [
            for (final (icon, color, text, question) in tiles)
              _Suggestion(icon: icon, color: color, text: text, onTap: a.busy || loading ? null : () => a.ask(question)),
          ],
        ),
      ]),
    );
  }
}

class _Suggestion extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onTap;
  const _Suggestion({required this.icon, required this.color, required this.text, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kLine, width: 1.5)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
      );
}

/// Three bouncing dots while an answer is on its way (only alive until the first words arrive).
class _Dots extends StatefulWidget {
  const _Dots();

  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: Transform.translate(
                offset: Offset(0, -4 * math.max(0, math.sin((_c.value - i / 6) * 2 * math.pi))),
                child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: kMoss, shape: BoxShape.circle)),
              ),
            ),
        ]),
      );
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  final Assistant a;
  const _Bubble({super.key, required this.m, required this.a});

  // one-shot fade and rise as each message arrives
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        builder: (_, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child)),
        child: m.user ? _user(context) : GestureDetector(onLongPress: () => _debug(context), child: _answer()),
      );

  Widget _user(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_hhmm(m.at)} Local', style: label(kInkMuted, size: 10).copyWith(letterSpacing: 0)),
                const SizedBox(width: 6),
                Text('YOU', style: label(kMoss, size: 10)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
            decoration: BoxDecoration(
              color: kUserBubble,
              border: Border.all(color: kUserBorder),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (m.imagePath != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(m.imagePath!),
                      width: double.infinity,
                      height: 180,
                      fit: BoxFit.cover,
                    ),
                  ),
                  if (m.text.isNotEmpty) const SizedBox(height: 8),
                ],
                if (m.text.isNotEmpty)
                  Text(m.text, style: const TextStyle(fontSize: 15, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// Long-press: how this answer was routed and, for Gemma, the exact prompt.
  void _debug(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
            Text('WHY THIS ANSWER', style: label(kInk, size: 14)),
            const SizedBox(height: 8),
            SelectableText(m.debug ?? '—', style: const TextStyle(fontSize: 13, height: 1.4)),
            if (m.prompt != null) ...[
              const SizedBox(height: 16),
              Text('PROMPT SENT TO GEMMA', style: label(kInk, size: 14)),
              const SizedBox(height: 8),
              SelectableText(m.prompt!, style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.35)),
            ],
          ]),
        ),
      );

  Widget _answer() {
    final gemma = m.kind == AnswerKind.gemma;
    final emergency = m.kind == AnswerKind.emergency;
    final isStreamingThis = a.streaming == m;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Icon(
                  gemma ? Icons.auto_awesome : Icons.verified_outlined,
                  size: 16,
                  color: emergency ? kClay : (isStreamingThis ? const Color(0xFFE87A3E) : kMoss),
                ),
                const SizedBox(width: 6),
                Text(
                  isStreamingThis
                      ? 'STREAMING INFERENCE (${a.lastTokenCount} TOKENS)'
                      : (gemma
                          ? 'GEMMA TACTICAL BRIEF'
                          : emergency
                              ? 'EMERGENCY SCRIPT'
                              : m.kind == AnswerKind.quick
                                  ? 'OFFLINE MAP DATA'
                                  : 'OFFLINE GUIDE'),
                  style: label(emergency ? kClay : (isStreamingThis ? const Color(0xFFE87A3E) : kMoss), size: 11),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: emergency
                    ? kClay
                    : (isStreamingThis ? const Color(0xFFE87A3E).withValues(alpha: 0.8) : kLine),
                width: (emergency || isStreamingThis) ? 1.5 : 1,
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kWell,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E9E3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Gemma answers are generated; only the scripted ones are vetted text
                  if (!gemma) ...[Text('VERIFIED OFFLINE ACTION', style: label(kClay, size: 10)), const SizedBox(height: 4)],
                  if (m.text.isEmpty)
                    const _Dots()
                  else
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.black87),
                      children: [
                        TextSpan(text: m.text),
                        if (isStreamingThis)
                          const TextSpan(
                            text: ' ▊',
                            style: TextStyle(
                              color: Color(0xFFE87A3E),
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (m.map != null) RouteMiniMap(assistant: a, route: m.map!),
                  // quick answers come from Laya + templates; one tap re-asks Gemma instead
                  if (!gemma && m.question != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: kMoss, visualDensity: VisualDensity.compact),
                        onPressed: a.busy ? null : () => a.ask(m.question!, forceLlm: true),
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: Text('ASK GEMMA', style: label(kMoss, size: 11)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The main input: one big hold-to-talk button. Typing is the secondary path.
class _VoiceBar extends StatelessWidget {
  final Assistant a;
  final VoidCallback onKeyboard;
  final void Function(ImageSource) onPickImage;
  const _VoiceBar({
    required this.a,
    required this.onKeyboard,
    required this.onPickImage,
  });

  @override
  Widget build(BuildContext context) {
    final listening = a.phase == Phase.listening;
    final loading = a.phase == Phase.loading;
    final working = a.busy && !listening && !loading;
    final stopMode = working || a.speaking;
    final caption = switch (a.phase) {
      Phase.loading => 'GETTING READY…',
      Phase.listening => 'LISTENING… RELEASE TO ASK',
      _ when stopMode => 'TAP TO STOP',
      Phase.ready => '',
      _ => a.status.toUpperCase(),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _RoundIcon(icon: Icons.keyboard_alt_outlined, tooltip: 'Type instead', onTap: onKeyboard),
          const SizedBox(width: 8),
          _RoundIcon(
            icon: Icons.camera_alt_outlined,
            tooltip: 'Camera snapshot',
            onTap: () => onPickImage(ImageSource.camera),
          ),
          const Spacer(),
          GestureDetector(
            onTapDown: stopMode || loading
                ? null
                : (_) {
                    HapticFeedback.mediumImpact();
                    a.pressTalk();
                  },
            onTapUp: stopMode || loading
                ? null
                : (_) {
                    HapticFeedback.lightImpact();
                    a.releaseTalk();
                  },
            onTapCancel: stopMode || loading ? null : () => a.releaseTalk(),
            onTap: stopMode ? a.stop : null,
            child: _MicButton(listening: listening, enabled: !loading, stop: stopMode),
          ),
          const Spacer(),
          _RoundIcon(
            icon: Icons.photo_outlined,
            tooltip: 'Pick photo',
            onTap: () => onPickImage(ImageSource.gallery),
          ),
        ]),
        const SizedBox(height: 6),
        if (caption.isNotEmpty) Text(caption, style: label(listening ? kClay : kInkMuted, size: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

class _MicButton extends StatefulWidget {
  final bool listening, enabled, stop;
  const _MicButton({required this.listening, required this.enabled, required this.stop});

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    // the pulse only runs while recording (battery)
    if (widget.listening && !_pulse.isAnimating) _pulse.repeat();
    if (!widget.listening && _pulse.isAnimating) _pulse.reset();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? kOutline
        : widget.listening
            ? kInk
            : widget.stop
                ? kInkMuted
                : kClay;
    return SizedBox(
      width: 140,
      height: 140,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) => Stack(alignment: Alignment.center, children: [
          if (widget.listening)
            Container(
              width: 110 + 30 * _pulse.value,
              height: 110 + 30 * _pulse.value,
              decoration: BoxDecoration(shape: BoxShape.circle, color: kClay.withValues(alpha: 0.35 * (1 - _pulse.value))),
            ),
          child!,
        ]),
        child: Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: kInk, width: 2),
            boxShadow: const [BoxShadow(color: kInk, offset: Offset(0, 3))],
          ),
          child: Icon(widget.listening ? Icons.graphic_eq : (widget.stop ? Icons.stop : Icons.mic), size: 52, color: kCard),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap, this.color = kInk});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        iconSize: 24,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: kCard,
          foregroundColor: color,
          side: BorderSide(color: color == kInk ? kLine : color, width: 1.5),
        ),
        icon: Icon(icon),
      );
}

class _Composer extends StatelessWidget {
  final Assistant a;
  final TextEditingController text;
  final String? pendingImagePath;
  final VoidCallback onClearImage;
  final void Function(ImageSource) onPickImage;
  final VoidCallback onClose;
  const _Composer({
    required this.a,
    required this.text,
    required this.pendingImagePath,
    required this.onClearImage,
    required this.onPickImage,
    required this.onClose,
  });

  void _send() {
    final v = text.text.trim();
    if (v.isEmpty && pendingImagePath == null) return;
    final prompt = v.isEmpty ? 'Analyze and describe what you see in this photo.' : v;
    a.ask(prompt, imagePath: pendingImagePath);
    text.clear();
    onClearImage();
  }

  @override
  Widget build(BuildContext context) {
    final listening = a.phase == Phase.listening;
    final working = a.busy && !listening;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pendingImagePath != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(pendingImagePath!),
                      height: 100,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: onClearImage,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              _RoundIcon(icon: Icons.mic, tooltip: 'Talk instead', onTap: onClose, color: kClay),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Camera snapshot',
                icon: const Icon(Icons.camera_alt_outlined, size: 20, color: kInkMuted),
                onPressed: () => onPickImage(ImageSource.camera),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Pick photo',
                icon: const Icon(Icons.photo_outlined, size: 20, color: kInkMuted),
                onPressed: () => onPickImage(ImageSource.gallery),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: text,
                  enabled: !working && a.phase != Phase.loading,
                  autofocus: true,
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: pendingImagePath != null
                        ? 'Ask about this image…'
                        : 'Ask Gemma about navigation, wildlife',
                    hintStyle: const TextStyle(color: Color(0xFF5C6E61), fontSize: 14),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 48,
                height: 48,
                child: working || a.speaking
                    ? IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: kClay,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: a.stop,
                        icon: const Icon(Icons.stop, color: kCard),
                      )
                    : IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: kInk,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: _send,
                        icon: const Icon(Icons.arrow_upward, color: kCard),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen emergency card: the scripted answer, the 911 / SOS call to action and the
/// matching first-aid steps, shown the moment the router flags an emergency.
class _EmergencyTakeover extends StatelessWidget {
  final Assistant a;
  final ChatMessage m;
  const _EmergencyTakeover({required this.a, required this.m});

  @override
  Widget build(BuildContext context) {
    final topic = RegExp(r'topic (\w+)').firstMatch(m.debug ?? '')?.group(1);
    final section = topic == null || topic == 'none' ? null : a.guide?.byId(topic);
    return Scaffold(
      backgroundColor: kClay,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.emergency, color: kCard, size: 28),
              const SizedBox(width: 8),
              Expanded(child: Text('EMERGENCY', style: label(kCard, size: 22))),
              IconButton(
                tooltip: 'Back to chat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: kCard, size: 28),
              ),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(m.text, style: const TextStyle(color: kCard, fontSize: 22, fontWeight: FontWeight.w700, height: 1.35)),
              ),
            ),
            const SizedBox(height: 16),
            const SosBanner(onClay: true),
            const SizedBox(height: 12),
            if (section != null)
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                icon: const Icon(Icons.format_list_numbered),
                label: Text('STEP-BY-STEP: ${section.title.toUpperCase()}'),
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => StepsScreen(assistant: a, section: section, name: section.title)),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(context),
              child: const Text('BACK TO CHAT'),
            ),
          ]),
        ),
      ),
    );
  }
}
