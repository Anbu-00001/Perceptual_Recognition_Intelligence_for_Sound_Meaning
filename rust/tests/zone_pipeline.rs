//! End-to-end Phase 3 pipeline test.
//!
//! This goes one level deeper than the per-module unit tests:
//!   1. Start the real DSP loop (`start_dsp`).
//!   2. Push synthetic audio into the global ring on a producer thread.
//!   3. Use the real `zone_compute_feature` to derive a centroid from the
//!      same audio shape that's playing.
//!   4. Register that centroid as a prototype via `zone_set_prototypes`.
//!   5. Drain `next_dsp_event()` and assert that at least one event
//!      arrives with `zone_label == "TEST_ROOM"` and a confidence above
//!      the floor.
//!
//! This catches FFI-wiring bugs that the per-module unit tests miss —
//! e.g. the wiring missed by the cold-boot `ensureSynced` regression on
//! the Dart side. If `dsp_pipeline` ever stops calling the zone classifier
//! on snapshot/onset events, this test fails.
//!
//! Cargo test orchestration: this test serially manipulates global state
//! (the DSP RUNNING flag, the prototype table, the ring). Other tests in
//! `tests/` also touch the ring, so this file runs in its own binary.

use prism_dsp::api::dsp_pipeline::{
    next_dsp_event, start_dsp, stop_dsp, DspEventKind,
};
use prism_dsp::api::zone::{
    zone_clear_prototypes, zone_compute_feature, zone_prototype_count,
    zone_set_prototypes, ZonePrototypeDto,
};
use prism_dsp::ring;
use std::thread;
use std::time::{Duration, Instant};

/// Stride-and-average downsampler 48 k → 16 k. Same scheme the production
/// enrollment recorder uses (see `api/enrollment.rs::enroll_recorder_stop_take`).
fn downsample_48_to_16(mono_48k: &[i16]) -> Vec<i16> {
    let ratio = 3;
    let mut out = Vec::with_capacity(mono_48k.len() / ratio + 1);
    let mut i = 0;
    while i + ratio <= mono_48k.len() {
        let mut acc = 0_i32;
        for k in 0..ratio {
            acc += mono_48k[i + k] as i32;
        }
        out.push((acc / ratio as i32) as i16);
        i += ratio;
    }
    out
}

/// 5 s of a smooth, pitched sweep — varied enough to give the spectral
/// summary something interesting, stationary enough that the feature
/// extraction lands near the same centroid the running pipeline sees.
fn synthesize_room_audio_48k_stereo() -> Vec<i16> {
    let sr = 48_000_f32;
    let secs = 5.0;
    let n = (sr * secs) as usize;
    let mut out = Vec::with_capacity(n * 2);
    for i in 0..n {
        let t = i as f32 / sr;
        // Mix of three sines so MFCC / centroid features are non-trivial.
        let s = 0.10 * (2.0 * std::f32::consts::PI * 220.0 * t).sin()
            + 0.05 * (2.0 * std::f32::consts::PI * 740.0 * t).sin()
            + 0.03 * (2.0 * std::f32::consts::PI * 1600.0 * t).sin();
        let sample = (s * 16_000.0) as i16;
        out.push(sample); // L
        out.push(sample); // R (mono-replicated on purpose so the spatial
                          // path stays Unknown — we are NOT testing spatial here,
                          // we ARE testing zone classification from spectral features)
    }
    out
}

/// Push interleaved stereo at roughly real time (50 chunks of 20 ms each
/// per second). Anything much faster overruns the DSP loop's drain rate
/// and gets dropped by the ring.
fn pump_audio_realtime(audio: &[i16], total_ms: u64) {
    let chunk_pairs = 960; // 20 ms @ 48 k
    let chunk_len = chunk_pairs * 2;
    let total_chunks = (total_ms / 20) as usize;
    let mut cursor = 0_usize;
    for _ in 0..total_chunks {
        if cursor + chunk_len > audio.len() {
            cursor = 0;
        }
        ring::push_interleaved(&audio[cursor..cursor + chunk_len]);
        cursor += chunk_len;
        thread::sleep(Duration::from_millis(20));
    }
}

