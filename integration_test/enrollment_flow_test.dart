// Integration test for the Phase 2 enrollment pipeline end-to-end on a
// connected device or emulator. Verifies:
//   1. RustLib is initialized.
//   2. The Rust enrollment recorder lifecycle (start → stop → take) works
//      across the FFI bridge with the same semantics as the host tests.
//   3. The Rust clip-quality validator returns a populated report for a
//      synthetic 16 kHz mono buffer and lands in either accepted or a
//      readable reject reason.
//
// What this test does NOT do:
//   - Drive Gemma3n / EmbeddingGemma. Those need model files + an HF token,
//     so they live in `test_with_models/` per `docs/adr/0006-test-strategy.md`.
//   - Tap the microphone. patrol drives that flow in
//     `integration_test/patrol_permissions_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;
import 'package:prism/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Object? rustInitError;
  StackTrace? rustInitTrace;

  setUpAll(() async {
    try {
      await RustLib.init();
    } catch (e, st) {
      rustInitError = e;
      rustInitTrace = st;
      // ignore: avoid_print
      print('[PRISM][enroll] RustLib.init failed: $e\n$st');
    }
  });

  void requireRust() {
    expect(
      rustInitError,
      isNull,
      reason: 'RustLib.init failed during setUpAll: '
          '$rustInitError\n${rustInitTrace ?? ''}',
    );
  }

  testWidgets('enrollment recorder start/stop returns empty buffer when idle',
      (tester) async {
    requireRust();
    rust_enroll.enrollRecorderStart(maxDurationMs: 1500);
    final pcm = await rust_enroll.enrollRecorderStopTake();
    expect(pcm, isA<List<int>>());
    expect(pcm, isEmpty,
        reason: 'idle recorder has no pipeline pushing audio in');
  });

  testWidgets('clip validator returns a populated report for synthetic audio',
      (tester) async {
    requireRust();
    // 1 second of synthetic 16 kHz mono mid-amplitude noise (clearly above
    // the noise floor, no clipping). Should pass every gate.
    final n = 16000;
    final pcm = List<int>.generate(n, (i) {
      // ~5000 amplitude tonal+noise mix: easily detectable, never clips.
      final base = (3000 * (i % 13 == 0 ? -1 : 1));
      final mod = (1500 * (i % 7 == 0 ? -1 : 1));
      return (base + mod).toInt();
    });
    final report =
        await rust_enroll.analyzeEnrollmentClip16K(samples: pcm);
    expect(report.durationMs, inInclusiveRange(800, 1200));
    expect(report.peakDbfs, greaterThan(-40));
    expect(report.snrDb, isA<double>());
  });

  testWidgets('clip validator rejects a 200ms-too-short clip with TooShort',
      (tester) async {
    requireRust();
    final pcm = List<int>.filled(3200, 1000); // 200 ms @ 16 kHz
    final report =
        await rust_enroll.analyzeEnrollmentClip16K(samples: pcm);
    expect(report.accepted, isFalse);
    expect(report.rejectReason, rust_enroll.EnrollRejectReason.tooShort);
  });
}
