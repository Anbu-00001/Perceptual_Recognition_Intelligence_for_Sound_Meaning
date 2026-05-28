package com.prism.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlin.concurrent.thread
import android.util.Log

/**
 * Phase 0 foreground service that owns the [AudioRecord] instance.
 *
 * Compliance notes:
 *  - Android 14 (API 34) requires `foregroundServiceType=microphone` in the manifest +
 *    `FOREGROUND_SERVICE_MICROPHONE` permission + the type code passed to startForeground().
 *  - RECORD_AUDIO is subject to while-in-use restrictions. The service must be started
 *    while the app is in the foreground (i.e., from MainActivity, not from a Receiver).
 *  - Android 13+ also requires runtime POST_NOTIFICATIONS permission for the foreground notification.
 *
 * Hot path: AudioRecord -> ShortArray -> RustBindings.pushAudioInterleaved (JNI).
 * No data crosses the MethodChannel.
 */
class AudioCaptureService : Service() {

    @Volatile private var running = false
    private var recorder: AudioRecord? = null
    private var audioThread: Thread? = null

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
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE /* 34 */) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q /* 29 */) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            ENCODING,
        )
        // Generously sized so we never block on the producer.
        val bufBytes = (minBuf * 4).coerceAtLeast(SAMPLE_RATE * 2 * 2 / 5) // ~200ms
        val rec = AudioRecord(
            MediaRecorder.AudioSource.UNPROCESSED.takeIf { supportsUnprocessed() }
                ?: MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            ENCODING,
            bufBytes,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize")
            rec.release()
            stopSelf()
            return
        }
        recorder = rec
        running = true
        rec.startRecording()

        audioThread = thread(name = "prism-audio-capture", isDaemon = true) {
            // Read window ≈ 21 ms at 48 kHz stereo (1024 samples L + 1024 R = 2048 shorts).
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

    private fun stopCapture() {
        running = false
        try {
            audioThread?.join(500)
        } catch (_: InterruptedException) {}
        audioThread = null
        recorder = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    private fun supportsUnprocessed(): Boolean {
        // UNPROCESSED gives us pre-AGC, pre-NS, pre-AEC PCM — much better for DSP.
        // Devices declare support via PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED.
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            am.getProperty(android.media.AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)
                .equals("true", ignoreCase = true)
        } catch (_: Throwable) { false }
    }

    companion object {
        const val TAG = "PrismCapture"
        const val ACTION_START = "com.prism.audio.START"
        const val ACTION_STOP = "com.prism.audio.STOP"
        const val NOTIFICATION_ID = 1042
        const val CHANNEL_ID = "prism_audio_capture"
        const val CHANNEL_NAME = "PRISM audio capture"

        const val SAMPLE_RATE = 48_000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO
        const val ENCODING = AudioFormat.ENCODING_PCM_16BIT

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val mgr = context.getSystemService(NotificationManager::class.java)
                if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                    val ch = NotificationChannel(
                        CHANNEL_ID,
                        CHANNEL_NAME,
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Persistent notification while PRISM is listening"
                        setShowBadge(false)
                    }
                    mgr.createNotificationChannel(ch)
                }
            }
        }
    }
}
