//! Onset detection via spectral flux.
//!
//! Whenever the half-wave-rectified frame-to-frame change in magnitude crosses an
//! adaptive threshold, we emit an Onset. Tuned for sharp transients (knock, doorbell,
//! tap, glass break) — Phase 1 focal categories per the Phase 1 enrolled-sound list.

use super::fft::NYQUIST_BIN;

pub struct OnsetDetector {
    prev_mag: Vec<f32>,
    flux_ema: f32,
    flux_var_ema: f32,
    cooldown_frames: usize,
    since_last_onset: usize,
}

impl OnsetDetector {
    pub fn new() -> Self {
        Self {
            prev_mag: vec![0.0_f32; NYQUIST_BIN],
            flux_ema: 0.0,
            flux_var_ema: 0.0,
            cooldown_frames: 6, // ~60 ms at hop=512 / 48 kHz
            since_last_onset: usize::MAX / 2,
        }
    }

    /// Push the latest magnitude spectrum, returns Some(intensity) if an onset fired.
    pub fn push(&mut self, mag: &[f32]) -> Option<f32> {
        let n = mag.len().min(self.prev_mag.len());
        let mut flux = 0.0_f32;
        for k in 0..n {
            let d = mag[k] - self.prev_mag[k];
            if d > 0.0 {
                flux += d;
            }
            self.prev_mag[k] = mag[k];
        }
        // Update EMA stats.
        let delta = flux - self.flux_ema;
        self.flux_ema += 0.05 * delta;
        let v_delta = delta * delta - self.flux_var_ema;
        self.flux_var_ema += 0.05 * v_delta;
        let sigma = self.flux_var_ema.sqrt();
        let threshold = self.flux_ema + 2.5 * sigma;

        self.since_last_onset = self.since_last_onset.saturating_add(1);
        if flux > threshold && self.since_last_onset > self.cooldown_frames {
            self.since_last_onset = 0;
            Some(flux)
        } else {
            None
        }
    }
}

impl Default for OnsetDetector {
    fn default() -> Self {
        Self::new()
    }
}
