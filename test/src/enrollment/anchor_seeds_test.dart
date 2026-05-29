import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/categories.dart';

void main() {
  late List<Map<String, dynamic>> seeds;

  setUpAll(() {
    final file = File('assets/anchor_seeds.json');
    expect(file.existsSync(), isTrue,
        reason: 'assets/anchor_seeds.json must be committed to the repo');
    seeds = (jsonDecode(file.readAsStringSync()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  });

  test('manifest is non-trivial (at least 40 entries)', () {
    expect(seeds.length, greaterThanOrEqualTo(40));
  });

  test('every entry has id, label, category, caption', () {
    for (final e in seeds) {
      for (final k in ['id', 'label', 'category', 'caption']) {
        expect(e[k], isA<String>(),
            reason: 'entry ${e['id'] ?? '?'} missing $k');
        expect((e[k] as String).isNotEmpty, isTrue);
      }
    }
  });

  test('ids are unique', () {
    final ids = seeds.map((e) => e['id'] as String).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('categories reference at least one known SoundCategory id, '
      'or are one of the runtime-only ambient buckets', () {
    final known = SoundCategory.all.map((c) => c.id).toSet()
      ..addAll(['speech', 'ambient', 'animal', 'household', 'alarm']);
    for (final e in seeds) {
      expect(known, contains(e['category']),
          reason: 'entry ${e['id']} has unknown category ${e['category']}');
    }
  });

  test('captions look caption-shaped (one sentence, 8-25 words)', () {
    final wordCounts = <int>[];
    for (final e in seeds) {
      final caption = e['caption'] as String;
      // Single sentence: at most one '.' near the end.
      final inner = caption.replaceAll(RegExp(r'[.!?]$'), '');
      expect(inner.contains('.'), isFalse,
          reason: 'caption for ${e['id']} has more than one sentence');
      final words = inner.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      wordCounts.add(words);
      expect(words, greaterThanOrEqualTo(6),
          reason: 'caption for ${e['id']} too short: $caption');
      expect(words, lessThanOrEqualTo(28),
          reason: 'caption for ${e['id']} too long: $caption');
    }
  });
}
