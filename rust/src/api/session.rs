//! Session recording — writes captured audio + IMU to disk for later analysis.
//!
//! Phase 0: record-to-file functionality so the acceptance test can verify the captured
//! `.wav` plays back correctly and the IMU CSV is at the expected rate.

use crate::ring;
use flutter_rust_bridge::frb;
use hound::{SampleFormat, WavSpec, WavWriter};
use parking_lot::Mutex;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

struct SessionState {
    wav_writer: Option<WavWriter<BufWriter<File>>>,
    imu_writer: Option<BufWriter<File>>,
    wav_path: Option<PathBuf>,
    imu_path: Option<PathBuf>,
}

static STATE: OnceLock<Mutex<SessionState>> = OnceLock::new();
static RECORDING: AtomicBool = AtomicBool::new(false);

fn state() -> &'static Mutex<SessionState> {
    STATE.get_or_init(|| {
        Mutex::new(SessionState {
            wav_writer: None,
            imu_writer: None,
            wav_path: None,
            imu_path: None,
        })
    })
}

#[frb(sync)]
pub fn start_session(documents_dir: String, ts_label: String) -> Result<SessionPaths, String> {
    if RECORDING.load(Ordering::SeqCst) {
        return Err("session already running".into());
    }
    let dir = PathBuf::from(&documents_dir).join("sessions");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let wav_path = dir.join(format!("session_{}.wav", ts_label));
    let imu_path = dir.join(format!("imu_{}.csv", ts_label));

    let spec = WavSpec {
        channels: ring::CHANNELS as u16,
        sample_rate: ring::SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };
    let wav = WavWriter::create(&wav_path, spec).map_err(|e| e.to_string())?;
    let imu_file = File::create(&imu_path).map_err(|e| e.to_string())?;
    let mut imu = BufWriter::new(imu_file);
    writeln!(imu, "ts_ns,ax,ay,az,gx,gy,gz").map_err(|e| e.to_string())?;

    let mut s = state().lock();
    s.wav_writer = Some(wav);
    s.imu_writer = Some(imu);
    s.wav_path = Some(wav_path.clone());
    s.imu_path = Some(imu_path.clone());

    RECORDING.store(true, Ordering::SeqCst);

    thread::Builder::new()
        .name("prism-session-wav".into())
        .spawn(wav_drain_loop)
        .map_err(|e| e.to_string())?;

    Ok(SessionPaths {
        wav_path: wav_path.to_string_lossy().to_string(),
        imu_path: imu_path.to_string_lossy().to_string(),
    })
}

#[frb(sync)]
pub fn stop_session() -> Result<SessionPaths, String> {
    if !RECORDING.swap(false, Ordering::SeqCst) {
        return Err("no session running".into());
    }
    // Let the drain loop flush.
    thread::sleep(Duration::from_millis(150));
    let mut s = state().lock();
    if let Some(w) = s.wav_writer.take() {
        w.finalize().map_err(|e| e.to_string())?;
    }
    if let Some(mut w) = s.imu_writer.take() {
        let _ = w.flush();
    }
    Ok(SessionPaths {
        wav_path: s
            .wav_path
            .clone()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default(),
        imu_path: s
            .imu_path
            .clone()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default(),
    })
}

/// Called from the native IMU sample callback. Appends one row to the CSV.
pub fn append_imu_sample(ts_ns: u64, ax: f32, ay: f32, az: f32, gx: f32, gy: f32, gz: f32) {
    if !RECORDING.load(Ordering::SeqCst) {
        return;
    }
    let mut s = state().lock();
    if let Some(w) = s.imu_writer.as_mut() {
        let _ = writeln!(
            w, "{},{:.6},{:.6},{:.6},{:.6},{:.6},{:.6}", ts_ns, ax, ay, az, gx, gy, gz
        );
    }
}

fn wav_drain_loop() {
    // We share the consumer with the waveform stream via a tee — Phase 0 keeps it simple:
    // the WAV writer reads directly from the ring at a moderate cadence so we don't starve
    // the visualization. In Phase 1 this becomes a proper fan-out.
    //
    // For now: small periodic drains, sized below the FFT window we'll need later.
    const DRAIN_INTERLEAVED: usize = 9_600; // 100ms at 48kHz stereo
    let mut buf = vec![0i16; DRAIN_INTERLEAVED];

    while RECORDING.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(50));
        let n = ring::pop_interleaved(&mut buf);
        if n == 0 {
            continue;
        }
        let mut s = state().lock();
        if let Some(w) = s.wav_writer.as_mut() {
            for &sample in &buf[..n] {
                let _ = w.write_sample(sample);
            }
        }
    }
}

#[frb(dart_metadata = ("freezed"))]
#[derive(Debug, Clone)]
pub struct SessionPaths {
    pub wav_path: String,
    pub imu_path: String,
}
