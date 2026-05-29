package com.prism.audio

import android.app.ActivityManager
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel "com.prism/audio_capture" — controls the foreground service + IMU lifecycle
 * from Dart. Audio data does NOT cross this channel; only commands and lifecycle events.
 *
 * Methods:
 *   - "startCapture"           : starts AudioCaptureService + ImuCapture.
 *   - "stopCapture"            : stops both.
 *   - "isCapturing"            : returns Boolean.
 *   - "captureDiagnostics"     : returns Map<String, Any> with audio source + device tier.
 *   - "isIgnoringBatteryOpt"   : returns Boolean (whether user already whitelisted PRISM).
 *   - "requestIgnoreBatteryOpt": fires the system dialog. Returns true if intent dispatched.
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
                "captureDiagnostics" -> result.success(diagnostics(ctx))
                "isIgnoringBatteryOpt" -> result.success(isIgnoringBatteryOpt(ctx))
                "requestIgnoreBatteryOpt" -> result.success(requestIgnoreBatteryOpt(activity))
                else -> result.notImplemented()
            }
        }
    }

    private fun diagnostics(ctx: Context): Map<String, Any> {
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val totalMb = mi.totalMem / (1024 * 1024)
        val availMb = mi.availMem / (1024 * 1024)
        // Thresholds calibrated against the OPPO A18 (4 GB phys + 4 GB virtual swap):
        // it reports ~3.5 GB total, lands in "low_borderline".
        val tier = when {
            totalMb < 3072 -> "low"            // 3 GB phones
            totalMb < 5120 -> "low_borderline" // 4 GB phones like OPPO A18
            totalMb < 7168 -> "mid"            // 6 GB
            else -> "high"                     // 8 GB+
        }
        return mapOf(
            "audioSource" to AudioCaptureService.lastSelectedSource,
            "manufacturer" to (Build.MANUFACTURER ?: "unknown"),
            "model" to (Build.MODEL ?: "unknown"),
            "androidSdk" to Build.VERSION.SDK_INT,
            "totalMemMb" to totalMb,
            "availMemMb" to availMb,
            "memoryTier" to tier,
            "lowMemory" to mi.lowMemory,
            "isOemAggressive" to isOemAggressive(),
        )
    }

    /**
     * Manufacturers that dontkillmyapp.com flags as needing user-side whitelisting on
     * top of the standard battery-optimization opt-out. Used to decide whether PRISM
     * shows the explanatory banner.
     */
    private fun isOemAggressive(): Boolean {
        val m = (Build.MANUFACTURER ?: "").lowercase()
        return m in setOf(
            "xiaomi", "redmi", "poco",
            "huawei", "honor",
            "oppo", "realme", "oneplus",
            "vivo", "iqoo",
            "samsung",
        )
    }

    private fun isIgnoringBatteryOpt(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(ctx.packageName)
    }

    @Suppress("BatteryLife") // Continuous mic capture for accessibility justifies the request.
    private fun requestIgnoreBatteryOpt(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
            activity.startActivity(intent)
            true
        } catch (_: Throwable) {
            try {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Throwable) {
                false
            }
        }
    }
}
