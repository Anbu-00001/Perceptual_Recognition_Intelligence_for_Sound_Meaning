package com.prism.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import kotlin.concurrent.thread
import android.util.Log

/**
 * Phase 0 foreground service that owns the [AudioRecord] instance.
 *
 * Compliance + OEM survival notes (validated on OPPO A18 / ColorOS 15):
 *  - Android 14 (API 34) requires `foregroundServiceType=microphone` in the manifest +
 *    `FOREGROUND_SERVICE_MICROPHONE` permission + the type code passed to startForeground().
 *  - RECORD_AUDIO is subject to while-in-use restrictions. Start the service from the
 *    foreground Activity (MainActivity), never from a Receiver.
 *  - Android 13+ requires runtime POST_NOTIFICATIONS permission for the foreground notification.
 *  - ColorOS HansManager kills foreground services that have NOTIFICATION_IMPORTANCE > MIN
 *    and that don't hold a PartialWakeLock. We do both:
 *      1. IMPORTANCE_MIN notification channel (we recreate the channel if a previous
 *         install used LOW — Android won't upgrade an existing channel's importance).
 *      2. PARTIAL_WAKE_LOCK while audio is being read.
 *
 * Hot path: AudioRecord -> ShortArray -> RustBindings.pushAudioInterleaved (JNI).
 * No data crosses the MethodChannel.
 *
 * The selected audio source is reported via [lastSelectedSource] so Dart can fetch it
 * after capture starts; this lets the UI show "true stereo" vs "mono replicated" to
 * the user and lets Phase 1+ spatial code know whether GCC-PHAT is meaningful.
 */
class AudioCaptureService : Service() {

