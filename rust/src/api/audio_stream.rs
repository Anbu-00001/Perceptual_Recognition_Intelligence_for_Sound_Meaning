//! Phase 0 — polled waveform frame access.
//!
//! Dart drives the visualization cadence at 30 fps via `Timer.periodic` and calls
//! `next_waveform_frame()`. Rust drains up to ~33 ms of audio from the ring buffer
//! and returns a decimated frame.
//!
//! Stream-based pushes (`StreamSink<WaveformFrame>`) come in Phase 1 once flutter_rust_bridge
//! codegen is wired and the generated `StreamSink` type is in scope.

use crate::ring;
use flutter_rust_bridge::frb;
use parking_lot::Mutex;
use std::sync::OnceLock;
use std::time::Instant;

/// One waveform frame for the UI scope.
#[frb(dart_metadata = ("freezed"))]
#[derive(Debug, Clone)]
pub struct WaveformFrame {
    pub timestamp_ms: u64,
    /// Decimated left channel, length ≤ `WAVEFORM_FRAME_LEN`.
    pub left: Vec<i16>,
    /// Decimated right channel, length ≤ `WAVEFORM_FRAME_LEN`.
    pub right: Vec<i16>,
    /// Peak absolute amplitude (0..32767) seen in this frame across both channels.
    pub peak: i16,
    /// Samples available in the ring buffer right now (interleaved count).
    pub ring_occupancy: u32,
}

pub const WAVEFORM_FRAME_LEN: usize = 512;

static START_INSTANT: OnceLock<Instant> = OnceLock::new();
static SCRATCH: OnceLock<Mutex<Vec<i16>>> = OnceLock::new();

fn scratch() -> &'static Mutex<Vec<i16>> {
    SCRATCH.get_or_init(|| Mutex::new(vec![0i16; 4096]))
}

/// Pop up to ~33 ms of interleaved samples and return a decimated waveform frame.
/// Returns None when the ring is empty (fewer than 2 samples available).
#[frb(sync)]
pub fn next_waveform_frame() -> Option<WaveformFrame> {
    let start = START_INSTANT.get_or_init(Instant::now);
    let mut scratch = scratch().lock();
    let n = ring::pop_interleaved(scratch.as_mut_slice());
    if n < 2 {
        return None;
    }
    // Ensure even (pairs of L/R).
    let usable = n & !1;
    let pairs = usable / 2;
    let step = (pairs as f32 / WAVEFORM_FRAME_LEN as f32).max(1.0);
    let mut left = Vec::with_capacity(WAVEFORM_FRAME_LEN);
    let mut right = Vec::with_capacity(WAVEFORM_FRAME_LEN);
    let mut peak: i16 = 0;
    for i in 0..WAVEFORM_FRAME_LEN {
        let idx = (i as f32 * step) as usize;
        if idx >= pairs {
            break;
        }
        let l = scratch[idx * 2];
        let r = scratch[idx * 2 + 1];
        left.push(l);
        right.push(r);
        let abs_l = l.saturating_abs();
        let abs_r = r.saturating_abs();
        if abs_l > peak {
            peak = abs_l;
        }
        if abs_r > peak {
            peak = abs_r;
        }
    }

    Some(WaveformFrame {
        timestamp_ms: start.elapsed().as_millis() as u64,
        left,
        right,
        peak,
        ring_occupancy: ring::available() as u32,
    })
}

#[frb(sync)]
pub fn ring_occupancy() -> u32 {
    ring::available() as u32
}
