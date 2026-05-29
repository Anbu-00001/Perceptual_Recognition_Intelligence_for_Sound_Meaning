import 'dart:async';
import 'dart:typed_data';

import '../rust/api/dsp_pipeline.dart' as rust_dsp;
import 'embedding_store.dart';
import 'gemma_audio.dart';
import 'scene_verdict.dart';

/// Drives the Phase 1 inference pipeline:
///   1. Poll DspEvents from Rust at ~30 Hz.
///   2. For each event (SkippingPeriodicSnapshot unless useful):
///      a) Fast-path: ask EmbeddingStore for a personal/anchor match.
///         - If personal match >= personalGate → emit immediately as
///           SceneVerdict + skip slow path.
///         - Else: continue.
///      b) Slow-path: pop captured audio from Rust, call Gemma3n via
///         [GemmaAudioReasoner.classify], emit SceneVerdict.
///   3. Surface results via [scenesStream].
///
/// Phase 1 keeps the slow-path *blocking on the previous slow-path call* —
/// only one Gemma3n inference at a time (it pegs the NPU). Onset bursts during
/// inference fall through to fast-path only or are dropped to keep latency low.
class ScenePipeline {
  ScenePipeline({
    required this.embeddings,
    required this.reasoner,
    this.environment = 'home',
  });

  final EmbeddingStore embeddings;
  final GemmaAudioReasoner reasoner;
  final String environment;

  final _controller = StreamController<SceneEvent>.broadcast();
  Timer? _pollTimer;
  bool _slowPathBusy = false;

  Stream<SceneEvent> get scenesStream => _controller.stream;

  void start() {
    rust_dsp.startDsp();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _pump(),
    );
  }

  void stop() {
    _pollTimer?.cancel();
    rust_dsp.stopDsp();
  }

  Future<void> _pump() async {
    final ev = rust_dsp.nextDspEvent();
    if (ev == null) return;

    // Skip periodic snapshots unless future Phase 6 NL-query consumes them.
    if (ev.kind == rust_dsp.DspEventKind.periodicSnapshot) return;

    final match = await embeddings.matchByQuery(
      query: _eventToQueryDigest(ev),
      environment: environment,
    );

    if (match.isHit && match.source == MatchSource.personal && match.score >= 0.85) {
      _controller.add(SceneEvent.fromFastPath(ev, match));
      return;
    }
    await _maybeSlowPath(ev, match);
  }

  Future<void> _maybeSlowPath(rust_dsp.DspEvent ev, MatchResult match) async {
    if (_slowPathBusy) return;
    _slowPathBusy = true;
    try {
      final audio = rust_dsp.takeEventAudio16K(eventId: ev.eventId);
      if (audio.isEmpty) {
        _controller.add(SceneEvent.fromFastPath(ev, match));
        return;
      }
      final verdict = await reasoner.classify(
        event: ev,
        audio16kMono: Int16List.fromList(audio),
      );
      _controller.add(SceneEvent.fromSlowPath(ev, verdict, match));
    } catch (e) {
      _controller.add(SceneEvent.fromError(ev, e));
    } finally {
      _slowPathBusy = false;
    }
  }

  /// Coarse string used as the fast-path retrieval query. EmbeddingGemma in
  /// flutter_gemma converts text queries to embeddings internally; in Phase 1b
  /// we will switch to passing the *audio embedding* directly when flutter_gemma
  /// exposes that.
  String _eventToQueryDigest(rust_dsp.DspEvent ev) {
    return '${ev.kind.name} '
        'centroid:${ev.spectralCentroidHz.toStringAsFixed(0)}Hz '
        'rolloff:${ev.spectralRolloffHz.toStringAsFixed(0)}Hz '
        'flatness:${ev.spectralFlatness.toStringAsFixed(2)} '
        'rms:${ev.rms.toStringAsFixed(3)} '
        'crest:${ev.crestFactor.toStringAsFixed(2)} '
        'zone:${ev.zone.name}';
  }
}

class SceneEvent {
  SceneEvent({
    required this.dspEventId,
    required this.timestampMs,
    required this.verdict,
    required this.matched,
    required this.path,
    this.error,
  });

  final BigInt dspEventId;
  final BigInt timestampMs;
  final SceneVerdict verdict;
  final MatchResult matched;
  final Path path;
  final Object? error;

  factory SceneEvent.fromFastPath(rust_dsp.DspEvent ev, MatchResult match) =>
      SceneEvent(
        dspEventId: ev.eventId,
        timestampMs: ev.timestampMs,
        verdict: SceneVerdict(
          kind: match.metadata['category'] as String? ?? 'unknown',
          sceneSummary: match.label,
          confidence: match.score,
          salience: 'notable',
          keyElements: const [],
          needsVisualConfirmation: false,
        ),
        matched: match,
        path: Path.fast,
      );

  factory SceneEvent.fromSlowPath(
    rust_dsp.DspEvent ev,
    SceneVerdict v,
    MatchResult match,
  ) =>
      SceneEvent(
        dspEventId: ev.eventId,
        timestampMs: ev.timestampMs,
        verdict: v,
        matched: match,
        path: Path.slow,
      );

  factory SceneEvent.fromError(rust_dsp.DspEvent ev, Object err) => SceneEvent(
        dspEventId: ev.eventId,
        timestampMs: ev.timestampMs,
        verdict: SceneVerdict.empty(),
        matched: MatchResult.empty(),
        path: Path.error,
        error: err,
      );
}

enum Path { fast, slow, error }
