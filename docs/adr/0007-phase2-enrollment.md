# ADR 0007 — Phase 2 enrollment design

**Status:** Active. 2026-05-29.

## Context

Phase 2 ships the on-device personal sound library: a user records their
own doorbell, knock pattern, smoke alarm, family voices, appliance beeps.
Each becomes a *prototype* that the Phase 1 fast-path matches against
before falling back to Gemma3n.

Three design questions had no obvious answer from the Phase 1 stack and
are pinned here so future phases don't drift.

## Decision 1 — Captioning-then-embedding, not audio-to-embedding

EmbeddingGemma in `flutter_gemma` 0.16.1 is **text-only**. (Confirmed by
reading the bundled `EmbeddingModel` interface.) Audio→embedding directly
is not exposed.

So the Phase 2 fast-path is:

```
PCM 16 kHz mono  ─►  Gemma3n caption  ─►  EmbeddingGemma  ─►  qdrant-edge
   (Rust)           (one short sentence)   (768-D L2 vector)    (centroid point)
```

The captioner's system prompt forces a uniform style (one objective
sentence, present tense, 10-18 words, source/texture/spatial cues) so that
captions across recordings of the same physical sound land near each
other in cosine space. The anchor-seed manifest captions follow the same
template — see [/assets/anchor_seeds.json](../../assets/anchor_seeds.json).

Phase 1b will swap in a direct audio-embedding path when the upstream
plugin exposes it. The repository contract isolates this: a sample only
needs `embedding: List<double>`; the source doesn't matter.

## Decision 2 — Centroid prototypes with a sidecar source-of-truth

Speaker-verification literature (Variani et al., *d-vector*) uses
**L2-normalized averages of enrollment embeddings** as the centroid. We
do the same: per recorded sample, an embedding; per prototype, an
average of those embeddings, renormalized, written once into qdrant-edge
under the prototype's UUID.

`flutter_gemma` exposes only `addDocumentWithEmbedding`, `searchSimilar`,
`getVectorStoreStats`, and `clearVectorStore` — no per-document delete or
update. Upserting by the same id replaces (qdrant-edge semantics), so
*updates* work. *Deletes* require clearing the store and reindexing every
survivor.

To make that survivable we maintain a sidecar:
`<docs>/enrollment_store.json` keeps the entire prototype + every raw
sample embedding. The vector store is treated as a derived cache:
[PrototypeRepository.delete] does
`clearVectorStore` → re-seed anchors → re-push surviving prototypes from
the sidecar. No re-recording, no Gemma3n calls.

## Decision 3 — Anchor seeding is text captions, not bundled audio

We seed ~50 AudioSet-style anchor categories at first launch from
[/assets/anchor_seeds.json](../../assets/anchor_seeds.json). Each entry is
`{id, label, category, caption}`. On first launch, EmbeddingGemma batch-
embeds the captions and writes them to qdrant-edge with
`collection: "anchor"`.

This is consistent with Decision 1 (we're already matching captions, not
audio) and avoids shipping audio bytes in the APK. The anchor manifest is
versioned with a sentinel marker doc — bumping
`EmbeddingStore._currentAnchorVersion` re-seeds on next launch.

## Where the parts live

| Layer | File | Purpose |
|---|---|---|
| Rust DSP | [rust/src/dsp/enrollment.rs](../../rust/src/dsp/enrollment.rs) | Clip quality gates (duration, peak, SNR, active ratio, clipping) |
| Rust API | [rust/src/api/enrollment.rs](../../rust/src/api/enrollment.rs) | Dart-facing validators + explicit-record tap into pipeline |
| Dart model | [lib/src/enrollment/prototype.dart](../../lib/src/enrollment/prototype.dart) | `SoundPrototype` + `EnrollmentSample` + centroid math |
| Dart repo | [lib/src/enrollment/prototype_repository.dart](../../lib/src/enrollment/prototype_repository.dart) | Sidecar JSON ↔ qdrant-edge mirror |
| Dart env | [lib/src/enrollment/environment_manager.dart](../../lib/src/enrollment/environment_manager.dart) | Active-environment selection (SharedPreferences) |
| Dart service | [lib/src/enrollment/enrollment_service.dart](../../lib/src/enrollment/enrollment_service.dart) | Orchestrates validate → caption → embed → persist |
| Dart captioner | [lib/src/enrollment/caption_generator.dart](../../lib/src/enrollment/caption_generator.dart) | Gemma3n one-sentence caption |
| Dart store | [lib/src/llm/embedding_store.dart](../../lib/src/llm/embedding_store.dart) | TaskType prefixes, anchor seeding, env-aware retrieval |
| UI | [lib/src/ui/enrollment_wizard.dart](../../lib/src/ui/enrollment_wizard.dart) | 4-step wizard: category → label → record → review |
| UI | [lib/src/ui/prototype_library_screen.dart](../../lib/src/ui/prototype_library_screen.dart) | List, switch env, add, delete |

## Quality gates (Rust)

Defaults in [`EnrollmentGates::default`]:

| Gate | Threshold | Rationale |
|---|---|---|
| `min_duration_ms` | 500 | Below 0.5 s Gemma3n cannot describe a sound. |
| `max_duration_ms` | 4 000 | Gemma3n audio context window cap. |
| `min_peak_dbfs` | −28 | Mic too far / source too quiet to retrieve reliably. |
| `min_snr_db` | 6 | Below 6 dB the centroid drifts toward the background. |
| `min_active_ratio` | 0.30 | <30 % active = clip is mostly silence. |
| `max_clipping_ratio` | 0.01 | >1 % saturated samples corrupt embeddings. |

These can be sweep-tuned via `analyze_enrollment_clip_16k_tuned`. The
Phase 1 eval harness will A/B them against the kill/continue dataset.

## What's deferred to later phases

- **Audio→embedding direct** — Phase 1b once flutter_gemma exposes it.
- **Auto-detected environment** (BSSID / geofence / acoustic fingerprint) —
  Phase 3+. Phase 2 is manual.
- **Active-learning labels on live notifications** (Phase 9 LoRA prep) —
  prototype repo already accepts post-hoc sample additions.
- **Personal voice biometrics** — caption-based embedding is sufficient
  for "my name spoken by family" identification at Phase 2 quality; we'll
  revisit if the gate flags `family_voice` as a recall bottleneck.

## Acceptance test (Phase 2 success criterion)

Per `project_prism_phases.md`:

> Enroll 5 personal sounds, restart app, recognition still works.
> Multi-environment switching honored.

The integration test
[`integration_test/enrollment_flow_test.dart`](../../integration_test/enrollment_flow_test.dart)
will validate this against the connected-device path once recording is
plumbed. Phase 2 unit-level proof:

- 6 Rust gate-decision tests in `rust/src/dsp/enrollment.rs`.
- 5 Dart centroid-math tests in `test/src/enrollment/prototype_test.dart`.
- 6 Dart env-manager tests in `test/src/enrollment/environment_manager_test.dart`.
- 6 Dart anchor-seed validity tests in `test/src/enrollment/anchor_seeds_test.dart`.
- 3 Dart category-taxonomy tests in `test/src/enrollment/categories_test.dart`.

All pass headlessly. Total host tests rises from 28 (Phase 1) to 56.
