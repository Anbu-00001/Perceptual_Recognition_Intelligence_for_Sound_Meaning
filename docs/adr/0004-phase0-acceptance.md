# ADR 0004 — Phase 0 acceptance test

**Status:** Active. 2026-05-28.

## Goal

Demonstrate that the polyglot skeleton (Dart + Kotlin + Swift + Rust + CMake stub)
actually moves bytes across the bridges and to disk. No DSP, no AI. Just plumbing.

## Pre-flight (one-time)

```bash
./scripts/setup.sh
```

Installs Rust, cargo-ndk, flutter_rust_bridge_codegen; configures
`android/local.properties` with the NDK path; runs `flutter pub get` and `codegen.sh`.

## Run on Android

```bash
./scripts/dev.sh android   # builds Rust .so, runs flutter on attached device
```

## Acceptance checks

| # | Check | Pass |
|---|---|---|
| 1 | App launches without crash | UI shows "PRISM · Phase 0" + Idle state |
| 2 | Tap **Start capture** prompts mic + notification permission | Both grants succeed |
| 3 | Persistent notification appears | "PRISM is listening" with mic icon |
| 4 | Stereo waveform renders live | Cyan left + magenta right, ≤100 ms perceived latency |
| 5 | Tap **Record session** | Session paths shown under waveform |
| 6 | After 30 s of audio + claps, tap **Stop recording** | WAV + IMU CSV written to documents dir |
| 7 | Pull files via `adb pull /sdcard/Android/data/com.prism.prism/files/sessions/` | Both files present |
| 8 | Open `.wav` in Audacity | 48 kHz stereo, both channels visible |
| 9 | Inspect IMU CSV row count vs duration | ~200 ± 10 rows/sec (Android) |
| 10 | Background the app (home button) for 60 s, foreground again | Capture still running, no crash |
| 11 | Battery check: 1 h capture | ≤ 6% drain on mid-range Android |

## Run on iOS (when on a Mac)

```bash
./scripts/dev.sh ios
```

Same checks, plus:
- Lock screen during capture → recording continues (validates `UIBackgroundModes=audio`).
- IMU CSV ≈ 100 ± 5 rows/sec (iOS cap).

## Known Phase 0 limitations

- No DSP — the waveform is decimated raw samples. Phase 1 adds VAD + features.
- IMU and audio share the ring drain; in Phase 1 the WAV writer becomes a proper
  fan-out so visualization and recording don't compete.
- iOS background-mode audio requires App Store reviewer justification for release.
