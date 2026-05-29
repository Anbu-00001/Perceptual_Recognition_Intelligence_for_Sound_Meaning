import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

import '../enrollment/enrollment_service.dart' show DocumentEmbedder;

/// Fast-path matcher + per-environment longitudinal store backed by qdrant-edge
/// (flutter_gemma 0.16+ default vector store).
///
/// Two collections share one DB, distinguished only by the payload `collection`
/// key:
///   - **personal**: user's enrolled sound prototypes (one centroid point per
///     prototype, derived in [PrototypeRepository] from N enrollment samples).
///   - **anchor**:   ~50 AudioSet anchor categories seeded on first launch
///     from `assets/anchor_seeds.json`. Used as the fallback when the
///     personal collection misses, or to provide a coarse category label.
///
/// Phase 2 key changes over Phase 1:
///   1. Asymmetric TaskType prefixes — index with `retrievalDocument`, query
///      with `retrievalQuery`. EmbeddingGemma's prefixes are not symmetric;
///      mixing them costs ~3 pp recall on the eval set.
///   2. Anchor seeding is *idempotent* and lives on the store, not in
///      app-launch code, so the repository can ask the store to "reseed
///      anchors" after a clear-and-rebuild.
///   3. Environment-aware search filters: must=collection,environment for the
///      personal hit, then a fallback search over anchors without environment.
class EmbeddingStore implements DocumentEmbedder {
  EmbeddingStore({
    String anchorAssetPath = 'assets/anchor_seeds.json',
    String? overrideDirectory,
  })  : _anchorAssetPath = anchorAssetPath,
        _overrideDir = overrideDirectory;

  static const String personalCollection = 'personal';
  static const String anchorCollection = 'anchor';
  static const String _anchorVersionMarker = 'prism.anchor.seed_version';
  static const int _currentAnchorVersion = 1;