    @Volatile private var running = false
    private var recorder: AudioRecord? = null
    private var audioThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        RustBindings.ensureLoaded()
        createNotificationChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startCapture()
            ACTION_STOP -> {
                stopCapture()
                stopSelf()
            }
        }
        return START_STICKY
    }

    @Suppress("MissingPermission")
    private fun startCapture() {
        if (running) return

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PRISM is listening")
            .setContentText("Ambient acoustic capture is active")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q /* 29 */) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Acquire a partial wake lock so the audio thread doesn't get suspended when the
        // screen turns off. Released in stopCapture() — both branches always run.
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PRISM:audio_capture")
            wl.setReferenceCounted(false)
            wl.acquire(WAKE_LOCK_TIMEOUT_MS)
            wakeLock = wl
        } catch (t: Throwable) {
            Log.w(TAG, "wake lock acquire failed (continuing): ${t.message}")
        }

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            ENCODING,
        )
        val bufBytes = (minBuf * 4).coerceAtLeast(SAMPLE_RATE * 2 * 2 / 5) // ~200ms
        val (rec, sourceName) = openBestAudioRecord(bufBytes) ?: run {
            Log.e(TAG, "AudioRecord failed to initialize with every fallback")
            releaseWakeLock()
            stopSelf()
            return
        }
        recorder = rec
        lastSelectedSource = sourceName
        running = true
        rec.startRecording()

        audioThread = thread(name = "prism-audio-capture", isDaemon = true) {
            val readSize = 2048
            val buf = ShortArray(readSize)
            try {
                while (running) {
                    val n = rec.read(buf, 0, readSize, AudioRecord.READ_BLOCKING)
                    if (n > 0) {
                        RustBindings.pushAudioInterleaved(
                            if (n == readSize) buf else buf.copyOf(n)
                        )
                    } else if (n < 0) {
                        Log.w(TAG, "AudioRecord.read returned error $n")
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "audio thread crashed", t)
            } finally {
                try { rec.stop() } catch (_: Throwable) {}
                rec.release()
            }
        }
    }

    /**
     * Try the audio sources in descending DSP-friendliness order. Returns the first one
     * that yields an INITIALIZED recorder + the human-readable name we chose.
     *
     * Order rationale:
     *   - UNPROCESSED: pre-AGC/NS/AEC. Best for DSP but requires the device to declare
     *     `PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED == "true"` and meet a flat-response
     *     spec. Budget devices like the OPPO A18 won't qualify.
     *   - VOICE_RECOGNITION: pre-AGC/NS, post-EQ. Universally available, recommended
     *     fallback per Android docs.
     *   - CAMCORDER: stereo-aware on devices that have multiple mics for video.
     *   - MIC: last resort. AGC + NS applied; spatial features will be lossy.
     */
    @Suppress("MissingPermission")
    private fun openBestAudioRecord(bufBytes: Int): Pair<AudioRecord, String>? {
        data class Candidate(val source: Int, val name: String, val gate: () -> Boolean)
        val ladder = listOf(
            Candidate(MediaRecorder.AudioSource.UNPROCESSED, "UNPROCESSED") { supportsUnprocessed() },
            Candidate(MediaRecorder.AudioSource.VOICE_RECOGNITION, "VOICE_RECOGNITION") { true },
            Candidate(MediaRecorder.AudioSource.CAMCORDER, "CAMCORDER") { true },
            Candidate(MediaRecorder.AudioSource.MIC, "MIC") { true },
        )
        for (c in ladder) {
            if (!c.gate()) continue
            try {
                val rec = AudioRecord(c.source, SAMPLE_RATE, CHANNEL_CONFIG, ENCODING, bufBytes)
                if (rec.state == AudioRecord.STATE_INITIALIZED) {
                    Log.i(TAG, "AudioRecord selected source=${c.name}")
                    return rec to c.name
                }
                rec.release()
            } catch (t: Throwable) {
                Log.w(TAG, "source ${c.name} threw at construct: ${t.message}")
            }
        }
        return null
    }

    private fun stopCapture() {
        running = false
        try {
            audioThread?.join(500)
        } catch (_: InterruptedException) {}
        audioThread = null
        recorder = null
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (t: Throwable) {
            Log.w(TAG, "wake lock release failed: ${t.message}")
        }
        wakeLock = null
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    private fun supportsUnprocessed(): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)
                ?.equals("true", ignoreCase = true) == true
        } catch (_: Throwable) { false }
    }

    companion object {
        const val TAG = "PrismCapture"
        const val ACTION_START = "com.prism.audio.START"
        const val ACTION_STOP = "com.prism.audio.STOP"
        const val NOTIFICATION_ID = 1042

        // Channel id is versioned because Android won't downgrade an existing channel's
        // importance — we shipped IMPORTANCE_LOW in earlier installs and now need MIN.
        const val CHANNEL_ID = "prism_audio_capture_v2"
        const val CHANNEL_NAME = "PRISM listening"
        private const val LEGACY_CHANNEL_ID = "prism_audio_capture"

        const val SAMPLE_RATE = 48_000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO
        const val ENCODING = AudioFormat.ENCODING_PCM_16BIT

        // Hard ceiling for the wake lock — 10 hours covers any realistic continuous
        // capture session and prevents a runaway lock if the service somehow leaks.
        private const val WAKE_LOCK_TIMEOUT_MS = 10L * 60L * 60L * 1000L

        /** Last audio-source name we successfully opened. Read by Dart for diagnostics. */
        @Volatile var lastSelectedSource: String = "none"

        fun start(context: Context) {
            val i = Intent(context, AudioCaptureService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            val i = Intent(context, AudioCaptureService::class.java).setAction(ACTION_STOP)
            context.startService(i)
        }

        fun createNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = context.getSystemService(NotificationManager::class.java)

            // Drop the v1 channel on upgrade so the OS reclaims its IMPORTANCE_LOW slot.
            try {
                mgr.deleteNotificationChannel(LEGACY_CHANNEL_ID)
            } catch (_: Throwable) {}

            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Persistent low-priority notification while PRISM listens"
                    setShowBadge(false)
                    enableLights(false)
                    enableVibration(false)
                    setSound(null, null)
                    lockscreenVisibility = Notification.VISIBILITY_SECRET
                }
                mgr.createNotificationChannel(ch)
            }
        }
    }
}
