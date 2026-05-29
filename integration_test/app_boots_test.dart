// In-app integration tests. Run on a device or emulator:
//   flutter test integration_test/app_boots_test.dart
//
// These tests boot the real Flutter engine, load the prism_dsp .so, and verify
// that the cross-language plumbing carries data end-to-end. They do NOT grant
// system permissions — that's patrol's job.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:prism/main.dart' show PrismApp;
import 'package:prism/src/rust/api/audio_stream.dart' as audio;
import 'package:prism/src/rust/api/dsp_pipeline.dart' as dsp;
import 'package:prism/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // RustLib.init() must succeed exactly once per process. Doing it in setUpAll
  // means a single failure surfaces with full stack trace in CI logs, then
  // every downstream test reports the same root cause instead of timing out.
  Object? rustInitError;
  StackTrace? rustInitTrace;

  setUpAll(() async {
    try {
      await RustLib.init();
    } catch (e, st) {
      rustInitError = e;
      rustInitTrace = st;
      // ignore: avoid_print
      print('[PRISM][test] RustLib.init failed: $e\n$st');
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

  testWidgets('RustLib FFI bridge loads on this device/emulator',
      (tester) async {
    requireRust();
    // ring_occupancy is a synchronous FFI call; if the .so didn't load this
    // would throw before returning.
    final occ = audio.ringOccupancy();
    expect(occ, isA<int>());
    expect(occ, greaterThanOrEqualTo(0));
  });

  testWidgets('Phase 0 — app boots and renders home screen', (tester) async {
    requireRust();
    await tester.pumpWidget(const PrismApp());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('PRISM · Phase 0'), findsOneWidget);
    expect(find.text('Start capture'), findsOneWidget);
    expect(find.text('Record session'), findsOneWidget);
  });

  testWidgets('DSP pipeline lifecycle survives start/stop cycle',
      (tester) async {
    requireRust();
    dsp.startDsp();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // Even with no real audio, periodic snapshots may not fire because the ring
    // is empty — just verify we don't crash polling.
    final ev = dsp.nextDspEvent();
    expect(ev, isA<dsp.DspEvent?>());
    dsp.stopDsp();
  });

  testWidgets('Start/Stop capture button does not crash', (tester) async {
    requireRust();
    await tester.pumpWidget(const PrismApp());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final startBtn = find.text('Start capture');
    expect(startBtn, findsOneWidget);

    // Tapping fires the permission flow; on emulator without granted mic it
    // produces a banner error, which is the expected branch — we just verify
    // the app survives.
    await tester.tap(startBtn);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
