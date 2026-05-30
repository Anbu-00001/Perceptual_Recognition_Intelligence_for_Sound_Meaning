//! Room/zone classification by acoustic-fingerprint prototypes.
//!
//! Each room has a *stationary* sound signature: the HVAC's hum, the
//! refrigerator's compressor, the muffled traffic from one specific wall,
//! the reverberation pattern. Even a phone with one physical mic captures
//! enough of this to discriminate "kitchen" from "bedroom" from "entryway",
//! because it does NOT depend on phase between channels — only on the
//! magnitude-spectrum shape.
//!
//! Architecture mirrors Phase 2's sound prototypes: enrolment produces a
//! centroid feature vector, classification is argmax cosine similarity
//! over enrolled centroids. No NN training, no weight format. Drift
//! adaptation is deferred to Phase 9.
//!
//! Feature vector layout (21-D, all log-domain where appropriate so
//! amplitude differences across enrollments don't dominate):
//!
//!   `[mfcc_0 .. mfcc_12, log(centroid_hz+1), log(rolloff_hz+1),
//!     flatness, log(sub_band_0+ε) .. log(sub_band_3+ε), log(rms+ε)]`
//!
//! See `zone_feature_from_audio` for the canonical extractor — the same
//! routine is used at enrolment time *and* inference time. If you change
//! one, change the other.

use crate::dsp::features::{spectral_summary, time_features};
use crate::dsp::fft::{magnitude_spectrum, STFT_HOP, STFT_N};
use crate::dsp::mel::{log_mel, mfcc, N_CEPSTRAL};

/// Length of the room-fingerprint feature vector.
pub const ZONE_FEATURE_DIM: usize = N_CEPSTRAL + 3 + 4 + 1;
//                                   ^13       ^centroid,rolloff,flatness
//                                              ^sub-bands       ^rms

const EPS: f32 = 1e-6;

/// Compute the 21-D acoustic fingerprint of a short window of mono audio.
/// `samples` is f32 in [-1, 1] at any sample rate ≥ STFT_N; only the
/// first STFT_N samples are used. The mean of frame-level features across
/// all available windows is returned, so 1 sec of audio gives one vector.
pub fn zone_feature_from_audio(samples: &[f32], sample_rate: f32) -> [f32; ZONE_FEATURE_DIM] {
    let mut acc = [0.0_f32; ZONE_FEATURE_DIM];
    let mut n_windows = 0usize;

    let mut start = 0usize;
    while start + STFT_N <= samples.len() {
        let window = &samples[start..start + STFT_N];
        let mag = magnitude_spectrum(window);
        let lm = log_mel(&mag);
        let mfcc_v = mfcc(&lm);
        let spec = spectral_summary(&mag, sample_rate);
        let tf = time_features(window);

        // MFCCs (13)
        for (i, m) in mfcc_v.iter().enumerate().take(N_CEPSTRAL) {
            acc[i] += *m;
        }
        // Spectral scalars (3) — log-compressed so a quiet vs loud
        // enrolment from the same room still lands at the same point.
        acc[N_CEPSTRAL]     += (spec.centroid_hz + 1.0).ln();
        acc[N_CEPSTRAL + 1] += (spec.rolloff_85_hz + 1.0).ln();
        acc[N_CEPSTRAL + 2] += spec.flatness;
        // Sub-bands (4) — log energies.
        for (i, e) in spec.sub_band_energy.iter().enumerate() {
            acc[N_CEPSTRAL + 3 + i] += (e + EPS).ln();
        }
        // RMS (1)
        acc[ZONE_FEATURE_DIM - 1] += (tf.rms + EPS).ln();

        start += STFT_HOP;
        n_windows += 1;
    }

    if n_windows > 0 {
        let inv = 1.0 / n_windows as f32;
        for v in acc.iter_mut() {
            *v *= inv;
        }
    }
    acc
}

/// L2-normalize a feature vector in place. Cosine similarity uses
/// pre-normalized vectors so the inference dot product is a one-liner.
pub fn l2_normalize(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > EPS {
        let inv = 1.0 / norm;
        for x in v.iter_mut() {
            *x *= inv;
        }
    }
}

/// One enrolled room. The centroid is the L2-normalized mean of the
/// per-window feature vectors collected during enrolment.
#[derive(Debug, Clone)]
pub struct ZonePrototype {
    pub id: String,
    pub label: String,
    /// L2-normalized 21-D centroid.
    pub centroid: [f32; ZONE_FEATURE_DIM],
}

/// Outcome of a single classification.
#[derive(Debug, Clone)]
pub struct ZoneClassification {
    /// Best-matching label, or empty string when no prototype crossed the
    /// confidence floor (treat as "unknown room").
    pub label: String,
    pub id: String,
    /// 0..1. Cosine similarity in [-1, 1] mapped to [0, 1] via (1 + s) / 2.
    pub confidence: f32,
}

impl ZoneClassification {
    pub fn unknown() -> Self {
        Self {
            label: String::new(),
            id: String::new(),
            confidence: 0.0,
        }
    }
}

/// Minimum margin between best and second-best zone for the classifier to
/// commit to a label. A tight race is reported as unknown — it's better
/// to say nothing than to flicker between two rooms.
pub const MIN_MARGIN: f32 = 0.02;
/// Absolute confidence floor for any verdict.
pub const MIN_CONFIDENCE: f32 = 0.55;

