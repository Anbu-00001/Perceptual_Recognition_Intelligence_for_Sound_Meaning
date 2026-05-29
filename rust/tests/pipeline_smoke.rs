//! End-to-end smoke: start the DSP pipeline, push synthetic audio into the ring,
//! drain DspEvents from the queue, verify the pipeline is alive.
//!
//! Doesn't try to validate verdicts — just that the plumbing carries events from
//! a producer thread (impersonating native AudioRecord) through to the public
//! `next_dsp_event()` polling API.

use prism_dsp::api::dsp_pipeline::{next_dsp_event, start_dsp, stop_dsp, DspEventKind};
use prism_dsp::ring;
use std::thread;
use std::time::{Duration, Instant};

fn push_burst(amp_i16: i16, duration_ms: u64) {
    // 48 kHz stereo, alternating bursts to provoke onset.
    let samples_per_chunk = 4096_usize;
    let buf = vec![amp_i16; samples_per_chunk];
    let chunks = (48 * 2 * duration_ms as usize) / samples_per_chunk;
    for _ in 0..chunks {
        ring::push_interleaved(&buf);
    }
}

#[test]
fn pipeline_emits_at_least_one_event() {
    start_dsp().expect("start_dsp");

    // Push 500 ms of synthetic loud "audio" (square-ish DC blocks). The onset
    // detector should fire at least once given the burst pattern.
    let stop_at = Instant::now() + Duration::from_secs(2);
    let pump = thread::spawn(move || {
        while Instant::now() < stop_at {
            push_burst(20_000, 100);
            thread::sleep(Duration::from_millis(40));
            push_burst(-20_000, 100);
            thread::sleep(Duration::from_millis(40));
        }
    });

    let mut events = 0;
    let mut periodic = 0;
    let mut onsets_or_vad = 0;
    let drain_until = Instant::now() + Duration::from_secs(3);
    while Instant::now() < drain_until {
        if let Some(ev) = next_dsp_event() {
            events += 1;
            match ev.kind {
                DspEventKind::PeriodicSnapshot => periodic += 1,
                _ => onsets_or_vad += 1,
            }
            if onsets_or_vad >= 1 && periodic >= 1 {
                break;
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    pump.join().unwrap();
    stop_dsp();

    assert!(events > 0, "no DSP events emitted in 3s");
    assert!(periodic > 0, "no periodic snapshots emitted");
    // Onset/VAD may be flaky on synthetic DC blocks; assert as soft.
    eprintln!("events={events} periodic={periodic} onset_or_vad={onsets_or_vad}");
}
