// Cross-phase integration: when [EnvironmentManager.setActive] fires, both
// the Phase 2 [PrototypeRepository] (sound prototypes) and the Phase 3
// [RoomZoneRepository] (room fingerprints) must filter to the new
// environment without crossing the streams.
//
// The repos don't subscribe to the manager directly — the home screen
// wires the subscription. This test recreates the wire and asserts the
// joint contract:
//   - Each repo is populated with entries in BOTH 'home' and 'office'.
//   - Subscribe a syncer to EnvironmentManager.changes.
//   - Initial state: active env is 'home', both repos report 'home' rows.
//   - Trigger setActive('office').
//   - Both repos now report 'office' rows.
//   - RoomZoneRepository's Rust-push captured exactly the 'office' set —
//     proving the active-env filter reached the Rust mirror, not just
//     the Dart-side query.
//
// This guards against future regressions where one phase's filter is
// switched while the other silently drifts (an easy oversight when the
// home screen wires only one of them).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/categories.dart';
import 'package:prism/src/enrollment/environment_manager.dart';
import 'package:prism/src/enrollment/prototype.dart';
import 'package:prism/src/enrollment/prototype_repository.dart';
import 'package:prism/src/enrollment/prototype_vector_mirror.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;
import 'package:prism/src/rust/api/zone.dart' as rust_zone;
import 'package:prism/src/spatial/room_zone.dart';
import 'package:prism/src/spatial/room_zone_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

SoundPrototype _sound(String id, String env) => SoundPrototype(
      id: id,
      label: id,
      category: SoundCategory.knock.id,
      environment: env,
      samples: [
        EnrollmentSample(
          id: '${id}_s',
          caption: 'tap',
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
    );

RoomZone _zone(String id, String env) => RoomZone(
      id: id,
      label: id,
      environment: env,
      centroid: Float32List.fromList(List<double>.filled(21, 0.5)),
      createdAtMs: 0,
      sampleSeconds: 12,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late EnvironmentManager envManager;
  late PrototypeRepository soundRepo;
  late RoomZoneRepository roomRepo;
  late List<List<rust_zone.ZonePrototypeDto>> rustPushes;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('prism_env_switch');
    SharedPreferences.setMockInitialValues(
      <String, Object>{'prism.env.active': 'home'},
    );
    final prefs = await SharedPreferences.getInstance();
    envManager = EnvironmentManager(prefs: prefs);

    soundRepo = PrototypeRepository(
      mirror: InMemoryPrototypeVectorMirror(),
      overrideDirectory: tmp.path,
    );

    rustPushes = [];
    roomRepo = RoomZoneRepository(
      overrideDirectory: '${tmp.path}/zones',
      pushPrototypes: (dtos) => rustPushes.add(List.of(dtos)),
    );

    // Seed both repos with content in both environments.
    await soundRepo.upsert(_sound('home_knock', 'home'));
    await soundRepo.upsert(_sound('office_knock', 'office'));
    await roomRepo.upsert(_zone('home_kitchen', 'home'));
    await roomRepo.upsert(_zone('office_lobby', 'office'));

    // After upserts, only the active environment's room set should have
    // been pushed to Rust. The default is 'home'.
    expect(roomRepo.activeEnvironment, 'home');
    expect(rustPushes.last.map((d) => d.id), unorderedEquals(['home_kitchen']));
  });

  tearDown(() async {
    await envManager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('initial state: both repos return only the active environment',
      () async {
    final sounds = await soundRepo.listFor('home');
    final zones = await roomRepo.listFor('home');
    expect(sounds.map((s) => s.id), ['home_knock']);
    expect(zones.map((z) => z.id), ['home_kitchen']);
  });

  test('env switch reflects in BOTH repos (Dart + Rust mirror)', () async {
    // Wire the syncer that production wires in home_screen.dart.
    final sub = envManager.changes.listen((env) async {
      await roomRepo.setActiveEnvironment(env);
    });

    // Sanity: pre-switch, listFor('office') still works for the sound
    // repo (it's stateless w.r.t. env), but no one's queried it yet.
    final preOffice = await soundRepo.listFor('office');
    expect(preOffice.map((s) => s.id), ['office_knock']);

    // Switch.
    await envManager.setActive('office');
    // Let the stream microtask + the setActiveEnvironment future land.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Phase 2 contract: post-switch, listFor('office') still returns the
    // right rows — it never depended on internal state.
    final officeSounds = await soundRepo.listFor('office');
    expect(officeSounds.map((s) => s.id), ['office_knock']);

    // Phase 3 contract: room repo's active env is now 'office' and the
    // last Rust push contains ONLY office zones.
    expect(roomRepo.activeEnvironment, 'office');
    expect(rustPushes.last.map((d) => d.id), unorderedEquals(['office_lobby']));

    await sub.cancel();
  });

  test('repeated identical switches do NOT re-push to Rust', () async {
    final sub = envManager.changes.listen((env) async {
      await roomRepo.setActiveEnvironment(env);
    });

    final pushCount0 = rustPushes.length;
    await envManager.setActive('office');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final pushCount1 = rustPushes.length;
    expect(pushCount1, greaterThan(pushCount0));

    // Re-setting to the same env should NOT push again — guards against
    // a regression where _syncRust runs on every event.
    await envManager.setActive('office');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rustPushes.length, pushCount1,
        reason: 'idempotent setActive must not re-sync Rust');

    await sub.cancel();
  });

  test('unknown env yields empty Rust push, not a crash', () async {
    final sub = envManager.changes.listen((env) async {
      await roomRepo.setActiveEnvironment(env);
    });

    await envManager.setActive('mars');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(roomRepo.activeEnvironment, 'mars');
    expect(rustPushes.last, isEmpty,
        reason:
            'no rooms enrolled at "mars" — Rust must see an empty set, '
            'not the previous env\'s set');
    // listFor on the sound repo for a never-seen env should be empty too.
    expect((await soundRepo.listFor('mars')), isEmpty);

    await sub.cancel();
  });
}
