import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/llm/scene_verdict.dart';

void main() {
  group('SceneVerdict', () {
    test('parses well-formed JSON', () {
      final v = SceneVerdict.fromJson({
        'kind': 'alarm',
        'scene_summary': 'smoke alarm beeping in kitchen',
        'confidence': 0.91,
        'salience': 'urgent',
        'key_elements': ['smoke alarm', 'periodic beep'],
        'needs_visual_confirmation': true,
      });
      expect(v.kind, 'alarm');
      expect(v.confidence, 0.91);
      expect(v.salience, 'urgent');
      expect(v.keyElements, ['smoke alarm', 'periodic beep']);
      expect(v.needsVisualConfirmation, true);
    });

    test('falls back to safe defaults for missing fields', () {
      final v = SceneVerdict.fromJson(const {});
      expect(v.kind, 'unknown');
      expect(v.confidence, 0.0);
      expect(v.salience, 'info');
      expect(v.keyElements, isEmpty);
      expect(v.needsVisualConfirmation, false);
    });

    test('toJson roundtrips', () {
      final original = SceneVerdict(
        kind: 'household',
        sceneSummary: 'fridge compressor cycling',
        confidence: 0.42,
        salience: 'info',
        keyElements: const ['compressor', 'periodic'],
        needsVisualConfirmation: false,
      );
      final round = SceneVerdict.fromJson(original.toJson());
      expect(round.kind, original.kind);
      expect(round.sceneSummary, original.sceneSummary);
      expect(round.confidence, original.confidence);
      expect(round.salience, original.salience);
      expect(round.keyElements, original.keyElements);
      expect(round.needsVisualConfirmation, original.needsVisualConfirmation);
    });

    test('empty() is a valid SceneVerdict', () {
      final v = SceneVerdict.empty();
      expect(v.kind, 'unknown');
      expect(v.sceneSummary, isEmpty);
    });
  });
}
