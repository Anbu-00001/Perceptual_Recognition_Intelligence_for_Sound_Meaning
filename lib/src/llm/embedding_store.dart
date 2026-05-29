import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

/// Fast-path matcher + per-environment longitudinal store backed by qdrant-edge
/// (flutter_gemma 0.16+ native default vector store).
///
/// Two collections share one DB:
///   - **personal**: user's enrolled sounds + family voices (high-trust prototypes).
///   - **anchor**:   ~50 AudioSet anchor categories (doorbell, knock, fire alarm,
///                    smoke alarm, baby cry, glass break, dog bark, ...) seeded
///                    on first run. Lower trust, used as fallback retrieval.
class EmbeddingStore {
  EmbeddingStore();

  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = '${dir.path}/prism_rag.db';
    await FlutterGemmaPlugin.instance.initializeVectorStore(dbPath);
    _initialised = true;
  }

  /// Add a labeled prototype (user enrollment or anchor seed).
  Future<void> addPrototype({
    required String id,
    required String label,
    required String category,
    required String collection,
    required List<double> embedding,
    String environment = 'home',
    String? spatialZone,
  }) async {
    await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
      id: id,
      content: label,
      embedding: embedding,
      metadata: jsonEncode({
        'collection': collection,
        'category': category,
        'environment': environment,
        'spatial_zone': ?spatialZone,
        'created_at': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// Query against the personal collection first; if best score < [personalGate],
  /// fall back to the anchor collection.
  Future<MatchResult> matchByQuery({
    required String query,
    required String environment,
    double personalGate = 0.78,
    int topK = 5,
  }) async {
    final personal = await FlutterGemmaPlugin.instance.searchSimilar(
      query: query,
      topK: topK,
      threshold: 0.0,
      filter: Filter(
        must: [
          FieldEquals(key: 'collection', value: 'personal'),
          FieldEquals(key: 'environment', value: environment),
        ],
      ),
    );
    if (personal.isNotEmpty && personal.first.similarity >= personalGate) {
      return MatchResult.fromHit(personal.first, source: MatchSource.personal);
    }
    final anchor = await FlutterGemmaPlugin.instance.searchSimilar(
      query: query,
      topK: topK,
      threshold: 0.0,
      filter: Filter(must: [FieldEquals(key: 'collection', value: 'anchor')]),
    );
    if (anchor.isEmpty) return MatchResult.empty();
    return MatchResult.fromHit(anchor.first, source: MatchSource.anchor);
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
