import 'package:flutter_gemma/flutter_gemma.dart';

import '../audio/device_profile.dart';

/// Coordinates download + install of the three model families PRISM needs.
///
/// Models are downloaded from HuggingFace litert-community on first run, cached
/// under the device's documents directory by flutter_gemma's own model store.
///
/// Sources confirmed by flutter_gemma README + changelog (2026-05-29):
///   - Gemma3n E2B/E4B (audio + vision input) — `.task` (mobile) or `.litertlm`.
///   - EmbeddingGemma 300M (768-D embeddings) — `.tflite`.
///   - DeepSeek R1 distilled 1.5B with `isThinking:true` — `.task` or `.litertlm`.
///
/// All install URLs are HuggingFace; user provides their HF token via env / Secure
/// Storage (Phase 7 productization). For Phase 1 dev runs, paste it into [hfToken].
class ModelManager {
  ModelManager({this.hfToken = '', this.profile = DeviceProfile.unknown});

  final String hfToken;
  final DeviceProfile profile;

  /// Refuses to install DeepSeek on memory-tight devices. Calling
  /// [ensureDeepSeek] on a low-tier phone returns false without touching the
  /// network — the OPPO A18-class hardware (4 GB / 4 GB virtual) would OOM
  /// at runtime even if the install succeeded.
  bool get canRunDeepSeek => !profile.memoryTier.skipDeepSeek;

  /// Confirmed by inspecting flutter_gemma v0.16.1 example folder.
  static const _gemma3nUrl =
      'https://huggingface.co/litert-community/Gemma-3n-E2B-it-litert-lm-preview/resolve/main/Gemma-3n-E2B-it-int4.litertlm';
  static const _embedderUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300M/resolve/main/embeddinggemma-300M_seq256.tflite';
  static const _embedderTokenizerUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300M/resolve/main/tokenizer.json';
  static const _deepseekUrl =
      'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B_seq2048_q8.litertlm';

  Future<void> ensureGemma3n(void Function(int progress) onProgress) async {
    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
    ).fromNetwork(_gemma3nUrl, token: hfToken).withProgress(onProgress).install();
  }

  /// Returns `true` if install ran, `false` if skipped due to memory tier.
  Future<bool> ensureDeepSeek(void Function(int progress) onProgress) async {
    if (!canRunDeepSeek) {
      return false;
    }
    await FlutterGemma.installModel(
      modelType: ModelType.deepSeek,
    ).fromNetwork(_deepseekUrl, token: hfToken).withProgress(onProgress).install();
    return true;
  }

  Future<void> ensureEmbedder({
    void Function(int progress)? onModelProgress,
    void Function(int progress)? onTokenizerProgress,
  }) async {
    final builder = FlutterGemma.installEmbedder()
        .modelFromNetwork(_embedderUrl, token: hfToken)
        .tokenizerFromNetwork(_embedderTokenizerUrl, token: hfToken);
    if (onModelProgress != null) builder.withModelProgress(onModelProgress);
    if (onTokenizerProgress != null) {
      builder.withTokenizerProgress(onTokenizerProgress);
    }
    await builder.install();
  }

  /// Active model handle for inference. Caller [maxTokens] sized for short structured
  /// JSON responses; the verbose narration model gets its own session.
  Future<InferenceModel> getActiveModel({int maxTokens = 768}) async {
    return FlutterGemma.getActiveModel(maxTokens: maxTokens);
  }
}
