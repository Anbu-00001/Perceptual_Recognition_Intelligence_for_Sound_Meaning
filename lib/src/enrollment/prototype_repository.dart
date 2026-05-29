import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../llm/embedding_store.dart';
import 'prototype.dart';
import 'prototype_vector_mirror.dart';

/// Persists [SoundPrototype]s in a sidecar JSON file and keeps qdrant-edge in
/// sync. The sidecar is the source of truth — qdrant-edge is regenerable.
///
/// The reason: flutter_gemma 0.16's vector store exposes no per-document
/// delete or update. We can only upsert (`addDocumentWithEmbedding` with the
/// same id) or clear the whole store. So removing a single sample requires
/// rebuilding the centroid in Dart, then upserting the centroid; deleting a
/// prototype requires clearing + reindexing every other prototype. Doing
/// that without a sidecar would mean re-recording.
class PrototypeRepository {
  PrototypeRepository({
    EmbeddingStore? store,
    PrototypeVectorMirror? mirror,
    String? overrideDirectory,
  })  : _mirror = mirror ??
            QdrantPrototypeVectorMirror(
              store ??
                  (throw ArgumentError(
                      'PrototypeRepository requires either store or mirror')),
            ),
        _overrideDir = overrideDirectory;

  final PrototypeVectorMirror _mirror;
  final String? _overrideDir;

  static const String _fileName = 'enrollment_store.json';

  final Map<String, SoundPrototype> _byId = {};
  bool _loaded = false;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final file = await _file();
    if (await file.exists()) {
      final text = await file.readAsString();
      if (text.isNotEmpty) {
        final raw = jsonDecode(text);
        if (raw is List) {
          for (final entry in raw) {
            if (entry is Map<String, dynamic>) {
              final p = SoundPrototype.fromJson(entry);
              _byId[p.id] = p;
            }
          }
        }
      }
    }
    _loaded = true;
  }

  Future<List<SoundPrototype>> listAll() async {
    await _ensureLoaded();
    final out = _byId.values.toList();
    out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  Future<List<SoundPrototype>> listFor(String environment) async {
    final all = await listAll();
    return all.where((p) => p.environment == environment).toList();
  }

  Future<SoundPrototype?> getById(String id) async {
    await _ensureLoaded();
    return _byId[id];
  }

  Future<void> upsert(SoundPrototype proto) async {
    await _ensureLoaded();
    proto.rebuildCentroid();
    _byId[proto.id] = proto;
    await _persistSidecar();
    await _mirror.upsert(proto);
    _changes.add(null);
  }

  Future<void> appendSample(String prototypeId, EnrollmentSample sample) async {
    await _ensureLoaded();
    final p = _byId[prototypeId];
    if (p == null) {
      throw StateError('Unknown prototype: $prototypeId');
    }
    p.samples.add(sample);
    await upsert(p);
  }

  Future<void> removeSample(String prototypeId, String sampleId) async {
    await _ensureLoaded();
    final p = _byId[prototypeId];
    if (p == null) return;
    p.samples.removeWhere((s) => s.id == sampleId);
    if (p.samples.isEmpty) {
      await delete(prototypeId);
      return;
    }
    await upsert(p);
  }

  /// Delete a prototype. Because qdrant-edge has no point-delete, we clear
  /// the whole store and reindex every survivor. Cost: O(n) embeddings written,
  /// no model calls (we cache embeddings in the sidecar).
  Future<void> delete(String prototypeId) async {
    await _ensureLoaded();
    if (!_byId.containsKey(prototypeId)) return;
    _byId.remove(prototypeId);
    await _persistSidecar();
    await _mirror.rebuildFrom(_byId.values);
    _changes.add(null);
  }

  Future<void> _persistSidecar() async {
    final file = await _file();
    final data = _byId.values.map((p) => p.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }

  Future<File> _file() async {
    final override = _overrideDir;
    final dir = override != null ? Directory(override) : await getApplicationDocumentsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }
}
