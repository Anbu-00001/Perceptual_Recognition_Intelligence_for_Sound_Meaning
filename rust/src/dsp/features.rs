//! Spectral and time-domain features derived per STFT frame.
//!
//! These are cheap descriptors that survive the fast-path: even when we don't escalate
//! to Gemma3n, the timeline gets these so a query over the longitudinal log can match
//! by acoustic signature, not just by embedding.

use super::fft::NYQUIST_BIN;

#[derive(Debug, Clone, Copy)]
pub struct SpectralSummary {
    pub centroid_hz: f32,
    pub rolloff_85_hz: f32,
    pub flatness: f32,
    /// Energy in 4 sub-bands: <500, 500-2k, 2k-6k, 6k-16k Hz.
    pub sub_band_energy: [f32; 4],
}

#[derive(Debug, Clone, Copy)]
pub struct TimeFeatures {
    pub rms: f32,
    pub peak_abs: f32,
    pub crest_factor: f32,
}

pub fn spectral_summary(mag: &[f32], sample_rate: f32) -> SpectralSummary {
    let n = mag.len().min(NYQUIST_BIN);
    let bin_hz = sample_rate / (2.0 * (n - 1) as f32);

    let mut energy_total = 0.0;
    let mut weighted = 0.0;
    let mut geo_log_sum = 0.0;
    let mut geo_n = 0;
    let mut sub = [0.0_f32; 4];
    let sub_edges = [500.0_f32, 2_000.0, 6_000.0, 16_000.0];

    for k in 1..n {
        let m = mag[k];
        let m2 = m * m;
        let f = k as f32 * bin_hz;
        energy_total += m2;
        weighted += f * m2;
        if m > 1e-9 {
            geo_log_sum += m.ln();
            geo_n += 1;
        }
        // Sub-band accumulators.
        let bi = match f {
            x if x < sub_edges[0] => 0,
            x if x < sub_edges[1] => 1,
            x if x < sub_edges[2] => 2,
            _ => 3,
        };
        sub[bi] += m2;
    }

    let centroid = if energy_total > 1e-9 { weighted / energy_total } else { 0.0 };

    // Rolloff: smallest f such that cumulative energy reaches 85%.
    let mut rolloff = 0.0;
    let threshold = 0.85 * energy_total;
    let mut cum = 0.0;
    for k in 1..n {
        let m = mag[k];
        cum += m * m;
        if cum >= threshold {
            rolloff = k as f32 * bin_hz;
            break;
        }
    }

    // Spectral flatness = exp(mean(log mag)) / mean(mag).
    let geo_mean = if geo_n > 0 { (geo_log_sum / geo_n as f32).exp() } else { 0.0 };
    let arith_mean = mag.iter().sum::<f32>() / mag.len() as f32;
    let flatness = if arith_mean > 1e-9 { geo_mean / arith_mean } else { 0.0 };

    SpectralSummary {
        centroid_hz: centroid,
        rolloff_85_hz: rolloff,
        flatness,
        sub_band_energy: sub,
    }
}

pub fn time_features(frame: &[f32]) -> TimeFeatures {
    let mut sum_sq = 0.0_f32;
    let mut peak = 0.0_f32;
    for &s in frame {
        sum_sq += s * s;
        let a = s.abs();
        if a > peak {
            peak = a;
        }
    }
    let rms = (sum_sq / frame.len() as f32).sqrt();
    let crest = if rms > 1e-9 { peak / rms } else { 0.0 };
    TimeFeatures { rms, peak_abs: peak, crest_factor: crest }
}

pub fn zero_crossing_rate(frame: &[f32]) -> f32 {
    if frame.len() < 2 {
        return 0.0;
    }
    let mut crossings = 0;
    for w in frame.windows(2) {
        if (w[0] >= 0.0) != (w[1] >= 0.0) {
            crossings += 1;
        }
    }
    crossings as f32 / (frame.len() - 1) as f32
}
