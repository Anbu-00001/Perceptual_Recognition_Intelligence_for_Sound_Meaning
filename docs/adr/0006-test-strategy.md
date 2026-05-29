# ADR 0006 — Layered test strategy

**Status:** Active. 2026-05-29.

## Context

A Flutter + Rust + native (Kotlin/Swift) APK has at least five places things
can break, and no single tool covers all of them. Naming what each layer is for
prevents the test pyramid from collapsing into "one tool, half the coverage."

**Playwright is explicitly rejected.** Playwright drives browsers; our APK
exposes no WebView, so it has nothing to drive.

## Decision

| Layer | Tool | Lives in | Catches |
|---|---|---|---|
| 1. Rust unit | `cargo test --lib` | `rust/src/**/*.rs` `#[cfg(test)]` | DSP math errors, VAD config drift |
| 2. Rust integration | `cargo test --tests` | `rust/tests/*.rs` | Public DSP surface, ring concurrency, pipeline plumbing |
| 3. Dart unit | `flutter test` | `test/**/*_test.dart` | JSON shape drift, metric math, UI logic, golden renders |
| 4. Flutter integration | `flutter test integration_test/` | `integration_test/*_test.dart` | Real Flutter engine on device — FFI, codegen surfaces, lifecycle |
| 5. OS-level system flows | `patrol` | `integration_test/patrol_*_test.dart` | Mic + notification dialogs, background survival, foreground service notification |
| 6. E2E smoke | `maestro` | `.maestro/*.yaml` | Cold-boot regressions when you don't want a full Dart test cycle |
| 7. CI orchestration | GitHub Actions | `.github/workflows/ci.yml` | Everything runs on every PR |

Each layer is an **independent** entry point — none of them imports the
fixtures of another. This is deliberate. When one fails it must be obvious
which boundary broke.

## What's in the tree as of Phase 2

- **Rust:** 29 tests across `dsp_smoke.rs`, `ring_concurrent.rs`,
  `pipeline_smoke.rs`, `enrollment_tap.rs` (recorder lifecycle), plus
  in-source `vad`, `enrollment`, and `tap_tests` units. Inline tests that
  share global state (recorder tap) serialize via a file-scope `Mutex<()>`
  because `cargo test` runs unit tests on multiple threads.
- **Dart unit:** 49 tests (1 skipped) across SceneVerdict, GateMetrics,
  WaveformPainter, MatchResult, SoundPrototype centroid math,
  EnvironmentManager persistence, SoundCategory taxonomy, anchor-seed
  manifest validity, EnrollmentService orchestration (6 outcomes),
  PrototypeRepository sidecar/mirror roundtrip (7 paths),
  PrototypeLibraryScreen empty-state rendering.
- **Flutter integration:** `app_boots_test.dart` (4 tests including the
  diagnostic RustLib init guard), `dsp_event_flow_test.dart`,
  `scene_pipeline_test.dart`, and **new in Phase 2**
  `enrollment_flow_test.dart` (recorder lifecycle + Rust validator
  responses).
- **Patrol:** `patrol_permissions_test.dart` — drives the system mic +
  notification dialogs, validates the foreground service notification,
  exercises a 30 s background → foreground cycle.
- **Maestro:** `.maestro/smoke.yaml` — cold-boot → permission grant →
  10 s capture → stop → verify file.

**Total host tests as of Phase 2: 78 green** (49 Dart + 29 Rust).

## Skipped tests and why

- `prototype_library_screen_test.dart` — the second test
  ("populated repo renders a row per prototype with sample count") is
  marked `skip: true`. The host widget-test path hangs reliably on the
  second `pumpWidget` after a `PrototypeRepository.upsert`, due to a
  broadcast `StreamController` × `InMemoryPrototypeVectorMirror` × test
  binding microtask interaction. Functionality is covered by
  `prototype_repository_test.dart` (upsert path) and
  `enrollment_service_test.dart` (full chain). Patrol coverage in Phase
  2.5 will validate the populated render on device.

