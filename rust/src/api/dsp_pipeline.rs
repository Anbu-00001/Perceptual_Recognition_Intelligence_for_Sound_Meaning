//! Phase 1 DSP pipeline runner.
//!
//! Owns a background thread that drains the global audio ring at ~20 ms cadence,
//! runs VAD per frame, STFT on 4096-sample windows with 512-sample hops, computes
//! features, runs onset detection and GCC-PHAT spatial, and pushes `DspEvent`s onto
//! a lock-free queue. Dart polls via `next_dsp_event()`.
//!
//! Audio segments around VAD/Onset events are captured to a side buffer keyed by
//! event id; Dart fetches them via `take_event_audio_16k(event_id)` for forwarding
//! to Gemma3n (which expects 16 kHz mono WAV).

use crate::dsp::fft::{magnitude_spectrum, pcm_to_f32, STFT_HOP, STFT_N};
use crate::dsp::features::{spectral_summary, time_features};
use crate::dsp::mel::{log_mel, mfcc, N_CEPSTRAL};
use crate::dsp::onset::OnsetDetector;
use crate::dsp::spatial::{estimate as spatial_estimate, SpatialZone};
use crate::dsp::vad::{VadConfig, VadEdge, VadStream};
use crate::ring;

use crossbeam_channel::{bounded, Receiver, Sender};
use flutter_rust_bridge::frb;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

const VAD_FRAME_LEN: usize = 960; // 20 ms @ 48 kHz mono
const SAMPLE_RATE: u32 = 48_000;
const SEGMENT_PRE_MS: u64 = 500;
const SEGMENT_POST_MS: u64 = 1500;
const HISTORY_SECONDS: usize = 3; // rolling mono buffer for grabbing segments

#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspEventKind {
    VadStart,
    VadEnd,
    Onset,
    PeriodicSnapshot,
}

#[frb(non_opaque)]
#[derive(Debug, Clone, Copy)]
pub enum Zone {
    Left,
    Center,
    Right,
    Unknown,
}

impl From<SpatialZone> for Zone {
    fn from(z: SpatialZone) -> Self {
        match z {
            SpatialZone::Left => Zone::Left,
            SpatialZone::Right => Zone::Right,
            SpatialZone::Center => Zone::Center,
        }
    }
}

#[frb(non_opaque)]
#[derive(Debug, Clone)]
pub struct DspEvent {
    pub event_id: u64,
    pub timestamp_ms: u64,
    pub kind: DspEventKind,

    pub mfcc: Vec<f32>,
    pub spectral_centroid_hz: f32,
    pub spectral_rolloff_hz: f32,
    pub spectral_flatness: f32,
    pub sub_band_energy: Vec<f32>,
    pub rms: f32,
    pub crest_factor: f32,

    pub zone: Zone,
    pub angle_deg: f32,
    pub spatial_confidence: f32,
}

static RUNNING: AtomicBool = AtomicBool::new(false);
static NEXT_EVENT_ID: AtomicU64 = AtomicU64::new(1);

fn channel() -> &'static (Sender<DspEvent>, Receiver<DspEvent>) {
    static C: OnceLock<(Sender<DspEvent>, Receiver<DspEvent>)> = OnceLock::new();
    C.get_or_init(|| bounded(1024))
}

fn segments() -> &'static Mutex<HashMap<u64, Vec<i16>>> {
    static S: OnceLock<Mutex<HashMap<u64, Vec<i16>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

fn start_instant() -> &'static Mutex<Option<Instant>> {
    static T: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(None))
}

