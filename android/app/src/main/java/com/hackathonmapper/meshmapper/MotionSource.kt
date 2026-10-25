package com.hackathonmapper.meshmapper

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.Positioning
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.swiftRounded

/**
 * Device motion for the positioning engine, the Android counterpart of Core Motion in
 * `MotionSource.swift`: gravity, user acceleration and the (drift-compensated) rotation rate at
 * 50 Hz and, from the calibrated magnetic field, a tilt-compensated compass at 10 Hz. Motion
 * sensors need no runtime permission. Timestamps are the sensor events' (`elapsedRealtime`, seconds
 * since boot including sleep), which is the engine's clock (`PositioningService.now`).
 *
 * Android delivers each sensor separately, where Core Motion fuses them into one `CMDeviceMotion`:
 * the latest gravity and linear acceleration are combined with each gyroscope event (throttled to
 * about [rate]), and every [compassEvery]th sample also yields a compass reading from the latest
 * magnetic field. Values are converted to Core Motion's conventions (PORTING.md): gravity and user
 * acceleration in g with the opposite sign (`ios = −android / 9.80665`); rotation rate (rad/s) and
 * magnetic field (µT, device frame) are the same on both platforms.
 *
 * The listener runs on its own thread (Swift's operation queue); samples are handed to the main
 * thread, where `onMotion`/`onCompass` run and the observable state changes.
 */
class MotionSource(context: Context) {
    companion object {
        const val rate = 50.0
        const val compassEvery = 5
        /** Standard gravity: Android reports m/s², Core Motion g. */
        const val standardGravity = 9.80665

        /** An Android `TYPE_GRAVITY` / `TYPE_LINEAR_ACCELERATION` vector (m/s²) in Core Motion's g and sign. */
        fun coreMotion(x: Float, y: Float, z: Float): Positioning.Vec3 =
            Positioning.Vec3(-x / standardGravity, -y / standardGravity, -z / standardGravity)

        /** Degrees of heading sigma for a magnetometer accuracy, or null when it is unreliable. */
        fun sigmaDegrees(accuracy: Int): Double? = when (accuracy) {
            SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> 6.0
            SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> 12.0
            SensorManager.SENSOR_STATUS_ACCURACY_LOW -> 25.0
            else -> null
        }

        /**
         * Compass reading with an honest sigma for the magnetometer's calibration level; disturbed
         * when field strength or dip is off the local Earth field. Swift reads the field and its
         * accuracy from `CMCalibratedMagneticField`; here they are the `TYPE_MAGNETIC_FIELD` vector
         * (µT, device frame) and its `SensorManager.SENSOR_STATUS_*` accuracy.
         */
        fun compass(
            field: Positioning.Vec3,
            accuracy: Int,
            gravity: Positioning.Vec3,
            t: TimeInterval,
            declination: Double,
        ): Pair<Positioning.CompassSample?, String> {
            val sigmaDegrees = sigmaDegrees(accuracy)
                ?: return null to "uncalibrated: wave the phone in a figure eight"
            val h = Positioning.Compass.heading(field, gravity, declination) ?: return null to "no heading"
            val disturbed = Positioning.Compass.isDisturbed(h.strength, h.dip)
            val sample = Positioning.CompassSample(t, h.heading, Positioning.degrees(sigmaDegrees), disturbed)
            return sample to if (disturbed) "disturbed (${swiftRounded(h.strength).toInt()} µT)" else "ok ±${sigmaDegrees.toInt()}°"
        }
    }

    var isRunning: Boolean by mutableStateOf(false)
        private set
    var compassState: String by mutableStateOf("not started")
        private set

    private val manager = context.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager?
    private val gravitySensor = manager?.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val accelerationSensor = manager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val gyroscope = manager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val magnetometer = manager?.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)

    /** Core Motion's `isDeviceMotionAvailable`: gravity, user acceleration and rotation rate. */
    val isAvailable: Boolean = gravitySensor != null && accelerationSensor != null && gyroscope != null
    /** True minus magnetic north, radians; Tampere is about +11°. */
    var declination: Double = Positioning.Compass.tampereDeclination
    var onMotion: ((Positioning.MotionSample) -> Unit)? = null
    var onCompass: ((Positioning.CompassSample) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var listener: Listener? = null

    fun start() {
        val manager = manager ?: return
        if (!isAvailable || listener != null) return
        val thread = HandlerThread("positioning.motion").also { it.start() }
        val handler = Handler(thread.looper)
        val listener = Listener(declination)
        val period = (1_000_000 / rate).toInt()
        for (sensor in listOfNotNull(gravitySensor, accelerationSensor, gyroscope, magnetometer)) {
            manager.registerListener(listener, sensor, period, handler)
        }
        if (magnetometer == null) compassState = "no magnetometer"
        this.thread = thread
        this.listener = listener
        isRunning = true
    }

    fun stop() {
        listener?.let { manager?.unregisterListener(it) }
        listener = null
        thread?.quitSafely()
        thread = null
        isRunning = false
    }

    /** Runs on the sensor thread; only hands finished samples to the main thread. */
    private inner class Listener(private val declination: Double) : SensorEventListener {
        private var gravity: Positioning.Vec3? = null
        private var acceleration: Positioning.Vec3? = null
        private var field: Positioning.Vec3? = null
        private var fieldAccuracy = SensorManager.SENSOR_STATUS_UNRELIABLE
        private var lastT = Double.NEGATIVE_INFINITY
        private var count = 0

        override fun onSensorChanged(event: SensorEvent) {
            val v = event.values
            when (event.sensor.type) {
                Sensor.TYPE_GRAVITY -> gravity = coreMotion(v[0], v[1], v[2])
                Sensor.TYPE_LINEAR_ACCELERATION -> acceleration = coreMotion(v[0], v[1], v[2])
                Sensor.TYPE_MAGNETIC_FIELD -> {
                    field = Positioning.Vec3(v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
                    fieldAccuracy = event.accuracy
                }
                Sensor.TYPE_GYROSCOPE -> gyroscope(event)
            }
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
            if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) fieldAccuracy = accuracy
        }

        /** The gyroscope paces the samples, like one `CMDeviceMotion` per update interval. */
        private fun gyroscope(event: SensorEvent) {
            val gravity = gravity ?: return
            val acceleration = acceleration ?: return
            val t = event.timestamp / 1_000_000_000.0
            // Android treats the requested period as a hint and may deliver faster.
            if (t - lastT < 0.8 / rate) return
            lastT = t
            val v = event.values
            val sample = Positioning.MotionSample(
                t, gravity, acceleration,
                Positioning.Vec3(v[0].toDouble(), v[1].toDouble(), v[2].toDouble()),
            )
            count += 1
            var compass: Positioning.CompassSample? = null
            var state: String? = null
            if (count % compassEvery == 0) {
                val field = field
                if (field == null) {
                    state = if (magnetometer == null) "no magnetometer" else "no magnetic field yet"
                } else {
                    val (reading, text) = compass(field, fieldAccuracy, gravity, t, declination)
                    compass = reading
                    state = text
                }
            }
            main.post {
                if (listener !== this) return@post
                onMotion?.invoke(sample)
                compass?.let { onCompass?.invoke(it) }
                if (state != null && state != compassState) compassState = state
            }
        }
    }
}
