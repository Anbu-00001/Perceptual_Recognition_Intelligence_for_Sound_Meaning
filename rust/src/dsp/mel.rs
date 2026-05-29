//! Mel filterbank + MFCC + delta + delta-delta.
//!
//! Configuration (locked for Phase 1 — change before LoRA fine-tune in Phase 9):
//!   - 64 mel bands from 20 Hz to 22 050 Hz
//!   - 13 cepstral coefficients (keeping c0, dropping nothing — see comment)
//!   - Δ + ΔΔ computed via simple symmetric differences across 5 frames
//!
//! Output dimensionality per frame: 39 (= 13 + 13 + 13). Hand to Gemma3n as a feature
//! vector alongside the raw audio for the slow path.

use super::fft::{NYQUIST_BIN, STFT_N};
use std::sync::OnceLock;

pub const N_MEL_BANDS: usize = 64;
pub const N_CEPSTRAL: usize = 13;
pub const SAMPLE_RATE_HZ: f32 = 48_000.0;
pub const MEL_FMIN_HZ: f32 = 20.0;
pub const MEL_FMAX_HZ: f32 = 22_050.0;

fn hz_to_mel(hz: f32) -> f32 {
    2595.0 * (1.0 + hz / 700.0).log10()
}

fn mel_to_hz(mel: f32) -> f32 {
    700.0 * (10f32.powf(mel / 2595.0) - 1.0)
}

/// Triangular mel filterbank weights: [N_MEL_BANDS][NYQUIST_BIN].
pub fn filterbank() -> &'static [Vec<f32>] {
    static FB: OnceLock<Vec<Vec<f32>>> = OnceLock::new();
    FB.get_or_init(|| {
        let mel_lo = hz_to_mel(MEL_FMIN_HZ);
        let mel_hi = hz_to_mel(MEL_FMAX_HZ);
        // N_MEL_BANDS + 2 mel points → N_MEL_BANDS triangles.
        let mel_points: Vec<f32> = (0..N_MEL_BANDS + 2)
            .map(|i| mel_lo + (mel_hi - mel_lo) * (i as f32) / (N_MEL_BANDS + 1) as f32)
            .collect();
        let hz_points: Vec<f32> = mel_points.iter().copied().map(mel_to_hz).collect();
        // Bin index for each Hz point (FFT bin spacing = sample_rate / STFT_N).
        let bin_of = |hz: f32| ((hz / SAMPLE_RATE_HZ) * STFT_N as f32) as usize;
        let bins: Vec<usize> = hz_points.iter().map(|&hz| bin_of(hz)).collect();

        let mut fb = vec![vec![0.0_f32; NYQUIST_BIN]; N_MEL_BANDS];
        for m in 0..N_MEL_BANDS {
            let lo = bins[m];
            let mid = bins[m + 1];
            let hi = bins[m + 2];
            // Rising side.
            for k in lo..mid.min(NYQUIST_BIN) {
                if mid > lo {
                    fb[m][k] = (k - lo) as f32 / (mid - lo) as f32;
                }
            }
            // Falling side.
            for k in mid..hi.min(NYQUIST_BIN) {
                if hi > mid {
                    fb[m][k] = (hi - k) as f32 / (hi - mid) as f32;
                }
            }
        }
        fb
    })
}

/// DCT-II basis cached: [N_CEPSTRAL][N_MEL_BANDS].
fn dct_basis() -> &'static [Vec<f32>] {
    static D: OnceLock<Vec<Vec<f32>>> = OnceLock::new();
    D.get_or_init(|| {
        let n = N_MEL_BANDS as f32;
        let mut d = vec![vec![0.0_f32; N_MEL_BANDS]; N_CEPSTRAL];
        for c in 0..N_CEPSTRAL {
            let norm = if c == 0 { (1.0 / n).sqrt() } else { (2.0 / n).sqrt() };
            for m in 0..N_MEL_BANDS {
                d[c][m] =
                    norm * ((std::f32::consts::PI / n) * (m as f32 + 0.5) * c as f32).cos();
            }
        }
        d
    })
}

/// Compute log-mel spectrum (length N_MEL_BANDS) from a magnitude spectrum.
pub fn log_mel(mag: &[f32]) -> [f32; N_MEL_BANDS] {
    let fb = filterbank();
    let mut out = [0.0_f32; N_MEL_BANDS];
    for m in 0..N_MEL_BANDS {
        let mut s = 0.0;
        let row = &fb[m];
        for k in 0..mag.len().min(NYQUIST_BIN) {
            s += row[k] * mag[k];
        }
        out[m] = (s + 1e-6).ln();
    }
    out
}

/// Compute MFCC (length N_CEPSTRAL) from log-mel.
pub fn mfcc(log_mel: &[f32; N_MEL_BANDS]) -> [f32; N_CEPSTRAL] {
    let d = dct_basis();
    let mut out = [0.0_f32; N_CEPSTRAL];
    for c in 0..N_CEPSTRAL {
        let mut s = 0.0;
        let row = &d[c];
        for m in 0..N_MEL_BANDS {
            s += row[m] * log_mel[m];
        }
        out[c] = s;
    }
    out
}

/// Δ (delta) of a series of frames using symmetric difference over ±2 frames.
/// frames[t] has length N. Output same shape. Border frames use one-sided.
pub fn delta(frames: &[[f32; N_CEPSTRAL]]) -> Vec<[f32; N_CEPSTRAL]> {
    let n = frames.len();
    let mut out = vec![[0.0_f32; N_CEPSTRAL]; n];
    let denom = 10.0_f32; // 2 * (1^2 + 2^2)
    for t in 0..n {
        for k in 0..N_CEPSTRAL {
            let mut s = 0.0;
            for tau in 1..=2 {
                let t_plus = (t + tau).min(n - 1);
                let t_minus = t.saturating_sub(tau);
                s += tau as f32 * (frames[t_plus][k] - frames[t_minus][k]);
            }
            out[t][k] = s / denom;
        }
    }
    out
}
