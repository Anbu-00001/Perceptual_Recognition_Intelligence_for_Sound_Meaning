import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/eval/phase1_eval.dart';

void main() {
  group('GateMetrics', () {
    test('CONTINUE when every threshold is hit', () {
      final m = GateMetrics();
      // 96/100 = 96% fast-path
      m.fastPathTotal = 100;
      m.fastPathCorrect = 96;
      // 48/50 ≥4/5 = 96% coherence
      m.coherenceRatings.addAll(List.filled(48, 5));
      m.coherenceRatings.addAll(List.filled(2, 2));
      // 90/100 = 90% spatial
      m.spatialTotal = 100;
      m.spatialCorrect = 90;
      // latencies under 4s p95
      for (var i = 0; i < 100; i++) {
        m.slowPathLatencyMs.add(1000 + i * 10);
      }
      expect(m.decision(), 'CONTINUE');
    });

    test('KILL when fast path collapses below 80%', () {
      final m = GateMetrics();
      m.fastPathTotal = 100;
      m.fastPathCorrect = 70;
      m.coherenceRatings.addAll(List.filled(50, 5));
      m.spatialTotal = 10;
      m.spatialCorrect = 9;
      m.slowPathLatencyMs.add(500);
      expect(m.decision(), contains('KILL'));
      expect(m.decision(), contains('fast_path<0.80'));
    });

    test('CONTINUE_WITH_WARNINGS when between thresholds', () {
      final m = GateMetrics();
      m.fastPathTotal = 100;
      m.fastPathCorrect = 85; // < 92 (warn) but > 80 (continue)
      m.coherenceRatings.addAll(List.filled(70, 5));
      m.coherenceRatings.addAll(List.filled(30, 2)); // 70%
      m.spatialTotal = 100;
      m.spatialCorrect = 78; // < 85 warn but > 70 continue
      for (var i = 0; i < 100; i++) {
        m.slowPathLatencyMs.add(5000); // > 4s warn but < 8s continue
      }
      final decision = m.decision();
      expect(decision, startsWith('CONTINUE_WITH_WARNINGS'));
      expect(decision, contains('fast_path<0.92'));
      expect(decision, contains('coherence<0.80'));
      expect(decision, contains('spatial<0.85'));
      expect(decision, contains('latency_p95>4s'));
    });

    test('p95 latency computation', () {
      final m = GateMetrics();
      for (var i = 1; i <= 100; i++) {
        m.slowPathLatencyMs.add(i);
      }
      expect(m.p95LatencyMs, anyOf(95, 96)); // depending on floor rounding
    });

    test('handles empty data without crashing', () {
      final m = GateMetrics();
      expect(m.fastPathAcc, 0);
      expect(m.spatialAcc, 0);
      expect(m.coherence80, 0);
      expect(m.p95LatencyMs, 0);
    });
  });
}
