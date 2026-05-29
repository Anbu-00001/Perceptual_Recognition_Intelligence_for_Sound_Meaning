//! Phase 1 VAD — energy + zero-crossing-rate with hangover smoothing.
//!
//! Not Silero — but adequate for segmentation. Pure-Rust, zero deps, deterministic.
//! Phase 1b will swap this for Silero VAD via `voice_activity_detector` crate
//! (ort runtime) once the kill/continue gate validates the architecture and we know
//! the accuracy lift is worth the binary-size cost (+~6 MB).
//!
//! Inputs: 20-ms frames of f32 mono PCM in [-1, 1] at 48 kHz (960 samples per frame).
//! Outputs: VadEdge events (SpeechStart, SpeechContinue, SpeechEnd, Silent).

use super::features::{time_features, zero_crossing_rate};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadEdge {
    Silent,
    SpeechStart,
    SpeechContinue,
    SpeechEnd,
}

pub struct VadConfig {
    /// Frame length in samples (960 at 48 kHz / 20 ms).
    pub frame_len: usize,
    /// Higher RMS → more likely speech.
    pub rms_threshold: f32,
    /// ZCR in [0.02, 0.20] is typical for speech; tonal sounds drop ZCR.
    pub zcr_min: f32,
    pub zcr_max: f32,
    /// Number of consecutive speech frames to confirm SpeechStart.
    pub onset_frames: usize,
    /// Number of consecutive silent frames before SpeechEnd.
    pub hangover_frames: usize,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            frame_len: 960,
            rms_threshold: 0.012, // ~-38 dBFS — tunable post kill/continue gate
            zcr_min: 0.02,
            zcr_max: 0.35,
            onset_frames: 2,   // 40 ms to confirm
            hangover_frames: 12, // 240 ms to release
        }
    }
}

pub struct VadStream {
    cfg: VadConfig,
    in_speech: bool,
    silent_streak: usize,
    speech_streak: usize,
    /// Rolling background RMS — used for adaptive thresholding.
    bg_rms_ema: f32,
}

impl VadStream {
    pub fn new(cfg: VadConfig) -> Self {
        Self {
            cfg,
            in_speech: false,
            silent_streak: 0,
            speech_streak: 0,
            bg_rms_ema: 0.0,
        }
    }

    /// Push one frame and get an edge label.
    pub fn push(&mut self, frame: &[f32]) -> VadEdge {
        assert_eq!(frame.len(), self.cfg.frame_len);
        let tf = time_features(frame);
        let zcr = zero_crossing_rate(frame);

        // EMA of background level when not in speech.
        if !self.in_speech {
            self.bg_rms_ema = 0.95 * self.bg_rms_ema + 0.05 * tf.rms;
        }
        // Adaptive threshold: max of static and 4× background EMA.
        let dynamic_thr = (self.cfg.rms_threshold).max(4.0 * self.bg_rms_ema);

        let speech_like = tf.rms > dynamic_thr
            && zcr >= self.cfg.zcr_min
            && zcr <= self.cfg.zcr_max;

        if speech_like {
            self.silent_streak = 0;
            self.speech_streak += 1;
            if !self.in_speech && self.speech_streak >= self.cfg.onset_frames {
                self.in_speech = true;
                self.speech_streak = 0;
                return VadEdge::SpeechStart;
            }
            if self.in_speech {
                return VadEdge::SpeechContinue;
            }
            VadEdge::Silent
        } else {
            self.speech_streak = 0;
            self.silent_streak += 1;
            if self.in_speech && self.silent_streak >= self.cfg.hangover_frames {
                self.in_speech = false;
                self.silent_streak = 0;
                return VadEdge::SpeechEnd;
            }
            if self.in_speech {
                return VadEdge::SpeechContinue;
            }
            VadEdge::Silent
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Speech-like band-limited noise: white noise → 1-pole low-pass → ZCR drops
    /// into the speech range while RMS stays elevated.
    fn speech_like_noise(n: usize, amp: f32) -> Vec<f32> {
        let mut x = 0x1234_5678_u32;
        let mut y = 0.0_f32;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                let w = (x as i32 as f32) / (i32::MAX as f32);
                y = 0.93 * y + 0.07 * w;
                y * amp
            })
            .collect()
    }

    #[test]
    fn detects_band_noise_as_speech_then_releases_on_silence() {
        let mut v = VadStream::new(VadConfig::default());
        let speech_like = speech_like_noise(960, 0.8);
        let silence = vec![0.0_f32; 960];

        // ~4 frames to confirm onset (default onset_frames=2 plus some warm-up).
        let mut saw_start = false;
        for _ in 0..6 {
            if v.push(&speech_like) == VadEdge::SpeechStart {
                saw_start = true;
            }
        }
        assert!(saw_start, "should have detected speech onset on noise burst");

        let mut saw_end = false;
        for _ in 0..30 {
            if v.push(&silence) == VadEdge::SpeechEnd {
                saw_end = true;
            }
        }
        assert!(saw_end, "should release after hangover");
    }

    #[test]
    fn pure_tone_is_not_speech() {
        let mut v = VadStream::new(VadConfig::default());
        let tone: Vec<f32> = (0..960)
            .map(|i| 0.5 * (2.0 * std::f32::consts::PI * 500.0 * i as f32 / 48_000.0).sin())
            .collect();
        // Tone has ZCR ≈ 0.01 which is below the speech window. Never starts speech.
        for _ in 0..30 {
            assert_ne!(v.push(&tone), VadEdge::SpeechStart);
        }
    }

    #[test]
    fn silence_is_silence() {
        let mut v = VadStream::new(VadConfig::default());
        let silence = vec![0.0_f32; 960];
        for _ in 0..10 {
            assert_eq!(v.push(&silence), VadEdge::Silent);
        }
    }
}
