// Integration test for the DSP event flow end-to-end. The native audio capture
// is not exercised here (that requires patrol + a real mic) — instead we verify
// that the polling surface doesn't crash when fed no input.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:prism/src/rust/api/audio_stream.dart' as audio;
import 'package:prism/src/rust/api/dsp_pipeline.dart' as dsp;
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

  testWidgets('pipeline emits at least one periodic snapshot when idle',
      (tester) async {
    requireRust();
    dsp.startDsp();

    var seenPeriodicOrNull = false;
    for (var i = 0; i < 30; i++) {
      final ev = dsp.nextDspEvent();
      if (ev == null) {
        seenPeriodicOrNull = true;
      } else if (ev.kind == dsp.DspEventKind.periodicSnapshot) {
        seenPeriodicOrNull = true;
        expect(ev.mfcc.length, greaterThan(0));
        expect(ev.subBandEnergy.length, 4);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    expect(seenPeriodicOrNull, isTrue);
    dsp.stopDsp();
  });

  testWidgets('next_dsp_event returns null when pipeline is stopped',
      (tester) async {
    requireRust();
    dsp.stopDsp();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    while (dsp.nextDspEvent() != null) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(dsp.nextDspEvent(), isNull);
  });

  testWidgets('waveform pull returns a frame or null without crashing',
      (tester) async {
    requireRust();
    final f = audio.nextWaveformFrame();
    expect(f, isA<audio.WaveformFrame?>());
  });
}
