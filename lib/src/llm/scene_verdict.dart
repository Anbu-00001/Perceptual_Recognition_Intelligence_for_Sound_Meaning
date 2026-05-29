/// Structured response from Gemma3n's slow-path scene narration.
/// JSON shape locked for Phase 1 — Phase 4+ extends this with `reasoning_trace`.
class SceneVerdict {
  SceneVerdict({
    required this.kind,
    required this.sceneSummary,
    required this.confidence,
    required this.salience,
    required this.keyElements,
    required this.needsVisualConfirmation,
  });

  /// One of: speech | alarm | household | animal | ambient | unknown
  final String kind;
  final String sceneSummary;
  final double confidence;
  /// One of: info | notable | urgent
  final String salience;
  final List<String> keyElements;
  final bool needsVisualConfirmation;

  factory SceneVerdict.fromJson(Map<String, dynamic> json) {
    return SceneVerdict(
      kind: (json['kind'] ?? 'unknown') as String,
      sceneSummary: (json['scene_summary'] ?? '') as String,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      salience: (json['salience'] ?? 'info') as String,
      keyElements: ((json['key_elements'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      needsVisualConfirmation:
          (json['needs_visual_confirmation'] as bool?) ?? false,
    );
  }

  factory SceneVerdict.empty() => SceneVerdict(
        kind: 'unknown',
        sceneSummary: '',
        confidence: 0.0,
        salience: 'info',
        keyElements: const [],
        needsVisualConfirmation: false,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'scene_summary': sceneSummary,
        'confidence': confidence,
        'salience': salience,
        'key_elements': keyElements,
        'needs_visual_confirmation': needsVisualConfirmation,
      };
}
