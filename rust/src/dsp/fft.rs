//! Windowed real-FFT with a planner cache.
//!
//! Phase 1 uses 4096-point Hann-windowed STFT at 48 kHz mono. The cached planner
//! avoids per-call setup cost (rustfft's planner is expensive to construct).

use num_complex::Complex32;
use parking_lot::Mutex;
use realfft::{RealFftPlanner, RealToComplex};
use std::sync::Arc;
use std::sync::OnceLock;

pub const STFT_N: usize = 4096;
pub const STFT_HOP: usize = 512;
pub const NYQUIST_BIN: usize = STFT_N / 2 + 1;

/// Hann window of length [STFT_N].
pub fn hann_window() -> &'static [f32] {
    static W: OnceLock<Vec<f32>> = OnceLock::new();
    W.get_or_init(|| apodize::hanning_iter(STFT_N).map(|x| x as f32).collect())
}

struct Planner {
    fft: Arc<dyn RealToComplex<f32>>,
    scratch: Vec<Complex32>,
}

fn planner() -> &'static Mutex<Planner> {
    static P: OnceLock<Mutex<Planner>> = OnceLock::new();
    P.get_or_init(|| {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(STFT_N);
        let scratch_len = fft.get_scratch_len();
        Mutex::new(Planner {
            fft,
            scratch: vec![Complex32::new(0.0, 0.0); scratch_len],
        })
    })
}

/// Compute magnitude spectrum of one mono frame of [STFT_N] samples (`f32`, ±1.0).
///
/// Returns [NYQUIST_BIN] magnitudes. Input is window-applied; caller passes raw samples.
pub fn magnitude_spectrum(frame: &[f32]) -> Vec<f32> {
    assert_eq!(frame.len(), STFT_N);
    let window = hann_window();
    let mut input: Vec<f32> = frame.iter().zip(window).map(|(&x, &w)| x * w).collect();
    let mut output: Vec<Complex32> = vec![Complex32::new(0.0, 0.0); NYQUIST_BIN];

    let mut p = planner().lock();
    let fft = Arc::clone(&p.fft);
    let scratch = &mut p.scratch;
    fft.process_with_scratch(&mut input, &mut output, scratch)
        .expect("rfft");

    output.iter().map(|c| c.norm()).collect()
}

/// Complex spectrum (used by spatial GCC-PHAT). Returns [NYQUIST_BIN] complex bins.
pub fn complex_spectrum(frame: &[f32]) -> Vec<Complex32> {
    assert_eq!(frame.len(), STFT_N);
    let window = hann_window();
    let mut input: Vec<f32> = frame.iter().zip(window).map(|(&x, &w)| x * w).collect();
    let mut output: Vec<Complex32> = vec![Complex32::new(0.0, 0.0); NYQUIST_BIN];

    let mut p = planner().lock();
    let fft = Arc::clone(&p.fft);
    let scratch = &mut p.scratch;
    fft.process_with_scratch(&mut input, &mut output, scratch)
        .expect("rfft");
    output
}

/// Convert i16 PCM samples to f32 in [-1, 1] without allocation when used in-place.
pub fn pcm_to_f32(pcm: &[i16], out: &mut [f32]) {
    debug_assert_eq!(pcm.len(), out.len());
    for (s, o) in pcm.iter().zip(out.iter_mut()) {
        *o = *s as f32 / 32768.0;
    }
}
