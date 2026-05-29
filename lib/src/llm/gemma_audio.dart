import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../rust/api/dsp_pipeline.dart' show DspEvent;
import 'gemma_audio_wav.dart';
import 'model_manager.dart';
import 'scene_verdict.dart';

/// Slow-path Gemma3n audio scene reasoner.
///
/// Receives a [DspEvent] + its captured 16 kHz mono PCM segment, asks Gemma3n
/// for a structured JSON verdict, parses to [SceneVerdict].
///
/// The prompt is locked for Phase 1. Iterated via the Phase 1 eval harness.
class GemmaAudioReasoner {
  GemmaAudioReasoner(this._models);
  final ModelManager _models;
  InferenceChat? _chat;

  static const _system = '''
You are PRISM, an on-device ambient sound scene reasoner serving a deaf or
hard-of-hearing user. You receive a short audio clip plus numerical features.

Output STRICT JSON, no prose, conforming to:
{
  "kind": "speech" | "alarm" | "household" | "animal" | "ambient" | "unknown",
  "scene_summary": "<one short sentence>",
  "confidence": 0..1,
  "salience": "info" | "notable" | "urgent",
  "key_elements": ["<2-5 short tags>"],
  "needs_visual_confirmation": true | false
}
Lean toward "needs_visual_confirmation: true" when the verdict matters
(door knock, fire alarm, smoke alarm, glass break, name spoken).
''';

  Future<void> warmup() async {
    final model = await _models.getActiveModel(maxTokens: 768);
    _chat = await model.createChat(
      systemInstruction: _system,
      supportImage: false,
      supportAudio: true,
    );
  }

  /// Build a feature digest the LLM can use for grounding when audio alone is
  /// ambiguous. Kept small so it doesn't dominate the prompt budget.
  String featureDigest(DspEvent ev) {
    return jsonEncode({
      'kind': ev.kind.name,
      'centroid_hz': ev.spectralCentroidHz.toStringAsFixed(0),
      'rolloff_hz': ev.spectralRolloffHz.toStringAsFixed(0),
      'flatness': ev.spectralFlatness.toStringAsFixed(2),
      'rms': ev.rms.toStringAsFixed(3),
      'crest': ev.crestFactor.toStringAsFixed(2),
      'sub_band_energy': ev.subBandEnergy
          .map((v) => v.toStringAsFixed(3))
          .toList(),
      'zone': ev.zone.name,
      'angle_deg': ev.angleDeg.toStringAsFixed(0),
    });
  }

  Future<SceneVerdict> classify({
    required DspEvent event,
    required Int16List audio16kMono,
  }) async {
    final chat = _chat;
    if (chat == null) {
      throw StateError('GemmaAudioReasoner.warmup() must be called first.');
    }
    if (audio16kMono.isEmpty) {
      return SceneVerdict.empty();
    }

    final wavBytes = pcmToWav(audio16kMono, sampleRate: 16000);
    final digest = featureDigest(event);

    // Audio + text turn. flutter_gemma's `Message.withAudio` accepts WAV bytes
    // (PCM 16 kHz mono per Gemma3n's training rate). Confirmed by inspecting
    // lib/core/message.dart in v0.16.1.
    await chat.addQueryChunk(
      Message.withAudio(
        audioBytes: wavBytes,
        text: 'features=$digest. Classify this clip.',
        isUser: true,
      ),
    );

    final raw = await chat.generateChatResponse();
    final text = raw.toString().trim();
    try {
      // Tolerate stray prose by extracting first {...} block.
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end <= start) return SceneVerdict.empty();
      final json = jsonDecode(text.substring(start, end + 1))
          as Map<String, dynamic>;
      return SceneVerdict.fromJson(json);
    } catch (_) {
      return SceneVerdict.empty();
    }
  }

}
