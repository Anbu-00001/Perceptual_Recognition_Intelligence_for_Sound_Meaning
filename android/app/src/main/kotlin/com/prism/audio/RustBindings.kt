package com.prism.audio

/**
 * Direct JNI bindings to the `prism_dsp` Rust library.
 *
 * These are used by [AudioCaptureService] and [ImuCapture] on the hot path —
 * audio frames and IMU samples go straight to Rust without crossing the MethodChannel.
 *
 * The flutter_rust_bridge-generated Dart bindings give Dart a *different* surface
 * (streams, async functions). Both surfaces share the global Rust state (ring buffer,
 * session writers) because Rust uses `OnceLock`-backed singletons.
 */
object RustBindings {

    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            System.loadLibrary("prism_dsp")
            initLogger()
            loaded = true
        }
    }

    // -- declared in rust/src/ffi/android.rs -------------------------------------

    /** One-time init for android_logger. Safe to call multiple times. */
    @JvmStatic external fun initLogger()

    /**
     * Push interleaved stereo PCM (L, R, L, R, ...) into the Rust ring buffer.
     * @return number of samples consumed (== samples.size on success).
     */
    @JvmStatic external fun pushAudioInterleaved(samples: ShortArray): Int

    /**
     * Append one IMU sample (accelerometer + gyro) to the active session CSV.
     * No-op if no session is recording.
     */
    @JvmStatic external fun pushImuSample(
        tsNs: Long,
        ax: Float, ay: Float, az: Float,
        gx: Float, gy: Float, gz: Float,
    )
}
