//! Native-facing FFI. Kotlin calls via JNI; Swift calls via C-ABI.
//! These functions push raw PCM and IMU data into the global ring + session writers.

use crate::api::session;
use crate::ring;

#[cfg(target_os = "android")]
pub mod android;

#[cfg(target_os = "ios")]
pub mod ios;

/// C-ABI entry point. Both Android (via JNI thin wrapper) and iOS use this.
/// `samples_interleaved` points to `len` i16 values arranged L, R, L, R, ...
///
/// # Safety
/// Caller must guarantee the pointer is valid for `len` reads.
#[no_mangle]
pub unsafe extern "C" fn prism_push_audio_interleaved(
    samples_interleaved: *const i16,
    len: usize,
) -> usize {
    if samples_interleaved.is_null() || len == 0 {
        return 0;
    }
    let slice = std::slice::from_raw_parts(samples_interleaved, len);
    ring::push_interleaved(slice)
}

/// C-ABI entry point for IMU samples (CSV row append).
#[no_mangle]
pub unsafe extern "C" fn prism_push_imu(
    ts_ns: u64,
    ax: f32,
    ay: f32,
    az: f32,
    gx: f32,
    gy: f32,
    gz: f32,
) {
    session::append_imu_sample(ts_ns, ax, ay, az, gx, gy, gz);
}
