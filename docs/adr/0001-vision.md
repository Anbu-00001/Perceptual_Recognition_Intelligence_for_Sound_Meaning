# ADR 0001 — Vision and product framing

**Status:** Accepted. 2026-05-28.

## Context

PRISM went through four rejected framings before V5:
1. Structural-safety AI (liability cliff).
2. Pocket NDE for tile delamination (academic crowding, once-per-5-years use).
3. Consumer predictive maintenance for home machines (felt like a scanner app).
4. Counter-surveillance toolkit (underused flutter_gemma — LLM was a narrator over Bayesian sensor fusion, not the inference engine).

## Decision

**PRISM is an ambient acoustic intelligence companion.** Primary serving population:
deaf and hard-of-hearing. Secondary: anyone whose ears are blocked (headphones,
distance, noise, sleep, attention).

Audio → Gemma3n is the **primary inference path**, not a side channel. Every
flutter_gemma killer feature has a load-bearing role:

- **Gemma3n audio input** — direct scene reasoning, not labels.
- **DeepSeek R1 thinking mode** — transparent why for trust-critical UX.
- **EmbeddingGemma + qdrant-edge** — per-environment baselines + personal voice
  library + semantic-temporal NL query over a longitudinal audio log.
- **FunctionGemma** — household alerts, wearable haptics, transcribe-on-demand,
  emergency dial.
- **LoRA** — per-user environment adaptation.

## Consequences

- Privacy-on-device is the entire selling point. No cloud calls, ever.
- The patent strategy targets four anchors:
  1. Personalized embedding-gated escalation to audio-LLM inference.
  2. Multimodal uncertainty-triggered camera confirmation.
  3. Per-user LoRA with active-learning UX (solves ProtoSound's challenge that
     DHH users can't easily label sounds they cannot hear).
  4. Semantic-temporal audio log with NL query.
- The repo stays private until a US provisional patent is filed
  (US student micro-entity rate ~$75; India student rate ~₹1600). India and EU
  have no novelty grace period.

See `0002-foreground-service-compliance.md` for the Android 14 plumbing detail.
