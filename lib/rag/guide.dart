import 'dart:math' as math;

import 'package:flutter/services.dart';

class GuideSection {
  final String id, title, summary, body;
  const GuideSection(this.id, this.title, this.summary, this.body);
  String get full => '$summary\n$body';
}

class GuideHit {
  final GuideSection section;
  final double score;
  const GuideHit(this.section, this.score);
}

/// Retrieval over the bundled guide. v1: Laya picks the topic (see router.dart) and BM25 backs
/// it up; a v2 embedding retriever can implement [search] with the same signature.
abstract class Retriever {
  List<GuideHit> search(String query, {int k = 2});
}

class Guide implements Retriever {
  final List<GuideSection> sections;
  late final _Bm25 _bm25 = _Bm25([for (final s in sections) '${s.title} ${s.title} ${s.full}']);
  Guide(this.sections);

  static Future<Guide> load() async {
    final raw = await rootBundle.loadString('assets/guide/guide.md');
    final sections = <GuideSection>[];
    final parts = raw.split(RegExp(r'^## ', multiLine: true)).skip(1);
    for (final part in parts) {
      final nl = part.indexOf('\n');
      final header = part.substring(0, nl).split('|');
      final text = part.substring(nl + 1).trim();
      final para = text.split(RegExp(r'\n\s*\n'));
      sections.add(GuideSection(
        header[0].trim(),
        header.length > 1 ? header[1].trim() : header[0].trim(),
        para.first.trim(),
        para.skip(1).join('\n\n').trim(),
      ));
    }
    return Guide(sections);
  }

  GuideSection? byId(String id) {
    for (final s in sections) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  List<GuideHit> search(String query, {int k = 2}) {
    final scores = _bm25.score(query);
    final idx = List.generate(sections.length, (i) => i)..sort((a, b) => scores[b].compareTo(scores[a]));
    return [for (final i in idx.take(k)) if (scores[i] > 0) GuideHit(sections[i], scores[i])];
  }
}

class _Bm25 {
  static const _k1 = 1.4, _b = 0.75;
  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'to', 'of', 'in', 'on', 'is', 'it', 'i', 'my', 'me', 'do', 'what',
    'how', 'should', 'can', 'for', 'with', 'you', 'your', 'if', 'at', 'be', 'are', 'am', 'there', 'this',
    'near', 'our', 'we', 'they', 'get', 'got', 'from', 'into', 'out', 'up', 'down', 'not', 'no', 'all', 'any',
    'camp', 'help', 'need', 'now', 'will', 'just', 'very', 'much', 'more', 'less',
  };
  final List<Map<String, int>> _tf = [];
  final List<int> _len = [];
  final Map<String, int> _df = {};
  late final double _avg;

  _Bm25(List<String> docs) {
    for (final d in docs) {
      final tf = <String, int>{};
      final toks = tokens(d);
      for (final t in toks) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      for (final t in tf.keys) {
        _df[t] = (_df[t] ?? 0) + 1;
      }
      _tf.add(tf);
      _len.add(toks.length);
    }
    _avg = _len.fold<int>(0, (a, b) => a + b) / math.max(1, _len.length);
  }

  static List<String> tokens(String s) => [
        for (final t in s.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
          if (t.length > 1 && !_stop.contains(t)) _stem(t),
      ];

  static String _stem(String t) {
    for (final suf in const ['ing', 'ed', 'es', 's']) {
      if (t.length > suf.length + 3 && t.endsWith(suf)) return t.substring(0, t.length - suf.length);
    }
    return t;
  }

  List<double> score(String query) {
    final q = tokens(query);
    final n = _tf.length;
    return List.generate(n, (i) {
      var s = 0.0;
      for (final t in q) {
        final f = _tf[i][t];
        if (f == null) continue;
        final idf = math.log(1 + (n - _df[t]! + 0.5) / (_df[t]! + 0.5));
        s += idf * f * (_k1 + 1) / (f + _k1 * (1 - _b + _b * _len[i] / _avg));
      }
      return s;
    });
  }
}
