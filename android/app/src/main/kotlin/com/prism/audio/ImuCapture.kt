package com.prism.audio

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

/**
 * 200 Hz triaxial IMU capture (accel + gyro).
 *
 * Pairs each accelerometer sample with the most recent gyro sample (and vice versa)
 * and forwards via JNI to the active Rust session writer.
 *
 * Most modern Android devices support `SENSOR_DELAY_FASTEST` ≈ 5 ms (200 Hz).
 * Some OEMs cap closer to 100 Hz; the Phase 0 acceptance test accepts ≥190 Hz.
 */
class ImuCapture(context: Context) : SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accel: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyro: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

    @Volatile private var lastAx = 0f
    @Volatile private var lastAy = 0f
    @Volatile private var lastAz = 0f
    @Volatile private var lastGx = 0f
    @Volatile private var lastGy = 0f
    @Volatile private var lastGz = 0f

    fun start() {
        accel?.let {
            // 5_000 us ≈ 200 Hz
            sensorManager.registerListener(this, it, SENSOR_PERIOD_US)
        }
        gyro?.let {
            sensorManager.registerListener(this, it, SENSOR_PERIOD_US)
        }
    }

    fun stop() {
        sensorManager.unregisterListener(this)
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                lastAx = event.values[0]
                lastAy = event.values[1]
                lastAz = event.values[2]
                RustBindings.pushImuSample(
                    event.timestamp,
                    lastAx, lastAy, lastAz,
                    lastGx, lastGy, lastGz,
                )
            }
            Sensor.TYPE_GYROSCOPE -> {
                lastGx = event.values[0]
                lastGy = event.values[1]
                lastGz = event.values[2]
                // Gyro arrival also writes a row, paired with last accel sample. This roughly
                // doubles row count vs the strict accel rate; Phase 1 may downsample.
                RustBindings.pushImuSample(
                    event.timestamp,
                    lastAx, lastAy, lastAz,
                    lastGx, lastGy, lastGz,
                )
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    companion object {
        const val SENSOR_PERIOD_US = 5_000 // 200 Hz target
    }
}
