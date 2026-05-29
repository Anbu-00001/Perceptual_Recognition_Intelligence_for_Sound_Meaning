import 'dart:typed_data';

import '../llm/embedding_store.dart';
import '../rust/api/enrollment.dart' as rust_enroll;
import 'caption_generator.dart';
import 'categories.dart';
import 'prototype.dart';
import 'prototype_repository.dart';

/// Orchestrates one enrollment recording:
///   1. Validate PCM (Rust DSP gates).
///   2. Caption with Gemma3n.
///   3. Embed caption with EmbeddingGemma (`retrievalDocument` prefix).
///   4. Persist as an [EnrollmentSample]. Repository rebuilds the centroid and
///      upserts qdrant-edge.
///
/// Returns an [EnrollmentResult] that lets the wizard show the user *why* a
/// clip was rejected without a second round-trip.
class EnrollmentService {
  EnrollmentService({
    required this.repo,
    required this.embeddings,
    required this.captioner,
  });

  final PrototypeRepository repo;
  final EmbeddingStore embeddings;
  final CaptionGenerator captioner;

  /// Add a sample to an existing prototype or create a new one.
  /// [prototypeId] null → create.
  Future<EnrollmentResult> ingestSample({
    String? prototypeId,
    required Int16List pcm16k,
    required SoundCategory category,
    required String label,
    required String environment,
    String? spatialZone,
    String? userLabelHint,
  }) async {
    final report = await rust_enroll.analyzeEnrollmentClip16K(samples: pcm16k);
    if (!report.accepted) {
      return EnrollmentResult.rejected(report);
    }

    final caption = await captioner.caption(
      pcm16k: pcm16k,
      userLabelHint: userLabelHint ?? label,
    );
    if (caption.isEmpty) {
      return EnrollmentResult.failedCaption(report);
    }

    final embedding = await embeddings.embedAsDocument(caption);
    if (embedding.isEmpty) {
      return EnrollmentResult.failedEmbedding(report, caption);
    }

    final sample = EnrollmentSample(
      id: _genId(),
      caption: caption,
      embedding: embedding,
      report: report,
      recordedAt: DateTime.now(),
    );

    SoundPrototype proto;
    if (prototypeId != null) {
      final existing = await repo.getById(prototypeId);
      if (existing == null) {
        return EnrollmentResult.failedRepo(report, caption, 'Unknown prototype');
      }
      existing.samples.add(sample);
      await repo.upsert(existing);
      proto = existing;
    } else {
      proto = SoundPrototype(
        id: _genId(),
        label: label.trim().isEmpty ? category.suggestedLabel : label.trim(),
        category: category.id,
        environment: environment,
        spatialZone: spatialZone,
        createdAt: DateTime.now(),
        samples: [sample],
      );
      await repo.upsert(proto);
    }

    return EnrollmentResult.accepted(report, caption, proto, sample);
  }

  static String _genId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = now ^ (now >> 16);
    return 'p_${now.toRadixString(16)}_${rand.toUnsigned(16).toRadixString(16)}';
  }
}

enum EnrollmentOutcome {
  accepted,
  rejected,
  failedCaption,
  failedEmbedding,
  failedRepo,
}

class EnrollmentResult {
  EnrollmentResult({
    required this.outcome,
    required this.report,
    this.caption,
    this.prototype,
    this.sample,
    this.error,
  });

  factory EnrollmentResult.accepted(
    rust_enroll.EnrollClipReport report,
    String caption,
    SoundPrototype prototype,
    EnrollmentSample sample,
  ) =>
      EnrollmentResult(
        outcome: EnrollmentOutcome.accepted,
        report: report,
        caption: caption,
        prototype: prototype,
        sample: sample,
      );

  factory EnrollmentResult.rejected(rust_enroll.EnrollClipReport report) =>
      EnrollmentResult(outcome: EnrollmentOutcome.rejected, report: report);

  factory EnrollmentResult.failedCaption(rust_enroll.EnrollClipReport report) =>
      EnrollmentResult(outcome: EnrollmentOutcome.failedCaption, report: report);

  factory EnrollmentResult.failedEmbedding(
    rust_enroll.EnrollClipReport report,
    String caption,
  ) =>
      EnrollmentResult(
        outcome: EnrollmentOutcome.failedEmbedding,
        report: report,
        caption: caption,
      );

  factory EnrollmentResult.failedRepo(
    rust_enroll.EnrollClipReport report,
    String caption,
    String error,
  ) =>
      EnrollmentResult(
        outcome: EnrollmentOutcome.failedRepo,
        report: report,
        caption: caption,
        error: error,
      );

  final EnrollmentOutcome outcome;
  final rust_enroll.EnrollClipReport report;
  final String? caption;
  final SoundPrototype? prototype;
  final EnrollmentSample? sample;
  final String? error;

  bool get accepted => outcome == EnrollmentOutcome.accepted;
}