## What's in the tree as of Phase 1

- **Rust:** 12 tests across `dsp_smoke.rs` (FFT/MFCC/spectral/onset/GCC-PHAT),
  `ring_concurrent.rs` (concurrent push/pop), `pipeline_smoke.rs` (full DSP
  pipeline thread). Plus 3 in-source VAD tests. All pass headlessly.
- **Dart unit:** 16 tests across SceneVerdict JSON, GateMetrics math,
  WaveformPainter rendering, MatchResult shape. Pass via `flutter test`.
- **Flutter integration:** `app_boots_test.dart` (boot + FFI bridge load),
  `dsp_event_flow_test.dart` (Rust → Dart events), `scene_pipeline_test.dart`
  (orchestrator shape). Requires a device or emulator.
- **Patrol:** `patrol_permissions_test.dart` — drives the system mic +
  notification dialogs, validates the foreground service notification appears,
  exercises a 30 s background → foreground cycle. Requires
  `dart pub global activate patrol_cli`.
- **Maestro:** `.maestro/smoke.yaml` — cold-boot → permission grant →
  10 s capture → stop → verify file. Requires `maestro` CLI.

## Runner

```bash
./scripts/test.sh                     # rust + dart (host, no device needed)
./scripts/test.sh --layer rust        # cargo only
./scripts/test.sh --layer dart        # flutter test only
./scripts/test.sh --layer integration # integration_test on device
./scripts/test.sh --layer patrol      # patrol on device
./scripts/test.sh --layer maestro     # maestro on device
./scripts/test.sh --layer all-device  # 4 + 5 + 6
./scripts/test.sh --layer everything  # 1 + 2 + 3 + 4 + 5 + 6
```

## Conventions for future phases

1. **Every new Rust DSP module gets an integration test in `rust/tests/`.**
   Unit tests live next to the code; the integration test is the contract.
2. **Every new public Dart class with non-trivial logic gets a unit test in
   `test/src/<mirror_path>_test.dart`.**
3. **Every new UI surface gets either a widget test or an integration test.**
   Use `find.text` / `find.byKey` — never `find.byType` with generic widgets,
   they're brittle.
4. **System-permission flows go through patrol, not integration_test.** If a
   test needs to grant a permission, it's a patrol test.
5. **Long-running soak tests (battery, leak) go in `integration_test/soak/`**
   and run nightly, not per-PR. Phase 9+ adds these.
6. **LLM model-loading tests are gated behind a `--dart-define=HF_TOKEN=...`
   variable** and a `test_with_models/` directory — never required for green CI
   because they need real model downloads (~1–2 GB).

## What doesn't get tested (and why)

- **Native Kotlin/Swift unit tests for `AudioCaptureService`, `AudioCapture.swift`** —
  the surface is small enough that integration_test + patrol catch
  everything that matters. Add JUnit only if a Phase 6+ feature pushes
  the Kotlin side past ~500 LOC.
- **Performance regressions per-PR** — Phase 10 adds Android `Battery Historian`
  + iOS `Instruments → Energy Log` as a nightly job, not per-PR.
- **Model accuracy** — that's the Phase 1 kill/continue gate's job
  (`scripts/eval_phase1.sh`), not CI's.

## What changes in Phase 2+

- Phase 2 adds enrollment flow → patrol test for enrolling 5 personal sounds.
- Phase 3 adds spatial overlay → widget test + integration test for
  zone-classification rendering.
- Phase 5 (multimodal) → integration test that exercises the camera path.
- Phase 6 (NL query) → patrol test for typed natural-language queries returning
  bounded results.
- Phase 8 (wearable) → patrol test for Watch / Wear haptic delivery.
- Phase 9 (LoRA) → a separate `cargo test --features lora-tests` profile that
  exercises the on-device adapter loading.
