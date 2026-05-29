import 'dart:math' as math;
import 'dart:typed_data';

import '../rust/api/enrollment.dart' as rust_enroll;

/// A user-defined sound prototype: 1..N enrollment samples consolidated into a
/// single L2-normalized centroid vector stored in qdrant-edge.
///
/// Two layers of truth:
///   - **Sidecar JSON** (this object, persisted in `enrollment_store.json`):
///     authoritative. Holds every sample's raw embedding so a centroid can be
///     rebuilt on add/remove without re-recording.
///   - **qdrant-edge** point keyed by [id]: derived. Holds only the centroid
///     and a payload mirror. Rebuilt by upsert on any sidecar mutation.
///
/// We need the sidecar because flutter_gemma 0.16 exposes no per-document
/// delete or update on the vector store; the only mutating verbs are
/// `addDocumentWithEmbedding` (which upserts by id) and `clearVectorStore`.
class SoundPrototype {
  SoundPrototype({
    required this.id,
    required this.label,
    required this.category,
    required this.environment,
    required this.samples,
    this.spatialZone,
    this.createdAt,
    this.lastTrainedAt,
  });

  final String id;
  String label;
  String category;
  String environment;
  String? spatialZone;
  final DateTime? createdAt;
  DateTime? lastTrainedAt;

  /// 1..N samples. Each carries its own raw embedding + quality stamp so the
  /// centroid can be rebuilt without re-querying flutter_gemma.
  final List<EnrollmentSample> samples;

  /// Cached centroid (L2-normalized). Recomputed by [rebuildCentroid] on any
  /// sample mutation. May be empty before the first embedding is attached.
  List<double> centroid = const [];

  bool get isReady => samples.isNotEmpty && centroid.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'category': category,
        'environment': environment,
        'spatial_zone': spatialZone,
        'created_at': createdAt?.toIso8601String(),
        'last_trained_at': lastTrainedAt?.toIso8601String(),
        'samples': samples.map((s) => s.toJson()).toList(),
        'centroid': centroid,
      };

  factory SoundPrototype.fromJson(Map<String, dynamic> j) {
    final proto = SoundPrototype(
      id: j['id'] as String,
      label: j['label'] as String,
      category: j['category'] as String,
      environment: j['environment'] as String,
      spatialZone: j['spatial_zone'] as String?,
      createdAt: _parseDate(j['created_at']),
      lastTrainedAt: _parseDate(j['last_trained_at']),
      samples: (j['samples'] as List<dynamic>? ?? const [])
          .map((e) => EnrollmentSample.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    proto.centroid =
        (j['centroid'] as List<dynamic>? ?? const []).map((e) => (e as num).toDouble()).toList();
    return proto;
  }

  /// Recompute the L2-normalized average across all sample embeddings.
  /// Done in Dart (not Rust) because vectors are 768-D Float32 — small
  /// enough that the FFI cost would dominate.
  void rebuildCentroid() {
    final embedded = samples.where((s) => s.embedding.isNotEmpty).toList();
    if (embedded.isEmpty) {
      centroid = const [];
      return;
    }
    final dim = embedded.first.embedding.length;
    final sum = List<double>.filled(dim, 0.0);
    for (final s in embedded) {
      if (s.embedding.length != dim) continue;
      for (var i = 0; i < dim; i++) {
        sum[i] += s.embedding[i];
      }
    }
    final inv = 1.0 / embedded.length;
    for (var i = 0; i < dim; i++) {
      sum[i] *= inv;
    }
    centroid = _l2Normalize(sum);
    lastTrainedAt = DateTime.now();
  }

  static List<double> _l2Normalize(List<double> v) {
    double sq = 0;
    for (final x in v) {
      sq += x * x;
    }
    if (sq < 1e-12) return v;
    final inv = 1.0 / math.sqrt(sq);
    return [for (final x in v) x * inv];
  }

  static DateTime? _parseDate(dynamic v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }
}

/// One recording attached to a [SoundPrototype]. We persist the embedding so
/// centroid rebuilds don't need to re-query flutter_gemma; the raw audio is
/// optional and lives outside the JSON when the user opted in to local replay.
class EnrollmentSample {
  EnrollmentSample({
    required this.id,
    required this.caption,
    required this.embedding,
    required this.report,
    required this.recordedAt,
    this.audioPath,
  });

  final String id;
  final String caption;
  final List<double> embedding;
  final rust_enroll.EnrollClipReport report;
  final DateTime recordedAt;
  final String? audioPath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'caption': caption,
        'embedding': embedding,
        'recorded_at': recordedAt.toIso8601String(),
        'audio_path': audioPath,
        'report': {
          'accepted': report.accepted,
          'reject_reason': report.rejectReason?.name,
          'duration_ms': report.durationMs,
          'peak_dbfs': report.peakDbfs,
          'rms_dbfs': report.rmsDbfs,
          'noise_floor_dbfs': report.noiseFloorDbfs,
          'snr_db': report.snrDb,
          'active_ratio': report.activeRatio,
          'clipping_ratio': report.clippingRatio,
          'zcr': report.zcr,
        },
      };

  factory EnrollmentSample.fromJson(Map<String, dynamic> j) {
    final r = j['report'] as Map<String, dynamic>? ?? const {};
    return EnrollmentSample(
      id: j['id'] as String,
      caption: j['caption'] as String? ?? '',
      embedding:
          (j['embedding'] as List<dynamic>? ?? const []).map((e) => (e as num).toDouble()).toList(),
      report: rust_enroll.EnrollClipReport(
        accepted: r['accepted'] as bool? ?? false,
        rejectReason: _parseReason(r['reject_reason'] as String?),
        durationMs: (r['duration_ms'] as num?)?.toInt() ?? 0,
        peakDbfs: (r['peak_dbfs'] as num?)?.toDouble() ?? -120,
        rmsDbfs: (r['rms_dbfs'] as num?)?.toDouble() ?? -120,
        noiseFloorDbfs: (r['noise_floor_dbfs'] as num?)?.toDouble() ?? -120,
        snrDb: (r['snr_db'] as num?)?.toDouble() ?? 0,
        activeRatio: (r['active_ratio'] as num?)?.toDouble() ?? 0,
        clippingRatio: (r['clipping_ratio'] as num?)?.toDouble() ?? 0,
        zcr: (r['zcr'] as num?)?.toDouble() ?? 0,
      ),
      recordedAt:
          DateTime.tryParse(j['recorded_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      audioPath: j['audio_path'] as String?,
    );
  }
}

rust_enroll.EnrollRejectReason? _parseReason(String? name) {
  if (name == null) return null;
  for (final r in rust_enroll.EnrollRejectReason.values) {
    if (r.name == name) return r;
  }
  return null;
}

/// Helper used by callers that already have the raw PCM in hand and need to
/// run the Rust validator + ship a sample object in one step.
Future<EnrollmentSample> buildSample({
  required String id,
  required Int16List pcm16k,
  required String caption,
  required List<double> embedding,
  String? audioPath,
}) async {
  final report = await rust_enroll.analyzeEnrollmentClip16K(samples: pcm16k);
  return EnrollmentSample(
    id: id,
    caption: caption,
    embedding: embedding,
    report: report,
    recordedAt: DateTime.now(),
    audioPath: audioPath,
  );
}

