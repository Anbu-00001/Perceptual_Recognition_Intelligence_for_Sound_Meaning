import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../llm/model_manager.dart';
import '../llm/gemma_audio_wav.dart';

/// Turns a 16 kHz mono enrollment clip into a short, retrieval-style caption
/// using Gemma3n's audio modality.
///
/// Why caption-then-embed instead of audio-to-embedding directly?
/// EmbeddingGemma is text-only in 0.16. So Phase 2 routes the audio through
/// Gemma3n once (asking it to describe rather than classify), then feeds the
/// caption to EmbeddingGemma. The captions are also stable across enrollments:
/// "front door knock, three light taps" embeds close to itself across recordings.
///
/// The caption prompt is intentionally constrained: short, present-tense,
/// objective. Keeping captions stylistically uniform tightens the cosine
/// neighborhood of the centroid; chatty captions add variance that hurts
/// recall.
class CaptionGenerator {
  CaptionGenerator(this._models, {this.maxTokens = 96});

  final ModelManager _models;
  final int maxTokens;
  InferenceChat? _chat;

  static const _system = '''
You caption short audio clips for an on-device sound library.
Always answer in ONE short objective sentence, present tense, 10-18 words.
Mention: the sound source, the texture (e.g. metallic, soft, sharp, repeating),
and any spatial cues you can hear. Do NOT use the words "I" or "you".
Do NOT speculate on intent. Do NOT add prose. Output the sentence only.
''';

  Future<void> warmup() async {
    final model = await _models.getActiveModel(maxTokens: maxTokens);
    _chat = await model.createChat(
      systemInstruction: _system,
      supportImage: false,
      supportAudio: true,
      temperature: 0.3,
    );
  }

  /// Generate one caption for [pcm16k]. Returns an empty string on failure;
  /// the caller treats that as "embed the user-typed label instead".
  Future<String> caption({
    required Int16List pcm16k,
    String? userLabelHint,
  }) async {
    final chat = _chat;
    if (chat == null) {
      throw StateError('CaptionGenerator.warmup() must be called first.');
    }
    if (pcm16k.isEmpty) return '';

    final wavBytes = pcmToWav(pcm16k, sampleRate: 16000);
    final hint = (userLabelHint ?? '').trim();
    final hintLine = hint.isEmpty
        ? 'Describe this sound.'
        : 'The user calls this "$hint". Describe what makes it identifiable.';

    await chat.addQueryChunk(
      Message.withAudio(
        audioBytes: wavBytes,
        text: hintLine,
        isUser: true,
      ),
    );
    final raw = await chat.generateChatResponse();
    return _sanitize(raw.toString());
  }

  static String _sanitize(String s) {
    var line = s.trim();
    // Strip enclosing quotes / code fences if the model adds any.
    line = line.replaceAll(RegExp(r'^["`\s]+|["`\s]+$'), '');
    if (line.startsWith('{')) {
      try {
        final j = jsonDecode(line);
        if (j is Map && j.values.isNotEmpty) {
          final v = j.values.first;
          if (v is String) return v.trim();
        }
      } catch (_) {}
    }
    // Single line only.
    final firstNl = line.indexOf('\n');
    if (firstNl >= 0) line = line.substring(0, firstNl).trim();
    return line;
  }
}
