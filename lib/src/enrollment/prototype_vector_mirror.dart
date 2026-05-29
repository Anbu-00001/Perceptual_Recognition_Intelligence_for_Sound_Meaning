import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../llm/embedding_store.dart';
import 'prototype.dart';

/// Thin seam between [PrototypeRepository] and the vector store. Production
/// path writes to qdrant-edge via flutter_gemma; the test path uses an
/// in-memory implementation so the repository's filesystem + centroid logic
/// can be exercised without a running model or a device.
abstract interface class PrototypeVectorMirror {
  Future<void> upsert(SoundPrototype proto);

  /// Used when a prototype is deleted: clear the underlying store, ensure
  /// anchors are re-seeded, then re-push every surviving prototype.
  Future<void> rebuildFrom(Iterable<SoundPrototype> survivors);
}

class QdrantPrototypeVectorMirror implements PrototypeVectorMirror {
  QdrantPrototypeVectorMirror(this.store);

  final EmbeddingStore store;

  @override
  Future<void> upsert(SoundPrototype proto) async {
    if (proto.centroid.isEmpty) return;
    await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
      id: proto.id,
      content: proto.label,
      embedding: proto.centroid,
      metadata: jsonEncode({
        'collection': EmbeddingStore.personalCollection,
        'category': proto.category,
        'environment': proto.environment,
        'spatial_zone': proto.spatialZone,
        'prototype_id': proto.id,
        'sample_count': proto.samples.length,
        'last_trained_at': proto.lastTrainedAt?.toIso8601String(),
      }),
    );
  }

  @override
  Future<void> rebuildFrom(Iterable<SoundPrototype> survivors) async {
    await store.clearAndReseedAnchorsAfter(() async {
      for (final p in survivors) {
        await upsert(p);
      }
    });
  }
}

/// In-memory mirror for tests. Records the most recent state so assertions
/// can verify the repository's centroid-write contract without standing up
/// flutter_gemma.
class InMemoryPrototypeVectorMirror implements PrototypeVectorMirror {
  final Map<String, SoundPrototype> points = {};
  int rebuildCount = 0;

  @override
  Future<void> upsert(SoundPrototype proto) async {
    points[proto.id] = proto;
  }

  @override
  Future<void> rebuildFrom(Iterable<SoundPrototype> survivors) async {
    points.clear();
    rebuildCount++;
    for (final p in survivors) {
      points[p.id] = p;
    }
  }
}
