//! Phase 3 — Dart-facing room/zone classifier surface.
//!
//! Architecture:
//!   - Dart owns prototype storage (sidecar JSON, same pattern as Phase 2
//!     sound prototypes). On boot Dart calls `zone_set_prototypes(...)` with
//!     everything it knows. After every enrollment or deletion, Dart calls
//!     `zone_set_prototypes(...)` again — the call is idempotent.
//!   - Rust holds the active set in a static RwLock for the DSP loop to read
//!     on every event without synchronization stalls.
//!   - At enrollment time Dart records 30 s of ambient at 16 kHz mono and
//!     calls `zone_compute_feature(audio)` to get a 21-D centroid. Dart
//!     persists that centroid to the sidecar; on next boot it's pushed back
//!     via `zone_set_prototypes`.
//!   - Classification happens inside the DSP loop, NOT through this surface.
//!     Dart reads the result on `DspEvent.zone_label`.

use crate::dsp::zone::{
    centroid_from_features, zone_feature_from_audio, ZonePrototype as InnerProto,
    ZONE_FEATURE_DIM,
};
use flutter_rust_bridge::frb;
use parking_lot::RwLock;
use std::sync::OnceLock;

/// Sample rate Dart MUST resample enrollment audio to before calling
/// `zone_compute_feature`. Matches `analyze_enrollment_clip_16k`.
pub const ZONE_ENROLL_SR_HZ: u32 = 16_000;

/// Active prototype table — read on every DSP event, written rarely.
fn prototypes() -> &'static RwLock<Vec<InnerProto>> {
    static P: OnceLock<RwLock<Vec<InnerProto>>> = OnceLock::new();
    P.get_or_init(|| RwLock::new(Vec::new()))
}

/// Dart-facing prototype DTO. Uses a `Vec` of `f32` (rather than a fixed-size
/// array) because flutter_rust_bridge does not auto-generate Dart for raw
/// Rust arrays. The vector MUST have length `ZONE_FEATURE_DIM_OUT` (= 21);
/// other lengths are rejected at `zone_set_prototypes` time.
#[frb(non_opaque)]
#[derive(Debug, Clone)]
pub struct ZonePrototypeDto {
    pub id: String,
    pub label: String,
    pub centroid: Vec<f32>,
}

/// Read by Dart to verify against the dimension it stores.
#[frb(sync)]
pub fn zone_feature_dim() -> u32 {
    ZONE_FEATURE_DIM as u32
}

/// Replace the active prototype set. Returns the accepted count.
/// Prototypes with the wrong centroid length are silently dropped — log
/// the count mismatch on the Dart side if it matters.
#[frb(sync)]
pub fn zone_set_prototypes(items: Vec<ZonePrototypeDto>) -> u32 {
    let mut accepted: Vec<InnerProto> = Vec::with_capacity(items.len());
    for dto in items {
        if dto.centroid.len() != ZONE_FEATURE_DIM {
            continue;
        }
        let mut c = [0.0_f32; ZONE_FEATURE_DIM];
        c.copy_from_slice(&dto.centroid);
        accepted.push(InnerProto {
            id: dto.id,
            label: dto.label,
            centroid: c,
        });
    }
    let n = accepted.len();
    *prototypes().write() = accepted;
    n as u32
}

#[frb(sync)]
pub fn zone_clear_prototypes() {
    prototypes().write().clear();
}

#[frb(sync)]
pub fn zone_prototype_count() -> u32 {
    prototypes().read().len() as u32
}

/// Compute the 21-D acoustic fingerprint of a mono 16 kHz audio buffer.
/// Used at enrollment time: Dart records ~30 s of ambient, passes it here,
/// receives the centroid, persists it in the sidecar, and pushes the new
/// prototype set back via `zone_set_prototypes`.
///
/// The buffer SHOULD be at least 4096 samples (one STFT window at 16 kHz).
/// Shorter inputs return a zero vector — Dart should validate length and
/// surface a "recording too short" error before calling.
#[frb(sync)]
pub fn zone_compute_feature(samples_16k_mono: Vec<i16>) -> Vec<f32> {
    let f32_samples: Vec<f32> = samples_16k_mono.iter().map(|s| *s as f32 / 32768.0).collect();
    let feature = zone_feature_from_audio(&f32_samples, ZONE_ENROLL_SR_HZ as f32);
    feature.to_vec()
}

/// Aggregate a batch of per-window feature vectors into a single
/// L2-normalized centroid. Optional — Dart can also just average and
/// renormalize itself, but exposing it avoids float-precision drift
/// between Dart and Rust math.
#[frb(sync)]
pub fn zone_centroid_from_features(features: Vec<Vec<f32>>) -> Vec<f32> {
    let mut arrays: Vec<[f32; ZONE_FEATURE_DIM]> = Vec::with_capacity(features.len());
    for f in features {
        if f.len() != ZONE_FEATURE_DIM {
            continue;
        }
        let mut a = [0.0_f32; ZONE_FEATURE_DIM];
        a.copy_from_slice(&f);
        arrays.push(a);
    }
    centroid_from_features(&arrays).to_vec()
}

/// Snapshot the active prototype table — read by the DSP loop on every
/// classification. Cheap because RwLock readers don't block each other.
pub(crate) fn snapshot_prototypes() -> Vec<InnerProto> {
    prototypes().read().clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::zone::ZONE_FEATURE_DIM as DIM;

    #[test]
    fn set_then_count() {
        zone_clear_prototypes();
        let dto = ZonePrototypeDto {
            id: "kitchen".into(),
            label: "Kitchen".into(),
            centroid: vec![1.0_f32; DIM],
        };
        let accepted = zone_set_prototypes(vec![dto]);
        assert_eq!(accepted, 1);
        assert_eq!(zone_prototype_count(), 1);
        zone_clear_prototypes();
        assert_eq!(zone_prototype_count(), 0);
    }

    #[test]
    fn wrong_centroid_dim_is_silently_dropped() {
        zone_clear_prototypes();
        let bad = ZonePrototypeDto {
            id: "bad".into(),
            label: "Bad".into(),
            centroid: vec![0.0_f32; DIM + 1],
        };
        let accepted = zone_set_prototypes(vec![bad]);
        assert_eq!(accepted, 0);
    }

    #[test]
    fn compute_feature_returns_correct_dim() {
        let samples = vec![100_i16; 16_000];
        let f = zone_compute_feature(samples);
        assert_eq!(f.len(), DIM);
    }

    #[test]
    fn short_input_returns_zero_vector() {
        let samples = vec![100_i16; 100];
        let f = zone_compute_feature(samples);
        assert_eq!(f.len(), DIM);
        for v in f { assert_eq!(v, 0.0); }
    }
}