/// Stateless classifier — pass in the current prototype table and a
/// feature vector, get a decision.
pub fn classify(feature: &[f32; ZONE_FEATURE_DIM], prototypes: &[ZonePrototype]) -> ZoneClassification {
    if prototypes.is_empty() {
        return ZoneClassification::unknown();
    }
    let mut feat_norm = *feature;
    l2_normalize(&mut feat_norm);

    let mut best_score = -2.0_f32;
    let mut best_idx = 0_usize;
    let mut second_score = -2.0_f32;
    for (i, p) in prototypes.iter().enumerate() {
        let mut s = 0.0_f32;
        for k in 0..ZONE_FEATURE_DIM {
            s += feat_norm[k] * p.centroid[k];
        }
        if s > best_score {
            second_score = best_score;
            best_score = s;
            best_idx = i;
        } else if s > second_score {
            second_score = s;
        }
    }

    let confidence = ((1.0 + best_score) * 0.5).clamp(0.0, 1.0);
    let margin = best_score - second_score;
    if confidence < MIN_CONFIDENCE || (prototypes.len() > 1 && margin < MIN_MARGIN) {
        return ZoneClassification::unknown();
    }
    ZoneClassification {
        label: prototypes[best_idx].label.clone(),
        id: prototypes[best_idx].id.clone(),
        confidence,
    }
}

/// Combine multiple per-window feature vectors into one normalized centroid.
/// Used at enrollment time to fold ~30 sec of ambient into a single point.
pub fn centroid_from_features(features: &[[f32; ZONE_FEATURE_DIM]]) -> [f32; ZONE_FEATURE_DIM] {
    let mut acc = [0.0_f32; ZONE_FEATURE_DIM];
    if features.is_empty() {
        return acc;
    }
    let inv = 1.0 / features.len() as f32;
    for f in features {
        for k in 0..ZONE_FEATURE_DIM {
            acc[k] += f[k] * inv;
        }
    }
    l2_normalize(&mut acc);
    acc
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn sine(freq: f32, n: usize, amp: f32, sr: f32) -> Vec<f32> {
        (0..n).map(|i| amp * (2.0 * PI * freq * i as f32 / sr).sin()).collect()
    }

    #[test]
    fn feature_dim_is_21() {
        assert_eq!(ZONE_FEATURE_DIM, 21);
    }

    #[test]
    fn empty_audio_returns_zero_vector() {
        let v = zone_feature_from_audio(&[], 16_000.0);
        for x in v.iter() {
            assert_eq!(*x, 0.0);
        }
    }

    #[test]
    fn same_room_features_are_close_different_rooms_are_not() {
        // "Room A": 200 Hz hum (refrigerator-ish).
        let a1 = sine(200.0, 32_000, 0.2, 16_000.0);
        let a2 = sine(200.0, 32_000, 0.2, 16_000.0);
        // "Room B": 1.5 kHz hiss (HVAC-ish).
        let b1 = sine(1_500.0, 32_000, 0.2, 16_000.0);

        let fa1 = zone_feature_from_audio(&a1, 16_000.0);
        let fa2 = zone_feature_from_audio(&a2, 16_000.0);
        let fb1 = zone_feature_from_audio(&b1, 16_000.0);

        let dot = |x: &[f32], y: &[f32]| -> f32 {
            let mut a = 0.0; let mut nx = 0.0; let mut ny = 0.0;
            for i in 0..x.len() { a += x[i]*y[i]; nx += x[i]*x[i]; ny += y[i]*y[i]; }
            a / (nx.sqrt() * ny.sqrt() + 1e-9)
        };
        let same = dot(&fa1, &fa2);
        let diff = dot(&fa1, &fb1);
        assert!(same > diff, "same={same} diff={diff}");
        assert!(same > 0.99, "same-room cosine should be near 1: {same}");
    }

    #[test]
    fn classify_returns_enrolled_label_for_matching_audio() {
        let room_a = sine(200.0, 32_000, 0.2, 16_000.0);
        let mut feat = zone_feature_from_audio(&room_a, 16_000.0);
        l2_normalize(&mut feat);
        let proto = ZonePrototype {
            id: "a".into(),
            label: "kitchen".into(),
            centroid: feat,
        };
        let probe = zone_feature_from_audio(&room_a, 16_000.0);
        let v = classify(&probe, &[proto]);
        assert_eq!(v.label, "kitchen");
        assert!(v.confidence > MIN_CONFIDENCE, "conf={}", v.confidence);
    }

    #[test]
    fn classify_returns_unknown_when_no_prototypes() {
        let probe = [0.5_f32; ZONE_FEATURE_DIM];
        let v = classify(&probe, &[]);
        assert!(v.label.is_empty());
        assert_eq!(v.confidence, 0.0);
    }

    #[test]
    fn classify_picks_the_closer_of_two_prototypes() {
        let room_a = sine(200.0, 32_000, 0.2, 16_000.0);
        let room_b = sine(2_000.0, 32_000, 0.2, 16_000.0);
        let mut fa = zone_feature_from_audio(&room_a, 16_000.0);
        let mut fb = zone_feature_from_audio(&room_b, 16_000.0);
        l2_normalize(&mut fa);
        l2_normalize(&mut fb);
        let protos = vec![
            ZonePrototype { id: "a".into(), label: "kitchen".into(), centroid: fa },
            ZonePrototype { id: "b".into(), label: "office".into(),  centroid: fb },
        ];
        // Probe is ROOM A.
        let probe = zone_feature_from_audio(&room_a, 16_000.0);
        let v = classify(&probe, &protos);
        assert_eq!(v.label, "kitchen");
    }

    #[test]
    fn centroid_from_features_normalizes() {
        let f = vec![[1.0_f32; ZONE_FEATURE_DIM]; 4];
        let c = centroid_from_features(&f);
        let norm: f32 = c.iter().map(|x| x*x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-5);
    }
}
