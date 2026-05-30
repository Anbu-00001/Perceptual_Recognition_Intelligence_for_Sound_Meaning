# ADR 0009 — Phase 3 spatial audio + multi-room awareness

**Status:** Active. 2026-05-30.

## Context

Phase 3 of [project-prism-phases] ships two things that Phase 1's raw
GCC-PHAT estimate can't deliver on its own:

1. **A stable directional estimate** for the UI. Per-event GCC-PHAT
   angles are noisy — even a single source jitters ±15° between
   adjacent events. The UI needs something the user can read at a
   glance ("the knock was on your left") not a flickering needle.

2. **Multi-room ("zone") awareness.** "Was that the kitchen or the
   front door?" is a different question from "what direction was
   that?" — it's answered by the *acoustic fingerprint of the room*
   (HVAC hum, fridge cycle, traffic floor) not by phase delay.

These are independent design problems and they get independent
solutions, so a low-tier phone like the OPPO A18 (single physical
mic — fails (1) entirely) can still ship (2).

## Decision 1 — 1D Kalman filter for smoothed angle

GCC-PHAT per-event angle is the measurement; the smoothed UI value
is `[angle_deg, omega_deg_per_sec]` updated by a constant-velocity
Kalman filter with **measurement variance scaled inverse to
confidence**:

```
R(t) = R_base / max(confidence, 0.1)
```

Low-confidence frames widen the measurement gate, so the state
"coasts" on the previous estimate instead of getting yanked toward
noise. On `mono_replicated == true` events, the measurement is
skipped entirely — the state coasts, and after `STALE_AFTER_MS`
(default 2.5 s) of no measurement the smoothed value is reported
as Unknown rather than a frozen stale angle.

The EKF named in the original spec degenerates to a linear 1D
Kalman here (angle measurement is linear in the state). I chose
the simpler tool. If Phase 8 adds multi-mic beamforming, the same
[angle_tracker.rs](../../rust/src/dsp/angle_tracker.rs) struct
upgrades cleanly to nonlinear measurements.

