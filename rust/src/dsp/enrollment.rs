//! Phase 2 — enrollment clip validators.
//!
//! Cheap quality gates applied to every recorded enrollment sample BEFORE we
//! ask Gemma3n to caption it. Rejecting bad clips up front saves NPU cycles
//! and prevents poisoned centroids in the personal library.
//!
//! Gate thresholds were chosen from FSD50K enrollment cleanup heuristics and
//! the speaker-verification literature (Centroid d-vector, Variani et al.).
//! Tunable: every threshold lives in `EnrollmentGates` so the Phase 1 eval
//! harness can A/B them against the kill/continue dataset without recompile.
//!
//! Input: 16 kHz mono i16 (this is the captured-segment format the
//! `dsp_pipeline` already produces via `take_event_audio_16k`).
//!
//! Output: `ClipQuality` (always populated) + `ClipDecision` (Accept/Reject)
//! with the specific gate that fired so the UI can give actionable feedback
//! ("too short", "clipping", "too quiet") rather than a generic "try again".

use super::features::zero_crossing_rate;

pub const ENROLL_SR_HZ: u32 = 16_000;
const NOISE_FLOOR_MS: u32 = 120;
const I16_MAX_F: f32 = 32_767.0;
const CLIP_THRESH: f32 = 0.985 * I16_MAX_F;

#[derive(Debug, Clone, Copy)]
pub struct EnrollmentGates {
    pub min_duration_ms: u32,
    pub max_duration_ms: u32,
    pub min_snr_db: f32,
    pub min_active_ratio: f32,
    pub max_clipping_ratio: f32,
    pub min_peak_dbfs: f32,
}

