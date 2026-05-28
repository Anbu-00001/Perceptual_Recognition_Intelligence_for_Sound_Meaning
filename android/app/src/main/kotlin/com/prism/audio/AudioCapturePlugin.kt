package com.prism.audio

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel "com.prism/audio_capture" — controls the foreground service + IMU lifecycle
 * from Dart. Audio data does NOT cross this channel; only commands and lifecycle events.
 *
 * Methods:
 *   - "startCapture"  : starts AudioCaptureService + ImuCapture.
 *   - "stopCapture"   : stops both.
 *   - "isCapturing"   : returns Boolean.
 */
object AudioCapturePlugin {
    private const val CHANNEL = "com.prism/audio_capture"
    private var imu: ImuCapture? = null
    @Volatile private var capturing = false

    fun register(engine: FlutterEngine, activity: Activity) {
        val ctx: Context = activity.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCapture" -> {
                    if (!capturing) {
                        AudioCaptureService.start(ctx)
                        imu = ImuCapture(ctx).also { it.start() }
                        capturing = true
                    }
                    result.success(true)
                }
                "stopCapture" -> {
                    if (capturing) {
                        AudioCaptureService.stop(ctx)
                        imu?.stop()
                        imu = null
                        capturing = false
                    }
                    result.success(true)
                }
                "isCapturing" -> result.success(capturing)
                else -> result.notImplemented()
            }
        }
    }
}
