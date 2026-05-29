import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/prototype.dart';
import 'package:prism/src/enrollment/prototype_repository.dart';
import 'package:prism/src/enrollment/prototype_vector_mirror.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prism_repo_test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  rust_enroll.EnrollClipReport okReport() => rust_enroll.EnrollClipReport(
        accepted: true,
        rejectReason: null,
        durationMs: 1500,
        peakDbfs: -10,
        rmsDbfs: -18,
        noiseFloorDbfs: -50,
        snrDb: 12,
        activeRatio: 0.7,
        clippingRatio: 0.0,
        zcr: 0.08,
      );

  SoundPrototype proto(String id, String env, {String label = 'x'}) =>
      SoundPrototype(
        id: id,
        label: label,
        category: 'knock',
        environment: env,
        createdAt: DateTime(2026, 1, 1),
        samples: [
          EnrollmentSample(
            id: '${id}_s1',
            caption: 'caption $id',
            embedding: const [0.6, 0.8, 0.0],
            report: okReport(),
            recordedAt: DateTime(2026, 1, 1),
          ),
        ],
      );

  test('upsert persists to sidecar JSON and pushes to mirror', () async {
    final mirror = InMemoryPrototypeVectorMirror();
    final repo = PrototypeRepository(mirror: mirror, overrideDirectory: tmp.path);

    await repo.upsert(proto('p1', 'home'));

    expect(mirror.points, hasLength(1));
    final file = File('${tmp.path}/enrollment_store.json');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('"id":"p1"'));
  });

  test('new repository instance loads from sidecar JSON', () async {
    {
      final mirror = InMemoryPrototypeVectorMirror();
      final repo = PrototypeRepository(mirror: mirror, overrideDirectory: tmp.path);
      await repo.upsert(proto('p1', 'home', label: 'A'));
      await repo.upsert(proto('p2', 'office', label: 'B'));
    }
    // Fresh instance, same dir.
    final mirror2 = InMemoryPrototypeVectorMirror();
    final repo2 = PrototypeRepository(mirror: mirror2, overrideDirectory: tmp.path);
    final all = await repo2.listAll();
    expect(all.map((p) => p.id).toSet(), {'p1', 'p2'});
    expect(all.first.centroid, isNotEmpty);
  });

  test('listFor returns only prototypes for the requested environment',
      () async {
    final repo = PrototypeRepository(
      mirror: InMemoryPrototypeVectorMirror(),
      overrideDirectory: tmp.path,
    );
    await repo.upsert(proto('a', 'home', label: 'A'));
    await repo.upsert(proto('b', 'office', label: 'B'));
    await repo.upsert(proto('c', 'home', label: 'C'));

    final atHome = await repo.listFor('home');
    expect(atHome.map((p) => p.id).toSet(), {'a', 'c'});
    final atOffice = await repo.listFor('office');
    expect(atOffice.map((p) => p.id).toSet(), {'b'});
  });

  test('delete clears the mirror and rebuilds from survivors', () async {
    final mirror = InMemoryPrototypeVectorMirror();
    final repo = PrototypeRepository(mirror: mirror, overrideDirectory: tmp.path);
    await repo.upsert(proto('a', 'home'));
    await repo.upsert(proto('b', 'home'));
    await repo.upsert(proto('c', 'home'));

    final beforeRebuilds = mirror.rebuildCount;
    await repo.delete('b');

    expect(mirror.rebuildCount, beforeRebuilds + 1);
    expect(mirror.points.keys.toSet(), {'a', 'c'});

    // Reload from disk — confirms the sidecar mutation persisted too.
    final mirror2 = InMemoryPrototypeVectorMirror();
    final repo2 = PrototypeRepository(mirror: mirror2, overrideDirectory: tmp.path);
    final ids = (await repo2.listAll()).map((p) => p.id).toSet();
    expect(ids, {'a', 'c'});
  });

  test('removeSample with empty samples cascades to prototype delete',
      () async {
    final mirror = InMemoryPrototypeVectorMirror();
    final repo = PrototypeRepository(mirror: mirror, overrideDirectory: tmp.path);
    await repo.upsert(proto('a', 'home')); // 1 sample

    await repo.removeSample('a', 'a_s1');

    expect((await repo.listAll()), isEmpty);
    expect(mirror.points, isEmpty);
  });

  test('changes stream emits on upsert and delete', () async {
    final repo = PrototypeRepository(
      mirror: InMemoryPrototypeVectorMirror(),
      overrideDirectory: tmp.path,
    );
    var notifications = 0;
    final sub = repo.changes.listen((_) => notifications++);
    await repo.upsert(proto('a', 'home'));
    await repo.upsert(proto('b', 'home'));
    await repo.delete('a');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(notifications, 3);
  });

  test('constructing with neither store nor mirror throws ArgumentError',
      () async {
    expect(
      () => PrototypeRepository(overrideDirectory: tmp.path),
      throwsArgumentError,
    );
  });
}