impl Default for EnrollmentGates {
    fn default() -> Self {
        Self {
            min_duration_ms: 500,
            max_duration_ms: 4_000,
            min_snr_db: 6.0,
            min_active_ratio: 0.30,
            max_clipping_ratio: 0.01,
            min_peak_dbfs: -28.0,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ClipQuality {
    pub duration_ms: u32,
    pub peak_dbfs: f32,
    pub rms_dbfs: f32,
    pub noise_floor_dbfs: f32,
    pub snr_db: f32,
    pub active_ratio: f32,
    pub clipping_ratio: f32,
    pub zcr: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    TooShort,
    TooLong,
    TooQuiet,
    TooNoisy,
    Clipping,
    NoSignal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipDecision {
    Accept,
    Reject(RejectReason),
}

pub fn analyze_clip(samples: &[i16], gates: &EnrollmentGates) -> (ClipQuality, ClipDecision) {
    let duration_ms = ((samples.len() as u64) * 1000 / ENROLL_SR_HZ as u64) as u32;

    if duration_ms < gates.min_duration_ms {
        return (
            empty_quality(duration_ms),
            ClipDecision::Reject(RejectReason::TooShort),
        );
    }
    if duration_ms > gates.max_duration_ms {
        return (
            empty_quality(duration_ms),
            ClipDecision::Reject(RejectReason::TooLong),
        );
    }

    let pcm_f32: Vec<f32> = samples.iter().map(|&s| s as f32 / I16_MAX_F).collect();
    let peak_abs = pcm_f32.iter().map(|x| x.abs()).fold(0.0_f32, f32::max);
    let rms = rms_of(&pcm_f32);
    let zcr = zero_crossing_rate(&pcm_f32);

    let clipping = samples
        .iter()
        .filter(|&&s| (s as f32).abs() >= CLIP_THRESH)
        .count() as f32
        / samples.len().max(1) as f32;

    let noise_window = (NOISE_FLOOR_MS as usize * ENROLL_SR_HZ as usize / 1000).min(samples.len());
    let noise_floor_rms = if noise_window > 0 {
        rms_of(&pcm_f32[..noise_window])
    } else {
        1e-9
    };

    // Active-frame ratio: 20 ms frames whose RMS exceeds 3x the noise floor.
    let frame_len = (ENROLL_SR_HZ / 50) as usize; // 320 samples = 20 ms @ 16 kHz
    let active_thresh = (noise_floor_rms * 3.0).max(1e-6);
    let mut active = 0;
    let mut total = 0;
    for chunk in pcm_f32.chunks(frame_len) {
        total += 1;
        if rms_of(chunk) > active_thresh {
            active += 1;
        }
    }
    let active_ratio = if total > 0 { active as f32 / total as f32 } else { 0.0 };

    let peak_dbfs = dbfs(peak_abs);
    let rms_dbfs = dbfs(rms);
    let noise_dbfs = dbfs(noise_floor_rms);
    let snr_db = rms_dbfs - noise_dbfs;

    let quality = ClipQuality {
        duration_ms,
        peak_dbfs,
        rms_dbfs,
        noise_floor_dbfs: noise_dbfs,
        snr_db,
        active_ratio,
        clipping_ratio: clipping,
        zcr,
    };

    let decision = if clipping > gates.max_clipping_ratio {
        ClipDecision::Reject(RejectReason::Clipping)
    } else if peak_dbfs < gates.min_peak_dbfs {
        ClipDecision::Reject(RejectReason::TooQuiet)
    } else if active_ratio < gates.min_active_ratio {
        ClipDecision::Reject(RejectReason::NoSignal)
    } else if snr_db < gates.min_snr_db {
        ClipDecision::Reject(RejectReason::TooNoisy)
    } else {
        ClipDecision::Accept
    };

    (quality, decision)
}

fn empty_quality(duration_ms: u32) -> ClipQuality {
    ClipQuality {
        duration_ms,
        peak_dbfs: -120.0,
        rms_dbfs: -120.0,
        noise_floor_dbfs: -120.0,
        snr_db: 0.0,
        active_ratio: 0.0,
        clipping_ratio: 0.0,
        zcr: 0.0,
    }
}

fn rms_of(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    let sum: f32 = x.iter().map(|v| v * v).sum();
    (sum / x.len() as f32).sqrt()
}

fn dbfs(x: f32) -> f32 {
    if x < 1e-9 {
        -120.0
    } else {
        20.0 * x.log10()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, ms: u32, amp_dbfs: f32) -> Vec<i16> {
        let n = (ENROLL_SR_HZ as u32 * ms / 1000) as usize;
        let amp = 10f32.powf(amp_dbfs / 20.0) * I16_MAX_F;
        (0..n)
            .map(|i| {
                let t = i as f32 / ENROLL_SR_HZ as f32;
                (amp * (2.0 * std::f32::consts::PI * freq * t).sin()) as i16
            })
            .collect()
    }

    #[test]
    fn accepts_clean_speech_like_burst() {
        // Filtered noise (low-pass via running mean) at -12 dBFS, 1 second
        let mut rng = 0xDEAD_BEEF_u32;
        let n = ENROLL_SR_HZ as usize;
        let mut raw: Vec<f32> = (0..n)
            .map(|_| {
                rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
                (rng as i32 as f32) / i32::MAX as f32
            })
            .collect();
        // 3-tap LPF to land ZCR in the speech band
        for i in 1..n - 1 {
            raw[i] = (raw[i - 1] + raw[i] + raw[i + 1]) / 3.0;
        }
        // Add 100ms of true-silence headroom at the very start so the noise
        // floor measurement is genuinely quiet relative to the rest.
        let noise_n = (ENROLL_SR_HZ as usize * 120) / 1000;
        for s in raw.iter_mut().take(noise_n) {
            *s *= 0.001;
        }
        let amp = 10f32.powf(-12.0 / 20.0) * I16_MAX_F;
        let pcm: Vec<i16> = raw.iter().map(|v| (v * amp).clamp(-I16_MAX_F, I16_MAX_F) as i16).collect();
        let (q, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert_eq!(d, ClipDecision::Accept, "quality={:?}", q);
        assert!(q.snr_db > 6.0, "snr_db={}", q.snr_db);
    }

    #[test]
    fn rejects_too_short() {
        let pcm = sine(1000.0, 200, -12.0); // 200 ms < 500 ms gate
        let (_, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert_eq!(d, ClipDecision::Reject(RejectReason::TooShort));
    }

    #[test]
    fn rejects_too_long() {
        let pcm = sine(1000.0, 5_000, -12.0); // 5 s > 4 s gate
        let (_, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert_eq!(d, ClipDecision::Reject(RejectReason::TooLong));
    }

    #[test]
    fn rejects_clipping() {
        // Pure sine at 0 dBFS will fully saturate.
        let pcm = sine(1000.0, 1_500, 0.0);
        let (_, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert_eq!(d, ClipDecision::Reject(RejectReason::Clipping));
    }

    #[test]
    fn rejects_too_quiet() {
        let pcm = sine(1000.0, 1_500, -45.0);
        let (_, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert_eq!(d, ClipDecision::Reject(RejectReason::TooQuiet));
    }

    #[test]
    fn rejects_no_signal_silence() {
        let pcm = vec![0_i16; ENROLL_SR_HZ as usize]; // 1 s of pure silence
        let (_, d) = analyze_clip(&pcm, &EnrollmentGates::default());
        assert!(matches!(
            d,
            ClipDecision::Reject(RejectReason::TooQuiet | RejectReason::NoSignal)
        ));
    }
}