#[frb(sync)]
pub fn start_dsp() -> Result<(), String> {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    *start_instant().lock() = Some(Instant::now());
    thread::Builder::new()
        .name("prism-dsp".into())
        .spawn(dsp_loop)
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[frb(sync)]
pub fn stop_dsp() {
    RUNNING.store(false, Ordering::SeqCst);
}

#[frb(sync)]
pub fn next_dsp_event() -> Option<DspEvent> {
    channel().1.try_recv().ok()
}

/// Pop the cached 16 kHz mono audio segment around an event.
/// Returns interleaved Int16 samples; empty if the segment has expired or never existed.
#[frb(sync)]
pub fn take_event_audio_16k(event_id: u64) -> Vec<i16> {
    segments().lock().remove(&event_id).unwrap_or_default()
}

fn dsp_loop() {
    let mut vad = VadStream::new(VadConfig::default());
    let mut onset = OnsetDetector::new();

    // 20 ms frame buffers (mono mixdown of stereo).
    let mut vad_buf = vec![0.0_f32; VAD_FRAME_LEN];

    // STFT sliding window of STFT_N mono samples.
    let mut stft_window_l = vec![0.0_f32; STFT_N];
    let mut stft_window_r = vec![0.0_f32; STFT_N];
    let mut stft_window_mono = vec![0.0_f32; STFT_N];
    let mut hop_accum: usize = 0;

    // Rolling history (mono i16 @ 48k) for cutting segments around events.
    let history_cap = SAMPLE_RATE as usize * HISTORY_SECONDS;
    let mut history_l: Vec<i16> = Vec::with_capacity(history_cap);
    let mut history_r: Vec<i16> = Vec::with_capacity(history_cap);

    // Interleaved scratch for ring drains.
    const DRAIN_INTERLEAVED: usize = VAD_FRAME_LEN * 2; // 20 ms stereo
    let mut drain = vec![0i16; DRAIN_INTERLEAVED];

    // Per-event "audio capture in progress" — collects post-event audio for SEGMENT_POST_MS.
    let mut pending_capture: Option<(u64, u64, usize)> = None;
    // (event_id, expiry_ms, samples_remaining_to_collect_mono_48k)

    // Periodic snapshot cadence: every ~500 ms.
    let mut last_snapshot = Instant::now();

    while RUNNING.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(20));
        let n = ring::pop_interleaved(&mut drain);
        if n < 2 {
            continue;
        }
        let usable = n & !1;
        let pairs = usable / 2;

        // Phase 2: feed the enrollment recorder iff Dart turned it on.
        crate::api::enrollment::pipeline_tap_push(&drain[..usable]);

        // Split L/R i16, append to history (with cap).
        for i in 0..pairs {
            history_l.push(drain[i * 2]);
            history_r.push(drain[i * 2 + 1]);
        }
        if history_l.len() > history_cap {
            let trim = history_l.len() - history_cap;
            history_l.drain(0..trim);
            history_r.drain(0..trim);
        }

        // Process in VAD_FRAME_LEN-sample chunks of MONO (L+R mixdown / 2).
        let mut mono = Vec::<f32>::with_capacity(pairs);
        for i in 0..pairs {
            let l = drain[i * 2] as f32 / 32768.0;
            let r = drain[i * 2 + 1] as f32 / 32768.0;
            mono.push((l + r) * 0.5);
        }

        // VAD: feed in 20 ms frames, save unconsumed tail for next round.
        let mut idx = 0;
        while idx + VAD_FRAME_LEN <= mono.len() {
            vad_buf.copy_from_slice(&mono[idx..idx + VAD_FRAME_LEN]);
            idx += VAD_FRAME_LEN;
            let edge = vad.push(&vad_buf);
            match edge {
                VadEdge::SpeechStart => emit_event(
                    DspEventKind::VadStart,
                    &vad_buf,
                    &history_l,
                    &history_r,
                    &mut pending_capture,
                ),
                VadEdge::SpeechEnd => emit_event(
                    DspEventKind::VadEnd,
                    &vad_buf,
                    &history_l,
                    &history_r,
                    &mut pending_capture,
                ),
                _ => {}
            }
        }

        // STFT hop accounting on the mono stream — slide window by 512 samples each.
        // (We push entire 'mono' Vec into the window via rotate.)
        for chunk in mono.chunks(STFT_HOP) {
            if chunk.len() < STFT_HOP {
                // Tail shorter than hop — accumulate into hop_accum (Phase 1 simplification: drop)
                hop_accum = 0;
                continue;
            }
            // Shift left by hop, append chunk.
            stft_window_mono.copy_within(STFT_HOP.., 0);
            stft_window_mono[(STFT_N - STFT_HOP)..].copy_from_slice(chunk);

            let mag = magnitude_spectrum(&stft_window_mono);

            // Onset detector.
            if let Some(intensity) = onset.push(&mag) {
                let lm = log_mel(&mag);
                let mfcc_v: Vec<f32> = mfcc(&lm).to_vec();
                let spec = spectral_summary(&mag, SAMPLE_RATE as f32);
                let tf = time_features(&stft_window_mono);

                let (zone, angle, conf) = compute_spatial(&history_l, &history_r);
                let event = build_event(
                    DspEventKind::Onset,
                    mfcc_v, spec, tf, zone, angle, conf,
                );
                queue_event(event, &history_l, &history_r, &mut pending_capture);
                let _ = intensity;
            }

            hop_accum = hop_accum.wrapping_add(1);
        }

        // Periodic snapshot every ~500 ms even when no event fires.
        if last_snapshot.elapsed() > Duration::from_millis(500) {
            last_snapshot = Instant::now();
            let mag = magnitude_spectrum(&stft_window_mono);
            let lm = log_mel(&mag);
            let mfcc_v: Vec<f32> = mfcc(&lm).to_vec();
            let spec = spectral_summary(&mag, SAMPLE_RATE as f32);
            let tf = time_features(&stft_window_mono);
            let (zone, angle, conf) = compute_spatial(&history_l, &history_r);
            let ev = build_event(
                DspEventKind::PeriodicSnapshot,
                mfcc_v, spec, tf, zone, angle, conf,
            );
            // Snapshots don't need captured audio.
            let _ = channel().0.try_send(ev);
        }

        // Finalize pending captures whose time is up.
        finalize_captures(&mut pending_capture, &history_l, &history_r);

        // Touch unused.
        let _ = stft_window_l.len();
        let _ = stft_window_r.len();
        let _ = pcm_to_f32;
    }
}

