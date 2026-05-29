//! GCC-PHAT for stereo TDOA estimation → left/right/center angle.
//!
//! Phone mic baseline is 8–15 cm depending on device — at the upper limit of the
//! range that GCC-PHAT works for. We DON'T attempt to estimate elevation or
//! distance, only left/center/right (binned into 3 classes for Phase 1).
//!
//! Pipeline:
//!   1. Take 4096-sample window per channel.
//!   2. Window + FFT each channel.
//!   3. Cross-spectrum X1 · conj(X2), normalized by |·| (the PHAT weighting).
//!   4. IFFT → cross-correlation in time domain.
//!   5. Find peak argmax → sample offset.
//!   6. Convert offset to angle assuming a known baseline.

use super::fft::{complex_spectrum, NYQUIST_BIN, STFT_N};
use num_complex::Complex32;
use parking_lot::Mutex;
use realfft::{ComplexToReal, RealFftPlanner};
use std::sync::Arc;
use std::sync::OnceLock;

/// Phone stereo baseline used to convert TDOA → angle. We default to 10 cm but
/// expose a setter for calibration.
static BASELINE_M: parking_lot::RwLock<f32> = parking_lot::RwLock::new(0.10);
const SPEED_OF_SOUND_MS: f32 = 343.0;

pub fn set_baseline_meters(b: f32) {
    *BASELINE_M.write() = b.max(0.02);
}

struct IfftPlanner {
    ifft: Arc<dyn ComplexToReal<f32>>,
    scratch: Vec<Complex32>,
}

