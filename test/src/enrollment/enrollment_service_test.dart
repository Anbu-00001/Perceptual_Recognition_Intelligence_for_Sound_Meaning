import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/categories.dart';
import 'package:prism/src/enrollment/enrollment_service.dart';
import 'package:prism/src/enrollment/prototype_repository.dart';
import 'package:prism/src/enrollment/prototype_vector_mirror.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;

import '_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late InMemoryPrototypeVectorMirror mirror;
  late RecordingEmbedder embedder;
  late FakeCaptioner captioner;
  late PrototypeRepository repo;
  late EnrollmentService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prism_enroll_test');
    mirror = InMemoryPrototypeVectorMirror();
    embedder = RecordingEmbedder();
    captioner = FakeCaptioner(captionText: 'three sharp wooden taps');
    repo = PrototypeRepository(
      mirror: mirror,
      overrideDirectory: tmp.path,
    );
    service = EnrollmentService(
      repo: repo,
      embeddings: embedder,
      captioner: captioner,
      analyzer: constantAnalyzer(accepted: true),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Int16List makePcm(int samples) =>
      Int16List.fromList(List<int>.generate(samples, (i) => (i % 200) - 100));

  test('first ingest creates a prototype, embeds caption, writes to mirror',
      () async {
    final result = await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.knock,
      label: 'Front door knock',
      environment: 'home',
    );

    expect(result.accepted, isTrue);
    expect(result.outcome, EnrollmentOutcome.accepted);
    expect(result.caption, 'three sharp wooden taps');
    expect(result.prototype, isNotNull);
    expect(result.prototype!.samples, hasLength(1));
    expect(result.prototype!.centroid, isNotEmpty);

    // Captioner was asked once with our label as the hint.
    expect(captioner.calls, ['Front door knock']);
    // Embedder received exactly the caption.
    expect(embedder.calls, ['three sharp wooden taps']);
    // Mirror upsert ran for this prototype.
    expect(mirror.points, hasLength(1));
    expect(mirror.points.values.first.label, 'Front door knock');
  });

  test('subsequent ingest with the prototype id appends + re-embeds',
      () async {
    final first = await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.knock,
      label: 'Front door knock',
      environment: 'home',
    );
    final pid = first.prototype!.id;

    captioner.captionText = 'three sharp wooden taps, slightly louder';
    final second = await service.ingestSample(
      prototypeId: pid,
      pcm16k: makePcm(16000),
      category: SoundCategory.knock,
      label: 'Front door knock',
      environment: 'home',
    );

    expect(second.accepted, isTrue);
    expect(second.prototype!.id, pid);
    expect(second.prototype!.samples, hasLength(2));
    expect(embedder.calls, hasLength(2));
    // Centroid was rebuilt; vector store has the new centroid keyed by same id.
    expect(mirror.points, hasLength(1));
    expect(mirror.points[pid]!.samples, hasLength(2));
  });

  test('rejected clip never reaches the captioner or embedder', () async {
    service = EnrollmentService(
      repo: repo,
      embeddings: embedder,
      captioner: captioner,
      analyzer: constantAnalyzer(
        accepted: false,
        reason: rust_enroll.EnrollRejectReason.tooNoisy,
      ),
    );

    final result = await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.doorbell,
      label: 'x',
      environment: 'home',
    );

    expect(result.accepted, isFalse);
    expect(result.outcome, EnrollmentOutcome.rejected);
    expect(result.report.rejectReason, rust_enroll.EnrollRejectReason.tooNoisy);
    expect(captioner.calls, isEmpty);
    expect(embedder.calls, isEmpty);
    expect(mirror.points, isEmpty);
  });

  test('caption failure short-circuits to failedCaption outcome', () async {
    captioner.captionText = '';
    final result = await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.doorbell,
      label: 'x',
      environment: 'home',
    );
    expect(result.outcome, EnrollmentOutcome.failedCaption);
    expect(embedder.calls, isEmpty);
    expect(mirror.points, isEmpty);
  });

  test('unknown prototypeId yields failedRepo without embedding', () async {
    final result = await service.ingestSample(
      prototypeId: 'p_no_such',
      pcm16k: makePcm(16000),
      category: SoundCategory.doorbell,
      label: 'x',
      environment: 'home',
    );
    expect(result.outcome, EnrollmentOutcome.failedRepo);
    expect(result.error, contains('Unknown prototype'));
  });

  test('environment filter routes prototypes correctly', () async {
    await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.doorbell,
      label: 'home bell',
      environment: 'home',
    );
    await service.ingestSample(
      pcm16k: makePcm(16000),
      category: SoundCategory.doorbell,
      label: 'office bell',
      environment: 'office',
    );

    final atHome = await repo.listFor('home');
    final atOffice = await repo.listFor('office');
    expect(atHome.map((p) => p.label), ['home bell']);
    expect(atOffice.map((p) => p.label), ['office bell']);
  });
}

