# ADR 0005 — Phase 1 architecture + kill/continue gate

**Status:** Active. 2026-05-29.

## What Phase 1 added on top of Phase 0

| Module | Path | Purpose |
|---|---|---|
| Rust DSP — FFT planner | `rust/src/dsp/fft.rs` | 4096-pt Hann-windowed STFT with cached planner |
| Rust DSP — mel filterbank + MFCC | `rust/src/dsp/mel.rs` | 64 mel bands, 13 cepstral coefficients, delta computation |
| Rust DSP — spectral + time features | `rust/src/dsp/features.rs` | Centroid, rolloff, flatness, sub-band energy, RMS, crest, ZCR |
| Rust DSP — VAD | `rust/src/dsp/vad.rs` | Energy + ZCR with adaptive background EMA + hangover |
| Rust DSP — onset | `rust/src/dsp/onset.rs` | Spectral-flux with adaptive threshold + cooldown |
| Rust DSP — spatial | `rust/src/dsp/spatial.rs` | GCC-PHAT TDOA → L/center/R zone |
| Rust pipeline runner | `rust/src/api/dsp_pipeline.rs` | Background thread drains ring, runs DSP, queues `DspEvent`s, captures 16 kHz mono audio segments |
| LLM — model installer | `lib/src/llm/model_manager.dart` | Installs Gemma3n / DeepSeek R1 / EmbeddingGemma from HuggingFace |
| LLM — Gemma3n slow path | `lib/src/llm/gemma_audio.dart` | Audio + feature digest → structured `SceneVerdict` JSON |
| RAG — embedding store | `lib/src/llm/embedding_store.dart` | qdrant-edge personal/anchor collections with payload filter |
| Pipeline — scene orchestrator | `lib/src/llm/scene_pipeline.dart` | Polls Rust events, fast-path match, escalates to slow-path |
| Eval — gate runner | `lib/src/eval/phase1_eval.dart` + `scripts/eval_phase1.sh` | Reads labeled manifest, produces JSON report against the 6 metrics |

## Decisions made under pressure

1. **VAD: energy+ZCR, not Silero (yet).** Silero VAD via the `ort` ONNX runtime adds ~6 MB of native binary per ABI. Phase 1 ships with a pure-Rust energy+ZCR detector with adaptive background tracking. The kill/continue gate measures whether this is enough. Phase 1b swaps to Silero only if the gate flags VAD-driven false-positives as the bottleneck.

2. **flutter_rust_bridge streams deferred again.** Even with codegen installed, the polled `next_dsp_event()` pattern is preserved because Dart already drives the cadence (50 ms timer) and the slow-path bottleneck is Gemma3n inference, not event delivery. Streams become worthwhile in Phase 5 when we add multi-channel push from C++ as well.

3. **Audio segment downsampling 48 → 16 kHz happens in Rust**, naive 3:1 averaging. flutter_gemma's Gemma3n input expects 16 kHz mono. A proper anti-aliased resampler is a Phase 1b polish.

4. **Fast-path uses text query embedding as a stand-in for audio embedding.** flutter_gemma 0.16 exposes audio→embedding only indirectly. Phase 1 sends the event's feature digest as a *string* to `searchSimilar`, which internally embeds it with EmbeddingGemma. Phase 1b switches to native audio-embedding once the API surface is public.

5. **Slow-path is single-flighted.** Gemma3n pegs the NPU; we let one inference run at a time. Events arriving during inference fall through to the fast-path only or are dropped. Phase 6 adds a priority queue.

6. **The model URLs in `model_manager.dart` are inferred from HuggingFace litert-community.** Validate when actually running on device — model IDs occasionally move between maintainers.

## Kill/continue gate — measurable thresholds

| # | Metric | Continue | Kill |
|---|---|---|---|
| 1 | Fast-path on enrolled sounds (5-class) | ≥ 92% | < 80% |
| 2 | Gemma3n narration coherence (n=50, ≥4/5) | ≥ 80% | < 60% |
| 3 | False positives over 24 h ambient | ≤ 1 / 3 h | > 1 / h |
| 4 | Event → notification p95 latency | ≤ 4 s | > 8 s |
| 5 | 24 h battery drain (mid-range Android) | ≤ 25 % | > 50 % |
| 6 | Spatial L / center / R at 1 m | ≥ 85 % | < 70 % |

Metrics 1, 2, 4 covered by `lib/src/eval/phase1_eval.dart`. Metric 6 lives in a
Rust unit test (`cargo test --lib spatial`) plus a host-side dart:ffi runner.
Metrics 3 + 5 require a real device and time — measured manually.

## Run the gate

```bash
# Build the eval clip manifest off-device first.
./scripts/eval_phase1.sh datasets/phase1_manifest.json $HF_TOKEN
adb pull /sdcard/Android/data/com.prism.prism/files/eval/phase1_report.json .
cat phase1_report.json | jq .
```

If `kill_or_continue` is `CONTINUE` or `CONTINUE_WITH_WARNINGS`, **file the
provisional patent** before starting Phase 2.

## Phase 1 testing now

```bash
cd rust && cargo test --lib
# 3 passed: silence_is_silence, detects_band_noise..., pure_tone_is_not_speech
```

```bash
flutter analyze        # 0 issues
flutter build apk --debug   # ✅ Built build/app/outputs/flutter-apk/app-debug.apk
```
