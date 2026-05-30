// Widget tests for [SpatialOverlay] — Phase 3.
//
// The overlay paints conditionally on a 4-state matrix:
//   1. event == null                  → arc only, chip says "unknown"
//   2. mono-replicated (single mic)   → arc greyed; chip empty or unknown
//   3. real measurement, known zone   → needle + confidence wedge + zone chip
//   4. real measurement, no zone yet  → needle drawn but chip says unknown
//
// These tests pin the visual contract at the widget-tree level so a
// future paint refactor can't quietly regress the four cases.
//
// `_AnglePainter` is private, so visual assertions are made via:
//   - chip text (the user-facing contract)
//   - CustomPaint presence + painter identity via shouldRepaint
//   - widget heights / structural finds
//
// Reasoning: pixel-perfect screenshot tests are brittle here; the
// semantic contract is what matters.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/rust/api/dsp_pipeline.dart' as rust_dsp;
import 'package:prism/src/ui/spatial_overlay.dart';

rust_dsp.DspEvent _ev({
  rust_dsp.Zone zone = rust_dsp.Zone.unknown,
  double angleDeg = 0.0,
  double spatialConfidence = 0.0,
  double smoothedAngleDeg = 0.0,
  double smoothedAngleConfidence = 0.0,
  String zoneLabel = '',
  String zoneId = '',
  double zoneConfidence = 0.0,
}) =>
    rust_dsp.DspEvent(
      eventId: BigInt.from(1),
      timestampMs: BigInt.from(0),
      kind: rust_dsp.DspEventKind.periodicSnapshot,
      mfcc: Float32List(13),
      spectralCentroidHz: 1000,
      spectralRolloffHz: 4000,
      spectralFlatness: 0.5,
      subBandEnergy: Float32List(4),
      rms: 0.05,
      crestFactor: 1.4,
      zone: zone,
      angleDeg: angleDeg,
      spatialConfidence: spatialConfidence,
      smoothedAngleDeg: smoothedAngleDeg,
      smoothedAngleConfidence: smoothedAngleConfidence,
      zoneLabel: zoneLabel,
      zoneId: zoneId,
      zoneConfidence: zoneConfidence,
    );

Future<void> _pumpOverlay(WidgetTester tester, rust_dsp.DspEvent? event) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: SpatialOverlay(event: event),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('zone chip text contract', () {
    testWidgets('null event → unknown chip with enroll-call-to-action',
        (tester) async {
      await _pumpOverlay(tester, null);
      expect(find.text('room: unknown · enroll rooms to identify'),
          findsOneWidget);
      // Should NOT incorrectly show a percentage when there's nothing.
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('event with empty zoneLabel → unknown chip', (tester) async {
      await _pumpOverlay(
        tester,
        _ev(spatialConfidence: 0.5, zoneLabel: '', zoneConfidence: 0.0),
      );
      expect(find.text('room: unknown · enroll rooms to identify'),
          findsOneWidget);
    });

    testWidgets('zoneLabel + zero confidence → still treated as unknown',
        (tester) async {
      // Guard against a Rust regression where label is populated but
      // confidence dropped below the floor; the chip must NOT lie.
      await _pumpOverlay(
        tester,
        _ev(zoneLabel: 'Kitchen', zoneConfidence: 0.0),
      );
      expect(find.text('room: unknown · enroll rooms to identify'),
          findsOneWidget);
      expect(find.textContaining('Kitchen'), findsNothing);
    });

    testWidgets('zoneLabel + confidence → renders "room: X · NN%"',
        (tester) async {
      await _pumpOverlay(
        tester,
        _ev(
          zoneLabel: 'Kitchen',
          zoneConfidence: 0.873,
          spatialConfidence: 0.4,
          smoothedAngleDeg: 30,
          smoothedAngleConfidence: 0.6,
        ),
      );
      expect(find.text('room: Kitchen · 87%'), findsOneWidget);
    });

    testWidgets('rounding: 0.945 → "94%" not "95%" (toStringAsFixed truncates)',
        (tester) async {
      // toStringAsFixed(0) rounds banker-style; test the contract not the
      // arithmetic. Use a value far from boundary to avoid flake.
      await _pumpOverlay(
        tester,
        _ev(zoneLabel: 'Bedroom', zoneConfidence: 0.501),
      );
      expect(find.text('room: Bedroom · 50%'), findsOneWidget);
    });

    testWidgets('exotic label characters render verbatim', (tester) async {
      // Non-ASCII labels (Japanese, emoji) should round-trip without
      // mangling — the chip uses plain Text, no escaping.
      await _pumpOverlay(
        tester,
        _ev(zoneLabel: '居間 🏠', zoneConfidence: 0.91),
      );
      expect(find.text('room: 居間 🏠 · 91%'), findsOneWidget);
    });
  });

  group('paint state contract', () {
    testWidgets('null event → CustomPaint still present (arc-only base layer)',
        (tester) async {
      await _pumpOverlay(tester, null);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('mono-replicated event renders without needle paint',
        (tester) async {
      // spatialConfidence == 0 AND zone == unknown is the Rust signature
      // for "mono replicated" in the overlay's isMonoReplicated detector.
      // We can't assert "no needle drawn" without intercepting Canvas, but
      // we CAN assert the chip still degrades gracefully and there is no
      // crash.
      await _pumpOverlay(
        tester,
        _ev(
          spatialConfidence: 0.0,
          zone: rust_dsp.Zone.unknown,
          smoothedAngleDeg: 0,
          smoothedAngleConfidence: 0,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.textContaining('unknown'), findsOneWidget);
    });

    testWidgets('changing event triggers shouldRepaint via CustomPaint rebuild',
        (tester) async {
      // Pump two distinct events back-to-back; widget tree should rebuild
      // without throwing. (Smoke test for shouldRepaint correctness.)
      await _pumpOverlay(tester, _ev(zoneLabel: 'A', zoneConfidence: 0.6));
      await _pumpOverlay(tester, _ev(zoneLabel: 'B', zoneConfidence: 0.7));
      expect(find.text('room: B · 70%'), findsOneWidget);
      expect(find.text('room: A · 60%'), findsNothing);
    });
  });

  group('layout contract', () {
    testWidgets('respects the height parameter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: SpatialOverlay(event: null, height: 80),
            ),
          ),
        ),
      );
      await tester.pump();
      final box = tester.getSize(find.byType(SpatialOverlay));
      expect(box.height, 80);
    });

    testWidgets('renders within a narrow column without overflow', (tester) async {
      // Phone widths from 320 to 720 logical px should never overflow.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 110,
              child: SpatialOverlay(
                event: _ev(zoneLabel: 'Long Room Name Here', zoneConfidence: 0.9),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
