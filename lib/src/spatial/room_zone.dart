import 'dart:typed_data';

/// Phase 3 — a labeled room/zone with a precomputed acoustic-fingerprint
/// centroid produced by the Rust `zone_compute_feature` extractor.
///
/// `environment` ties the zone to the same environment buckets the Phase 2
/// sound prototypes use (e.g. "home", "office"); zones from a different
/// environment are filtered out at classify-time.
///
/// Centroid is `Float32List` of length `ZONE_FEATURE_DIM` (21 in Rust). Wrong
/// length is treated as corruption — see `RoomZoneRepository.load`.
class RoomZone {
  RoomZone({
    required this.id,
    required this.label,
    required this.environment,
    required this.centroid,
    required this.createdAtMs,
    this.sampleSeconds = 0,
  });

  final String id;
  final String label;
  final String environment;
  final Float32List centroid;
  final int createdAtMs;
  final int sampleSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'environment': environment,
        'centroid': centroid.toList(),
        'createdAtMs': createdAtMs,
        'sampleSeconds': sampleSeconds,
      };

  factory RoomZone.fromJson(Map<String, dynamic> json) {
    final raw = (json['centroid'] as List).cast<num>();
    return RoomZone(
      id: json['id'] as String,
      label: json['label'] as String,
      environment: json['environment'] as String,
      centroid: Float32List.fromList(raw.map((n) => n.toDouble()).toList()),
      createdAtMs: (json['createdAtMs'] as num).toInt(),
      sampleSeconds: (json['sampleSeconds'] as num?)?.toInt() ?? 0,
    );
  }

  RoomZone copyWith({
    String? label,
    String? environment,
    Float32List? centroid,
    int? sampleSeconds,
  }) =>
      RoomZone(
        id: id,
        label: label ?? this.label,
        environment: environment ?? this.environment,
        centroid: centroid ?? this.centroid,
        createdAtMs: createdAtMs,
        sampleSeconds: sampleSeconds ?? this.sampleSeconds,
      );
}
