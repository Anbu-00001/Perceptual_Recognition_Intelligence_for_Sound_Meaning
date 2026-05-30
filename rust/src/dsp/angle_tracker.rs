//! 1-D Kalman filter on direction-of-arrival angle.
//!
//! Why a filter at all: raw GCC-PHAT angle wobbles ±20° between adjacent
//! windows even on a stationary source. A user-facing arrow that snaps
//! around is worse than no arrow at all. We smooth the estimate, weighted
//! by per-measurement confidence so low-confidence updates barely move it.
//!
//! Why 1-D (state = angle only), not 2-D (state = [angle, angular_velocity]):
//! sound sources in a room are mostly stationary (a fridge) or
//! instantaneous (a knock). A constant-velocity model over-fits transients
//! and overshoots. A position-only model with generous process noise stays
//! honest under both regimes.
//!
//! Why not a particle filter, EKF, or moving-average: this is *one source,
//! one bearing, scalar measurement.* Anything more is academic theatre on a
//! phone CPU.

/// Default measurement noise variance at confidence == 1.0, in degrees².
/// Below this floor the filter would converge instantly to noise spikes.
const MEAS_VAR_BASE: f32 = 25.0; // σ ≈ 5°

/// Process noise variance per second. Larger → tracker follows fast jumps
/// (good for transient sources) but is jitterier on stationary sources.
/// 400 deg²/s = σ ≈ 20°/√s, calibrated to feel responsive on a 30 Hz
/// pipeline.
const PROCESS_VAR_PER_SEC: f32 = 400.0;

/// Below this raw confidence we don't update the filter at all — the
/// measurement is dominated by the cross-correlation noise floor.
const MIN_UPDATE_CONFIDENCE: f32 = 0.10;

/// Stale-measurement timeout. If no update arrives for this long, the
/// filter forgets its previous state and reports Unknown. Sources that
/// stop emitting shouldn't leave a ghost arrow on the UI forever.
const STALE_TIMEOUT_MS: u64 = 5_000;

#[derive(Debug, Clone, Copy)]
pub struct AngleTracker {
    /// Posterior mean (degrees). Only meaningful when initialized.
    angle_deg: f32,
    /// Posterior variance (degrees²). Larger = less certain.
    variance: f32,
    /// Wall-clock ms of last update. None = never updated.
    last_update_ms: Option<u64>,
    /// Whether the filter has at least one real measurement.
    initialized: bool,
}

