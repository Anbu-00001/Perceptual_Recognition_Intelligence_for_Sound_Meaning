//! JNI entry points called from Kotlin.
//!
//! These wrap the platform-independent C-ABI functions so Kotlin can call them via
//! the standard `System.loadLibrary("prism_dsp")` + `external fun` mechanism.

#![cfg(target_os = "android")]

use jni::objects::{JClass, JShortArray};
use jni::sys::{jint, jlong};
use jni::JNIEnv;

use crate::ring;

/// `com.prism.audio.RustBindings.pushAudioInterleaved(short[])` -> jint
#[no_mangle]
pub extern "system" fn Java_com_prism_audio_RustBindings_pushAudioInterleaved<'local>(
    env: JNIEnv<'local>,
    _class: JClass<'local>,
    samples: JShortArray<'local>,
) -> jint {
    let len = match env.get_array_length(&samples) {
        Ok(n) => n as usize,
        Err(_) => return 0,
    };
    if len == 0 {
        return 0;
    }
    let mut buf = vec![0i16; len];
    if env.get_short_array_region(&samples, 0, &mut buf).is_err() {
        return 0;
    }
    ring::push_interleaved(&buf) as jint
}

/// `com.prism.audio.RustBindings.pushImuSample(long, float, float, float, float, float, float)`
#[no_mangle]
pub extern "system" fn Java_com_prism_audio_RustBindings_pushImuSample<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
    ts_ns: jlong,
    ax: f32,
    ay: f32,
    az: f32,
    gx: f32,
    gy: f32,
    gz: f32,
) {
    crate::api::session::append_imu_sample(ts_ns as u64, ax, ay, az, gx, gy, gz);
}

/// One-time init triggered from `MainActivity.onCreate` — sets up Android logger.
#[no_mangle]
pub extern "system" fn Java_com_prism_audio_RustBindings_initLogger<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
) {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("PrismDsp"),
    );
    log::info!("PRISM DSP native library initialized");
}
