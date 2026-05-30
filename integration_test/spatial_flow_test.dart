// Phase 3 integration test — runs on a connected device or emulator.
//
// Verifies the cross-process contract that host tests cannot reach:
//   1. `RustLib.init` brings up the Rust crate, including the zone module.
//   2. `zone_compute_feature` on 1 s of synthetic 16 kHz mono returns a
//      length-21 vector with at least one non-zero coefficient.
//   3. `zone_set_prototypes` / `zone_clear_prototypes` round-trip via
//      `zone_prototype_count`.
//   4. Two features computed from acoustically distinct synthetic audio
//      have different cosine similarity to one of them (sanity that the
//      feature is content-sensitive, not just length-correct).
//
// What this test does NOT do:
//   - Start the foreground service or open a real microphone. That's
//     covered by `enrollment_flow_test.dart` (Phase 2) and exercised
//     manually in `docs/adr/0009-phase3-spatial-zones.md` on-device.
//   - Drive the `ZoneEnrollmentScreen` widget; that's `test/src/ui/`.
//
// Why ship this at all when widget + unit tests already exist:
//   The Rust FFI surface is built by `flutter_rust_bridge_codegen` and
//   any signature drift between Dart and Rust shows up only on a real
//   device once the generated bridge is loaded. This test fails fast in
//   CI if the codegen step is skipped.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:prism/src/rust/api/zone.dart' as rust_zone;
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
      print('[PRISM][zone] RustLib.init failed: $e\n$st');
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

  setUp(() {
    // Each test starts from an empty prototype table so they don't bleed.
    if (rustInitError == null) {
      rust_zone.zoneClearPrototypes();
    }
  });

  List<int> synthSine({
    required double freqHz,
    int sampleRate = 16_000,
    double durationSec = 1.0,
    double amp = 0.3,
  }) {
    final n = (sampleRate * durationSec).toInt();
    return List<int>.generate(
      n,
      (i) => (amp * 32_767 * math.sin(2 * math.pi * freqHz * i / sampleRate))
          .toInt(),
    );
  }

  double cosineSim(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    var num = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      num += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0.0;
    return num / (math.sqrt(na) * math.sqrt(nb));
  }

  testWidgets('zone_feature_dim matches the Dart-side constant 21',
      (tester) async {
    requireRust();
    final dim = rust_zone.zoneFeatureDim();
    expect(dim, 21,
        reason:
            'feature dim is contract-frozen — if you change it, '
            'bump the centroid serialization version too');
  });

  testWidgets('zone_compute_feature returns 21-D non-zero vector for 1s tone',
      (tester) async {
    requireRust();
    final pcm = synthSine(freqHz: 740);
    final f = rust_zone.zoneComputeFeature(samples16KMono: pcm);
    expect(f.length, 21);
    expect(f.any((v) => v.abs() > 0.0), isTrue,
        reason: 'all-zero feature vector means STFT failed silently');
  });

  testWidgets('short input returns all-zero feature (graceful, not crash)',
      (tester) async {
    requireRust();
    final pcm = List<int>.filled(100, 0); // < one STFT window
    final f = rust_zone.zoneComputeFeature(samples16KMono: pcm);
    expect(f.length, 21);
    expect(f.every((v) => v == 0.0), isTrue);
  });

  testWidgets('set + clear prototypes round-trips via count',
      (tester) async {
    requireRust();
    expect(rust_zone.zonePrototypeCount(), 0);

    final centroid = Float32List.fromList(List<double>.filled(21, 0.5));
    final accepted = rust_zone.zoneSetPrototypes(items: [
      rust_zone.ZonePrototypeDto(
        id: 'a',
        label: 'A',
        centroid: centroid,
      ),
      rust_zone.ZonePrototypeDto(
        id: 'b',
        label: 'B',
        centroid: centroid,
      ),
    ]);
    expect(accepted, 2);
    expect(rust_zone.zonePrototypeCount(), 2);

    rust_zone.zoneClearPrototypes();
    expect(rust_zone.zonePrototypeCount(), 0);
  });

  testWidgets('wrong-dim prototype is silently dropped, not crashed',
      (tester) async {
    requireRust();
    final accepted = rust_zone.zoneSetPrototypes(items: [
      rust_zone.ZonePrototypeDto(
        id: 'wrong',
        label: 'Wrong',
        centroid: Float32List.fromList(const [0.1, 0.2, 0.3]), // dim != 21
      ),
    ]);
    expect(accepted, 0);
    expect(rust_zone.zonePrototypeCount(), 0);
  });

  testWidgets('features from acoustically distinct audio are NOT identical',
      (tester) async {
    requireRust();
    final low = rust_zone.zoneComputeFeature(
      samples16KMono: synthSine(freqHz: 220),
    );
    final high = rust_zone.zoneComputeFeature(
      samples16KMono: synthSine(freqHz: 4000),
    );
    final sim = cosineSim(low, high);
    expect(sim, lessThan(0.999),
        reason:
            'distinct frequencies produced identical features — extractor '
            'is broken or only carries DC');
    // Sanity floor: features still live in the same low-dim space, so
    // they won't be wildly orthogonal either. Just confirm they're not
    // bit-identical.
  });

  testWidgets('zone_centroid_from_features averages multiple windows',
      (tester) async {
    requireRust();
    final a = rust_zone.zoneComputeFeature(
      samples16KMono: synthSine(freqHz: 500),
    );
    final b = rust_zone.zoneComputeFeature(
      samples16KMono: synthSine(freqHz: 600),
    );
    final mean = rust_zone.zoneCentroidFromFeatures(features: [a, b]);
    expect(mean.length, 21);
    // The averaged centroid should land between the two endpoints in
    // cosine space — not literally equal to either.
    final simA = cosineSim(mean, a);
    final simB = cosineSim(mean, b);
    expect(simA, greaterThan(0.0));
    expect(simB, greaterThan(0.0));
    expect((simA - simB).abs(), lessThan(0.5),
        reason: 'centroid should not collapse onto one input');
  });
}
