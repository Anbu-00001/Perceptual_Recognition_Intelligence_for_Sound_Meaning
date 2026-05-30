import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/rust/api/zone.dart' as rust_zone;
import 'package:prism/src/spatial/room_zone.dart';
import 'package:prism/src/spatial/room_zone_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late List<List<rust_zone.ZonePrototypeDto>> pushed;
  late RoomZoneRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prism_zone_repo');
    pushed = [];
    repo = RoomZoneRepository(
      overrideDirectory: tmp.path,
      pushPrototypes: (dtos) => pushed.add(List.of(dtos)),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  RoomZone z(String id, String env, {String label = 'Kitchen'}) => RoomZone(
        id: id,
        label: label,
        environment: env,
        centroid: Float32List.fromList(List<double>.filled(21, 0.1)),
        createdAtMs: 1000,
        sampleSeconds: 30,
      );

  test('upsert then listFor returns only matching environment', () async {
    await repo.upsert(z('a', 'home', label: 'Kitchen'));
    await repo.upsert(z('b', 'office', label: 'Desk'));
    final home = await repo.listFor('home');
    final office = await repo.listFor('office');
    expect(home.map((x) => x.id), ['a']);
    expect(office.map((x) => x.id), ['b']);
  });

  test('upsert pushes filtered prototypes to Rust', () async {
    await repo.upsert(z('a', 'home'));
    await repo.upsert(z('b', 'office'));
    // Default active env is 'home' — only 'a' should be in the latest push.
    expect(pushed.last.map((d) => d.id), ['a']);
  });

  test('setActiveEnvironment changes the Rust push set', () async {
    await repo.upsert(z('a', 'home'));
    await repo.upsert(z('b', 'office'));
    await repo.setActiveEnvironment('office');
    expect(pushed.last.map((d) => d.id), ['b']);
  });

  test('delete removes from sidecar + Rust', () async {
    await repo.upsert(z('a', 'home'));
    await repo.upsert(z('b', 'home', label: 'B'));
    pushed.clear();
    await repo.delete('a');
    final remaining = await repo.listAll();
    expect(remaining.map((x) => x.id), ['b']);
    expect(pushed.last.map((d) => d.id), ['b']);
  });

  test('persists across reload', () async {
    await repo.upsert(z('a', 'home', label: 'Kitchen'));
    // New repo instance against the same dir.
    final fresh = RoomZoneRepository(
      overrideDirectory: tmp.path,
      pushPrototypes: (_) {},
    );
    final all = await fresh.listAll();
    expect(all.map((x) => x.label), ['Kitchen']);
  });

  test('ensureSynced loads sidecar AND pushes to Rust before any user call', () async {
    // Pre-seed the sidecar (simulating data left from a prior session).
    await repo.upsert(z('a', 'home'));
    pushed.clear();

    // Build a brand-new repo against the same dir and ONLY call ensureSynced.
    final fresh = RoomZoneRepository(
      overrideDirectory: tmp.path,
      pushPrototypes: (dtos) => pushed.add(List.of(dtos)),
    );
    await fresh.ensureSynced();

    // The bug we're guarding against: without this, the Rust classifier
    // starts with an empty prototype table on cold boot, so the very
    // first DSP event after launch misses zone classification.
    expect(pushed, isNotEmpty,
        reason: 'ensureSynced must push prototypes to Rust on cold load');
    expect(pushed.last.map((d) => d.id), ['a']);
  });

  test('changes stream fires on upsert and delete', () async {
    final events = <void>[];
    final sub = repo.changes.listen(events.add);
    await repo.upsert(z('a', 'home'));
    await repo.delete('a');
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 2);
    await sub.cancel();
  });
}
