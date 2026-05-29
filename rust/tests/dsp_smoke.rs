//! Black-box smoke tests for the public DSP surface.
//! Run from the rust/ directory: `cargo test --test dsp_smoke`.

use prism_dsp::dsp::fft::{magnitude_spectrum, STFT_N};
use prism_dsp::dsp::features::{spectral_summary, time_features, zero_crossing_rate};
use prism_dsp::dsp::mel::{log_mel, mfcc, N_CEPSTRAL, N_MEL_BANDS};
use prism_dsp::dsp::onset::OnsetDetector;
use prism_dsp::dsp::spatial::{estimate as spatial_estimate, SpatialZone};

const SR: f32 = 48_000.0;

fn sine(freq: f32, n: usize, amp: f32) -> Vec<f32> {
    (0..n)
        .map(|i| amp * (2.0 * std::f32::consts::PI * freq * i as f32 / SR).sin())
        .collect()
}

fn silence(n: usize) -> Vec<f32> {
    vec![0.0_f32; n]
}

/// 1 kHz tone should produce a clear peak at bin ≈ 1000 / (48000/4096) ≈ 85.
#[test]
fn fft_peaks_match_pure_tone_frequency() {
    let frame = sine(1_000.0, STFT_N, 0.5);
    let mag = magnitude_spectrum(&frame);
    let expected_bin = (1000.0 / (SR / STFT_N as f32)) as usize;
    let (peak_bin, _) = mag
        .iter()
        .enumerate()
        .skip(1)
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap();
    assert!(
        (peak_bin as isize - expected_bin as isize).abs() <= 2,
        "FFT peak at bin {peak_bin}, expected ~{expected_bin}",
    );
}

#[test]
fn mfcc_dim_and_first_coeff_grow_with_energy() {
    let quiet = sine(500.0, STFT_N, 0.01);
    let loud = sine(500.0, STFT_N, 0.5);
    let mq = magnitude_spectrum(&quiet);
    let ml = magnitude_spectrum(&loud);
    let lmq = log_mel(&mq);
    let lml = log_mel(&ml);
    let cq = mfcc(&lmq);
    let cl = mfcc(&lml);
    assert_eq!(cq.len(), N_CEPSTRAL);
    assert_eq!(cl.len(), N_CEPSTRAL);
    assert_eq!(lmq.len(), N_MEL_BANDS);
    assert!(
        cl[0] > cq[0],
        "louder signal should have higher c0 (got loud {} vs quiet {})",
        cl[0], cq[0]
    );
}

#[test]
fn spectral_centroid_higher_for_higher_tone() {
    let low = sine(500.0, STFT_N, 0.5);
    let high = sine(8_000.0, STFT_N, 0.5);
    let ml = magnitude_spectrum(&low);
    let mh = magnitude_spectrum(&high);
    let sl = spectral_summary(&ml, SR);
    let sh = spectral_summary(&mh, SR);
    assert!(sh.centroid_hz > sl.centroid_hz);
    assert!(sh.centroid_hz > 4_000.0);
    assert!(sl.centroid_hz < 2_000.0);
}

#[test]
fn time_features_match_amplitude() {
    let s = sine(1_000.0, 4096, 0.3);
    let tf = time_features(&s);
    // RMS of a sine with amp A is A / sqrt(2) ≈ 0.212
    assert!((tf.rms - 0.212).abs() < 0.01, "rms={}", tf.rms);
    assert!((tf.peak_abs - 0.3).abs() < 0.001, "peak={}", tf.peak_abs);
    // Crest factor of a sine = peak/rms = sqrt(2) ≈ 1.414
    assert!((tf.crest_factor - 1.414).abs() < 0.02, "crest={}", tf.crest_factor);
}

#[test]
fn zcr_grows_with_frequency() {
    let low = sine(500.0, 4096, 0.5);
    let high = sine(8_000.0, 4096, 0.5);
    let zl = zero_crossing_rate(&low);
    let zh = zero_crossing_rate(&high);
    assert!(zh > zl, "high {} should exceed low {}", zh, zl);
    // 8 kHz sine ≈ 16k zero crossings/sec ÷ 48k samples = 0.333
    assert!((zh - 0.333).abs() < 0.02, "zcr={}", zh);
}

#[test]
fn onset_fires_on_amplitude_step() {
    let mut det = OnsetDetector::new();
    let quiet = sine(1_000.0, STFT_N, 0.01);
    let loud = sine(1_000.0, STFT_N, 0.5);

    // Warm up so the EMA settles low.
    for _ in 0..10 {
        let _ = det.push(&magnitude_spectrum(&quiet));
    }
    // Sudden jump in energy should fire at least once in the next few frames.
    let mut fired = false;
    for _ in 0..6 {
        if det.push(&magnitude_spectrum(&loud)).is_some() {
            fired = true;
            break;
        }
    }
    assert!(fired, "onset detector should fire on a hard amplitude step");
}

#[test]
fn onset_does_not_fire_on_steady_silence() {
    let mut det = OnsetDetector::new();
    let s = silence(STFT_N);
    for _ in 0..20 {
        assert!(det.push(&magnitude_spectrum(&s)).is_none());
    }
}

/// GCC-PHAT should detect the channel that leads. A pure tone with delay τ on
/// the right channel should yield a negative TDOA (right lags), which maps to
/// SpatialZone::Left (the source is on the LEFT speaker — left arrives first).
#[test]
fn gcc_phat_resolves_left_vs_right() {
    let n = STFT_N;
    let freq = 1_000.0;
    let delay_samples = 14_i32; // ≈ baseline at 10 cm / c
    let left: Vec<f32> = (0..n)
        .map(|i| 0.5 * (2.0 * std::f32::consts::PI * freq * i as f32 / SR).sin())
        .collect();
    let right: Vec<f32> = (0..n)
        .map(|i| {
            let idx = i as i32 - delay_samples;
            if idx < 0 {
                0.0
            } else {
                0.5 * (2.0 * std::f32::consts::PI * freq * idx as f32 / SR).sin()
            }
        })
        .collect();
    let est = spatial_estimate(&left, &right, SR);
    assert!(
        matches!(est.zone, SpatialZone::Left),
        "expected Left (source closer to L mic), got {:?} angle={} tdoa={}",
        est.zone, est.angle_deg, est.tdoa_samples
    );
}

#[test]
fn gcc_phat_resolves_center_for_identical_channels() {
    let n = STFT_N;
    let s: Vec<f32> = sine(1_000.0, n, 0.5);
    let est = spatial_estimate(&s, &s, SR);
    assert!(
        matches!(est.zone, SpatialZone::Center),
        "expected Center for identical channels, got {:?} angle={}",
        est.zone, est.angle_deg
    );
    assert_eq!(est.tdoa_samples, 0);
}