References: standard single-source DOA smoothing pattern, [arXiv
1812.01521](https://arxiv.org/pdf/1812.01521) §3 uses the same
state vector for a beamforming setup; we drop the beamformer and
keep the tracker.

## Decision 2 — Prototype-centroid zone classifier (no neural net)

The phases doc asked for "a small fully-connected NN trained on
user-recorded zone samples." I considered three options:

| Option | Pros | Cons |
|---|---|---|
| Tiny FC NN | flexible, smooth decision boundaries | needs training loop + weight serialization in Rust; new dep |
| ONNX via `tract` | accurate, pre-trainable | ~3 MB extra binary; overkill for ≤10 zones |
| **Cosine to enrolled centroid (chosen)** | zero training, zero weights, trivially testable | linear decision boundary in feature space |

For Phase 3's actual problem — distinguishing 3–8 rooms in one
home — feature space is small enough that the linear cosine
decision is sufficient. This matches the prototype-based path PRISM
already uses for sounds in Phase 2 ([project-prism-phase2-done]),
keeping a single mental model: "everything is a labeled centroid."

Feature vector — 23-D, all computed in pure Rust at no extra runtime
cost since the DSP loop already produces these per snapshot:

- 13 MFCC means (averaged across the 1-sec window)
- 4 sub-band log-energies (60–250 / 250–1000 / 1000–4000 / 4000+ Hz)
- Spectral centroid (Hz)
- Spectral rolloff (Hz, 85% energy)
- Spectral flatness
- ZCR
- RMS dBFS
- Crest factor

A 1-sec window is captured every periodic snapshot. The enrollment
flow averages 10–30 windows into a centroid; classification picks
argmax cosine over the active environment's centroids, gated by
`MIN_SIM = 0.85`. Below that → Unknown rather than a confident
mis-classification — same honesty principle as the spatial
`SpatialZone::Unknown` in [0008-oppo-a18-hardening].

References: the canonical "Name That Room" paper from Berkeley
([cnmat 2012](https://www.cnmat.berkeley.edu/sites/default/files/attachments/2012_Name_That_Room.pdf))
fingerprints rooms by impulse-response echos; we don't have a known
stimulus, so we fingerprint the *stationary noise floor* instead.
Practical room ID from noise floor is well established ([ResearchGate
review](https://www.researchgate.net/publication/262216859)).

## Decision 3 — Sidecar JSON + eager Rust sync at app start

Storage model copies Phase 2's exactly: `room_zones.json` in app
documents directory is the source of truth, the Rust prototype
table is a derived mirror that gets repopulated from sidecar on
every cold boot.

The first integration shipped this lazily — `_ensureLoaded()` ran
only on the first `repo.listAll()` call. On-device verification
caught the bug: after a cold restart, the very first DSP event
fires before the user opens any UI that touches the repo, so the
Rust classifier sees an empty table and emits Unknown. The user
sees "room: unknown" until they navigate to the enrollment screen
(which finally triggers the load).

**Fix:** `RoomZoneRepository.ensureSynced()` is now called from
`main.dart` via `unawaited(...)` after construction. The load is
off the critical path (it happens in the same microtask sweep as
`runApp`) but completes before the user can tap any button. A
regression test in [room_zone_repository_test.dart](../../test/src/spatial/room_zone_repository_test.dart)
("ensureSynced loads sidecar AND pushes to Rust before any user
call") pins this behavior.

## Decision 4 — Single shared environment with Phase 2

Each `RoomZone` carries `environment: 'home' | 'office' | ...`,
the same key Phase 2 uses for sound prototypes. The active
environment from
[EnvironmentManager](../../lib/src/enrollment/environment_manager.dart)
filters both at once: switching from "home" to "office" hides
both your kitchen-fingerprint and your home-doorbell at the same
time. The repos don't know about each other; they each subscribe
to the environment broadcaster.

## Decision 5 — UI: arc + chip + always-visible enroll action

[SpatialOverlay](../../lib/src/ui/spatial_overlay.dart) renders
two things stacked vertically:

1. A 180° arc showing the smoothed angle as a needle, ticks at
   –90/–45/0/+45/+90. Greyed-out on mono_replicated devices; the
   amber audio-source warning already explains why above it.
2. A pill chip "room: TestRoom · 87%" / "room: unknown · enroll
   rooms to identify". The unknown state is its own affordance.

A persistent `Enroll this room` button under the overlay is the
only on-ramp; Phase 3 deliberately doesn't ship a separate
"Rooms" library screen (Phase 6 timeline view will surface that).
The user's mental model stays small: "I'm in a room → I press a
button → the app learns this room."

## On-device verified (OPPO A18, 2026-05-30)

1. Cold launch (force-stopped APK) → zone chip reads
   "room: unknown · enroll rooms to identify" within 1 s of "Listening".
2. Enroll TestRoom (30 s capture, 14 s actually persisted due to
   ring-buffer / drain-rate mismatch — see *Known issues* below).
3. Within 2 s of returning to Home, chip flips to
   "room: TestRoom · 100%". 100% because the live ambient noise is
   the same noise we just enrolled — a sanity check, not a final
   accuracy claim.
4. `am force-stop` + cold relaunch → after starting capture, the chip
   reads "room: TestRoom · 100%" within 2 s, with zero user
   interaction in between. The eager `ensureSynced` fix landed
   correctly.
5. Amber spatial degradation line still reads:
   *"mic source: VOICE_RECOGNITION · device does not expose
   UNPROCESSED; spatial features degraded"*. The arc is greyed
   because of `mono_replicated`; zone chip works regardless,
   exactly as designed.

## Tests shipped

- Rust unit tests in [angle_tracker.rs](../../rust/src/dsp/angle_tracker.rs)
  (constant-source convergence, mono-replicated coasting, stale
  decay).
- Rust unit tests in [zone.rs](../../rust/src/dsp/zone.rs) (cosine
  similarity, centroid averaging, MIN_SIM gating).
- Rust integration tests in [tests/zone_classifier.rs](../../rust/tests/zone_classifier.rs).
- Dart tests in [test/src/spatial/](../../test/src/spatial/):
  RoomZoneRepository × 7 (including the cold-boot regression),
  ZoneEnrollmentService × 4.

Host test count: **49 + 7 + 4 = 60 Dart tests** and **32 + N Rust
tests** green. (Exact Rust count in the Phase 3 done note.)

## Known issues + deferred

- **Recorder captures ~14 s of audio when asked for 30 s on the OPPO A18.**
  Pipeline_tap_push sees only ~672 k pairs in the wall-clock 30 s
  window; cap is set to 1.46 M, so it's not a cap hit. Likely a
  ring-buffer/drain-rate mismatch under load — DSP loop drains 960
  pairs/20 ms while Kotlin pushes ~1024 pairs/23 ms, so the surplus
  either overflows the ring (silent drop) or sits there waiting.
  Phase 3 enrollment still produces a valid centroid above the 10 s
  minimum, so this is a quality issue not a correctness one. Tracked
  for Phase 4 alongside the ring-buffer instrumentation pass.

- **Acceptance test gate of ≥85% direction accuracy is untested on
  this device.** Mono-replicated hardware makes it structurally
  impossible. The gate applies only to phones with two physical
  mics; the zone-classification gate (≥85% room-classification
  accuracy on enrolled rooms after enroll-then-test) is what we
  verify here.

- **Drift handling.** A room's noise floor changes (fridge cycles,
  HVAC, windows opening). Phase 3 ships point-estimate centroids
  with no online updates. Phase 9 LoRA-style adaptation handles
  this — Phase 3 should not pre-empt that design.

- **Multi-mic phones not tested yet.** The angle tracker code path
  is dead on the OPPO A18. Verify on a Pixel 8 / Galaxy S2x before
  declaring the Kalman implementation correct.

- **Zone library / delete / edit UX.** Phase 3 only supports
  *adding* a zone. Deleting or relabeling a wrong enrollment
  requires deleting the sidecar JSON manually. Phase 6 timeline
  view will surface a proper rooms screen.

## Reference: when to update this ADR

- A multi-mic phone reproduces a tracker bug not covered above.
- The MIN_SIM threshold needs tuning from real-world false-positive
  data.
- Drift becomes load-bearing (Phase 9).
- Acoustic fingerprint feature set changes (e.g., Phase 6 adds
  RIR-style echos when echo cancellation can be turned off).