/// Single combined test — both cases share global state (the DSP RUNNING
/// flag, the global ring, the prototype table). Cargo parallelizes tests
/// in the same binary by default, and serializing via `--test-threads=1`
/// is hard to enforce in CI. Folding both assertions into one #[test]
/// removes the race entirely.
#[test]
fn dsp_pipeline_zone_classification_e2e() {
    zone_clear_prototypes();
    stop_dsp();
    thread::sleep(Duration::from_millis(50));

    // --- Phase A: classifier returns nothing without prototypes -------
    start_dsp().expect("start_dsp #1");
    while next_dsp_event().is_some() {}

    let stereo_a = synthesize_room_audio_48k_stereo();
    let pumper_a = thread::spawn(move || {
        pump_audio_realtime(&stereo_a, 1500);
    });

    let deadline_a = Instant::now() + Duration::from_secs(3);
    let mut any_classified_a = false;
    while Instant::now() < deadline_a {
        if let Some(ev) = next_dsp_event() {
            if !ev.zone_label.is_empty() && ev.zone_confidence > 0.0 {
                any_classified_a = true;
                break;
            }
        } else {
            thread::sleep(Duration::from_millis(30));
        }
    }
    pumper_a.join().unwrap();
    stop_dsp();
    assert!(
        !any_classified_a,
        "classifier emitted a zone label when no prototypes were registered \
         — confidence floor regression"
    );

    // --- Phase B: register prototype, classifier returns it -----------
    let stereo = synthesize_room_audio_48k_stereo();
    let mut mono_48k = Vec::with_capacity(stereo.len() / 2);
    let mut i = 0;
    while i + 1 < stereo.len() {
        let l = stereo[i] as i32;
        let r = stereo[i + 1] as i32;
        mono_48k.push(((l + r) / 2) as i16);
        i += 2;
    }
    let mono_16k = downsample_48_to_16(&mono_48k);
    let centroid = zone_compute_feature(mono_16k);
    assert!(
        centroid.iter().any(|v| v.abs() > 0.0),
        "centroid is all-zero — synth audio is below the STFT floor"
    );

    let accepted = zone_set_prototypes(vec![ZonePrototypeDto {
        id: "test_room".into(),
        label: "TEST_ROOM".into(),
        centroid,
    }]);
    assert_eq!(accepted, 1, "prototype rejected — dim mismatch?");
    assert_eq!(zone_prototype_count(), 1);

    start_dsp().expect("start_dsp #2");
    thread::sleep(Duration::from_millis(50));
    while next_dsp_event().is_some() {}

    let stereo_b = stereo.clone();
    let pumper_b = thread::spawn(move || {
        // Pump for longer — Helio-class CI runners are slow and the
        // STFT window only fills after the first second of audio. The
        // classifier needs at least one periodic snapshot to fire after
        // the window is primed.
        pump_audio_realtime(&stereo_b, 6000);
    });

    let deadline_b = Instant::now() + Duration::from_secs(8);
    let mut classified = 0_u32;
    let mut snapshots = 0_u32;
    let mut last_label = String::new();
    let mut last_conf = 0.0_f32;
    while Instant::now() < deadline_b {
        if let Some(ev) = next_dsp_event() {
            if ev.kind == DspEventKind::PeriodicSnapshot {
                snapshots += 1;
            }
            if !ev.zone_label.is_empty() && ev.zone_confidence > 0.0 {
                last_label = ev.zone_label.clone();
                last_conf = ev.zone_confidence;
                classified += 1;
                if classified >= 2 {
                    break;
                }
            }
        } else {
            thread::sleep(Duration::from_millis(30));
        }
    }
    pumper_b.join().unwrap();
    stop_dsp();
    zone_clear_prototypes();

    assert!(
        snapshots > 0,
        "no periodic snapshots emitted — pipeline never ran"
    );
    assert!(
        classified >= 1,
        "no event carried a classified zone in 8 s (snapshots={snapshots}, \
         last_label={last_label:?}, last_conf={last_conf})"
    );
    assert_eq!(
        last_label, "TEST_ROOM",
        "wrong zone classified (expected TEST_ROOM, got {last_label:?})"
    );
    assert!(
        last_conf > 0.5,
        "classified zone confidence too low: {last_conf}"
    );

    eprintln!(
        "[zone_pipeline] classified={classified} snapshots={snapshots} \
         label={last_label:?} conf={last_conf:.3}"
    );
}
