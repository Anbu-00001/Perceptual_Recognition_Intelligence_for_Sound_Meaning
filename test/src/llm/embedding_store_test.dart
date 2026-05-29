// Pure data-shape tests for the embedding-store layer. We don't call into
// the real flutter_gemma plugin here (that requires a device + model files);
// integration_test/ covers the live path.

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/llm/embedding_store.dart';

void main() {
  group('MatchResult', () {
    test('empty() is a non-hit', () {
      final m = MatchResult.empty();
      expect(m.isHit, isFalse);
      expect(m.source, MatchSource.none);
      expect(m.label, isEmpty);
      expect(m.score, 0);
      expect(m.metadata, isEmpty);
    });

    test('treats non-none source as a hit', () {
      final m = MatchResult(
        label: 'doorbell',
        score: 0.93,
        source: MatchSource.personal,
        metadata: const {'category': 'knock'},
      );
      expect(m.isHit, isTrue);
      expect(m.source, MatchSource.personal);
    });
  });
}