  final String _anchorAssetPath;
  final String? _overrideDir;
  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    final dirPath = _overrideDir ??
        (await getApplicationDocumentsDirectory()).path;
    final dbPath = '$dirPath/prism_rag.db';
    await FlutterGemmaPlugin.instance.initializeVectorStore(dbPath);
    _initialised = true;
  }

  /// Seed the anchor collection from the bundled JSON manifest. Idempotent:
  /// no-op when the on-device version matches the marker stored in the
  /// vector store, unless [force] is true.
  Future<void> seedAnchorsIfNeeded({bool force = false}) async {
    await init();
    if (!force) {
      final stats = await FlutterGemmaPlugin.instance.getVectorStoreStats();
      // qdrant-edge has no kv side-channel; we encode the version as a
      // sentinel doc id and look it up via search-with-filter.
      final hit = await FlutterGemmaPlugin.instance.searchSimilar(
        query: 'anchor_version_marker',
        topK: 1,
        threshold: 0.0,
        filter: Filter(must: [
          FieldEquals(key: _anchorVersionMarker, value: '$_currentAnchorVersion'),
        ]),
      );
      if (hit.isNotEmpty && stats.documentCount > 0) return;
    }

    final raw = await rootBundle.loadString(_anchorAssetPath);
    final List<dynamic> entries = jsonDecode(raw) as List<dynamic>;
    final embedder = await _embedder();
    final texts = entries
        .map((e) => (e as Map<String, dynamic>)['caption'] as String)
        .toList(growable: false);
    final vectors = await embedder.generateEmbeddings(
      texts,
      taskType: TaskType.retrievalDocument,
    );
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i] as Map<String, dynamic>;
      await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
        id: 'anchor:${e['id']}',
        content: e['label'] as String,
        embedding: vectors[i],
        metadata: jsonEncode({
          'collection': anchorCollection,
          'category': e['category'],
          'caption': e['caption'],
        }),
      );
    }
    // Version sentinel — its embedding is irrelevant (we never search it by
    // similarity), but it must exist so the next launch can short-circuit.
    await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
      id: 'anchor_version_marker',
      content: 'anchor seed marker v$_currentAnchorVersion',
      embedding: List<double>.filled(vectors.first.length, 0.0),
      metadata: jsonEncode({
        _anchorVersionMarker: '$_currentAnchorVersion',
      }),
    );
  }

  /// Generate a query embedding using the document-side prefix. Useful for
  /// callers that want to compare two captions in cosine space (e.g. the
  /// prototype repository computing per-sample vectors before averaging).
  @override
  Future<List<double>> embedAsDocument(String text) async {
    final embedder = await _embedder();
    return embedder.generateEmbedding(text, taskType: TaskType.retrievalDocument);
  }

  /// Text-proxy enrollment used by the Phase 1 eval harness. Given just a
  /// label, embeds it as a "personal" prototype with no audio sample chain.
  /// Real enrollment goes through [PrototypeRepository] / [EnrollmentService].
  Future<void> quickEnrollFromText({
    required String id,
    required String label,
    required String category,
    String environment = 'home',
    String collection = personalCollection,
  }) async {
    await init();
    final vector = await embedAsDocument(label);
    await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
      id: id,
      content: label,
      embedding: vector,
      metadata: jsonEncode({
        'collection': collection,
        'category': category,
        'environment': environment,
      }),
    );
  }

  /// Personal-first retrieval. Honors [environment] for the personal hit, then
  /// falls back to the anchor collection (which is environment-agnostic).
  Future<MatchResult> matchByQuery({
    required String query,
    required String environment,
    double personalGate = 0.78,
    int topK = 5,
  }) async {
    await init();
    final personal = await FlutterGemmaPlugin.instance.searchSimilar(
      query: query,
      topK: topK,
      threshold: 0.0,
      filter: Filter(must: [
        FieldEquals(key: 'collection', value: personalCollection),
        FieldEquals(key: 'environment', value: environment),
      ]),
    );
    if (personal.isNotEmpty && personal.first.similarity >= personalGate) {
      return MatchResult.fromHit(personal.first, source: MatchSource.personal);
    }
    final anchor = await FlutterGemmaPlugin.instance.searchSimilar(
      query: query,
      topK: topK,
      threshold: 0.0,
      filter: Filter(must: [
        FieldEquals(key: 'collection', value: anchorCollection),
      ]),
    );
    if (anchor.isEmpty) return MatchResult.empty();
    return MatchResult.fromHit(anchor.first, source: MatchSource.anchor);
  }

  /// Wraps a mutation that clears the vector store and reseeds both the
  /// caller's points and the anchor collection. Used by the prototype
  /// repository when deleting a prototype (qdrant-edge has no
  /// per-document delete).
  Future<void> clearAndReseedAnchorsAfter(Future<void> Function() mutate) async {
    await init();
    await FlutterGemmaPlugin.instance.clearVectorStore();
    await seedAnchorsIfNeeded(force: true);
    await mutate();
  }

  Future<EmbeddingModel> _embedder() async {
    final existing = FlutterGemmaPlugin.instance.initializedEmbeddingModel;
    if (existing != null) return existing;
    return FlutterGemmaPlugin.instance.createEmbeddingModel();
  }
}

enum MatchSource { personal, anchor, none }

class MatchResult {
  MatchResult({
    required this.label,
    required this.score,
    required this.source,
    required this.metadata,
  });

  factory MatchResult.empty() => MatchResult(
        label: '',
        score: 0,
        source: MatchSource.none,
        metadata: const {},
      );

  factory MatchResult.fromHit(RetrievalResult hit, {required MatchSource source}) {
    return MatchResult(
      label: hit.content,
      score: hit.similarity,
      source: source,
      metadata: _parseMetadata(hit.metadata),
    );
  }

  final String label;
  final double score;
  final MatchSource source;
  final Map<String, dynamic> metadata;

  bool get isHit => source != MatchSource.none;

  static Map<String, dynamic> _parseMetadata(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}
