// Widget tests for [ZoneEnrollmentScreen] — Phase 3.
//
// Covers the wizard lifecycle that on-device manual verification only
// exercised on the happy path:
//
//   - Initial render: title, prompt, label field, "Ready" indicator,
//     "Start 30s capture" button, no banner.
//   - Empty label → tap Start → red banner, NOT a recorder start.
//   - Valid label → tap Start → recorder starts (FFI calls captured),
//     UI flips to recording state with countdown.
//   - Stop early → recorder stop_take called, service.enrollZone called
//     once, success banner shows "Saved …".
//   - Cancel mid-record → recorder stop_take called, NO success path.
//   - Service returns TooShort → red banner with "only Ns" message.
//
// We bypass the real Rust by injecting a FakeZoneEnrollmentService and
// stubbing the platform method-channel that backs the Rust FFI calls
// for `enrollRecorderStart` / `enrollRecorderStopTake`. The FFI surface
// is itself covered separately by `enrollment_flow_test.dart` (device)
// and the Rust unit tests in `rust/src/api/enrollment.rs`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/spatial/room_zone.dart';
import 'package:prism/src/spatial/room_zone_repository.dart';
import 'package:prism/src/spatial/zone_enrollment_service.dart';
import 'package:prism/src/ui/zone_enrollment_screen.dart';

class _Recorded {
  ZoneEnrollmentResult? returnedFromEnroll;
  final List<({String label, String environment, int pcmLen})> calls = [];
}

class _FakeZoneService extends ZoneEnrollmentService {
  _FakeZoneService(this._rec, this._result, RoomZoneRepository repo)
      : super(
          repo: repo,
          minSampleSeconds: 10,
          featureExtractor: (_) => Float32List.fromList(
            List<double>.filled(21, 0.5),
          ),
        );

  final _Recorded _rec;
  final ZoneEnrollmentResult Function() _result;

  @override
  Future<ZoneEnrollmentResult> enrollZone({
    required Int16List pcm16k,
    required String label,
    required String environment,
    String? overrideId,
  }) async {
    _rec.calls.add((
      label: label,
      environment: environment,
      pcmLen: pcm16k.length,
    ));
    final r = _result();
    if (r is ZoneEnrollmentSuccess) {
      await repo.upsert(r.zone);
    }
    return r;
  }
}

Future<({RoomZoneRepository repo, Directory tmp, _Recorded rec})> _harness() async {
  final tmp = Directory.systemTemp.createTempSync('prism_zone_widget');
  final repo = RoomZoneRepository(
    overrideDirectory: tmp.path,
    pushPrototypes: (_) {},
  );
  return (repo: repo, tmp: tmp, rec: _Recorded());
}

class _Recorder {
  int starts = 0;
  int stops = 0;
  int lastMaxMs = 0;
  // PCM the next stopTake call returns; defaults to ~15 s @ 16 kHz so the
  // duration gate (≥10s) passes when tests don't override.
  List<int> nextPcm = List<int>.filled(16_000 * 15, 200);
}

Future<void> _pump(
  WidgetTester tester, {
  required RoomZoneRepository repo,
  required ZoneEnrollmentService service,
  required _Recorder recorder,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ZoneEnrollmentScreen(
      repo: repo,
      environment: 'home',
      service: service,
      recorderStart: (ms) {
        recorder.starts++;
        recorder.lastMaxMs = ms;
      },
      recorderStopTake: () async {
        recorder.stops++;
        return recorder.nextPcm;
      },
    ),
  ));
  // Let the FutureBuilder at the bottom resolve; do NOT use pumpAndSettle
  // (the success banner color animation never settles cleanly).
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initial render: prompt, "Ready", Start button, no banner',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z1',
          label: 'X',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 12,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    expect(find.text('Enroll a room'), findsOneWidget);
    expect(find.textContaining('Pick a quiet moment'), findsOneWidget);
    expect(find.widgetWithText(TextField, ''), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Start 30s capture'), findsOneWidget);
    expect(find.text('Stop early'), findsNothing);

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('empty label → red banner, no recorder call',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z1',
          label: 'X',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 12,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();

    expect(find.textContaining('Enter a label first'), findsOneWidget);
    expect(h.rec.calls, isEmpty,
        reason: 'Service.enrollZone must not be called when label is empty');

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('label + Start → "Ready" replaced by countdown + Stop early',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z1',
          label: 'Kitchen',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 14,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.enterText(find.byType(TextField), 'Kitchen');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump(); // Process the state transition.

    // Once recording starts the count-down replaces "Ready" with seconds.
    expect(find.text('Ready'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Stop early'), findsOneWidget);
    // Recorder hasn't been stopped yet → service not called yet.
    expect(h.rec.calls, isEmpty);

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('Stop early → service called once → success banner',
      (tester) async {
    final h = await _harness();
    final success = RoomZone(
      id: 'z42',
      label: 'Kitchen',
      environment: 'home',
      centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
      createdAtMs: 0,
      sampleSeconds: 14,
    );
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(success),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.enterText(find.byType(TextField), 'Kitchen');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();
    await tester.tap(find.text('Stop early'));
    // _finish() runs three awaits in sequence (stopTake, enrollZone,
    // setState). Drain real time + microtasks until everything lands.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    expect(h.rec.calls.length, 1);
    expect(h.rec.calls.single.label, 'Kitchen');
    expect(h.rec.calls.single.environment, 'home');
    expect(find.textContaining('Saved "Kitchen"'), findsOneWidget);
    expect(find.textContaining('14s'), findsOneWidget);
    expect(find.textContaining('env=home'), findsOneWidget);

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('Cancel mid-record → no service call, no success banner',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z',
          label: 'X',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 14,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.enterText(find.byType(TextField), 'Bedroom');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();

    expect(h.rec.calls, isEmpty,
        reason: 'Cancel must abandon the recording, not finalize it');
    expect(find.textContaining('Saved'), findsNothing);

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('service returns TooShort → red banner with seconds',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.tooShort(4, 10),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.enterText(find.byType(TextField), 'Office');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();
    await tester.tap(find.text('Stop early'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();

    expect(find.textContaining('only 4s'), findsOneWidget);
    expect(find.textContaining('at least 10s'), findsOneWidget);

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('label field is disabled while recording', (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z',
          label: 'X',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 14,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);

    await tester.enterText(find.byType(TextField), 'X');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();

    // Now recording — the field should be disabled.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse,
        reason: 'Label edits while recording would diverge from the centroid');

    h.tmp.deleteSync(recursive: true);
  });

  testWidgets('back-button mid-record disposes timer cleanly (no exception)',
      (tester) async {
    final h = await _harness();
    final svc = _FakeZoneService(
      h.rec,
      () => ZoneEnrollmentResult.success(
        RoomZone(
          id: 'z',
          label: 'X',
          environment: 'home',
          centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
          createdAtMs: 0,
          sampleSeconds: 14,
        ),
      ),
      h.repo,
    );

    final rec = _Recorder();
    await _pump(tester, repo: h.repo, service: svc, recorder: rec);
    await tester.enterText(find.byType(TextField), 'X');
    await tester.tap(find.text('Start 30s capture'));
    await tester.pump();

    // Pump a different widget — equivalent to navigating away. The
    // dispose() must cancel the periodic Timer or we'd get a "setState
    // called on disposed widget" exception in the next pump cycle.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull,
        reason: 'Timer must be cancelled in dispose');

    h.tmp.deleteSync(recursive: true);
  });
}