impl Default for AngleTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl AngleTracker {
    pub fn new() -> Self {
        Self {
            angle_deg: 0.0,
            variance: 90.0 * 90.0,
            last_update_ms: None,
            initialized: false,
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Run prediction + update. `confidence` is GCC-PHAT confidence in 0..1.
    /// `now_ms` is monotonic wall-clock for variance growth. Returns the
    /// posterior mean, or None if the measurement was rejected and no
    /// prior state exists (or has gone stale).
    pub fn observe(
        &mut self,
        raw_angle_deg: f32,
        confidence: f32,
        now_ms: u64,
    ) -> Option<SmoothedAngle> {
        // Stale-timeout: a long silence resets us.
        if let Some(prev) = self.last_update_ms {
            if now_ms.saturating_sub(prev) > STALE_TIMEOUT_MS {
                self.reset();
            }
        }

        // Predict step: variance grows with elapsed time.
        let dt_s = match self.last_update_ms {
            Some(prev) => (now_ms.saturating_sub(prev)) as f32 / 1000.0,
            None => 0.0,
        };
        self.variance += PROCESS_VAR_PER_SEC * dt_s;

        // Gate weak measurements.
        if confidence < MIN_UPDATE_CONFIDENCE {
            self.last_update_ms = Some(now_ms);
            return if self.initialized {
                Some(SmoothedAngle {
                    angle_deg: self.angle_deg,
                    variance: self.variance,
                    fresh: false,
                })
            } else {
                None
            };
        }

        // Measurement variance scales inverse-with-confidence.
        let conf = confidence.clamp(MIN_UPDATE_CONFIDENCE, 1.0);
        let meas_var = MEAS_VAR_BASE / (conf * conf);

        if !self.initialized {
            // First real measurement: take it at face value, weighted by meas_var.
            self.angle_deg = raw_angle_deg;
            self.variance = meas_var;
            self.initialized = true;
        } else {
            // Standard 1-D Kalman update.
            let k = self.variance / (self.variance + meas_var);
            self.angle_deg += k * (raw_angle_deg - self.angle_deg);
            self.variance *= 1.0 - k;
        }
        self.last_update_ms = Some(now_ms);

        Some(SmoothedAngle {
            angle_deg: self.angle_deg,
            variance: self.variance,
            fresh: true,
        })
    }

    /// Idle tick: called when no measurement is available (e.g. mono-replicated
    /// device). Lets variance grow so the UI can fade the arrow as confidence
    /// decays.
    pub fn coast(&mut self, now_ms: u64) -> Option<SmoothedAngle> {
        if let Some(prev) = self.last_update_ms {
            if now_ms.saturating_sub(prev) > STALE_TIMEOUT_MS {
                self.reset();
                return None;
            }
        }
        if !self.initialized {
            return None;
        }
        let dt_s = self
            .last_update_ms
            .map(|p| (now_ms.saturating_sub(p)) as f32 / 1000.0)
            .unwrap_or(0.0);
        let variance = self.variance + PROCESS_VAR_PER_SEC * dt_s;
        Some(SmoothedAngle {
            angle_deg: self.angle_deg,
            variance,
            fresh: false,
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SmoothedAngle {
    pub angle_deg: f32,
    pub variance: f32,
    /// True if this report includes a fresh measurement. False = coasting.
    pub fresh: bool,
}

impl SmoothedAngle {
    /// 0..1 confidence derived from posterior variance. 0 = useless, 1 = sharp.
    pub fn confidence(&self) -> f32 {
        // Map variance to confidence with a soft knee at σ = 15°.
        (1.0 / (1.0 + self.variance / 225.0)).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_high_confidence_measurement_initializes() {
        let mut t = AngleTracker::new();
        let s = t.observe(30.0, 0.9, 1000).expect("should accept");
        assert!((s.angle_deg - 30.0).abs() < 0.5);
        assert!(s.fresh);
    }

    #[test]
    fn low_confidence_does_not_seed_state() {
        let mut t = AngleTracker::new();
        assert!(t.observe(45.0, 0.05, 1000).is_none());
    }

    #[test]
    fn repeated_consistent_measurements_converge() {
        let mut t = AngleTracker::new();
        for i in 0..20 {
            let _ = t.observe(45.0, 0.7, (i as u64) * 50);
        }
        let s = t.coast(20 * 50).unwrap();
        assert!((s.angle_deg - 45.0).abs() < 2.0, "got {}", s.angle_deg);
        assert!(s.confidence() > 0.7, "conf {}", s.confidence());
    }

    #[test]
    fn outlier_does_not_yank_the_estimate() {
        let mut t = AngleTracker::new();
        for i in 0..15 {
            t.observe(0.0, 0.8, (i as u64) * 50);
        }
        let s = t.observe(80.0, 0.2, 15 * 50).unwrap();
        // Outlier with low confidence: estimate moves less than 30% of the way.
        assert!(s.angle_deg.abs() < 25.0,
            "outlier yanked estimate to {}", s.angle_deg);
    }

    #[test]
    fn stale_silence_resets_the_filter() {
        let mut t = AngleTracker::new();
        for i in 0..10 {
            t.observe(60.0, 0.8, (i as u64) * 50);
        }
        // Long silence.
        let after = t.coast(STALE_TIMEOUT_MS + 1000);
        assert!(after.is_none());
        // Next observation initializes from scratch.
        let s = t.observe(-60.0, 0.8, STALE_TIMEOUT_MS + 2000).unwrap();
        assert!((s.angle_deg + 60.0).abs() < 1.0);
    }
}
