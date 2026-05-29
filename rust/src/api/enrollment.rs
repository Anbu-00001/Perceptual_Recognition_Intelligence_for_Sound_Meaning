//! Phase 2 — Dart-facing enrollment helpers.
//!
//! Thin wrapper over `dsp::enrollment` exposed to Dart via flutter_rust_bridge.
//! Dart hands a freshly recorded 16 kHz mono clip (Int16List) in and gets back
//! a quality report plus an accept/reject decision tagged with the failing
//! gate so the UI can guide the user to re-record correctly.
//!
//! Why is this Rust and not Dart? Two reasons:
//!   1. The DSP primitives (ZCR, RMS over frame chunks) already live here —
//!      duplicating them in Dart would drift.
//!   2. A 4-second clip is 128 k samples; iterating it in Rust is ~10× faster
//!      than in Dart, which matters when the user is mid-flow and the UI
//!      needs to show a verdict within ~100 ms of stopping recording.

use crate::dsp::enrollment::{
    analyze_clip, ClipDecision, ClipQuality as RustQuality, EnrollmentGates,
    RejectReason as RustRejectReason, ENROLL_SR_HZ,
};
use flutter_rust_bridge::frb;
use parking_lot::Mutex;
use std::sync::OnceLock;

#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnrollRejectReason {
    TooShort,
    TooLong,
    TooQuiet,
    TooNoisy,
    Clipping,
    NoSignal,
}

impl From<RustRejectReason> for EnrollRejectReason {
    fn from(r: RustRejectReason) -> Self {
        match r {
            RustRejectReason::TooShort => Self::TooShort,
            RustRejectReason::TooLong => Self::TooLong,
            RustRejectReason::TooQuiet => Self::TooQuiet,
            RustRejectReason::TooNoisy => Self::TooNoisy,
            RustRejectReason::Clipping => Self::Clipping,
            RustRejectReason::NoSignal => Self::NoSignal,
        }
    }
}

#[frb(non_opaque)]
#[derive(Debug, Clone, Copy)]
pub struct EnrollClipReport {
    pub accepted: bool,
    pub reject_reason: Option<EnrollRejectReason>,

    pub duration_ms: u32,
    pub peak_dbfs: f32,
    pub rms_dbfs: f32,
    pub noise_floor_dbfs: f32,
    pub snr_db: f32,
    pub active_ratio: f32,
    pub clipping_ratio: f32,
    pub zcr: f32,
}

impl EnrollClipReport {
    fn from_parts(q: RustQuality, d: ClipDecision) -> Self {
        let (accepted, reject_reason) = match d {
            ClipDecision::Accept => (true, None),
            ClipDecision::Reject(r) => (false, Some(r.into())),
        };
        Self {
            accepted,
            reject_reason,
            duration_ms: q.duration_ms,
            peak_dbfs: q.peak_dbfs,
            rms_dbfs: q.rms_dbfs,
            noise_floor_dbfs: q.noise_floor_dbfs,
            snr_db: q.snr_db,
            active_ratio: q.active_ratio,
            clipping_ratio: q.clipping_ratio,
            zcr: q.zcr,
        }
    }
}

/// Analyze a 16 kHz mono i16 clip with default enrollment gates.
pub fn analyze_enrollment_clip_16k(samples: Vec<i16>) -> EnrollClipReport {
    let (q, d) = analyze_clip(&samples, &EnrollmentGates::default());
    EnrollClipReport::from_parts(q, d)
}

/// Analyze with custom gates (Phase 1 eval harness will sweep these).
/// Explicit-record buffer.
///
/// Used by the Phase 2 enrollment wizard: the user holds a Record button,
/// the pipeline is already running, and we want to grab the audio captured
/// while the button was held — not a VAD-bracketed segment.
///
/// The pipeline writes into this tap from its drain loop iff the tap is
/// active. We accumulate native-rate interleaved samples and only downmix +
/// downsample on stop, so the hot path stays branchless.
pub(crate) const NATIVE_SR_HZ: u32 = 48_000;
pub(crate) const DOWNSAMPLE_RATIO: usize = (NATIVE_SR_HZ / ENROLL_SR_HZ) as usize;

pub(crate) struct EnrollmentTap {
    pub interleaved_pairs: Vec<i16>,
    pub max_pairs: usize,
}

pub(crate) fn tap() -> &'static Mutex<Option<EnrollmentTap>> {
    static TAP: OnceLock<Mutex<Option<EnrollmentTap>>> = OnceLock::new();
    TAP.get_or_init(|| Mutex::new(None))
}

/// Begin a fresh enrollment recording. Idempotent: calling twice resets.
/// [max_duration_ms] caps memory; once the cap is hit the tap stops accepting
/// new samples but keeps everything captured so far.
pub fn enroll_recorder_start(max_duration_ms: u32) {
    let max_pairs =
        (NATIVE_SR_HZ as u64 * max_duration_ms as u64 / 1000) as usize;
    *tap().lock() = Some(EnrollmentTap {
        interleaved_pairs: Vec::with_capacity(max_pairs * 2),
        max_pairs,
    });
}

