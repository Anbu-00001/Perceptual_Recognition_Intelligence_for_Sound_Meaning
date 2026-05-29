// In-app integration tests. Run on a device or emulator:
//   flutter test integration_test/app_boots_test.dart
//
// These tests boot the real Flutter engine, load the prism_dsp .so, and verify
// that the cross-language plumbing carries data end-to-end. They do NOT grant
// system permissions — that's patrol's job. They DO verify that the UI renders
// and the Rust runtime initializes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:prism/main.dart' as app;
import 'package:prism/src/rust/api/audio_stream.dart' as audio;
import 'package:prism/src/rust/api/dsp_pipeline.dart' as dsp;
import 'package:prism/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 0 — app boots and renders home screen', (tester) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('PRISM · Phase 0'), findsOneWidget);
    expect(find.text('Start capture'), findsOneWidget);
    expect(find.text('Record session'), findsOneWidget);
  });

  testWidgets('RustLib FFI bridge is loaded and callable', (tester) async {
    await RustLib.init();
    // ring_occupancy is a synchronous FFI call; if the .so didn't load this
    // would throw before returning.
    final occ = audio.ringOccupancy();
    expect(occ, isA<int>());
    expect(occ, greaterThanOrEqualTo(0));
  });

  testWidgets('DSP pipeline lifecycle survives start/stop cycle', (tester) async {
    await RustLib.init();
    dsp.startDsp();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // Even with no real audio, periodic snapshots may not fire because the ring
    // is empty — just verify we don't crash polling.
    final ev = dsp.nextDspEvent();
    expect(ev, isA<dsp.DspEvent?>());
    dsp.stopDsp();
  });

  testWidgets('Start/Stop capture button does not crash', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

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