fn ifft_planner() -> &'static Mutex<IfftPlanner> {
    static P: OnceLock<Mutex<IfftPlanner>> = OnceLock::new();
    P.get_or_init(|| {
        let mut planner = RealFftPlanner::<f32>::new();
        let ifft = planner.plan_fft_inverse(STFT_N);
        let scratch_len = ifft.get_scratch_len();
        Mutex::new(IfftPlanner {
            ifft,
            scratch: vec![Complex32::new(0.0, 0.0); scratch_len],
        })
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpatialZone {
    Left,
    Center,
    Right,
    /// Cannot localize — channels are identical (phone with one mic), too quiet,
    /// or GCC-PHAT confidence below the minimum. Surfaced separately from
    /// `Center` so the UI doesn't claim "sound source dead ahead" when really
    /// the hardware can't tell.
    Unknown,
}

#[derive(Debug, Clone, Copy)]
pub struct SpatialEstimate {
    pub zone: SpatialZone,
    /// Estimated angle in degrees, -90 (hard left) .. 0 (center) .. +90 (hard right).
    /// 0.0 when `zone == Unknown`.
    pub angle_deg: f32,
    /// 0..1 confidence (peak prominence / mean magnitude). 0.0 when Unknown.
    pub confidence: f32,
    /// Sample offset that won the argmax (sign = which channel led).
    pub tdoa_samples: i32,
    /// True when the two channels carry essentially identical samples — i.e.,
    /// the device hardware is one mic replicated, so any GCC-PHAT result would
    /// be noise. Computed before the FFT; cheap.
    pub mono_replicated: bool,
}

/// L vs R difference RMS. Used to detect mono-replicated stereo (single-mic
/// phones like the OPPO A18 report both channels but they're bit-identical).
/// Returns 0 if the two slices are the same length and equal sample-by-sample.
pub fn channel_difference_rms(left: &[f32], right: &[f32]) -> f32 {
    let n = left.len().min(right.len());
    if n == 0 {
        return 0.0;
    }
    let mut sum_sq = 0.0_f32;
    for i in 0..n {
        let d = left[i] - right[i];
        sum_sq += d * d;
    }
    (sum_sq / n as f32).sqrt()
}

/// Threshold below which we treat L/R as effectively identical. ~ -60 dBFS
/// for 32-bit floats normalized to [-1, 1] — sets a floor that absorbs
/// quantization noise from i16 → f32 conversion but rejects real stereo.
pub const MONO_REPLICATED_THRESHOLD: f32 = 1e-3;

/// Minimum confidence for a non-Unknown verdict. Tuned during the eval
/// harness against held-out spatial recordings; below this the angle is
/// dominated by the mean lobe of the cross-correlation.
pub const MIN_CONFIDENCE: f32 = 0.15;

/// Run GCC-PHAT on a stereo pair. Both frames must be STFT_N long.
pub fn estimate(left: &[f32], right: &[f32], sample_rate: f32) -> SpatialEstimate {
    assert_eq!(left.len(), STFT_N);
    assert_eq!(right.len(), STFT_N);

    // Early-out: if the channels are bit-identical (or near it), GCC-PHAT will
    // place the peak at lag=0 with near-1.0 confidence — falsely reporting
    // a strong centered source. Detect and return Unknown instead.
    let diff_rms = channel_difference_rms(left, right);
    if diff_rms < MONO_REPLICATED_THRESHOLD {
        return SpatialEstimate {
            zone: SpatialZone::Unknown,
            angle_deg: 0.0,
            confidence: 0.0,
            tdoa_samples: 0,
            mono_replicated: true,
        };
    }

    let xl = complex_spectrum(left);
    let xr = complex_spectrum(right);

    // PHAT: cross-spectrum / |cross-spectrum|.
    let mut x: Vec<Complex32> = (0..NYQUIST_BIN)
        .map(|k| {
            let c = xl[k] * xr[k].conj();
            let m = c.norm();
            if m > 1e-9 { c / m } else { Complex32::new(0.0, 0.0) }
        })
        .collect();

    let mut time: Vec<f32> = vec![0.0_f32; STFT_N];
    let mut p = ifft_planner().lock();
    let ifft = Arc::clone(&p.ifft);
    let scratch = &mut p.scratch;
    ifft.process_with_scratch(&mut x, &mut time, scratch)
        .expect("ifft");

    // Find max-magnitude over a plausible lag window. For 10 cm baseline at 48 kHz:
    // max delay = baseline / c = 0.10/343 = 0.291 ms = 14 samples. Pad to ±30 for slack.
    let max_lag_samples = ((*BASELINE_M.read() / SPEED_OF_SOUND_MS) * sample_rate) as i32 + 8;
    let n = STFT_N as i32;

    let mut best_lag = 0_i32;
    let mut best_val = f32::MIN;
    let mut sum_abs = 0.0_f32;
    let mut count = 0_i32;

    for lag in -max_lag_samples..=max_lag_samples {
        let idx = ((lag + n) % n) as usize;
        let v = time[idx];
        sum_abs += v.abs();
        count += 1;
        if v > best_val {
            best_val = v;
            best_lag = lag;
        }
    }
    let mean_abs = if count > 0 { sum_abs / count as f32 } else { 1e-9 };
    let confidence = (best_val / (mean_abs + 1e-9)).clamp(0.0, 5.0) / 5.0;

    // tdoa seconds → angle.
    let tdoa_s = best_lag as f32 / sample_rate;
    let max_tdoa = *BASELINE_M.read() / SPEED_OF_SOUND_MS;
    let sin_theta = (tdoa_s / max_tdoa).clamp(-1.0, 1.0);
    let angle_deg = sin_theta.asin().to_degrees();

    let zone = if confidence < MIN_CONFIDENCE {
        SpatialZone::Unknown
    } else if angle_deg < -15.0 {
        SpatialZone::Left
    } else if angle_deg > 15.0 {
        SpatialZone::Right
    } else {
        SpatialZone::Center
    };

    SpatialEstimate {
        zone,
        angle_deg: if zone == SpatialZone::Unknown { 0.0 } else { angle_deg },
        confidence,
        tdoa_samples: best_lag,
        mono_replicated: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_channels_yield_unknown_zone_not_center() {
        let buf: Vec<f32> = (0..STFT_N).map(|i| (i as f32 / 100.0).sin()).collect();
        let est = estimate(&buf, &buf, 48_000.0);
        assert_eq!(est.zone, SpatialZone::Unknown,
            "identical L/R must be Unknown; was {:?}", est.zone);
        assert!(est.mono_replicated);
    }

    #[test]
    fn channel_difference_rms_zero_for_identical() {
        let buf: Vec<f32> = (0..1000).map(|i| i as f32).collect();
        assert_eq!(channel_difference_rms(&buf, &buf), 0.0);
    }

    #[test]
    fn channel_difference_rms_positive_for_phase_shift() {
        let a: Vec<f32> = (0..1000).map(|i| (i as f32 * 0.01).sin()).collect();
        let mut b = a.clone();
        // Shift b by 5 samples — different but correlated.
        b.rotate_right(5);
        assert!(channel_difference_rms(&a, &b) > 0.001);
    }
}
