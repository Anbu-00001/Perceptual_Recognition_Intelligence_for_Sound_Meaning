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
pub mod dsp;

// flutter_rust_bridge codegen output. MUST be compiled into the cdylib —
// without it the .so ships zero `frbgen_prism_dsp_*` symbols and
// `RustLib.init()` fails on `Failed to lookup symbol 'frb_get_rust_content_hash'`.
// (Phase 0 used a `#[cfg(feature = "frb_generated")]` gate as a bootstrap so the
// crate compiled before codegen had ever run. Removed once codegen settled.)
mod frb_generated;
