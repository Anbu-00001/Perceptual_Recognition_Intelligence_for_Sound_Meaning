import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/spatial/room_zone_repository.dart';
import 'package:prism/src/spatial/zone_enrollment_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late RoomZoneRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prism_zone_svc');
    repo = RoomZoneRepository(
      overrideDirectory: tmp.path,
      pushPrototypes: (_) {},
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  ZoneEnrollmentService service({
    Float32List Function(List<int>)? extractor,
    int minSeconds = 10,
  }) =>
      ZoneEnrollmentService(
        repo: repo,
        minSampleSeconds: minSeconds,
        featureExtractor: extractor ??
            (_) => Float32List.fromList(List<double>.filled(21, 0.5)),
      );

  test('rejects too-short recording', () async {
    final svc = service(minSeconds: 10);
    final result = await svc.enrollZone(
      pcm16k: Int16List(16_000 * 3), // 3 sec
      label: 'Kitchen',
      environment: 'home',
    );
    expect(result, isA<ZoneEnrollmentTooShort>());
    final all = await repo.listAll();
    expect(all, isEmpty);
  });

  test('rejects empty label', () async {
    final svc = service();
    final result = await svc.enrollZone(
      pcm16k: Int16List(16_000 * 15),
      label: '   ',
      environment: 'home',
    );
    expect(result, isA<ZoneEnrollmentInvalidLabel>());
  });

  test('accepts long-enough recording and persists with feature', () async {
    final feat = Float32List.fromList(List<double>.generate(21, (i) => i / 21.0));
    final svc = service(extractor: (_) => feat);
    final result = await svc.enrollZone(
      pcm16k: Int16List(16_000 * 30),
      label: 'Kitchen',
      environment: 'home',
    );
    expect(result, isA<ZoneEnrollmentSuccess>());
    final all = await repo.listAll();
    expect(all.length, 1);
    expect(all.first.label, 'Kitchen');
    expect(all.first.centroid.length, 21);
    expect(all.first.centroid[5], closeTo(5 / 21.0, 1e-6));
    expect(all.first.sampleSeconds, 30);
  });

  test('overrideId is honored', () async {
    final svc = service();
    final result = await svc.enrollZone(
      pcm16k: Int16List(16_000 * 20),
      label: 'Bedroom',
      environment: 'home',
      overrideId: 'fixed-id',
    );
    expect(result, isA<ZoneEnrollmentSuccess>());
    final fetched = await repo.getById('fixed-id');
    expect(fetched?.label, 'Bedroom');
  });
}
