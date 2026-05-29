import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/prototype.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;

rust_enroll.EnrollClipReport _ok({double snr = 12, double peak = -10}) =>
    rust_enroll.EnrollClipReport(
      accepted: true,
      rejectReason: null,
      durationMs: 1500,
      peakDbfs: peak,
      rmsDbfs: -18,
      noiseFloorDbfs: -50,
      snrDb: snr,
      activeRatio: 0.7,
      clippingRatio: 0.0,
      zcr: 0.08,
    );

EnrollmentSample _sample(String id, List<double> emb) => EnrollmentSample(
      id: id,
      caption: 'caption $id',
      embedding: emb,
      report: _ok(),
      recordedAt: DateTime(2026, 5, 29),
    );

double _norm(List<double> v) {
  double s = 0;
  for (final x in v) {
    s += x * x;
  }
  return math.sqrt(s);
}

void main() {
  test('centroid is L2-normalized average over the per-sample vectors', () {
    final p = SoundPrototype(
      id: 'p1',
      label: 'Front door knock',
      category: 'knock',
      environment: 'home',
      samples: [
        _sample('a', const [1.0, 0.0, 0.0]),
        _sample('b', const [0.0, 1.0, 0.0]),
        _sample('c', const [0.0, 0.0, 1.0]),
      ],
    );
    p.rebuildCentroid();
    expect(p.centroid.length, 3);
    expect(_norm(p.centroid), closeTo(1.0, 1e-6));
    // Symmetric average → all three components equal.
    expect(p.centroid[0], closeTo(p.centroid[1], 1e-6));
    expect(p.centroid[1], closeTo(p.centroid[2], 1e-6));
    expect(p.lastTrainedAt, isNotNull);
  });

  test('rebuilding twice with the same samples yields the same centroid', () {
    final p = SoundPrototype(
      id: 'p2',
      label: 'x',
      category: 'custom',
      environment: 'home',
      samples: [
        _sample('a', const [0.6, 0.8]),
        _sample('b', const [0.8, 0.6]),
      ],
    );
    p.rebuildCentroid();
    final first = List<double>.from(p.centroid);
    p.rebuildCentroid();
    expect(p.centroid.length, first.length);
    for (var i = 0; i < first.length; i++) {
      expect(p.centroid[i], closeTo(first[i], 1e-9));
    }
  });

  test('centroid is empty when no sample has an embedding', () {
    final p = SoundPrototype(
      id: 'p3',
      label: 'no-embed',
      category: 'custom',
      environment: 'home',
      samples: [_sample('a', const [])],
    );
    p.rebuildCentroid();
    expect(p.centroid, isEmpty);
  });

  test('JSON roundtrip preserves samples and centroid', () {
    final p = SoundPrototype(
      id: 'p4',
      label: 'Smoke alarm',
      category: 'smoke_alarm',
      environment: 'family',
      spatialZone: 'kitchen',
      createdAt: DateTime(2026, 1, 1),
      samples: [
        _sample('a', const [1.0, 2.0, 3.0]),
        _sample('b', const [2.0, 3.0, 4.0]),
      ],
    );
    p.rebuildCentroid();
    final j = p.toJson();
    final p2 = SoundPrototype.fromJson(j);
    expect(p2.id, p.id);
    expect(p2.label, p.label);
    expect(p2.category, p.category);
    expect(p2.environment, p.environment);
    expect(p2.spatialZone, p.spatialZone);
    expect(p2.samples.length, p.samples.length);
    expect(p2.samples.first.caption, p.samples.first.caption);
    expect(p2.centroid.length, p.centroid.length);
    for (var i = 0; i < p.centroid.length; i++) {
      expect(p2.centroid[i], closeTo(p.centroid[i], 1e-9));
    }
  });

  test('average dominates outliers but does not zero them', () {
    // 9 unit vectors at angle 0, one at angle 90°. Centroid should be very
    // close to the (1,0) direction but not exactly — this is the standard
    // d-vector behavior that makes the centroid robust to a single bad
    // recording without erasing it.
    final samples = <EnrollmentSample>[
      for (var i = 0; i < 9; i++) _sample('inliner$i', const [1.0, 0.0]),
      _sample('outlier', const [0.0, 1.0]),
    ];
    final p = SoundPrototype(
      id: 'p5',
      label: 'x',
      category: 'custom',
      environment: 'home',
      samples: samples,
    );
    p.rebuildCentroid();
    expect(p.centroid[0], greaterThan(0.95));
    expect(p.centroid[1], greaterThan(0.05));
    expect(p.centroid[1], lessThan(0.2));
  });
}
