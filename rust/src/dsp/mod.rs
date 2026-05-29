//! Phase 1 DSP — internal modules called from the api layer.
//!
//! Layout:
//!   - `fft`      — windowed real-FFT with caching planner.
//!   - `mel`      — mel filterbank + MFCC + first-order delta.
//!   - `features` — spectral descriptors + time-domain features.
//!   - `vad`      — energy + ZCR voice activity detection with hangover.
//!   - `onset`    — spectral-flux onset detector.
//!   - `spatial`  — GCC-PHAT cross-channel TDOA → angle estimate.

pub mod fft;
pub mod features;
pub mod mel;
pub mod onset;
pub mod spatial;
pub mod vad;