/// Stop recording and return the captured audio as 16 kHz mono i16.
/// Uses a stride-and-average resampler (3:1 at 48→16 kHz) — same scheme as
/// the segment-capture path in `dsp_pipeline` so any aliasing artifacts
/// are consistent across the codebase.
pub fn enroll_recorder_stop_take() -> Vec<i16> {
    let taken = tap().lock().take();
    let Some(t) = taken else { return Vec::new() };
    if t.interleaved_pairs.is_empty() {
        return Vec::new();
    }
    let pairs = t.interleaved_pairs.len() / 2;
    let mut mono48 = Vec::with_capacity(pairs);
    for i in 0..pairs {
        let l = t.interleaved_pairs[i * 2] as i32;
        let r = t.interleaved_pairs[i * 2 + 1] as i32;
        mono48.push(((l + r) / 2) as i16);
    }
    let mut mono16 = Vec::with_capacity(mono48.len() / DOWNSAMPLE_RATIO + 1);
    let mut idx = 0;
    while idx + DOWNSAMPLE_RATIO <= mono48.len() {
        let mut acc = 0i32;
        for k in 0..DOWNSAMPLE_RATIO {
            acc += mono48[idx + k] as i32;
        }
        mono16.push((acc / DOWNSAMPLE_RATIO as i32) as i16);
        idx += DOWNSAMPLE_RATIO;
    }
    mono16
}

/// Pipeline hook — called from `dsp_pipeline` on every drained interleaved
/// chunk. No-op when the tap is inactive (fast path).
pub(crate) fn pipeline_tap_push(interleaved: &[i16]) {
    let mut g = tap().lock();
    let Some(t) = g.as_mut() else { return };
    let remaining_pairs = t.max_pairs.saturating_sub(t.interleaved_pairs.len() / 2);
    if remaining_pairs == 0 {
        return;
    }
    let usable_pairs = interleaved.len() / 2;
    let pairs_to_take = usable_pairs.min(remaining_pairs);
    let take_samples = pairs_to_take * 2;
    t.interleaved_pairs.extend_from_slice(&interleaved[..take_samples]);
}

#[allow(clippy::too_many_arguments)]
pub fn analyze_enrollment_clip_16k_tuned(
    samples: Vec<i16>,
    min_duration_ms: u32,
    max_duration_ms: u32,
    min_snr_db: f32,
    min_active_ratio: f32,
    max_clipping_ratio: f32,
    min_peak_dbfs: f32,
) -> EnrollClipReport {
    let gates = EnrollmentGates {
        min_duration_ms,
        max_duration_ms,
        min_snr_db,
        min_active_ratio,
        max_clipping_ratio,
        min_peak_dbfs,
    };
    let (q, d) = analyze_clip(&samples, &gates);
    EnrollClipReport::from_parts(q, d)
}

#[cfg(test)]
mod tap_tests {
    use super::*;
    use std::sync::Mutex;

    // The tap is global state, so tests must serialize to keep `cargo test`
    // (which runs unit tests on multiple threads) from racing on it.
    static TAP_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        TAP_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn push_then_stop_downmixes_and_downsamples() {
        let _g = lock();
        // 1 second of interleaved stereo @ 48 kHz with L=+1000, R=-1000 →
        // mono mixdown = 0. After 3:1 average downsample we should see ~16k
        // samples of value 0 (with possibly one sample rounded off).
        enroll_recorder_start(2000);
        let pairs = 48_000;
        let mut pcm = Vec::with_capacity(pairs * 2);
        for _ in 0..pairs {
            pcm.push(1_000);
            pcm.push(-1_000);
        }
        pipeline_tap_push(&pcm);
        let out = enroll_recorder_stop_take();
        assert!(
            (15_950..=16_010).contains(&out.len()),
            "expected ~16000 mono samples after 48->16 kHz downmix, got {}",
            out.len()
        );
        // All samples should be exactly 0 — L+R cancel before resample.
        let any_nonzero = out.iter().any(|&s| s.abs() > 1);
        assert!(!any_nonzero, "downmix should cancel symmetric L/R");
    }

    #[test]
    fn push_respects_max_pairs_cap() {
        let _g = lock();
        enroll_recorder_start(100); // 4800 pairs @ 48 kHz
        let huge_pairs = 100_000; // way more than the cap
        let mut pcm = vec![0i16; huge_pairs * 2];
        for i in 0..huge_pairs {
            pcm[i * 2] = (i as i16).wrapping_mul(3);
            pcm[i * 2 + 1] = (i as i16).wrapping_mul(3);
        }
        pipeline_tap_push(&pcm);
        let out = enroll_recorder_stop_take();
        // 4800 native pairs → ~1600 mono samples at 16 kHz.
        assert!(
            (1_500..=1_700).contains(&out.len()),
            "cap should limit output to ~1600 samples; got {}",
            out.len()
        );
    }

    #[test]
    fn push_with_no_active_tap_is_a_noop() {
        let _g = lock();
        let _ = enroll_recorder_stop_take(); // ensure no tap
        pipeline_tap_push(&[1, 2, 3, 4]); // should not panic
    }

    #[test]
    fn multiple_pushes_accumulate() {
        let _g = lock();
        enroll_recorder_start(2000);
        let mut chunk = vec![0i16; 4800 * 2]; // 100 ms @ 48 kHz stereo
        for i in 0..chunk.len() {
            chunk[i] = if i % 2 == 0 { 5_000 } else { 5_000 };
        }
        pipeline_tap_push(&chunk);
        pipeline_tap_push(&chunk);
        let out = enroll_recorder_stop_take();
        // 9600 native pairs → ~3200 mono samples at 16 kHz.
        assert!(
            (3_100..=3_300).contains(&out.len()),
            "two 100ms pushes should yield ~3200 mono samples; got {}",
            out.len()
        );
        // Downmix of L=R=5000 is 5000, then 3:1 average is still ~5000.
        let avg = out.iter().map(|&s| s as i32).sum::<i32>() / out.len() as i32;
        assert!((4_900..=5_100).contains(&avg), "expected ~5000 avg, got {}", avg);
    }
}
