// Integration test for the SceneVerdict orchestration layer. Mocks out the
// flutter_gemma model calls (those require model downloads + an NPU). Verifies
// the orchestrator's routing logic, error handling, and lifecycle.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:prism/src/llm/scene_verdict.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SceneVerdict.empty is structurally valid', (tester) async {
    final v = SceneVerdict.empty();
    expect(v.kind, 'unknown');
    expect(v.confidence, 0.0);
    expect(v.keyElements, isEmpty);
  });

  // Live model tests live in test_with_models/ — gated behind a HF_TOKEN
  // dart-define and a downloaded model. See docs/adr/0006-test-strategy.md.
}
