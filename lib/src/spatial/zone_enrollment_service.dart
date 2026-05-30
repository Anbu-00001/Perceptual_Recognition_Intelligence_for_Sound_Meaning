import 'dart:typed_data';

import '../rust/api/zone.dart' as rust_zone;
import 'room_zone.dart';
import 'room_zone_repository.dart';

/// Phase 3 — turn a ~30 s ambient recording into a saved [RoomZone].
///
/// Why this exists separately from Phase 2's `EnrollmentService`: room
/// fingerprinting does not need a Gemma3n caption or an EmbeddingGemma
/// vector — the centroid IS the embedding, computed by the Rust DSP. So
/// the enrollment path is pure Rust + sidecar, no LLM in the loop.
///
/// The 16 kHz mono PCM contract matches Phase 2 to keep enrollment audio
/// pipeline uniform. Phase 2's recorder downsamples 48k → 16k; we reuse it.
class ZoneEnrollmentService {
  ZoneEnrollmentService({
    required this.repo,
    int minSampleSeconds = 10,
    int recommendedSampleSeconds = 30,
    Float32List Function(List<int>)? featureExtractor,
  })  : _minSampleSeconds = minSampleSeconds,
        _recommendedSampleSeconds = recommendedSampleSeconds,
        _featureExtractor = featureExtractor ?? _defaultFeatureExtractor;

  final RoomZoneRepository repo;
  final int _minSampleSeconds;
  final int _recommendedSampleSeconds;
  final Float32List Function(List<int>) _featureExtractor;

  static const int sampleRateHz = 16_000;

  int get minSampleSeconds => _minSampleSeconds;
  int get recommendedSampleSeconds => _recommendedSampleSeconds;

  static Float32List _defaultFeatureExtractor(List<int> pcm16k) =>
      rust_zone.zoneComputeFeature(samples16KMono: pcm16k);

  /// Persist a new zone (or replace an existing one with the same label).
  /// Validates: PCM length must be ≥ `minSampleSeconds`. Centroid is
  /// computed by Rust; on a Phase-2-style mono-replicated phone the
  /// centroid still works because it's spectrum-based, not phase-based.
  Future<ZoneEnrollmentResult> enrollZone({
    required Int16List pcm16k,
    required String label,
    required String environment,
    String? overrideId,
  }) async {
    final actualSeconds = pcm16k.length ~/ sampleRateHz;
    if (actualSeconds < _minSampleSeconds) {
      return ZoneEnrollmentResult.tooShort(actualSeconds, _minSampleSeconds);
    }
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty) {
      return ZoneEnrollmentResult.invalidLabel();
    }

    final feature = _featureExtractor(pcm16k);
    if (feature.isEmpty) {
      return ZoneEnrollmentResult.featureExtractionFailed();
    }

    final id = overrideId ?? _generateId();
    final zone = RoomZone(
      id: id,
      label: trimmedLabel,
      environment: environment,
      centroid: feature,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      sampleSeconds: actualSeconds,
    );
    await repo.upsert(zone);
    return ZoneEnrollmentResult.success(zone);
  }

  String _generateId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    return 'zone_$ts';
  }
}

/// Discriminated union of enrollment outcomes.
sealed class ZoneEnrollmentResult {
  const ZoneEnrollmentResult();

  factory ZoneEnrollmentResult.success(RoomZone zone) =>
      ZoneEnrollmentSuccess(zone);
  factory ZoneEnrollmentResult.tooShort(int actual, int required) =>
      ZoneEnrollmentTooShort(actualSeconds: actual, requiredSeconds: required);
  factory ZoneEnrollmentResult.invalidLabel() => const ZoneEnrollmentInvalidLabel();
  factory ZoneEnrollmentResult.featureExtractionFailed() =>
      const ZoneEnrollmentFeatureFailed();

  bool get isSuccess => this is ZoneEnrollmentSuccess;
}

class ZoneEnrollmentSuccess extends ZoneEnrollmentResult {
  const ZoneEnrollmentSuccess(this.zone);
  final RoomZone zone;
}

class ZoneEnrollmentTooShort extends ZoneEnrollmentResult {
  const ZoneEnrollmentTooShort({
    required this.actualSeconds,
    required this.requiredSeconds,
  });
  final int actualSeconds;
  final int requiredSeconds;
}

class ZoneEnrollmentInvalidLabel extends ZoneEnrollmentResult {
  const ZoneEnrollmentInvalidLabel();
}

class ZoneEnrollmentFeatureFailed extends ZoneEnrollmentResult {
  const ZoneEnrollmentFeatureFailed();
}
