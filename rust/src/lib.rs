//! PRISM DSP — Phase 0 skeleton.
//!
//! Two surfaces:
//!   1. The Dart-facing API in `api::` — generated bindings via flutter_rust_bridge v2.
//!   2. The native-facing FFI in `ffi::` — JNI (Android) and C-ABI (iOS) for pushing raw
//!      audio frames into the Rust ring buffer at hot-path latency.
//!
//! The hot audio path never crosses into Dart. Dart subscribes to *events*
//! (downsampled visualization frames in Phase 0, segmented DSP events from Phase 1+).

pub mod api;
pub mod ring;
pub mod ffi;

// flutter_rust_bridge generates this on first `codegen` run.
// The compiler will error until codegen has been run once; that's expected.
#[cfg(feature = "frb_generated")]
mod frb_generated;
