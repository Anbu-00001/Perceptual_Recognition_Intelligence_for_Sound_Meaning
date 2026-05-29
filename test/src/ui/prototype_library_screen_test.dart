import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/audio/audio_service.dart';
import 'package:prism/src/enrollment/enrollment_service.dart';
import 'package:prism/src/enrollment/environment_manager.dart';
import 'package:prism/src/enrollment/prototype.dart';
import 'package:prism/src/enrollment/prototype_repository.dart';
import 'package:prism/src/enrollment/prototype_vector_mirror.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;
import 'package:prism/src/ui/prototype_library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../enrollment/_fakes.dart';

/// Drive enough real time + pumps for the screen's `_load()` to land + the
/// trailing setState to flush. We don't use pumpAndSettle: the loading
/// indicator's rotation never settles.
Future<void> _settleLoad(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
  }
}

Future<({PrototypeRepository repo, EnrollmentService service, EnvironmentManager env, AudioService audio, Directory tmp})> _setupHarness() async {
  final tmp = Directory.systemTemp.createTempSync('prism_proto_lib_widget');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final env = EnvironmentManager(prefs: prefs);
  final repo = PrototypeRepository(
    mirror: InMemoryPrototypeVectorMirror(),
    overrideDirectory: tmp.path,
  );
  final service = EnrollmentService(
    repo: repo,
    embeddings: RecordingEmbedder(),
    captioner: FakeCaptioner(),
    analyzer: constantAnalyzer(accepted: true),
  );
  final audio = AudioService();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.prism/audio_capture'),
    (call) async => true,
  );

  return (repo: repo, service: service, env: env, audio: audio, tmp: tmp);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty state shows the no-sounds hint and the enroll FAB',
      (tester) async {
    final h = await _setupHarness();

    await tester.pumpWidget(MaterialApp(
      home: PrototypeLibraryScreen(
        service: h.service,
        envManager: h.env,
        repo: h.repo,
        audio: h.audio,
      ),
    ));
    await _settleLoad(tester);

    expect(find.textContaining('No personal sounds enrolled'), findsOneWidget);
    expect(find.text('Enroll'), findsOneWidget);

    try {
      h.tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // TODO(phase 2.5): wire device-side patrol coverage for the populated state.
  // The host widget-test path hangs reliably on the second pumpWidget after a
  // PrototypeRepository.upsert (broadcast StreamController + InMemoryMirror
  // interaction with the test binding's microtask scheduler). Functionally
  // covered by `prototype_repository_test.dart` + `enrollment_service_test.dart`.
  testWidgets('populated repo renders a row per prototype with sample count',
      skip: true, (tester) async {
    final h = await _setupHarness();

    await h.repo.upsert(SoundPrototype(
      id: 'p1',
      label: 'Front door knock',
      category: 'knock',
      environment: 'home',
      samples: [
        EnrollmentSample(
          id: 's1',
          caption: 'three taps',
          embedding: const [1.0, 0.0],
          report: rust_enroll.EnrollClipReport(
            accepted: true,
            rejectReason: null,
            durationMs: 1500,
            peakDbfs: -10,
            rmsDbfs: -18,
            noiseFloorDbfs: -50,
            snrDb: 12,
            activeRatio: 0.7,
            clippingRatio: 0,
            zcr: 0.08,
          ),
          recordedAt: DateTime(2026, 1, 1),
        ),
      ],
    ));

    await tester.pumpWidget(MaterialApp(
      home: PrototypeLibraryScreen(
        service: h.service,
        envManager: h.env,
        repo: h.repo,
        audio: h.audio,
      ),
    ));
    await _settleLoad(tester);

    expect(find.text('Front door knock'), findsOneWidget);
    expect(find.byKey(const ValueKey('proto.p1')), findsOneWidget);
    expect(find.textContaining('1 sample'), findsOneWidget);

    try {
      h.tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
}