fn compute_spatial(history_l: &[i16], history_r: &[i16]) -> (Zone, f32, f32) {
    if history_l.len() < STFT_N {
        return (Zone::Unknown, 0.0, 0.0);
    }
    let start = history_l.len() - STFT_N;
    let l_slice: Vec<f32> = history_l[start..].iter().map(|s| *s as f32 / 32768.0).collect();
    let r_slice: Vec<f32> = history_r[start..].iter().map(|s| *s as f32 / 32768.0).collect();
    let est = spatial_estimate(&l_slice, &r_slice, SAMPLE_RATE as f32);
    (est.zone.into(), est.angle_deg, est.confidence)
}

fn build_event(
    kind: DspEventKind,
    mfcc_v: Vec<f32>,
    spec: crate::dsp::features::SpectralSummary,
    tf: crate::dsp::features::TimeFeatures,
    zone: Zone,
    angle: f32,
    conf: f32,
) -> DspEvent {
    let id = NEXT_EVENT_ID.fetch_add(1, Ordering::SeqCst);
    let ts_ms = start_instant()
        .lock()
        .map(|t| t.elapsed().as_millis() as u64)
        .unwrap_or(0);
    DspEvent {
        event_id: id,
        timestamp_ms: ts_ms,
        kind,
        mfcc: if mfcc_v.is_empty() { vec![0.0; N_CEPSTRAL] } else { mfcc_v },
        spectral_centroid_hz: spec.centroid_hz,
        spectral_rolloff_hz: spec.rolloff_85_hz,
        spectral_flatness: spec.flatness,
        sub_band_energy: spec.sub_band_energy.to_vec(),
        rms: tf.rms,
        crest_factor: tf.crest_factor,
        zone,
        angle_deg: angle,
        spatial_confidence: conf,
    }
}

fn emit_event(
    kind: DspEventKind,
    _frame: &[f32],
    history_l: &[i16],
    history_r: &[i16],
    pending: &mut Option<(u64, u64, usize)>,
) {
    let mag = vec![0.0_f32; 1]; // we don't recompute here — VAD events use the latest snapshot's features
    let spec = spectral_summary(&mag, SAMPLE_RATE as f32);
    let tf = crate::dsp::features::TimeFeatures { rms: 0.0, peak_abs: 0.0, crest_factor: 0.0 };
    let (zone, angle, conf) = compute_spatial(history_l, history_r);
    let ev = build_event(kind, vec![], spec, tf, zone, angle, conf);
    queue_event(ev, history_l, history_r, pending);
}

fn queue_event(
    ev: DspEvent,
    history_l: &[i16],
    history_r: &[i16],
    pending: &mut Option<(u64, u64, usize)>,
) {
    // Cut pre-roll mono audio (SEGMENT_PRE_MS) right now; post-roll added by finalize_captures.
    let pre_samples = (SAMPLE_RATE as u64 * SEGMENT_PRE_MS / 1000) as usize;
    let start = history_l.len().saturating_sub(pre_samples);
    let mut seg_48k_mono: Vec<i16> = Vec::with_capacity(pre_samples * 2);
    for i in start..history_l.len() {
        let m = ((history_l[i] as i32 + history_r[i] as i32) / 2) as i16;
        seg_48k_mono.push(m);
    }
    let event_id = ev.event_id;
    segments().lock().insert(event_id, seg_48k_mono);

    // Schedule post-roll collection.
    let now_ms = ev.timestamp_ms;
    let expiry_ms = now_ms + SEGMENT_POST_MS;
    let samples_remaining = (SAMPLE_RATE as u64 * SEGMENT_POST_MS / 1000) as usize;
    *pending = Some((event_id, expiry_ms, samples_remaining));

    let _ = channel().0.try_send(ev);
}

fn finalize_captures(
    pending: &mut Option<(u64, u64, usize)>,
    history_l: &[i16],
    history_r: &[i16],
) {
    let Some((event_id, expiry_ms, samples_remaining)) = *pending else { return };
    let now_ms = start_instant()
        .lock()
        .map(|t| t.elapsed().as_millis() as u64)
        .unwrap_or(0);
    let need_more = samples_remaining.min(SAMPLE_RATE as usize); // limit per tick
    let mono_count = (history_l.len()).min(need_more);
    {
        let mut segs = segments().lock();
        if let Some(buf) = segs.get_mut(&event_id) {
            let start = history_l.len().saturating_sub(mono_count);
            for i in start..history_l.len() {
                let m = ((history_l[i] as i32 + history_r[i] as i32) / 2) as i16;
                buf.push(m);
            }
            // Down-sample 48k → 16k by averaging triples (in-place rewrite).
            if now_ms >= expiry_ms {
                let mut downsampled = Vec::with_capacity(buf.len() / 3 + 1);
                let mut i = 0;
                while i + 3 <= buf.len() {
                    let avg = (buf[i] as i32 + buf[i + 1] as i32 + buf[i + 2] as i32) / 3;
                    downsampled.push(avg as i16);
                    i += 3;
                }
                *buf = downsampled;
            }
        }
    }
    if now_ms >= expiry_ms {
        *pending = None;
    }
}
