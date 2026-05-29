//! Phase 2 — public-surface enrollment recorder tests.
//!
//! These exercise the `enroll_recorder_start` / `enroll_recorder_stop_take`
//! contract that Dart drives. The data-path coverage
//! (`pipeline_tap_push`-style downmix + 3:1 resampler) lives in the
//! crate-internal `tap_tests` next to its implementation.
//!
//! The recorder is global state — all tests serialize through a single
//! file-scope mutex so `cargo test`'s multi-thread runner doesn't race.

use prism_dsp::api::enrollment::{
    enroll_recorder_start, enroll_recorder_stop_take,
};
use std::sync::Mutex;

static SERIAL: Mutex<()> = Mutex::new(());

fn lock() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn empty_stop_returns_empty_vec() {
    let _g = lock();
    enroll_recorder_start(2000);
    let out = enroll_recorder_stop_take();
    assert!(out.is_empty(), "stop without pushes should be empty");
}

#[test]
fn idempotent_start_resets_buffer() {
    let _g = lock();
    enroll_recorder_start(2000);
    enroll_recorder_start(2000); // second start drops anything prior
    let out = enroll_recorder_stop_take();
    assert!(out.is_empty());
}

#[test]
fn second_stop_after_drain_is_empty() {
    let _g = lock();
    enroll_recorder_start(2000);
    let _ = enroll_recorder_stop_take();
    let out = enroll_recorder_stop_take(); // no active tap
    assert!(out.is_empty());
}

#[test]
fn cap_at_max_duration_does_not_panic() {
    let _g = lock();
    enroll_recorder_start(100); // tiny cap, ~9600 i16 samples @ 16k mono
    let out = enroll_recorder_stop_take();
    assert!(out.is_empty());
}
