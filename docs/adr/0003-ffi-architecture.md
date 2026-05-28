# ADR 0003 — FFI architecture (native ↔ Rust ↔ Dart)

**Status:** Accepted. 2026-05-28.

## Context

The hot audio path is 48 kHz × 16-bit × 2 channels × 8 bytes/s = 192 KB/s of PCM.
At 24-hour continuous capture, that is ~17 GB/day — but we discard most of it
in the ring buffer; only ~10 KB/s of decimated waveform reaches Dart for
visualization in Phase 0.

Routing raw PCM through Flutter `MethodChannel` is infeasible at this rate
because of marshaling overhead and the channel's binary-message granularity.

## Decision

Two surfaces, sharing a single Rust global ring buffer:

### Surface 1 — Hot path (native → Rust, no Dart)

Native PCM callbacks call directly into Rust via:
- **Android:** JNI `extern "system" fn Java_com_prism_audio_RustBindings_*` declared
  in `rust/src/ffi/android.rs`, loaded by Kotlin via `System.loadLibrary("prism_dsp")`.
- **iOS:** C-ABI `extern "C" fn prism_push_audio_interleaved(...)` declared in
  `rust/src/ffi/mod.rs`, linked from Swift via the bridging header.

The functions push into a global `OnceLock<AudioRing>` defined in `rust/src/ring.rs`.

### Surface 2 — Event path (Rust → Dart via flutter_rust_bridge v2)

Dart subscribes to a `StreamSink<WaveformFrame>` exposed from
`rust/src/api/audio_stream.rs`. The Rust waveform thread drains the ring at
~30 fps, decimates to 512 samples per channel, and pushes a `WaveformFrame`
event. flutter_rust_bridge generates the Dart binding into `lib/src/rust/`.

### Surface 3 — Control path (Dart → native via MethodChannel)

The `com.prism/audio_capture` MethodChannel carries only lifecycle commands
(start / stop / isCapturing). Implementation:
- Android: `AudioCapturePlugin` (Kotlin).
- iOS: handler block in `AppDelegate.swift`.

## Why share state via Rust globals?

The MethodChannel command "startCapture" hits native code, which is decoupled
from the FRB stream subscription. Both must operate on the same ring buffer.
Using `OnceLock` in Rust gives us a process-wide singleton with zero overhead
on the hot path.

## Future evolution

- Phase 1: VAD + MFCC + spatial added in Rust; the stream emits richer event
  types (`VadEdge`, `OnsetDetected`, `SpatialEstimate`).
- Phase 5: C++ via NDK joins the stack. CMake builds `prism_native.so`; Dart
  calls it via `dart:ffi` for OpenCV/NCNN scene segmentation.
- Phase 6+: qdrant-edge sits in Dart space. EmbeddingGemma calls forward audio
  bytes from Dart to flutter_gemma; the embedding never leaves the device.
