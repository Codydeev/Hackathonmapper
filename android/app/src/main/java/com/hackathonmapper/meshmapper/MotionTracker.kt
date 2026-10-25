package com.hackathonmapper.meshmapper

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.hackathonmapper.meshcore.MotionSample
import com.hackathonmapper.meshcore.Vector3

/**
 * Motion feeds for dead reckoning: device motion at 50 Hz and barometric relative altitude.
 * Callbacks run on the main thread.
 *
 * Core Motion's device motion becomes three Android sensors combined into one [MotionSample]
 * per linear-acceleration event: `TYPE_GRAVITY` and `TYPE_LINEAR_ACCELERATION` (m/s², pointing
 * the other way) are converted to Core Motion's g units and sign with `ios = −android / 9.80665`;
 * `TYPE_GYROSCOPE` is already rad/s about the same device axes. Sample times are seconds on the
 * `SystemClock.elapsedRealtimeNanos()` clock ([uptime]), like `CMDeviceMotion.timestamp` is on the
 * system uptime clock. `CMAltimeter.relativeAltitude` becomes the `TYPE_PRESSURE` altitude
 * difference from the first reading after [start].
 */
class MotionTracker(context: Context) {
    companion object {
        const val sampleRate = 50.0
        /** Standard gravity: Core Motion reports acceleration in g. */
        const val standardGravity = 9.80665

        /**
         * The clock [MotionSample.time] uses: seconds since boot, including deep sleep.
         * `MeshModel` compares motion times with this (Swift: `ProcessInfo.systemUptime`).
         */
        fun uptime(): Double = SystemClock.elapsedRealtimeNanos() / 1e9

        /** Android sensor vector (m/s², Android sign) to Core Motion's (g, iOS sign). */
        fun coreMotionAcceleration(values: FloatArray): Vector3 = Vector3(
            -values[0] / standardGravity,
            -values[1] / standardGravity,
            -values[2] / standardGravity,
        )
    }

    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager?
    private val gravitySensor = sensors?.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val accelerationSensor = sensors?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val gyroscope = sensors?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val barometer = sensors?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val mainHandler = Handler(Looper.getMainLooper())

    var onSample: ((MotionSample) -> Unit)? = null
    /** Meters since `start()`; null without a barometer or before the first reading. */
    var relativeAltitude: Double? = null
        private set

    val isMotionAvailable: Boolean get() = gravitySensor != null && accelerationSensor != null && gyroscope != null
    val isAltitudeAvailable: Boolean get() = barometer != null

    private var active = false
    private var gravity: Vector3? = null
    private var rotationRate: Vector3? = null
    private var lastSampleTime: Double? = null
    private var baselineAltitude: Double? = null

    private val motionListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            when (event.sensor.type) {
                Sensor.TYPE_GRAVITY -> gravity = coreMotionAcceleration(event.values)
                Sensor.TYPE_GYROSCOPE -> rotationRate =
                    Vector3(event.values[0].toDouble(), event.values[1].toDouble(), event.values[2].toDouble())
                Sensor.TYPE_LINEAR_ACCELERATION -> emit(event)
            }
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    private val altitudeListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val pressure = event.values.firstOrNull() ?: return
            if (!pressure.isFinite() || pressure <= 0f) return
            val altitude = SensorManager.getAltitude(SensorManager.PRESSURE_STANDARD_ATMOSPHERE, pressure).toDouble()
            val baseline = baselineAltitude ?: altitude.also { baselineAltitude = it }
            relativeAltitude = altitude - baseline
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    /** One sample per linear-acceleration event, once gravity and rotation have been seen. */
    private fun emit(event: SensorEvent) {
        val gravity = gravity ?: return
        val rotationRate = rotationRate ?: return
        val time = event.timestamp / 1e9
        // Some devices deliver faster than requested; keep about `sampleRate` and monotonic times.
        lastSampleTime?.let { if (time - it < 0.5 / sampleRate) return }
        lastSampleTime = time
        onSample?.invoke(MotionSample(
            time = time,
            gravity = gravity,
            userAcceleration = coreMotionAcceleration(event.values),
            rotationRate = rotationRate,
        ))
    }

    fun start() {
        val sensors = sensors ?: return
        if (!isMotionAvailable || active) return
        active = true
        gravity = null
        rotationRate = null
        lastSampleTime = null
        val period = (1_000_000 / sampleRate).toInt()
        // Gyro-based orientation (no magnetometer): smooth indoors, where steel and electronics
        // skew the compass. The fusion estimates the slow drift that remains.
        for (sensor in listOfNotNull(gravitySensor, gyroscope, accelerationSensor)) {
            sensors.registerListener(motionListener, sensor, period, mainHandler)
        }
        relativeAltitude = null
        baselineAltitude = null
        barometer?.let { sensors.registerListener(altitudeListener, it, 200_000, mainHandler) }
    }

    fun stop() {
        sensors?.unregisterListener(motionListener)
        sensors?.unregisterListener(altitudeListener)
        active = false
        relativeAltitude = null
        baselineAltitude = null
    }
}
