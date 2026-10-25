package com.hackathonmapper.meshcore

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.double
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Port of ios/MeshCore/Sources/MeshCore/Positioning/ — ALL nine Swift files live in this one Kotlin
 * file, in sections marked "MARK: <File>.swift" and in the same order as the Swift files:
 * PositioningMath, MotionProcessing, RSSIFilter, RangeGeometry, RSSICalibration, PositionEngine,
 * ContractMapping, PeerLocator, PositioningReplay.
 *
 * Why one file: Swift adds the nested types to `enum Positioning` with `extension Positioning`
 * from several files, and every caller writes `Positioning.Engine`, `Positioning.Vec2`, ... Kotlin
 * (2.0) cannot add nested classes to an object from another file and has no nested type aliases,
 * and four nested names (PathLossModel, GNSSFix, MotionSample, RSSISample) collide with top-level
 * MeshCore types, so the namespace must be one `object Positioning` declared in one file. The other
 * eight Kotlin files in this folder only point here.
 */

/**
 * GhostCore positioning engine. Everything lives under this namespace so it cannot collide with the
 * shared contract types (`PositionEstimate`, `PeerObservation`, ...) or the Bluetooth estimator while
 * those are still moving; adapters map these types onto the contract.
 *
 * Conventions used throughout:
 * - Frame: the floor plane of a `GeoFrame` (x east, z north, metres). Height is not estimated.
 * - Heading: radians clockwise from north (+z) towards east (+x), the compass convention, so a unit
 *   step along heading h moves (sin h, cos h).
 * - Time: local monotonic seconds (`ProcessInfo.systemUptime` on iOS, the base Core Motion uses).
 *   Wall-clock dates are converted once on entry; timestamps from other phones are never compared
 *   directly.
 */
object Positioning {

    // MARK: PositioningMath.swift

    /** A point or displacement on the floor plane: x east, z north, metres. */
    @Serializable
    data class Vec2(val x: Double, val z: Double) {
        val length: Double get() = hypot(x, z)
        fun distance(to: Vec2): Double = hypot(x - to.x, z - to.z)

        operator fun plus(b: Vec2): Vec2 = Vec2(x = x + b.x, z = z + b.z)
        operator fun minus(b: Vec2): Vec2 = Vec2(x = x - b.x, z = z - b.z)
        operator fun times(s: Double): Vec2 = Vec2(x = x * s, z = z * s)

        /** Swift `Double ==` semantics (0.0 equals -0.0). */
        override fun equals(other: Any?): Boolean = other is Vec2 && x == other.x && z == other.z
        override fun hashCode(): Int = 31 * (x + 0.0).hashCode() + (z + 0.0).hashCode()

        companion object {
            val zero = Vec2(x = 0.0, z = 0.0)

            /** Unit vector along a heading. */
            fun heading(h: Double): Vec2 = Vec2(x = sin(h), z = cos(h))
        }
    }

    /** A device-frame vector (Core Motion axes: x right, y up the screen, z out of the screen). */
    @Serializable
    data class Vec3(val x: Double, val y: Double, val z: Double) {
        val length: Double get() = sqrt(x * x + y * y + z * z)
        fun dot(o: Vec3): Double = x * o.x + y * o.y + z * o.z
        fun cross(o: Vec3): Vec3 = Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
        fun scaled(s: Double): Vec3 = Vec3(x * s, y * s, z * s)
        operator fun plus(b: Vec3): Vec3 = Vec3(x + b.x, y + b.y, z + b.z)
        operator fun minus(b: Vec3): Vec3 = Vec3(x - b.x, y - b.y, z - b.z)
        val normalized: Vec3?
            get() {
                val l = length
                return if (l.isFinite() && l > 1e-9) scaled(1 / l) else null
            }

        /** Swift `Double ==` semantics (0.0 equals -0.0). */
        override fun equals(other: Any?): Boolean = other is Vec3 && x == other.x && y == other.y && z == other.z
        override fun hashCode(): Int = 31 * (31 * (x + 0.0).hashCode() + (y + 0.0).hashCode()) + (z + 0.0).hashCode()
    }

    /** Symmetric 2x2 covariance of a floor-plane position, m². */
    @Serializable
    data class Covariance2(val xx: Double, val xz: Double, val zz: Double) {
        /** Swift's `(major: Double, minor: Double)` tuple. */
        data class Eigenvalues(val major: Double, val minor: Double)

        /** Eigenvalues, largest first. */
        val eigenvalues: Eigenvalues
            get() {
                val mean = (xx + zz) / 2
                val root = sqrt(((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz)
                return Eigenvalues(mean + root, max(0.0, mean - root))
            }

        /**
         * Radius of a circle around the mean that holds at least 95 % of a Gaussian with this
         * covariance (exact for a circular one, conservative for an elongated one).
         */
        val r95: Double get() = sqrt(Stats.chi2_2dof_95 * eigenvalues.major)

        /** Squared Mahalanobis distance of `d` (nil if singular). */
        fun mahalanobis2(d: Vec2): Double? {
            val det = xx * zz - xz * xz
            if (!(det > 1e-12)) return null
            return (zz * d.x * d.x - 2 * xz * d.x * d.z + xx * d.z * d.z) / det
        }

        companion object {
            fun isotropic(sigma: Double): Covariance2 = Covariance2(xx = sigma * sigma, xz = 0.0, zz = sigma * sigma)
        }
    }

    internal object Stats {
        /** Chi-square quantiles used for gates and radii. */
        const val chi2_1dof_95 = 3.841
        const val chi2_1dof_997 = 8.807
        const val chi2_2dof_95 = 5.991
        const val chi2_2dof_999 = 13.816
        /** Per-axis sigma of a circular Gaussian whose 68 % radius is 1 (Core Location's accuracy). */
        const val radius68ToSigma = 1 / 1.5096
        val r95PerSigma: Double = sqrt(chi2_2dof_95)

        fun median(values: List<Double>): Double? {
            if (values.isEmpty()) return null
            val s = values.sorted()
            val m = s.size / 2
            return if (s.size % 2 == 1) s[m] else (s[m - 1] + s[m]) / 2
        }

        /** 1.4826 × median absolute deviation: the standard deviation for Gaussian data, robust to outliers. */
        fun robustSpread(values: List<Double>, around: Double): Double =
            (median(values.map { abs(it - around) }) ?: 0.0) * 1.4826

        fun percentile(values: List<Double>, p: Double): Double? {
            if (values.isEmpty()) return null
            val s = values.sorted()
            val rank = min((s.size - 1).toDouble(), max(0.0, p * (s.size - 1).toDouble()))
            val lo = floor(rank).toInt()
            val hi = min(s.size - 1, lo + 1)
            return s[lo] + (s[hi] - s[lo]) * (rank - lo.toDouble())
        }
    }

    /** Wraps an angle to (-π, π]. */
    fun wrap(a: Double): Double {
        var r = a % (2 * PI)
        if (r <= -PI) r += 2 * PI
        if (r > PI) r -= 2 * PI
        return r
    }

    fun degrees(d: Double): Double = d * PI / 180

    /** Swift `String(format:)` (POSIX decimal point). */
    private fun format(pattern: String, vararg args: Any?): String = String.format(Locale.ROOT, pattern, *args)

    /** Small dense row-major matrix for the filter. Sizes stay below ~20, so clarity beats BLAS. A value type in Swift: copy before mutating a shared one. */
    internal class Matrix(val rows: Int, val cols: Int, repeating: Double = 0.0) {
        var a: DoubleArray = DoubleArray(rows * cols) { repeating }

        fun copy(): Matrix {
            val m = Matrix(rows, cols)
            m.a = a.copyOf()
            return m
        }

        operator fun get(i: Int, j: Int): Double = a[i * cols + j]
        operator fun set(i: Int, j: Int, newValue: Double) {
            a[i * cols + j] = newValue
        }

        val transposed: Matrix
            get() {
                val t = Matrix(rows = cols, cols = rows)
                for (i in 0 until rows) for (j in 0 until cols) t[j, i] = this[i, j]
                return t
            }

        operator fun times(r: Matrix): Matrix {
            require(cols == r.rows)
            val m = Matrix(rows = rows, cols = r.cols)
            for (i in 0 until rows) {
                for (k in 0 until cols) {
                    val v = this[i, k]
                    if (v == 0.0) continue
                    for (j in 0 until r.cols) m.a[i * r.cols + j] += v * r.a[k * r.cols + j]
                }
            }
            return m
        }

        operator fun plus(r: Matrix): Matrix {
            val m = copy()
            for (i in m.a.indices) m.a[i] += r.a[i]
            return m
        }

        operator fun minus(r: Matrix): Matrix {
            val m = copy()
            for (i in m.a.indices) m.a[i] -= r.a[i]
            return m
        }

        fun scaled(s: Double): Matrix {
            val m = copy()
            for (i in m.a.indices) m.a[i] *= s
            return m
        }

        /** Gauss-Jordan inverse with partial pivoting; nil if (numerically) singular. */
        fun inverted(): Matrix? {
            require(rows == cols)
            val n = rows
            val m = copy()
            val inv = identity(n)
            for (c in 0 until n) {
                var p = c
                for (r in c + 1 until max(c + 1, n)) if (abs(m[r, c]) > abs(m[p, c])) p = r
                if (!(abs(m[p, c]) > 1e-12)) return null
                if (p != c) {
                    for (j in 0 until n) {
                        m.a.swap(c * n + j, p * n + j)
                        inv.a.swap(c * n + j, p * n + j)
                    }
                }
                val d = m[c, c]
                for (j in 0 until n) {
                    m[c, j] /= d
                    inv[c, j] /= d
                }
                for (r in 0 until n) {
                    if (r == c) continue
                    val f = m[r, c]
                    if (f == 0.0) continue
                    for (j in 0 until n) {
                        m[r, j] -= f * m[c, j]
                        inv[r, j] -= f * inv[c, j]
                    }
                }
            }
            return inv
        }

        /** Keeps the matrix symmetric against round-off. */
        fun symmetrize() {
            for (i in 0 until rows) {
                for (j in i + 1 until max(i + 1, cols)) {
                    val v = (this[i, j] + this[j, i]) / 2
                    this[i, j] = v
                    this[j, i] = v
                }
            }
        }

        override fun equals(other: Any?): Boolean =
            other is Matrix && rows == other.rows && cols == other.cols &&
                a.indices.all { a[it] == other.a[it] }

        override fun hashCode(): Int = 31 * (31 * rows + cols) + a.map { it + 0.0 }.hashCode()

        companion object {
            fun identity(n: Int): Matrix {
                val m = Matrix(rows = n, cols = n)
                for (i in 0 until n) m[i, i] = 1.0
                return m
            }

            private fun DoubleArray.swap(i: Int, j: Int) {
                val t = this[i]
                this[i] = this[j]
                this[j] = t
            }
        }
    }

    // MARK: MotionProcessing.swift

    /**
     * One Core Motion device-motion sample, device frame (x right, y up the screen, z out of the
     * screen). `gravity` and `userAcceleration` are in g, `rotationRate` in rad/s, as
     * `CMDeviceMotion` reports them (Android sensors must be converted, see PORTING.md).
     */
    @Serializable
    data class MotionSample(
        val t: TimeInterval,
        val gravity: Vec3,
        val userAcceleration: Vec3,
        val rotationRate: Vec3,
    )

    /**
     * Heading of the phone's forward axis from the magnetometer, already tilt-compensated and
     * turned to true north.
     */
    @Serializable
    data class CompassSample(
        val t: TimeInterval,
        /** Radians clockwise from true north. */
        val heading: Double,
        /** 1-sigma, radians. */
        val sigma: Double,
        /** The field strength or dip is off what the Earth gives here: steel, magnets, a car. */
        val disturbed: Boolean = false,
    )

    /** One detected step. `length` is the uncorrected model length; the engine scales it. */
    @Serializable
    data class StepEvent(
        val t: TimeInterval,
        val length: Double,
        val source: Source,
    ) {
        @Serializable
        enum class Source(val rawValue: String) {
            @SerialName("detector") detector("detector"),
            @SerialName("pedometer") pedometer("pedometer"),
        }
    }

    object DeviceAxes {
        /** Unit up vector in the device frame (gravity points down). */
        fun up(gravity: Vec3): Vec3? = gravity.scaled(-1.0).normalized

        /**
         * Heading rate, rad/s clockwise seen from above: minus the rotation about up. Independent of
         * how the phone is held, which is why the gyro can carry heading through pose changes.
         */
        fun headingRate(s: MotionSample): Double? {
            val up = up(s.gravity) ?: return null
            return -s.rotationRate.dot(up)
        }

        /**
         * The device axis treated as "forward": the top edge (+y) when the phone lies flat, the back
         * (-z) when it stands upright. Both point the same way through the usual tilt-up gesture.
         */
        fun forward(up: Vec3): Vec3? {
            val top = Vec3(0.0, 1.0, 0.0)
            val back = Vec3(0.0, 0.0, -1.0)
            val topH = top - up.scaled(top.dot(up))
            val backH = back - up.scaled(back.dot(up))
            return (if (topH.length >= 0.5) topH else backH).normalized
        }
    }

    object Compass {
        /** Swift's `(heading: Double, strength: Double, dip: Double)` tuple. */
        data class Heading(val heading: Double, val strength: Double, val dip: Double)

        /**
         * Tilt-compensated heading of the forward axis from Core Motion's calibrated magnetic field
         * (µT, device frame), plus field strength and dip to spot disturbances.
         */
        fun heading(magneticField: Vec3, gravity: Vec3, declination: Double): Heading? {
            val b = magneticField
            val up = DeviceAxes.up(gravity) ?: return null
            val forward = DeviceAxes.forward(up) ?: return null
            val north = (b - up.scaled(b.dot(up))).normalized ?: return null
            val east = north.cross(up)
            val magnetic = atan2(forward.dot(east), forward.dot(north))
            val strength = b.length
            val dip = asin(max(-1.0, min(1.0, -b.dot(up) / max(strength, 1e-9))))
            return Heading(wrap(magnetic + declination), strength, dip)
        }

        /** Earth's field near Tampere (WMM 2025): ~52.5 µT, dip ~74°, declination ~+11° east. */
        const val tampereStrength = 52.5
        val tampereDip: Double = degrees(74.0)
        val tampereDeclination: Double = degrees(11.0)

        fun isDisturbed(
            strength: Double,
            dip: Double,
            expectedStrength: Double = tampereStrength,
            expectedDip: Double = tampereDip,
        ): Boolean = abs(strength - expectedStrength) > 8 || abs(dip - expectedDip) > degrees(8.0)
    }

    /**
     * Step detector on gravity-aligned vertical acceleration: low-pass, then a peak above
     * `peakThreshold` at least `minInterval` after the previous step, with step length from the
     * Weinberg model L = K (aMax - aMin)^(1/4) over the stride (at most `strideWindow` back). K is a
     * population default; the engine learns a personal scale while GNSS is good.
     */
    class StepDetector {
        var peakThreshold = 0.08
        var minInterval: TimeInterval = 0.3
        var strideWindow: TimeInterval = 1.0
        var weinbergK = 0.45
        var cutoffHz = 3.0

        private data class Sample(val t: TimeInterval, val v: Double)

        private var filtered: Double? = null
        private val history: MutableList<Sample> = ArrayList()
        private var rising = false
        private var lastStep: TimeInterval = Double.NEGATIVE_INFINITY

        fun add(s: MotionSample): StepEvent? {
            val up = DeviceAxes.up(s.gravity) ?: return null
            val raw = s.userAcceleration.dot(up)
            val dt = history.lastOrNull()?.let { max(1e-3, s.t - it.t) } ?: 0.02
            val rc = 1 / (2 * PI * cutoffHz)
            val value = filtered?.let { it + dt / (rc + dt) * (raw - it) } ?: raw
            filtered = value
            try {
                val prev = history.lastOrNull() ?: return null
                var step: StepEvent? = null
                if (value < prev.v && rising && prev.v >= peakThreshold && prev.t - lastStep >= minInterval) {
                    // Peak at the previous sample; amplitude over this stride only.
                    val since = max(lastStep, prev.t - strideWindow)
                    val stride = history.filter { it.t > since }.map { it.v }
                    val amplitude = max(0.0, (stride.maxOrNull() ?: 0.0) - (stride.minOrNull() ?: 0.0)) * 9.80665
                    step = StepEvent(t = prev.t, length = weinbergK * amplitude.pow(0.25), source = StepEvent.Source.detector)
                    lastStep = prev.t
                }
                rising = value > prev.v
                return step
            } finally {
                // Swift's `defer`: runs on every return after the filter state was updated.
                history.add(Sample(s.t, value))
                history.removeAll { it.t < s.t - strideWindow }
            }
        }
    }

    /**
     * Stationary when user acceleration and rotation stay tiny for a full window. Used to stop
     * position growth and to measure gyro bias (true rate is zero).
     */
    class StationarityDetector {
        var window: TimeInterval = 1.0
        var maxAccelerationStd = 0.012
        var maxRotation = 0.05

        private data class Sample(val t: TimeInterval, val a: Double, val w: Double, val rate: Double)

        private val samples: MutableList<Sample> = ArrayList()

        /** Returns the mean heading rate over the window if the phone has been still for all of it. */
        fun add(s: MotionSample): Double? {
            val rate = DeviceAxes.headingRate(s) ?: return null
            samples.add(Sample(s.t, s.userAcceleration.length, s.rotationRate.length, rate))
            samples.removeAll { it.t < s.t - window }
            val first = samples.firstOrNull() ?: return null
            if (!(s.t - first.t >= window * 0.9 && samples.size >= 5)) return null
            val mean = samples.fold(0.0) { acc, it -> acc + it.a } / samples.size.toDouble()
            val variance = samples.fold(0.0) { acc, it -> acc + (it.a - mean) * (it.a - mean) } / samples.size.toDouble()
            if (!(sqrt(variance) <= maxAccelerationStd && samples.all { it.w <= maxRotation })) return null
            return samples.fold(0.0) { acc, it -> acc + it.rate } / samples.size.toDouble()
        }
    }

    // MARK: RSSIFilter.swift

    /**
     * How an RSSI value was measured. iPhones read a few dB apart on the two, and relayed values are
     * already smoothed by the sending phone, so each is calibrated and weighted separately.
     */
    @Serializable
    enum class RSSIChannel(val rawValue: String) {
        /** Advertisement RSSI heard while scanning: irregular rate, three advertising channels. */
        @SerialName("advertisement") advertisement("advertisement"),
        /** `readRSSI` on a connection where this phone is the central, about 1 Hz. */
        @SerialName("connection") connection("connection"),
        /**
         * The peer's raw readings of our signal, relayed in its `PeerObservation`: the same link
         * seen from the other end (shared shadowing, independent fading, the peer's radio).
         */
        @SerialName("reciprocal") reciprocal("reciprocal"),
        /**
         * A neighbour's reading of its link to us, relayed in its report (`NeighborObservation`):
         * exponentially smoothed on that phone, so it is one correlated sample, not raw data.
         */
        @SerialName("relayedSmoothed") relayedSmoothed("relayedSmoothed");

        companion object {
            fun fromRawValue(rawValue: String): RSSIChannel? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    /** One RSSI reading of the link between this phone and `peerId`. */
    @Serializable
    data class RSSISample(
        val peerId: String,
        val rssi: Double,
        /** Local monotonic seconds when the radio measured it. */
        val t: TimeInterval,
        val channel: RSSIChannel,
    )

    /** Robust summary of one window of RSSI from one peer on one channel. */
    data class RSSIWindow(
        val peerId: String,
        val channel: RSSIChannel,
        val median: Double,
        /** 1.4826 × median absolute deviation of the kept samples, dB. */
        val spread: Double,
        val count: Int,
        /** Samples dropped as Hampel outliers (more than `hampelK` robust sigmas from the median). */
        val rejected: Int,
        val start: TimeInterval,
        val end: TimeInterval,
        /** The time the window stands for: the median sample time. */
        val t: TimeInterval,
    )

    /**
     * Per-peer RSSI filter: a sliding time window of raw samples, impossible values and Hampel
     * outliers removed, summarised by the median. A median rather than the mean or the EMA in
     * `RSSIStatistics`: one deep fade or reflection spike moves a mean by several dB and leaves the
     * median alone. RSSI stays a noisy proxy for distance; the path-loss model carries its spread.
     */
    class RSSIMedianFilter(
        var window: TimeInterval = 4.0,
        var maxSamples: Int = 64,
        var minSamples: Int = 3,
        var hampelK: Double = 3.0,
    ) {
        private data class Key(val peerId: String, val channel: RSSIChannel)

        private val buffers: MutableMap<Key, MutableList<RSSISample>> = HashMap()
        /** Newest sample time already handed out by `takeWindow`, so each sample is used once. */
        private val consumedUntil: MutableMap<Key, TimeInterval> = HashMap()

        /** Adds a sample; false if it is invalid or older than samples already handed out. */
        fun add(sample: RSSISample): Boolean {
            if (!(isValid(sample.rssi) && sample.t.isFinite())) return false
            val key = Key(sample.peerId, sample.channel)
            val done = consumedUntil[key]
            if (done != null && sample.t <= done) return false
            val buffer = buffers[key] ?: ArrayList()
            // Keep time order even if samples arrive slightly out of order.
            val index = buffer.indexOfLast { it.t <= sample.t } + 1
            buffer.add(index, sample)
            if (buffer.size > maxSamples) buffer.subList(0, buffer.size - maxSamples).clear()
            buffers[key] = buffer
            return true
        }

        /** The current sliding window (overlapping with earlier calls), for display and calibration. */
        fun current(peerId: String, channel: RSSIChannel, now: TimeInterval): RSSIWindow? {
            val key = Key(peerId, channel)
            val samples = (buffers[key] ?: emptyList<RSSISample>()).filter { it.t > now - window && it.t <= now }
            return summarize(samples, peerId = peerId, channel = channel, minSamples = minSamples, hampelK = hampelK)
        }

        /**
         * Non-overlapping windows for the filter: once a peer has `window` seconds (or `maxSamples`)
         * of unused samples, returns their summary and marks them used. Samples older than two windows
         * are dropped unused as stale. Returns windows of every peer and channel, oldest first.
         */
        fun takeWindows(now: TimeInterval): List<RSSIWindow> {
            val out = ArrayList<RSSIWindow>()
            val keys = buffers.keys.sortedWith(compareBy<Key>({ it.peerId }, { it.channel.rawValue }))
            for (key in keys) {
                val buffer = buffers[key] ?: ArrayList()
                buffer.removeAll { it.t < now - 2 * window }
                val done = consumedUntil[key] ?: Double.NEGATIVE_INFINITY
                val fresh = buffer.filter { it.t > done && it.t <= now }
                buffers[key] = buffer
                val first = fresh.firstOrNull() ?: continue
                val last = fresh.last()
                // Relayed values are already averaged on the sender: each one is a window by itself.
                val ready = key.channel == RSSIChannel.relayedSmoothed ||
                    now - first.t >= window || fresh.size >= maxSamples
                if (!ready) continue
                consumedUntil[key] = last.t
                val minimum = if (key.channel == RSSIChannel.relayedSmoothed) 1 else minSamples
                summarize(fresh, peerId = key.peerId, channel = key.channel, minSamples = minimum, hampelK = hampelK)
                    ?.let { out.add(it) }
            }
            // Total order, so replays are repeatable whatever the dictionary order.
            return out.sortedWith(compareBy<RSSIWindow>({ it.t }, { it.peerId }, { it.channel.rawValue }))
        }

        /** Forgets peers with nothing newer than `maxAge`. */
        fun prune(now: TimeInterval, maxAge: TimeInterval = 60.0) {
            buffers.entries.removeAll { !((it.value.lastOrNull()?.t ?: Double.NEGATIVE_INFINITY) >= now - maxAge) }
            consumedUntil.keys.removeAll { buffers[it] == null }
        }

        companion object {
            /** iOS reports 127 when it has no reading; real values sit in -127...20 dBm. */
            fun isValid(rssi: Double): Boolean = rssi.isFinite() && rssi != 127.0 && rssi >= -127.0 && rssi <= 20.0

            /** Median of a set of samples after dropping Hampel outliers; nil below `minSamples`. */
            fun summarize(
                samples: List<RSSISample>,
                peerId: String,
                channel: RSSIChannel,
                minSamples: Int = 3,
                hampelK: Double = 3.0,
            ): RSSIWindow? {
                if (samples.size < max(1, minSamples)) return null
                val first = samples.firstOrNull() ?: return null
                val last = samples.last()
                val center = Stats.median(samples.map { it.rssi }) ?: return null
                val spread = Stats.robustSpread(samples.map { it.rssi }, around = center)
                // Below 1 dB of spread the integer steps of RSSI make the test meaningless.
                val limit = hampelK * max(1.0, spread)
                val kept = samples.filter { abs(it.rssi - center) <= limit }
                if (kept.size < max(1, minSamples)) return null
                val median = Stats.median(kept.map { it.rssi }) ?: return null
                return RSSIWindow(
                    peerId = peerId, channel = channel, median = median,
                    spread = Stats.robustSpread(kept.map { it.rssi }, around = median),
                    count = kept.size, rejected = samples.size - kept.size,
                    start = first.t, end = last.t, t = Stats.median(kept.map { it.t }) ?: last.t,
                )
            }
        }
    }

    /** Swift's `ClosedRange<Double>` as `distanceInterval` returns it: `lowerBound...upperBound`. */
    class DistanceInterval(override val start: Double, override val endInclusive: Double) : ClosedFloatingPointRange<Double> {
        val lowerBound: Double get() = start
        val upperBound: Double get() = endInclusive

        override fun lessThanOrEquals(a: Double, b: Double): Boolean = a <= b
        override fun equals(other: Any?): Boolean =
            other is DistanceInterval && start == other.start && endInclusive == other.endInclusive
        override fun hashCode(): Int = 31 * (start + 0.0).hashCode() + (endInclusive + 0.0).hashCode()
        override fun toString(): String = "$start...$endInclusive"
    }

    /**
     * Log-distance path loss, RSSI = p0 - 10 n log10(d), with calibrated spreads. The spreads are
     * the honest part: outdoors one window median still scatters by several dB, which is a factor of
     * ~1.7 in distance per sigma, so a range from RSSI is an interval, never a number.
     *
     * A value type in Swift: whoever stores one keeps a `copy()`.
     */
    @Serializable
    data class PathLossModel(
        /** Median RSSI at 1 m, dBm. */
        var p0: Double,
        /** Path-loss exponent. */
        var n: Double,
        /** Spread of window medians at one fixed spot (fading left after the median), dB. */
        var sigmaFast: Double,
        /**
         * Spread of the local mean from spot to spot around the fitted line (shadowing, body,
         * orientation, phone model), dB. It persists while neither phone moves.
         */
        var sigmaShadow: Double,
        /** Distance over which shadowing decorrelates as either phone moves, m. */
        var decorrelationDistance: Double = 3.0,
        /** Closer than this, readings saturate and stop tracking distance, m. */
        var minDistance: Double = 0.5,
        /** Beyond this, phones practically never hear each other outdoors, m. */
        var maxRange: Double = 100.0,
        /** Where the numbers came from, e.g. "default-outdoor" or "calibrated 2026-10-24 ...". */
        var source: String,
        /**
         * Weakest reading the receiver reports, dBm (nil: -105). Within `censorMargin` of it the
         * samples that faded below were never reported, so a median there reads too strong and only
         * says "far", not how far.
         */
        var sensitivity: Double? = null,
        /** dB above the sensitivity treated as censored (nil: 4, about one raw-sample fading sigma). */
        var censorMargin: Double? = null,
    ) {
        val totalSigma: Double get() = sqrt(sigmaFast * sigmaFast + sigmaShadow * sigmaShadow)

        /** Near the sensitivity the reading is censored: the distance is only bounded below. */
        fun isCensored(rssi: Double): Boolean = rssi - (sensitivity ?: -105.0) < (censorMargin ?: 4.0)

        /** dB of RSSI per natural-log unit of distance. */
        internal val slope: Double get() = 10 * n / ln(10.0)

        fun expectedRSSI(distance: Double): Double = p0 - 10 * n * log10(max(minDistance, distance))

        /** The median distance for a reading (log-normal), m. */
        fun medianDistance(rssi: Double): Double =
            min(maxRange, max(minDistance, 10.0.pow((p0 - rssi) / (10 * n))))

        /**
         * Distance interval holding ~`z`-sigma of the belief for a reading, using the total spread
         * (fading and shadowing) unless told otherwise. z = 1.96 gives 95 %.
         */
        fun distanceInterval(rssi: Double, z: Double = 1.96, sigma: Double? = null): DistanceInterval {
            val s = sigma ?: totalSigma
            val lo = 10.0.pow((p0 - rssi - z * s) / (10 * n))
            val hi = if (isCensored(rssi)) maxRange else 10.0.pow((p0 - rssi + z * s) / (10 * n))
            return DistanceInterval(max(0.0, min(lo, maxRange)), min(maxRange, max(hi, minDistance)))
        }

        companion object {
            /**
             * Uncalibrated phone-to-phone outdoors, matching `RadioModel.outdoors` (total spread ~5.6 dB).
             * Replace with a `CalibrationSession` fit for the phones actually used. A fresh value on
             * every read, since the Kotlin type is mutable.
             */
            val defaultOutdoor: PathLossModel
                get() = PathLossModel(p0 = -59.0, n = 2.5, sigmaFast = 2.5, sigmaShadow = 5.0, source = "default-outdoor")
        }
    }

    // MARK: RangeGeometry.swift

    /** A phone whose position is known well enough to range against. */
    @Serializable
    @ConsistentCopyVisibility
    data class Anchor private constructor(
        val id: String,
        val position: Vec2,
        /** 1-sigma per axis when measured, m. */
        val sigma: Double,
        val kind: Kind,
        /**
         * Local monotonic time the position was valid (receipt time minus the sender's age and
         * the relay latency).
         */
        val measuredAt: TimeInterval,
        /** Extra timing uncertainty from relaying, s. */
        val timeSigma: TimeInterval,
        /** How fast it may move, m/s: 0 for a surveyed anchor, walking pace for a phone. */
        val speedBound: Double,
        /** Device ids its position depends on (for `estimated`), to refuse cycles. */
        val dependsOn: List<String>,
        /** Its position rests on GNSS somewhere upstream. */
        val gnssDependent: Boolean,
    ) {
        @Serializable
        enum class Kind(val rawValue: String) {
            /** Its own GNSS fix, trusted by the integrity check. */
            @SerialName("gnss") gnss("gnss"),
            /** Placed at a surveyed or hand-entered spot; static. */
            @SerialName("surveyed") surveyed("surveyed"),
            /**
             * Itself estimated (dead reckoning or Bluetooth): usable only with its uncertainty and
             * only if its estimate does not depend on us.
             */
            @SerialName("estimated") estimated("estimated"),
        }

        /** Per-axis sigma at time `t`: grown by how far it may have moved since it was measured. */
        fun sigma(at: TimeInterval): Double {
            val age = max(0.0, at - measuredAt) + timeSigma
            val drift = speedBound * age
            return sqrt(sigma * sigma + drift * drift)
        }

        companion object {
            /** Swift's `init`: a GNSS anchor is always GNSS-dependent. */
            operator fun invoke(
                id: String,
                position: Vec2,
                sigma: Double,
                kind: Kind,
                measuredAt: TimeInterval,
                timeSigma: TimeInterval = 0.0,
                speedBound: Double = 1.5,
                dependsOn: List<String> = emptyList(),
                gnssDependent: Boolean = false,
            ): Anchor = Anchor(
                id, position, sigma, kind, measuredAt, timeSigma, speedBound, dependsOn,
                gnssDependent || kind == Kind.gnss,
            )
        }
    }

    /** A median RSSI window against an anchor, ready for geometry. */
    data class RangeObservation(
        val anchor: Anchor,
        val window: RSSIWindow,
        val model: PathLossModel,
    ) {
        /** Upper 95 % distance plus the anchor's own 95 % radius: the phone is inside this disc. */
        val discRadius95: Double
            get() = model.distanceInterval(rssi = window.median).upperBound + Stats.r95PerSigma * anchor.sigma(at = window.t)
    }

    /** What a set of simultaneous range observations says on its own, without motion or history. */
    data class GeometrySolution(
        val kind: Kind,
        /**
         * Best single point for `multilateration`; for the other kinds the centre of the covering
         * region (for `proximity` the anchor itself), which must not be shown as the phone.
         */
        val center: Vec2,
        /** Covering covariance (for proximity and ambiguous: a Gaussian over the whole region). */
        val covariance: Covariance2,
        val r95: Double,
        /** For `ambiguous`: each candidate position. */
        val candidates: List<Vec2>,
        val hdop: Double?,
        val anchorIds: List<String>,
        val t: TimeInterval,
    ) {
        @Serializable
        enum class Kind(val rawValue: String) {
            /** Inside a disc around one anchor. One range gives distance, never direction. */
            @SerialName("proximity") proximity("proximity"),
            /** Two (or mirror-symmetric) solutions fit equally well; the centre is not a guess. */
            @SerialName("ambiguous") ambiguous("ambiguous"),
            /** Three or more anchors with usable geometry: a single solution. */
            @SerialName("multilateration") multilateration("multilateration"),
        }
    }

    object RangeGeometry {
        /** Maximum horizontal dilution of precision for a multilateration to count. */
        const val maxHDOP = 3.0

        /** Swift's `(r: [Double], jx: [Double], jz: [Double])` tuple. */
        internal class Residuals(val r: DoubleArray, val jx: DoubleArray, val jz: DoubleArray)

        /** Swift's `(p: Vec2, cost: Double, info: Covariance2)` tuple. */
        internal data class Refinement(val p: Vec2, val cost: Double, val info: Covariance2)

        /**
         * Solves 1 anchor -> proximity disc, 2 -> ambiguous pair, 3+ -> multilateration if the
         * geometry is good and no mirror solution fits as well, else the tightest proximity disc.
         */
        fun solve(observations: List<RangeObservation>, maxHDOP: Double = RangeGeometry.maxHDOP): GeometrySolution? {
            // One observation per anchor: the latest.
            val latest = HashMap<String, RangeObservation>()
            for (o in observations) {
                val old = latest[o.anchor.id]
                if (old == null || old.window.t < o.window.t) latest[o.anchor.id] = o
            }
            val obs = latest.values.sortedBy { it.anchor.id }
            if (obs.isEmpty()) return null
            val t = obs.maxOf { it.window.t }
            if (obs.size == 1) return proximity(obs[0], t)
            val disc = tightestDisc(obs, t)
            if (obs.size != 2) return multilaterate(obs, maxHDOP, t) ?: disc
            // A candidate pair looser than the best single disc only says less.
            val pair = twoAnchors(obs, t)
            if (pair == null || !(pair.r95 < disc.r95)) return disc
            return pair
        }

        internal fun proximity(o: RangeObservation, t: TimeInterval): GeometrySolution {
            val r = o.discRadius95
            return GeometrySolution(
                kind = GeometrySolution.Kind.proximity, center = o.anchor.position,
                covariance = Covariance2.isotropic(sigma = r / Stats.r95PerSigma), r95 = r,
                candidates = emptyList(), hdop = null, anchorIds = listOf(o.anchor.id), t = t,
            )
        }

        internal fun tightestDisc(obs: List<RangeObservation>, t: TimeInterval): GeometrySolution =
            proximity(obs.minWith { a, b -> if (a.discRadius95 < b.discRadius95) -1 else if (b.discRadius95 < a.discRadius95) 1 else 0 }, t)

        /**
         * Whitened residuals and their Jacobian at p, in dB (log-distance), with the anchor's own
         * uncertainty mapped into each sigma. Huber weights make one blocked link count less.
         */
        internal fun residuals(obs: List<RangeObservation>, at: Vec2): Residuals {
            val p = at
            val r = DoubleArray(obs.size)
            val jx = DoubleArray(obs.size)
            val jz = DoubleArray(obs.size)
            for ((i, o) in obs.withIndex()) {
                val m = o.model
                val a = o.anchor.position
                val dx = p.x - a.x
                val dz = p.z - a.z
                val dist = max(m.minDistance, hypot(dx, dz))
                val grad = m.slope / dist
                val sa = o.anchor.sigma(at = o.window.t)
                val sigma = sqrt(m.totalSigma * m.totalSigma + grad * grad * sa * sa)
                val predicted = m.expectedRSSI(distance = dist)
                if (m.isCensored(rssi = o.window.median) && predicted < o.window.median) {
                    // Near the receiver's floor a reading only bounds the distance from below:
                    // being farther than it suggests costs nothing.
                    r[i] = 0.0
                    jx[i] = 0.0
                    jz[i] = 0.0
                    continue
                }
                r[i] = (o.window.median - predicted) / sigma
                // Derivative of the whitened residual: d(predicted)/dp = -slope (p - a) / d².
                val s = if (hypot(dx, dz) > m.minDistance) m.slope / (dist * dist) / sigma else 0.0
                jx[i] = s * dx
                jz[i] = s * dz
            }
            return Residuals(r, jx, jz)
        }

        internal fun cost(r: DoubleArray): Double {
            // Huber loss with k = 1.5 sigma.
            var sum = 0.0
            for (v in r) sum += if (abs(v) <= 1.5) v * v else 3 * abs(v) - 2.25
            return sum
        }

        /** Levenberg-Marquardt on the robust cost from one start point. */
        internal fun refine(obs: List<RangeObservation>, from: Vec2): Refinement? {
            var p = from
            var lambda = 1e-2
            var res = residuals(obs, p)
            var c = cost(res.r)
            for (iteration in 0 until 40) {
                var a11 = 0.0
                var a12 = 0.0
                var a22 = 0.0
                var b1 = 0.0
                var b2 = 0.0
                val r = res.r
                val jx = res.jx
                val jz = res.jz
                for (i in r.indices) {
                    val w = if (abs(r[i]) <= 1.5) 1.0 else 1.5 / abs(r[i])
                    // Gauss-Newton on the residual Jacobian J: (JᵀWJ) dp = -JᵀW r.
                    a11 += w * jx[i] * jx[i]
                    a12 += w * jx[i] * jz[i]
                    a22 += w * jz[i] * jz[i]
                    b1 += w * jx[i] * r[i]
                    b2 += w * jz[i] * r[i]
                }
                b1 = -b1
                b2 = -b2
                val d11 = a11 * (1 + lambda) + 1e-9
                val d22 = a22 * (1 + lambda) + 1e-9
                val det = d11 * d22 - a12 * a12
                if (!(abs(det) > 1e-15)) break
                val step = Vec2(x = (d22 * b1 - a12 * b2) / det, z = (d11 * b2 - a12 * b1) / det)
                val candidate = p + step
                val next = residuals(obs, candidate)
                val nc = cost(next.r)
                if (nc < c) {
                    p = candidate
                    res = next
                    val improvement = c - nc
                    c = nc
                    lambda = max(1e-6, lambda / 3)
                    if (step.length < 0.01 || improvement < 1e-6) break
                } else {
                    lambda *= 4
                    if (lambda > 1e6) break
                }
            }
            var a11 = 0.0
            var a12 = 0.0
            var a22 = 0.0
            for (i in res.r.indices) {
                a11 += res.jx[i] * res.jx[i]
                a12 += res.jx[i] * res.jz[i]
                a22 += res.jz[i] * res.jz[i]
            }
            val det = a11 * a22 - a12 * a12
            if (!(det > 1e-12)) return null
            return Refinement(p, c, Covariance2(xx = a22 / det, xz = -a12 / det, zz = a11 / det))
        }

        internal fun hdop(obs: List<RangeObservation>, at: Vec2): Double? {
            var a11 = 0.0
            var a12 = 0.0
            var a22 = 0.0
            for (o in obs) {
                val d = o.anchor.position - at
                val l = d.length
                if (!(l > 1e-6)) continue
                a11 += d.x * d.x / (l * l)
                a12 += d.x * d.z / (l * l)
                a22 += d.z * d.z / (l * l)
            }
            val det = a11 * a22 - a12 * a12
            if (!(det > 1e-9)) return null
            return sqrt((a11 + a22) / det)
        }

        /** Circle intersections of two median ranges (one point when they only touch or miss). */
        internal fun intersections(a: Vec2, ra: Double, b: Vec2, rb: Double): List<Vec2> {
            val d = a.distance(to = b)
            if (!(d > 1e-6)) return listOf(a)
            val u = (b - a) * (1 / d)
            if (ra + rb <= d || abs(ra - rb) >= d) {
                // No crossing: the best point lies on the line through the anchors.
                val along = if (ra + rb <= d) ra + (d - ra - rb) / 2 else (if (ra > rb) ra else -ra)
                return listOf(a + u * along)
            }
            val x = (ra * ra - rb * rb + d * d) / (2 * d)
            val h = sqrt(max(0.0, ra * ra - x * x))
            val base = a + u * x
            val perp = Vec2(x = -u.z, z = u.x)
            return listOf(base + perp * h, base - perp * h)
        }

        internal fun twoAnchors(obs: List<RangeObservation>, t: TimeInterval): GeometrySolution? {
            val a = obs[0]
            val b = obs[1]
            val starts = intersections(
                a.anchor.position, a.model.medianDistance(rssi = a.window.median),
                b.anchor.position, b.model.medianDistance(rssi = b.window.median),
            )
            val solutions = starts.mapNotNull { refine(obs, it) }
            if (solutions.isEmpty()) return null
            return covering(
                solutions.map { Pair(it.p, it.info) }, kind = GeometrySolution.Kind.ambiguous,
                anchorIds = obs.map { it.anchor.id }, hdop = null, t = t,
            )
        }

        /** A Gaussian over every candidate: centre between them, radius reaching each one's own r95. */
        internal fun covering(
            parts: List<Pair<Vec2, Covariance2>>,
            kind: GeometrySolution.Kind,
            anchorIds: List<String>,
            hdop: Double?,
            t: TimeInterval,
        ): GeometrySolution {
            val center = parts.fold(Vec2.zero) { acc, it -> acc + it.first } * (1 / parts.size.toDouble())
            val r95 = parts.map { it.first.distance(to = center) + it.second.r95 }.maxOrNull() ?: 0.0
            return GeometrySolution(
                kind = kind, center = center, covariance = Covariance2.isotropic(sigma = r95 / Stats.r95PerSigma),
                r95 = r95, candidates = parts.map { it.first }, hdop = hdop, anchorIds = anchorIds, t = t,
            )
        }

        internal fun multilaterate(obs: List<RangeObservation>, maxHDOP: Double, t: TimeInterval): GeometrySolution? {
            // Start from the weighted centroid and from every pairwise circle intersection, so a
            // mirror solution is found if it exists rather than hidden by the start point.
            val starts = ArrayList<Vec2>()
            var sw = 0.0
            var centroid = Vec2.zero
            for (o in obs) {
                val d = o.model.medianDistance(rssi = o.window.median)
                val w = 1 / max(1.0, d * d)
                centroid = centroid + o.anchor.position * w
                sw += w
            }
            starts.add(centroid * (1 / sw))
            for (i in obs.indices) {
                for (j in obs.indices) {
                    if (j <= i) continue
                    starts += intersections(
                        obs[i].anchor.position, obs[i].model.medianDistance(rssi = obs[i].window.median),
                        obs[j].anchor.position, obs[j].model.medianDistance(rssi = obs[j].window.median),
                    )
                }
            }
            val solutions = starts.mapNotNull { refine(obs, it) }.sortedWith { l, r -> if (l.cost < r.cost) -1 else if (r.cost < l.cost) 1 else 0 }
            val best = solutions.firstOrNull() ?: return null
            val h = hdop(obs, best.p) ?: return null
            if (!(h <= maxHDOP)) return null

            // Inflate by the reduced chi-square when the residuals are larger than the model says.
            val dof = max(1, obs.size - 2).toDouble()
            val scale = max(1.0, best.cost / dof)
            val info = Covariance2(xx = best.info.xx * scale, xz = best.info.xz * scale, zz = best.info.zz * scale)

            // A second minimum that fits about as well and lies outside the best one's error disc
            // is a mirror ambiguity (e.g. three nearly collinear anchors).
            val rivals = solutions.drop(1).filter {
                it.cost - best.cost < Stats.chi2_1dof_95 && it.p.distance(to = best.p) > max(3.0, info.r95)
            }
            val rival = rivals.firstOrNull()
            if (rival != null) {
                return covering(
                    listOf(Pair(best.p, info), Pair(rival.p, rival.info)), kind = GeometrySolution.Kind.ambiguous,
                    anchorIds = obs.map { it.anchor.id }, hdop = h, t = t,
                )
            }
            return GeometrySolution(
                kind = GeometrySolution.Kind.multilateration, center = best.p, covariance = info, r95 = info.r95,
                candidates = emptyList(), hdop = h, anchorIds = obs.map { it.anchor.id }, t = t,
            )
        }
    }

    // MARK: RSSICalibration.swift

    /**
     * Collects RSSI from one peer while the two phones stand at marked distances, then fits the
     * path-loss model. Workflow: put the phones at the first marked distance (tape measure, same
     * height, same way they will be carried), `begin`, wait until `isStepComplete`, `end`, move to
     * the next distance. At least three distances spanning 4x are required; the suggested set
     * spans 1-16 m because ranges beyond that are where the demo needs to tell "near" from "far".
     *
     * A value type in Swift: use `copy()` where Swift code copies one.
     */
    @Serializable
    class CalibrationSession(
        val peerId: String,
        val channel: RSSIChannel,
        /** Phone models of this phone and the peer: calibration does not transfer between models. */
        val observerModel: String,
        val peerModel: String,
        val environment: String,
    ) {
        @Serializable
        data class Step(
            val distance: Double,
            /** Free text: orientation, obstruction, "in hand", "pocket", ... */
            val label: String,
            var samples: List<RSSISample>,
        )

        var minSamplesPerStep = 40
        var minDurationPerStep: TimeInterval = 20.0

        var steps: List<Step> = emptyList()
            private set
        var activeStep: Int? = null
            private set

        fun begin(distance: Double, label: String = "") {
            if (!(distance.isFinite() && distance > 0)) return
            steps = steps + Step(distance = distance, label = label, samples = emptyList())
            activeStep = steps.size - 1
        }

        /** Records a sample if a step is active and it comes from the calibrated peer and channel. */
        fun record(sample: RSSISample): Boolean {
            val i = activeStep ?: return false
            if (!(sample.peerId == peerId && sample.channel == channel && RSSIMedianFilter.isValid(sample.rssi))) return false
            steps = steps.toMutableList().also { it[i] = it[i].copy(samples = it[i].samples + sample) }
            return true
        }

        fun end() {
            activeStep = null
        }

        /** Drops the last step, e.g. after someone walked between the phones. */
        fun discardLastStep() {
            if (steps.isNotEmpty()) steps = steps.dropLast(1)
            activeStep = null
        }

        val isStepComplete: Boolean
            get() {
                val i = activeStep ?: return false
                val first = steps[i].samples.firstOrNull() ?: return false
                val last = steps[i].samples.last()
                return steps[i].samples.size >= minSamplesPerStep && last.t - first.t >= minDurationPerStep
            }

        /**
         * Fits the model. `window` must match the engine's median window, since the fitted spread
         * describes window medians, not raw samples.
         */
        fun fit(window: TimeInterval = 4.0, date: String = ""): CalibrationResult =
            CalibrationFit.fit(
                steps = steps.filter { it.samples.isNotEmpty() }, window = window, channel = channel,
                source = "calibrated $date $observerModel->$peerModel ${channel.rawValue} $environment",
            )

        fun copy(): CalibrationSession {
            val c = CalibrationSession(peerId, channel, observerModel, peerModel, environment)
            c.minSamplesPerStep = minSamplesPerStep
            c.minDurationPerStep = minDurationPerStep
            c.steps = steps
            c.activeStep = activeStep
            return c
        }

        override fun equals(other: Any?): Boolean =
            other is CalibrationSession && peerId == other.peerId && channel == other.channel &&
                observerModel == other.observerModel && peerModel == other.peerModel &&
                environment == other.environment && minSamplesPerStep == other.minSamplesPerStep &&
                minDurationPerStep == other.minDurationPerStep && steps == other.steps && activeStep == other.activeStep

        override fun hashCode(): Int = listOf(peerId, channel, observerModel, peerModel, environment, steps).hashCode()

        companion object {
            val suggestedDistances: List<Double> = listOf(1.0, 2.0, 3.0, 5.0, 8.0, 12.0, 16.0)
        }
    }

    sealed class CalibrationError : Exception() {
        data class tooFewDistances(val found: Int) : CalibrationError()
        data class distanceSpanTooSmall(val ratio: Double) : CalibrationError()
        data class tooFewWindows(val distance: Double) : CalibrationError()
        data class nonPhysicalFit(val n: Double) : CalibrationError()
    }

    @Serializable
    data class CalibrationResult(
        val model: PathLossModel,
        val distances: List<DistanceSummary>,
        val rSquared: Double,
        /** RMS of distance medians around the line, dB. */
        val residualRMS: Double,
        /** Leave-one-distance-out: each distance predicted by a fit to the others. */
        val leaveOneOutRMS: Double,
        /** Median of |predicted / true - 1| for the held-out distances' median range. */
        val leaveOneOutRangeError: Double,
        val warnings: List<String>,
    ) {
        @Serializable
        data class DistanceSummary(
            val distance: Double,
            /** Median of the window medians at this distance, dBm. */
            val rssi: Double,
            val windows: Int,
            /** Robust spread of the window medians at this distance, dB. */
            val spread: Double,
            /** Measured minus fitted, dB. */
            val residual: Double,
        )
    }

    internal object CalibrationFit {
        /** Swift's `(x: Double, y: Double)` tuple. */
        data class Point(val x: Double, val y: Double)

        /** Swift's `(p0: Double, n: Double)` tuple. */
        data class Line(val p0: Double, val n: Double)

        /** Splits a step's samples into consecutive windows and returns the window medians. */
        fun windowMedians(samples: List<RSSISample>, window: TimeInterval, channel: RSSIChannel): List<Double> {
            val sorted = samples.sortedBy { it.t }
            val start = sorted.firstOrNull()?.t ?: return emptyList()
            val groups = HashMap<Int, MutableList<RSSISample>>()
            for (s in sorted) groups.getOrPut(((s.t - start) / window).toInt()) { ArrayList() }.add(s)
            return groups.keys.sorted().mapNotNull { k ->
                RSSIMedianFilter.summarize(groups[k]!!, peerId = "", channel = channel, minSamples = 2)?.median
            }
        }

        /** Huber-weighted least squares for y = p0 + n * x with x = -10 log10(d). */
        fun line(points: List<Point>): Line? {
            if (points.size < 2) return null
            var weights = List(points.size) { 1.0 }
            var result: Line? = null
            for (iteration in 0 until 10) {
                val sw = weights.fold(0.0) { acc, w -> acc + w }
                var sx = 0.0
                var sy = 0.0
                for (i in points.indices) sx += points[i].x * weights[i]
                for (i in points.indices) sy += points[i].y * weights[i]
                val mx = sx / sw
                val my = sy / sw
                var sxx = 0.0
                var sxy = 0.0
                for (i in points.indices) {
                    val p = points[i]
                    val w = weights[i]
                    sxx += w * (p.x - mx) * (p.x - mx)
                    sxy += w * (p.x - mx) * (p.y - my)
                }
                if (!(sxx > 1e-9)) return null
                val n = sxy / sxx
                val p0 = my - n * mx
                result = Line(p0, n)
                val residuals = points.map { it.y - (p0 + n * it.x) }
                val scale = max(1.0, Stats.robustSpread(residuals, around = 0.0))
                val k = 1.345 * scale
                weights = residuals.map { if (abs(it) <= k) 1.0 else k / abs(it) }
            }
            return result
        }

        fun fit(steps: List<CalibrationSession.Step>, window: TimeInterval, channel: RSSIChannel, source: String): CalibrationResult {
            // Repeated steps at one distance (e.g. two orientations) pool their windows.
            val byDistance = HashMap<Double, MutableList<Double>>()
            for (step in steps) {
                val medians = windowMedians(step.samples, window, channel)
                byDistance.getOrPut(step.distance) { ArrayList() }.addAll(medians)
            }
            val distances = byDistance.keys.sorted()
            if (distances.size < 3) throw CalibrationError.tooFewDistances(found = distances.size)
            val ratio = distances.last() / distances.first()
            if (!(ratio >= 4)) throw CalibrationError.distanceSpanTooSmall(ratio = ratio)
            for (d in distances) if ((byDistance[d]?.size ?: 0) < 2) throw CalibrationError.tooFewWindows(distance = d)

            val centers = distances.map { Stats.median(byDistance[it]!!)!! }
            val points = distances.indices.map { Point(x = -10 * log10(distances[it]), y = centers[it]) }
            val fitted = line(points) ?: throw CalibrationError.distanceSpanTooSmall(ratio = ratio)
            val p0 = fitted.p0
            val n = fitted.n
            if (!(n > 0.5 && n < 6)) throw CalibrationError.nonPhysicalFit(n = n)

            val residuals = points.map { it.y - (p0 + n * it.x) }
            val residualRMS = sqrt(residuals.map { it * it }.fold(0.0) { a, b -> a + b } / residuals.size.toDouble())
            val meanY = points.map { it.y }.fold(0.0) { a, b -> a + b } / points.size.toDouble()
            val ssTot = points.map { (it.y - meanY) * (it.y - meanY) }.fold(0.0) { a, b -> a + b }
            val rSquared = if (ssTot > 0) 1 - residuals.map { it * it }.fold(0.0) { a, b -> a + b } / ssTot else 0.0

            // Spread of window medians around their own distance's median: fading after the filter.
            val deviations = ArrayList<Double>()
            for (i in distances.indices) deviations += byDistance[distances[i]]!!.map { it - centers[i] }
            val sigmaFast = max(1.0, Stats.robustSpread(deviations, around = 0.0))

            val looResiduals = ArrayList<Double>()
            val looRangeErrors = ArrayList<Double>()
            for (i in points.indices) {
                if (!(points.size > 3)) continue
                val rest = points.toMutableList()
                rest.removeAt(i)
                val l = line(rest) ?: continue
                if (!(l.n > 0)) continue
                looResiduals.add(points[i].y - (l.p0 + l.n * points[i].x))
                val predicted = 10.0.pow((l.p0 - centers[i]) / (10 * l.n))
                looRangeErrors.add(abs(predicted / distances[i] - 1))
            }
            val looRMS = if (looResiduals.isEmpty()) residualRMS
            else sqrt(looResiduals.map { it * it }.fold(0.0) { a, b -> a + b } / looResiduals.size.toDouble())

            val warnings = ArrayList<String>()
            // One calibration walk sees one spot per distance, so it underestimates spot-to-spot
            // shadowing; outdoors 4-8 dB is typical. Never let a lucky fit claim less than 3 dB.
            // Each distance's centre is a median over many windows, so fading barely reaches it.
            val sigmaShadow = max(3.0, residualRMS)
            if (residualRMS < 3) warnings.add("Shadowing floored at 3 dB: one calibration walk cannot measure spot-to-spot variation.")
            if (n < 1.6 || n > 4.5) warnings.add(format("Path-loss exponent %.2f is outside the usual 1.6-4.5.", n))
            if (p0 > -35 || p0 < -85) warnings.add(format("RSSI at 1 m of %.1f dBm is unusual for phones.", p0))
            if (distances.size < 5) warnings.add("Fewer than 5 distances: the leave-one-out check is weak.")
            if (rSquared < 0.8) warnings.add(format("R² %.2f: RSSI barely follows distance here; ranges will be wide.", rSquared))

            val model = PathLossModel(p0 = p0, n = n, sigmaFast = sigmaFast, sigmaShadow = sigmaShadow, source = source)
            val summaries = distances.indices.map { i ->
                CalibrationResult.DistanceSummary(
                    distance = distances[i], rssi = centers[i], windows = byDistance[distances[i]]!!.size,
                    spread = Stats.robustSpread(byDistance[distances[i]]!!, around = centers[i]),
                    residual = residuals[i],
                )
            }
            return CalibrationResult(
                model = model, distances = summaries, rSquared = rSquared, residualRMS = residualRMS,
                leaveOneOutRMS = looRMS, leaveOneOutRangeError = Stats.median(looRangeErrors) ?: Double.NaN,
                warnings = warnings,
            )
        }
    }

    // MARK: PositionEngine.swift

    /** A GNSS fix in the shared frame. */
    @Serializable
    data class GNSSFix(
        /** Local monotonic time of the fix (Core Location's timestamp converted on entry). */
        val t: TimeInterval,
        val position: Vec2,
        /** Core Location `horizontalAccuracy`: radius of ~68 % confidence, m. */
        val horizontalAccuracy: Double,
        /** Course over ground, radians clockwise from true north, and its 1-sigma. */
        val course: Double? = null,
        val courseSigma: Double? = null,
        val speed: Double? = null,
        /**
         * The integrity check accepted this fix as trusted. Untrusted fixes are recorded in the
         * provenance and never used as a position constraint.
         */
        val trusted: Boolean,
    ) {
        companion object {
            /** From latitude/longitude through the shared `GeoFrame`; nil outside the frame. */
            fun make(
                frameId: String,
                t: TimeInterval,
                latitude: Double,
                longitude: Double,
                horizontalAccuracy: Double,
                courseDegrees: Double? = null,
                courseAccuracyDegrees: Double? = null,
                speed: Double? = null,
                trusted: Boolean,
            ): GNSSFix? {
                if (!(horizontalAccuracy.isFinite() && horizontalAccuracy > 0)) return null
                val p = GeoFrame.position(frameId = frameId, latitude = latitude, longitude = longitude) ?: return null
                val course = courseDegrees?.let { if (it >= 0) degrees(it) else null }
                val sigma = courseAccuracyDegrees?.let { if (it > 0) degrees(it) else null }
                return GNSSFix(
                    t = t, position = Vec2(x = p.x, z = p.z), horizontalAccuracy = horizontalAccuracy,
                    course = course, courseSigma = if (course == null) null else sigma,
                    speed = speed?.let { if (it >= 0) it else null }, trusted = trusted,
                )
            }
        }
    }

    /** One piece of evidence the engine considered, kept for provenance. */
    @Serializable
    data class Contribution(
        val source: Source,
        val peerId: String?,
        /** Local monotonic time the evidence describes. */
        val t: TimeInterval,
        val used: Boolean,
        val reason: String?,
    ) {
        @Serializable
        enum class Source(val rawValue: String) {
            @SerialName("gnss") gnss("gnss"),
            @SerialName("gnssCourse") gnssCourse("gnssCourse"),
            @SerialName("compass") compass("compass"),
            @SerialName("steps") steps("steps"),
            @SerialName("stationary") stationary("stationary"),
            @SerialName("bleRange") bleRange("bleRange"),
            @SerialName("bleProximity") bleProximity("bleProximity"),
            @SerialName("bleMultilateration") bleMultilateration("bleMultilateration"),
            @SerialName("bleAmbiguous") bleAmbiguous("bleAmbiguous"),
            @SerialName("declared") declared("declared"),
        }
    }

    /**
     * The engine's answer. `position` is set only for point estimates; proximity and ambiguous
     * results give a region (`regionCenter`, `r95`, `candidates`) that must be drawn as a region.
     */
    data class Estimate(
        val method: Method,
        val frameId: String,
        /** Local monotonic time the estimate describes. */
        val t: TimeInterval,
        val position: Vec2?,
        val regionCenter: Vec2?,
        val covariance: Covariance2?,
        val r95: Double?,
        val candidates: List<Vec2>,
        /** Walking direction, radians clockwise from north, and its 1-sigma. */
        val heading: Double?,
        val headingSigma: Double?,
        /** Last time any absolute evidence (trusted GNSS, a Bluetooth range, a declared spot) was used. */
        val lastAbsoluteAt: TimeInterval?,
        val lastTrustedGNSS: GNSSFix?,
        val anchorIds: List<String>,
        /** The estimate rests on GNSS somewhere (own fix or a GNSS anchor). */
        val gnssDependent: Boolean,
        val provenance: List<Contribution>,
        val flags: List<Flag>,
    ) {
        @Serializable
        enum class Method(val rawValue: String) {
            /** Trusted GNSS fix within the last few seconds. */
            @SerialName("gnss") gnss("gnss"),
            /** Steps and heading from the last absolute constraint, nothing newer. */
            @SerialName("deadReckoning") deadReckoning("deadReckoning"),
            /** Dead reckoning corrected by Bluetooth ranges to known anchors. */
            @SerialName("fused") fused("fused"),
            /** Three or more anchors with good geometry, no history needed. */
            @SerialName("multilateration") multilateration("multilateration"),
            /** Only "within r95 of this anchor" is known. */
            @SerialName("proximity") proximity("proximity"),
            /** Two (or mirror) candidate spots; neither may be shown as the position. */
            @SerialName("ambiguous") ambiguous("ambiguous"),
            /** Hand-entered or surveyed spot. */
            @SerialName("declared") declared("declared"),
            @SerialName("unavailable") unavailable("unavailable"),
        }

        @Serializable
        enum class Flag(val rawValue: String) {
            /** Walking direction is unknown or worse than 45°: steps only widen the circle. */
            @SerialName("headingUnreliable") headingUnreliable("headingUnreliable"),
            /** No motion data recently: uncertainty grows at walking pace in every direction. */
            @SerialName("motionUnavailable") motionUnavailable("motionUnavailable"),
            /** The compass is being rejected as disturbed or inconsistent. */
            @SerialName("compassRejected") compassRejected("compassRejected"),
            /** The latest trusted GNSS fix was rejected by the innovation gate. */
            @SerialName("gnssRejected") gnssRejected("gnssRejected"),
            /** Bluetooth evidence and dead reckoning disagreed and the engine restarted from Bluetooth. */
            @SerialName("restartedFromBluetooth") restartedFromBluetooth("restartedFromBluetooth"),
            /** Residuals ran larger than the model predicts, so the uncertainty was widened. */
            @SerialName("widenedByResiduals") widenedByResiduals("widenedByResiduals"),
        }

        /** Seconds since the last absolute evidence. */
        val age: TimeInterval? get() = lastAbsoluteAt?.let { max(0.0, t - it) }
    }

    /** The local motion summary the trust engine and predictor consume (contract `MotionObservation`). */
    data class MotionSummary(
        val t: TimeInterval,
        val stationary: Boolean,
        /**
         * Steps in the last `window` seconds, their scaled length and the dead-reckoned
         * displacement over the window (x east, z north) with its 95 % radius.
         */
        val steps: Int,
        val distance: Double,
        val displacement: Vec2,
        val displacementR95: Double,
        val window: TimeInterval,
        val heading: Double?,
        val headingSigma: Double?,
        val strideScale: Double,
    )

    /**
     * Self-positioning for one phone: an extended Kalman filter over [x, z, device heading, gyro
     * bias, carry offset, stride scale, compass bias, GNSS error x/z, pace change, one shadowing bias
     * per anchor].
     *
     * - Trusted GNSS fixes and course over ground anchor it; the last trusted fix stays the origin
     *   of dead reckoning after GNSS is lost.
     * - The gyro carries heading between compass readings; the compass and GNSS course correct it;
     *   the bias is learned from them and whenever the phone is still. The carry offset (walking
     *   direction minus device heading) is learned from GNSS course.
     * - Local magnetic disturbance is a compass-bias state that decorrelates with distance walked, so
     *   a steel railing bends the compass state, not the heading. The correlated part of GNSS error
     *   (multipath) is a state too, so averaging many fixes cannot claim more than GNSS supports.
     * - Steps move the position along the walking direction; the stride scale is learned from GNSS,
     *   and a fast pace-change state covers speeding up and slowing down that the accelerometer
     *   amplitude does not show.
     * - Bluetooth: with a tight prior each median RSSI window against a known anchor is a range
     *   update (iterated EKF) with that link's shadowing as a state, so a static link cannot shrink
     *   the uncertainty forever. With a broad prior the windows go through `RangeGeometry`
     *   (proximity disc / ambiguous / multilateration) and only tighten the estimate.
     * - Unknown heading or missing motion data grow the circle at the distance that may have been
     *   walked, not as a random walk, so a straight walk away stays covered.
     * - Self-check: the normalized innovations of range updates and GNSS fixes are tracked; when the
     *   residuals run larger than the filter predicted, its noise is widened (and flagged) instead of
     *   keeping a confident r95 the evidence contradicts.
     */
    class Engine(val selfId: String, val frameId: String, config: Config = Config()) {
        /** A value type in Swift: the engine keeps its own deep copy (`copy()` alone shares `models`). */
        data class Config(
            var models: MutableMap<RSSIChannel, PathLossModel> = linkedMapOf(
                RSSIChannel.advertisement to PathLossModel.defaultOutdoor,
                RSSIChannel.connection to PathLossModel.defaultOutdoor,
                RSSIChannel.reciprocal to PathLossModel.defaultOutdoor,
                RSSIChannel.relayedSmoothed to PathLossModel(
                    p0 = -59.0, n = 2.5, sigmaFast = 3.5, sigmaShadow = 5.0, source = "default-outdoor-relayed",
                ),
            ),
            var useBluetooth: Boolean = true,
            var useMotion: Boolean = true,
            var useCompass: Boolean = true,
            var medianWindow: TimeInterval = 4.0,

            /** A trusted fix counts as "gnss" for this long. */
            var gnssFreshFor: TimeInterval = 3.0,
            /** Measurements later than this behind the filter clock are dropped as stale. */
            var maxLag: TimeInterval = 2.0,
            /** RSSI windows (median time) older than this are stale. */
            var maxWindowAge: TimeInterval = 8.0,
            var anchorMaxAge: TimeInterval = 30.0,
            var anchorMaxSigma: Double = 50.0,
            var maxAnchorDepth: Int = 3,

            /** Gyro angle random walk, rad/√s, and bias random walk, rad/s/√s. */
            var gyroNoise: Double = 0.004,
            var gyroBiasWalk: Double = 0.0002,
            var initialBiasSigma: Double = degrees(0.5),
            /** Heading random walk when no gyro is available, rad/√s. */
            var headingWalkWithoutGyro: Double = degrees(15.0),
            var carryOffsetSigma: Double = degrees(20.0),
            var strideScaleSigma: Double = 0.15,
            var strideScaleWalk: Double = 0.001,
            /** Pace changes the step model misses: relative 1-sigma and time constant. */
            var paceChangeSigma: Double = 0.12,
            var paceChangeTime: TimeInterval = 30.0,
            /** Local magnetic disturbance: 1-sigma, and the distance and time over which it changes. */
            var compassBiasSigma: Double = degrees(8.0),
            var compassBiasDistance: Double = 15.0,
            var compassBiasTime: TimeInterval = 300.0,
            /** Share of a fix's sigma that varies slowly (multipath, atmosphere), and its time constant. */
            var gnssCorrelatedFraction: Double = 0.7,
            var gnssCorrelationTime: TimeInterval = 30.0,
            /** Per-step along/cross-track noise as a fraction of the step. */
            var stepAlongNoise: Double = 0.10,
            var stepCrossNoise: Double = 0.06,
            /** Motion the steps do not explain (shuffling, swaying), m/s random walk. */
            var unexplainedSpeed: Double = 0.12,
            var stationarySpeed: Double = 0.01,
            /** Assumed pace when motion data is missing, m/s. */
            var walkingSpeed: Double = 1.4,
            var headingUnknownAbove: Double = degrees(45.0),

            /** Range updates need sigma below this fraction of the anchor distance, and below `tightPriorMax`. */
            var tightPriorRatio: Double = 0.6,
            var tightPriorMax: Double = 15.0,
            var forgetAnchorBiasAfter: TimeInterval = 60.0,
            /** Shadowing also decorrelates slowly with time (people, doors), s. */
            var shadowTimeConstant: TimeInterval = 300.0,
            /** Consecutive mutually consistent trusted fixes rejected before the filter is reset to GNSS. */
            var gnssResetAfter: Int = 10,
            /** Consecutive disagreements before dead reckoning is abandoned for the Bluetooth solution. */
            var bluetoothResetAfter: Int = 3,
            /** Self-check: ceiling of the noise widening, and the averaging weight per update. */
            var maxWidening: Double = 6.0,
            var residualAveraging: Double = 0.1,
            /** Above this the estimate is reported unavailable rather than as a giant circle. */
            var maxUsefulR95: Double = 500.0,
        ) {
            /** Swift value copy, including the models dictionary and each model. */
            fun deepCopy(): Config = copy(models = models.entries.associateTo(LinkedHashMap()) { it.key to it.value.copy() })
        }

        @Suppress("ConstPropertyName")
        internal companion object {
            const val X = 0
            const val Z = 1
            const val PSI = 2
            const val BIAS = 3
            const val CARRY = 4
            const val SCALE = 5
            const val MAG = 6
            const val GX = 7
            const val GZ = 8
            const val PACE = 9
            const val BASE = 10
            const val version = "ghostcore-positioning@0.1"
        }

        private val cfg: Config = config.deepCopy()

        /** Swift `public private(set) var config`: reading returns a copy. */
        val config: Config get() = cfg.deepCopy()

        private var x: DoubleArray = doubleArrayOf(0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0)
        private var P = Matrix(rows = 10, cols = 10)
        /** Sigma of the latest trusted fix, which sets the level of the GNSS error states. */
        private var gnssSigma = 3.0
        private val biasIndex: MutableMap<String, Int> = HashMap()

        private data class BiasLink(val walked: Double, val anchor: Vec2, val t: TimeInterval)

        private val biasLink: MutableMap<String, BiasLink> = HashMap()

        private var positionReady = false
        private var headingReady = false
        private var filterTime: TimeInterval? = null
        private var headingTime: TimeInterval? = null
        private var lastMotionT: TimeInterval? = null
        private var stationary = false
        private var lastZeroRateUpdate: TimeInterval = Double.NEGATIVE_INFINITY
        /** Distance that may have been walked in an unknown direction since the heading was lost. */
        private var unknownHeadingDistance = 0.0
        private var noMotionDistance = 0.0

        private val stepDetector = StepDetector()
        private val stillness = StationarityDetector()
        private val rssi: RSSIMedianFilter = RSSIMedianFilter(window = cfg.medianWindow)
        private val anchors: MutableMap<String, Anchor> = HashMap()
        private val latestWindows: MutableMap<String, RSSIWindow> = HashMap()
        private var geometry: GeometrySolution? = null

        private data class TrailPoint(val t: TimeInterval, val d: Vec2)
        private data class RecentStep(val t: TimeInterval, val length: Double)

        /** Cumulative dead-reckoned displacement, to move late measurements to their own time. */
        private var displacement = Vec2.zero
        private val trail: MutableList<TrailPoint> = ArrayList()
        private var walked = 0.0
        private val recentSteps: MutableList<RecentStep> = ArrayList()

        private var initSource: Estimate.Method? = null
        /** False while the point only rests on a disc it started from (shown as that region). */
        private var pointConfirmed = true
        private var lastAbsoluteAt: TimeInterval? = null
        private var lastGNSSUpdate: TimeInterval? = null
        private var lastBluetoothUpdate: TimeInterval? = null
        private var lastTrustedFix: GNSSFix? = null
        private var gnssDependent = false
        private val usedAnchors: MutableMap<String, TimeInterval> = HashMap()
        private val gnssRejections: MutableList<GNSSFix> = ArrayList()
        private var bluetoothConflicts = 0
        private var compassRejectedSince: TimeInterval? = null
        private var restartedFromBluetoothAt: TimeInterval? = null
        private val contributions: MutableList<Contribution> = ArrayList()
        /** Moving averages of normalized innovation squared per dimension (1 when consistent). */
        private var rangeNIS = 1.0
        private var gnssNIS = 1.0
        private var lastNIS = 0.0

        private val diag = Diagnostics()

        /** Swift `public private(set) var diagnostics` (a struct): reading returns a copy. */
        val diagnostics: Diagnostics get() = diag.copy()

        /** Current gyro heading-rate bias estimate, rad/s. */
        val gyroBiasEstimate: Double get() = x[BIAS]

        data class Diagnostics(
            var staleDropped: Int = 0,
            var outOfOrderDropped: Int = 0,
            var gnssUntrusted: Int = 0,
            var gnssRejected: Int = 0,
            var compassRejected: Int = 0,
            var rangeUpdates: Int = 0,
            var rangeRejected: Int = 0,
            var geometryUpdates: Int = 0,
            var anchorsRefused: Int = 0,
            var steps: Int = 0,
        )

        init {
            P[PSI, PSI] = PI * PI
            P[BIAS, BIAS] = cfg.initialBiasSigma * cfg.initialBiasSigma
            P[CARRY, CARRY] = cfg.carryOffsetSigma * cfg.carryOffsetSigma
            P[SCALE, SCALE] = cfg.strideScaleSigma * cfg.strideScaleSigma
            P[MAG, MAG] = cfg.compassBiasSigma * cfg.compassBiasSigma
            P[PACE, PACE] = cfg.paceChangeSigma * cfg.paceChangeSigma
            P[GX, GX] = (cfg.gnssCorrelatedFraction * gnssSigma).pow(2)
            P[GZ, GZ] = (cfg.gnssCorrelatedFraction * gnssSigma).pow(2)
            P[X, X] = 1e6
            P[Z, Z] = 1e6
        }

        // MARK: - Inputs

        /** A surveyed or hand-entered position (e.g. "I am at the marked start point"). */
        fun declare(position: Vec2, sigma: Double, at: TimeInterval) {
            val t = at
            advance(max(filterTime ?: t, t))
            pointConfirmed = true
            if (positionReady) {
                positionUpdate(position, Covariance2.isotropic(sigma = sigma))
            } else {
                initializePosition(position, Covariance2.isotropic(sigma = sigma), source = Estimate.Method.declared)
            }
            lastAbsoluteAt = t
            record(Contribution.Source.declared, null, t, used = true, null)
        }

        fun ingest(gnss: GNSSFix) {
            val fix = gnss
            if (!fix.trusted) {
                diag.gnssUntrusted += 1
                record(Contribution.Source.gnss, null, fix.t, used = false, "integrity check did not trust the fix")
                return
            }
            val now = filterTime ?: fix.t
            val late = max(0.0, now - fix.t)
            val sigma = fix.horizontalAccuracy * Stats.radius68ToSigma
            if (!positionReady) {
                // Also how a remembered last fix seeds the filter after a restart: it widens at
                // walking pace for its age, since nobody counted the steps in between.
                val grown = sqrt(sigma * sigma + (cfg.walkingSpeed * late).pow(2))
                advance(max(now, fix.t))
                initializePosition(fix.position, Covariance2.isotropic(sigma = grown), source = Estimate.Method.gnss)
                seedGNSSError(sigma = sigma, fresh = late < 1)
                acceptFix(fix)
                courseUpdate(fix)
                return
            }
            if (!(late <= cfg.maxLag)) {
                diag.staleDropped += 1
                record(Contribution.Source.gnss, null, fix.t, used = false, format("stale by %.1f s", late))
                return
            }
            advance(max(now, fix.t))
            // Where the fix would put us now: add the steps walked since its timestamp.
            val shifted = fix.position + displacementSince(fix.t)
            gnssSigma = sigma * sqrt(gnssWidening)
            // The fix = position + slowly varying GNSS error + white noise.
            val white = (1 - cfg.gnssCorrelatedFraction.pow(2)) * sigma * sigma * gnssWidening +
                (0.1 * displacementSince(fix.t).length).pow(2)
            val applied = update2(
                listOf(Pair(X, 1.0), Pair(GX, 1.0)), listOf(Pair(Z, 1.0), Pair(GZ, 1.0)),
                shifted.x - x[X] - x[GX], shifted.z - x[Z] - x[GZ],
                Covariance2(xx = white, xz = 0.0, zz = white), gate = Stats.chi2_2dof_999,
            )
            gnssNIS = noteResidual(lastNIS, dimensions = 2.0, average = gnssNIS)
            if (applied) {
                gnssRejections.clear()
                acceptFix(fix)
                courseUpdate(fix)
            } else {
                diag.gnssRejected += 1
                gnssRejections.add(fix)
                // A run of trusted fixes that agree with each other but not with us means we are wrong.
                val recent = gnssRejections.takeLast(cfg.gnssResetAfter)
                val first = recent.firstOrNull()
                if (recent.size >= cfg.gnssResetAfter && first != null &&
                    recent.all { it.position.distance(to = first.position) < 3 * first.horizontalAccuracy + cfg.walkingSpeed * (it.t - first.t) }
                ) {
                    initializePosition(fix.position, Covariance2.isotropic(sigma = sigma), source = Estimate.Method.gnss)
                    seedGNSSError(sigma = sigma, fresh = true)
                    acceptFix(fix)
                    gnssRejections.clear()
                    record(
                        Contribution.Source.gnss, null, fix.t, used = true,
                        "filter reset: ${cfg.gnssResetAfter} consistent trusted fixes disagreed with it",
                    )
                } else {
                    record(Contribution.Source.gnss, null, fix.t, used = false, "innovation gate: fix inconsistent with the filter")
                }
            }
        }

        fun ingest(motion: MotionSample) {
            val s = motion
            if (!cfg.useMotion) return
            val ht = headingTime
            if (ht != null && s.t <= ht) {
                diag.outOfOrderDropped += 1
                return
            }
            val rate = DeviceAxes.headingRate(s)
            if (rate != null) {
                val dt = headingTime?.let { s.t - it } ?: 0.0
                if (dt > 0) {
                    if (dt <= 0.25) {
                        predictHeading(rate = rate, dt = dt)
                    } else {
                        // A gap in the gyro stream: heading may have changed by anything a person does.
                        headingWalk(dt = dt, sigma = cfg.headingWalkWithoutGyro)
                    }
                }
            }
            headingTime = s.t
            lastMotionT = s.t
            noMotionDistance = 0.0

            val meanRate = stillness.add(s)
            if (meanRate != null) {
                stationary = true
                if (s.t - lastZeroRateUpdate >= 1) {
                    // Still phone: the true heading rate is zero, so the measured mean is the bias.
                    val h = row(mapOf(BIAS to 1.0))
                    val innovation = meanRate - x[BIAS]
                    if (!scalarUpdate(h, innovation = innovation, r = 0.002 * 0.002, gate = Stats.chi2_1dof_997)) {
                        // The bias estimate went wrong (e.g. a disturbed compass leaked into it):
                        // admit it and take the still phone's word.
                        P[BIAS, BIAS] += innovation * innovation
                        scalarUpdate(h, innovation = innovation, r = 0.002 * 0.002, gate = Double.POSITIVE_INFINITY)
                    }
                    lastZeroRateUpdate = s.t
                }
            } else {
                stationary = false
            }
            stepDetector.add(s)?.let { applyStep(it) }
        }

        /** Steps from another source (e.g. `CMPedometer`); don't also let the built-in detector run. */
        fun ingest(step: StepEvent) {
            applyStep(step)
        }

        fun ingest(compass: CompassSample) {
            val c = compass
            if (!cfg.useCompass) return
            if (!(!c.disturbed && c.sigma.isFinite() && c.sigma > 0)) {
                compassRejected(c.t, "magnetic disturbance")
                return
            }
            val ht = headingTime
            if (ht != null && c.t < ht - 0.5) {
                diag.staleDropped += 1
                return
            }
            if (!headingReady) {
                setHeading(c.heading - x[MAG], sigma = sqrt(c.sigma * c.sigma + P[MAG, MAG]))
                record(Contribution.Source.compass, null, c.t, used = true, "initial heading")
                return
            }
            val h = row(mapOf(PSI to 1.0, MAG to 1.0))
            if (scalarUpdate(h, innovation = wrap(c.heading - x[PSI] - x[MAG]), r = c.sigma * c.sigma, gate = Stats.chi2_1dof_997)) {
                compassRejectedSince = null
            } else {
                compassRejected(c.t, "inconsistent with gyro heading")
            }
        }

        /**
         * A neighbour whose position is known (its trusted GNSS fix, a surveyed spot, or its own
         * estimate). Estimated anchors that depend on this phone are refused, which breaks cycles.
         */
        fun ingest(anchor: Anchor) {
            val a = anchor
            if (!(a.id != selfId && a.position.x.isFinite() && a.position.z.isFinite() && a.sigma.isFinite() &&
                    a.sigma >= 0 && a.sigma <= cfg.anchorMaxSigma)
            ) {
                diag.anchorsRefused += 1
                return
            }
            if (a.kind == Anchor.Kind.estimated && (a.dependsOn.contains(selfId) || a.dependsOn.size > cfg.maxAnchorDepth)) {
                diag.anchorsRefused += 1
                record(Contribution.Source.bleRange, a.id, a.measuredAt, used = false, "anchor estimate depends on this phone or is too many hops deep")
                return
            }
            val old = anchors[a.id]
            if (old != null && old.measuredAt > a.measuredAt) return
            anchors[a.id] = a
        }

        /**
         * Withdraws an anchor at once, e.g. when the integrity check stops trusting its GNSS. Its
         * earlier contributions leave the provenance, replaced by the withdrawal and its reason.
         */
        fun removeAnchor(id: String, at: TimeInterval? = null, reason: String = "anchor withdrawn") {
            val known = anchors[id] != null || usedAnchors[id] != null
            anchors.remove(id)
            latestWindows.remove(id)
            usedAnchors.remove(id)
            removeBias(id)
            val g = geometry
            if (g != null && g.anchorIds.contains(id)) geometry = null
            if (!known) return
            contributions.removeAll { it.peerId == id }
            record(Contribution.Source.bleRange, id, at ?: filterTime ?: 0.0, used = false, reason)
        }

        fun ingest(rssi: RSSISample) {
            if (!(cfg.useBluetooth && rssi.peerId != selfId)) return
            this.rssi.add(rssi)
        }

        fun setModel(model: PathLossModel, `for`: RSSIChannel) {
            cfg.models[`for`] = model.copy()
        }

        // MARK: - Output

        fun estimate(at: TimeInterval): Estimate {
            val t = at
            processBluetooth(now = t)
            advance(max(filterTime ?: t, t))
            pruneAnchors(now = t)

            val flags = ArrayList<Estimate.Flag>()
            val headingSigma = walkingHeadingSigma
            if (!headingReady || headingSigma > cfg.headingUnknownAbove) flags.add(Estimate.Flag.headingUnreliable)
            if (cfg.useMotion && (lastMotionT?.let { t - it > 1.5 } ?: true)) flags.add(Estimate.Flag.motionUnavailable)
            if (compassRejectedSince?.let { t - it > 5 } ?: false) flags.add(Estimate.Flag.compassRejected)
            if (gnssRejections.isNotEmpty()) flags.add(Estimate.Flag.gnssRejected)
            if (restartedFromBluetoothAt?.let { t - it < 30 } ?: false) flags.add(Estimate.Flag.restartedFromBluetooth)
            if (widening > 1.5 || gnssWidening > 1.5) flags.add(Estimate.Flag.widenedByResiduals)

            val heading = if (headingReady) wrap(x[PSI] + x[CARRY]) else null
            val anchorIds = usedAnchors.filter { t - it.value <= 30 }.keys.sorted()
            val provenance = summarizedProvenance(now = t)

            fun make(
                method: Estimate.Method,
                position: Vec2?,
                center: Vec2?,
                cov: Covariance2?,
                r95: Double?,
                candidates: List<Vec2> = emptyList(),
                anchorIds: List<String>,
                gnssDependent: Boolean,
            ): Estimate = Estimate(
                method = method, frameId = frameId, t = t, position = position, regionCenter = center, covariance = cov,
                r95 = r95, candidates = candidates, heading = heading, headingSigma = if (headingReady) headingSigma else null,
                lastAbsoluteAt = lastAbsoluteAt, lastTrustedGNSS = lastTrustedFix, anchorIds = anchorIds,
                gnssDependent = gnssDependent, provenance = provenance, flags = flags,
            )

            fun region(g: GeometrySolution): Estimate {
                val method = if (g.kind == GeometrySolution.Kind.ambiguous) Estimate.Method.ambiguous else Estimate.Method.proximity
                val dependent = g.anchorIds.any { anchors[it]?.gnssDependent ?: false }
                return make(
                    method, position = null, center = g.center, cov = g.covariance, r95 = g.r95, candidates = g.candidates,
                    anchorIds = g.anchorIds, gnssDependent = dependent,
                )
            }
            val freshRegion = geometry?.let { g -> if (t - g.t <= 10 && g.kind != GeometrySolution.Kind.multilateration) g else null }

            if (positionReady) {
                val cov = Covariance2(xx = P[X, X], xz = P[X, Z], zz = P[Z, Z])
                val p = Vec2(x = x[X], z = x[Z])
                val r95 = cov.r95
                val gnssFresh = lastGNSSUpdate?.let { t - it <= cfg.gnssFreshFor } ?: false
                // A disc or an unresolved pair is never fused into the point (its centre is not a
                // place the phone is likely to be); when it says more than the point, show it instead.
                if (!gnssFresh && freshRegion != null && freshRegion.r95 < r95) {
                    // A point that says less than half of what Bluetooth says is obsolete: let it go
                    // rather than flick between it and the region.
                    if (freshRegion.r95 < 0.5 * r95) positionReady = false
                    return region(freshRegion)
                }
                if (r95 > cfg.maxUsefulR95) {
                    return make(Estimate.Method.unavailable, position = null, center = null, cov = null, r95 = null, anchorIds = emptyList(), gnssDependent = gnssDependent)
                }
                if (!pointConfirmed) {
                    return make(Estimate.Method.proximity, position = null, center = p, cov = cov, r95 = r95, anchorIds = anchorIds, gnssDependent = gnssDependent)
                }
                val b = lastBluetoothUpdate
                val method = if (gnssFresh) {
                    Estimate.Method.gnss
                } else if (b != null && t - b <= 10) {
                    if (initSource == Estimate.Method.multilateration && diag.steps == 0) Estimate.Method.multilateration else Estimate.Method.fused
                } else if (initSource == Estimate.Method.declared && diag.steps == 0) {
                    Estimate.Method.declared
                } else {
                    Estimate.Method.deadReckoning
                }
                return make(method, position = p, center = p, cov = cov, r95 = r95, anchorIds = anchorIds, gnssDependent = gnssDependent)
            }
            if (freshRegion != null) return region(freshRegion)
            return make(Estimate.Method.unavailable, position = null, center = null, cov = null, r95 = null, anchorIds = emptyList(), gnssDependent = false)
        }

        fun motionSummary(at: TimeInterval, window: TimeInterval = 5.0): MotionSummary {
            val t = at
            val steps = recentSteps.filter { it.t > t - window }
            val distance = steps.fold(0.0) { acc, it -> acc + it.length }
            val moved = displacementSince(t - window)
            // Step noise, heading and stride-scale uncertainty over this short interval.
            val sigma = sqrt(
                steps.map { (cfg.stepAlongNoise * it.length).pow(2) }.fold(0.0) { a, b -> a + b } +
                    (distance * walkingHeadingSigma).pow(2) + (distance * strideSigma).pow(2),
            )
            return MotionSummary(
                t = t, stationary = stationary && steps.isEmpty(), steps = steps.size, distance = distance,
                displacement = moved, displacementR95 = Stats.r95PerSigma * sigma, window = window,
                heading = if (headingReady) wrap(x[PSI] + x[CARRY]) else null,
                headingSigma = if (headingReady) walkingHeadingSigma else null, strideScale = x[SCALE] + x[PACE],
            )
        }

        /** Raw sliding-window RSSI summary for one peer, for display and calibration screens. */
        fun rssiWindow(peerId: String, channel: RSSIChannel, now: TimeInterval): RSSIWindow? =
            rssi.current(peerId = peerId, channel = channel, now = now)

        // MARK: - Filter mechanics

        private val dim: Int get() = x.size

        /** Process-noise multiplier from the range residuals, and fix-noise multiplier from GNSS's. */
        private val widening: Double get() = min(cfg.maxWidening, max(1.0, rangeNIS))
        private val gnssWidening: Double get() = min(cfg.maxWidening, max(1.0, gnssNIS))

        /** Swift's `inout average`: returns the new average. */
        private fun noteResidual(nis: Double, dimensions: Double, average: Double): Double {
            val a = cfg.residualAveraging
            return (1 - a) * average + a * min(25.0, nis / dimensions)
        }

        private val strideSigma: Double
            get() = sqrt(max(0.0, P[SCALE, SCALE] + P[PACE, PACE] + 2 * P[SCALE, PACE]))

        private val walkingHeadingSigma: Double
            get() = sqrt(max(0.0, P[PSI, PSI] + P[CARRY, CARRY] + 2 * P[PSI, CARRY]))

        private fun row(entries: Map<Int, Double>): DoubleArray {
            val h = DoubleArray(dim)
            for ((i, v) in entries) h[i] = v
            return h
        }

        private fun advance(to: TimeInterval) {
            val t = to
            val ft = filterTime
            if (ft == null) {
                filterTime = t
                return
            }
            val dt = t - ft
            if (!(dt > 0)) return
            filterTime = t
            if (!cfg.useMotion || (lastMotionT?.let { t - it > 1.5 } ?: true)) {
                // No motion data: anyone may have walked off in any direction at walking pace.
                val before = noMotionDistance
                noMotionDistance += cfg.walkingSpeed * dt
                val q = (noMotionDistance * noMotionDistance - before * before) / 2
                P[X, X] += q
                P[Z, Z] += q
                if (headingTime?.let { t - it > 0.25 } ?: true) {
                    headingWalk(dt = dt, sigma = cfg.headingWalkWithoutGyro)
                    headingTime = max(headingTime ?: t, t)
                }
            } else {
                val v = if (stationary) cfg.stationarySpeed else cfg.unexplainedSpeed
                P[X, X] += v * v * dt * widening
                P[Z, Z] += v * v * dt * widening
            }
            P[BIAS, BIAS] += cfg.gyroBiasWalk * cfg.gyroBiasWalk * dt
            P[SCALE, SCALE] += cfg.strideScaleWalk * cfg.strideScaleWalk * dt
            decorrelate(MAG, rho = exp(-dt / cfg.compassBiasTime), sigma = cfg.compassBiasSigma)
            decorrelate(PACE, rho = exp(-dt / cfg.paceChangeTime), sigma = cfg.paceChangeSigma)
            val g = exp(-dt / cfg.gnssCorrelationTime)
            decorrelate(GX, rho = g, sigma = cfg.gnssCorrelatedFraction * gnssSigma)
            decorrelate(GZ, rho = g, sigma = cfg.gnssCorrelatedFraction * gnssSigma)
        }

        /** First-order Gauss-Markov step for one state: shrink towards zero, refill to `sigma`. */
        private fun decorrelate(i: Int, rho: Double, sigma: Double) {
            x[i] *= rho
            for (j in 0 until dim) {
                if (j == i) continue
                P[i, j] *= rho
                P[j, i] *= rho
            }
            P[i, i] = rho * rho * P[i, i] + (1 - rho * rho) * sigma * sigma
        }

        /** After initializing from a fix: part of its error is the slowly varying GNSS error. */
        private fun seedGNSSError(sigma: Double, fresh: Boolean) {
            gnssSigma = sigma
            val v = (cfg.gnssCorrelatedFraction * sigma).pow(2)
            for (i in intArrayOf(GX, GZ)) {
                x[i] = 0.0
                for (j in 0 until dim) {
                    if (j == i) continue
                    P[i, j] = 0.0
                    P[j, i] = 0.0
                }
                P[i, i] = v
            }
            if (fresh) {
                P[X, GX] = -v; P[GX, X] = -v
                P[Z, GZ] = -v; P[GZ, Z] = -v
            }
        }

        private fun predictHeading(rate: Double, dt: Double) {
            x[PSI] = wrap(x[PSI] + (rate - x[BIAS]) * dt)
            // F = I with F[psi, bias] = -dt: rows, then columns, gives F P Fᵀ.
            for (j in 0 until dim) P[PSI, j] -= dt * P[BIAS, j]
            for (i in 0 until dim) P[i, PSI] -= dt * P[i, BIAS]
            P[PSI, PSI] += cfg.gyroNoise * cfg.gyroNoise * dt
        }

        private fun headingWalk(dt: Double, sigma: Double) {
            P[PSI, PSI] += sigma * sigma * dt
        }

        private fun setHeading(h: Double, sigma: Double) {
            x[PSI] = wrap(h)
            for (i in 0 until dim) {
                if (i == PSI) continue
                P[i, PSI] = 0.0
                P[PSI, i] = 0.0
            }
            P[PSI, PSI] = sigma * sigma
            headingReady = true
        }

        private fun initializePosition(p: Vec2, cov: Covariance2, source: Estimate.Method) {
            x[X] = p.x
            x[Z] = p.z
            for (i in 0 until dim) {
                if (i <= Z) continue
                P[X, i] = 0.0; P[i, X] = 0.0
                P[Z, i] = 0.0; P[i, Z] = 0.0
            }
            P[X, X] = cov.xx
            P[Z, Z] = cov.zz
            P[X, Z] = cov.xz
            P[Z, X] = cov.xz
            positionReady = true
            initSource = source
            pointConfirmed = source != Estimate.Method.proximity
            unknownHeadingDistance = 0.0
            noMotionDistance = 0.0
            for (id in biasIndex.keys.sorted()) removeBias(id)
        }

        /** Kalman update for one scalar measurement, O(n²). False if gated out. */
        private fun scalarUpdate(h: DoubleArray, innovation: Double, r: Double, gate: Double): Boolean {
            val n = dim
            val ph = DoubleArray(n)
            for (i in 0 until n) {
                var s = 0.0
                for (j in 0 until n) if (h[j] != 0.0) s += P[i, j] * h[j]
                ph[i] = s
            }
            var s = r
            for (j in 0 until n) if (h[j] != 0.0) s += h[j] * ph[j]
            lastNIS = if (s > 0) innovation * innovation / s else Double.POSITIVE_INFINITY
            if (!(s > 0 && innovation * innovation / s <= gate)) return false
            for (i in 0 until n) x[i] += ph[i] / s * innovation
            for (i in 0 until n) {
                for (j in 0 until n) P[i, j] -= ph[i] * ph[j] / s
            }
            normalize()
            return true
        }

        /** Kalman update with a direct position measurement. False if gated out. */
        private fun positionUpdate(z: Vec2, r: Covariance2, gate: Double = Double.POSITIVE_INFINITY): Boolean =
            update2(listOf(Pair(X, 1.0)), listOf(Pair(Z, 1.0)), z.x - x[X], z.z - x[Z], r, gate = gate)

        /**
         * Kalman update for a two-component measurement with sparse rows h1, h2, O(n²). Rows are
         * ordered pairs, not dictionaries, so the sums run in a fixed order and replays repeat exactly.
         */
        private fun update2(
            h1: List<Pair<Int, Double>>,
            h2: List<Pair<Int, Double>>,
            v1: Double,
            v2: Double,
            r: Covariance2,
            gate: Double = Double.POSITIVE_INFINITY,
        ): Boolean {
            val n = dim
            val a = DoubleArray(n)
            val b = DoubleArray(n)
            for (i in 0 until n) {
                for ((j, v) in h1) a[i] += P[i, j] * v
                for ((j, v) in h2) b[i] += P[i, j] * v
            }
            var s11 = r.xx
            var s12 = r.xz
            var s22 = r.zz
            for ((j, v) in h1) {
                s11 += v * a[j]
                s12 += v * b[j]
            }
            for ((j, v) in h2) s22 += v * b[j]
            val det = s11 * s22 - s12 * s12
            if (!(det > 1e-12)) return false
            val i11 = s22 / det
            val i12 = -s12 / det
            val i22 = s11 / det
            val m2 = v1 * (i11 * v1 + i12 * v2) + v2 * (i12 * v1 + i22 * v2)
            lastNIS = m2
            if (!(m2 <= gate)) return false
            val k1 = DoubleArray(n)
            val k2 = DoubleArray(n)
            for (i in 0 until n) {
                k1[i] = a[i] * i11 + b[i] * i12
                k2[i] = a[i] * i12 + b[i] * i22
            }
            for (i in 0 until n) {
                x[i] += k1[i] * v1 + k2[i] * v2
                for (j in 0 until n) P[i, j] -= k1[i] * a[j] + k2[i] * b[j]
            }
            normalize()
            return true
        }

        private fun normalize() {
            x[PSI] = wrap(x[PSI])
            x[CARRY] = wrap(x[CARRY])
            x[MAG] = wrap(x[MAG])
            P.symmetrize()
            for (i in 0 until dim) if (P[i, i] < 1e-12) P[i, i] = 1e-12
        }

        private fun applyStep(step: StepEvent) {
            if (!(step.length.isFinite() && step.length > 0 && step.length < 2.5)) return
            diag.steps += 1
            advance(max(filterTime ?: step.t, step.t))
            val scale = x[SCALE] + x[PACE]
            val length = max(0.2, scale) * step.length
            walked += length
            decorrelate(MAG, rho = exp(-length / cfg.compassBiasDistance), sigma = cfg.compassBiasSigma)
            recentSteps.add(RecentStep(step.t, length))
            recentSteps.removeAll { it.t < step.t - 30 }
            if (!headingReady || walkingHeadingSigma > cfg.headingUnknownAbove) {
                // Direction unknown: the step could have gone anywhere, and steps add up in a line
                // as easily as they cancel. Grow the circle by the distance, not a random walk.
                val before = unknownHeadingDistance
                unknownHeadingDistance += length
                val q = (unknownHeadingDistance * unknownHeadingDistance - before * before) / 2
                P[X, X] += q
                P[Z, Z] += q
                recordTrail(step.t)
                return
            }
            unknownHeadingDistance = 0.0
            val theta = x[PSI] + x[CARRY]
            val sn = sin(theta)
            val cs = cos(theta)
            x[X] += length * sn
            x[Z] += length * cs
            displacement = displacement + Vec2(x = length * sn, z = length * cs)
            recordTrail(step.t)

            val f = Matrix.identity(dim)
            f[X, PSI] = length * cs
            f[X, CARRY] = length * cs
            f[X, SCALE] = step.length * sn
            f[X, PACE] = step.length * sn
            f[Z, PSI] = -length * sn
            f[Z, CARRY] = -length * sn
            f[Z, SCALE] = step.length * cs
            f[Z, PACE] = step.length * cs
            P = f * P * f.transposed
            val along = (cfg.stepAlongNoise * length).pow(2) * widening
            val cross = (cfg.stepCrossNoise * length).pow(2) * widening
            P[X, X] += along * sn * sn + cross * cs * cs
            P[Z, Z] += along * cs * cs + cross * sn * sn
            P[X, Z] += (along - cross) * sn * cs
            P[Z, X] += (along - cross) * sn * cs
            P.symmetrize()
        }

        private fun recordTrail(t: TimeInterval) {
            trail.add(TrailPoint(t, displacement))
            trail.removeAll { it.t < t - 20 }
        }

        /** Dead-reckoned displacement since `t` (zero if older than the trail or no steps since). */
        private fun displacementSince(t: TimeInterval): Vec2 {
            val before = trail.lastOrNull { it.t <= t }
                ?: return if (trail.isEmpty()) Vec2.zero else displacement - (trail.firstOrNull()?.d ?: displacement)
            return displacement - before.d
        }

        private fun acceptFix(fix: GNSSFix) {
            pointConfirmed = true
            lastTrustedFix = fix
            lastGNSSUpdate = fix.t
            lastAbsoluteAt = max(lastAbsoluteAt ?: fix.t, fix.t)
            gnssDependent = true
            record(Contribution.Source.gnss, null, fix.t, used = true, null)
        }

        private fun courseUpdate(fix: GNSSFix) {
            val course = fix.course ?: return
            val sigma = fix.courseSigma ?: return
            val speed = fix.speed ?: return
            if (!(speed >= 1.0 && sigma < degrees(30.0))) return
            if (!headingReady) {
                setHeading(course - x[CARRY], sigma = sqrt(sigma * sigma + P[CARRY, CARRY]))
                record(Contribution.Source.gnssCourse, null, fix.t, used = true, "initial heading")
                return
            }
            val h = row(mapOf(PSI to 1.0, CARRY to 1.0))
            val used = scalarUpdate(h, innovation = wrap(course - x[PSI] - x[CARRY]), r = sigma * sigma, gate = Stats.chi2_1dof_997)
            record(Contribution.Source.gnssCourse, null, fix.t, used = used, if (used) null else "course inconsistent with heading")
        }

        private fun compassRejected(t: TimeInterval, reason: String) {
            diag.compassRejected += 1
            if (compassRejectedSince == null) {
                compassRejectedSince = t
                record(Contribution.Source.compass, null, t, used = false, reason)
            }
        }

        // MARK: - Bluetooth

        private fun model(channel: RSSIChannel): PathLossModel = cfg.models[channel] ?: PathLossModel.defaultOutdoor

        private fun processBluetooth(now: TimeInterval) {
            if (!cfg.useBluetooth) return
            val windows = rssi.takeWindows(now = now)
            rssi.prune(now = now)
            val broad = ArrayList<RSSIWindow>()
            for (w in windows) {
                val anchor = anchors[w.peerId] ?: continue
                if (!(now - anchor.measuredAt <= cfg.anchorMaxAge)) continue
                if (!(now - w.t <= cfg.maxWindowAge)) {
                    diag.staleDropped += 1
                    record(Contribution.Source.bleRange, w.peerId, w.t, used = false, "stale RSSI window")
                    continue
                }
                latestWindows[w.peerId] = w
                // A reading near the receiver's floor only says "far": never a tight range update.
                if (positionReady && isTight(anchor) && !model(w.channel).isCensored(rssi = w.median)) {
                    rangeUpdate(w, anchor, now = now)
                } else {
                    broad.add(w)
                }
            }
            if (broad.isEmpty()) return
            val observations = latestWindows.values.mapNotNull { w ->
                val a = anchors[w.peerId]
                if (a == null || !(now - w.t <= cfg.maxWindowAge)) null
                else RangeObservation(anchor = a, window = w, model = model(w.channel))
            }
            val solution = RangeGeometry.solve(observations) ?: return
            geometry = solution
            applyGeometry(solution, now = now)
        }

        private fun isTight(anchor: Anchor): Boolean {
            val cov = Covariance2(xx = P[X, X], xz = P[X, Z], zz = P[Z, Z])
            val sigma = sqrt(cov.eigenvalues.major)
            val d = Vec2(x = x[X], z = x[Z]).distance(to = anchor.position)
            return sigma <= cfg.tightPriorMax && sigma <= cfg.tightPriorRatio * max(d, 2.0)
        }

        private fun ensureBias(id: String, model: PathLossModel, anchor: Anchor, t: TimeInterval): Int {
            val m = model
            val i = biasIndex[id]
            val link = biasLink[id]
            if (i != null && link != null) {
                // Shadowing decorrelates as either phone moves and, slowly, with time.
                // Without step data the phone may have walked off at walking pace.
                val unseen = if (cfg.useMotion) 0.0 else cfg.walkingSpeed * max(0.0, t - link.t)
                val moved = (walked - link.walked) + anchor.position.distance(to = link.anchor) + unseen
                val rho = exp(-moved / m.decorrelationDistance) * exp(-max(0.0, t - link.t) / cfg.shadowTimeConstant)
                x[i] *= rho
                for (j in 0 until dim) {
                    if (j == i) continue
                    P[i, j] *= rho
                    P[j, i] *= rho
                }
                P[i, i] = rho * rho * P[i, i] + (1 - rho * rho) * m.sigmaShadow * m.sigmaShadow
                biasLink[id] = BiasLink(walked, anchor.position, t)
                return i
            }
            val n = dim
            val grown = Matrix(rows = n + 1, cols = n + 1)
            for (r in 0 until n) for (c in 0 until n) grown[r, c] = P[r, c]
            grown[n, n] = m.sigmaShadow * m.sigmaShadow
            P = grown
            x = x.copyOf(n + 1)
            biasIndex[id] = n
            biasLink[id] = BiasLink(walked, anchor.position, t)
            return n
        }

        private fun removeBias(id: String) {
            val i = biasIndex[id] ?: return
            val n = dim
            val shrunk = Matrix(rows = n - 1, cols = n - 1)
            for (r in 0 until n) {
                if (r == i) continue
                for (c in 0 until n) {
                    if (c == i) continue
                    shrunk[if (r < i) r else r - 1, if (c < i) c else c - 1] = P[r, c]
                }
            }
            P = shrunk
            val shorter = DoubleArray(n - 1)
            for (k in 0 until n) if (k != i) shorter[if (k < i) k else k - 1] = x[k]
            x = shorter
            biasIndex.remove(id)
            biasLink.remove(id)
            for ((k, v) in biasIndex.entries.map { Pair(it.key, it.value) }) if (v > i) biasIndex[k] = v - 1
        }

        /**
         * Iterated EKF update with one median RSSI window, measured in dB against
         * p0 - 10 n log10(d) + shadowing. The anchor's uncertainty, the time-smearing of the window
         * and the late arrival are all added to the noise.
         */
        private fun rangeUpdate(w: RSSIWindow, anchor: Anchor, now: TimeInterval) {
            val m = model(w.channel)
            val bi = ensureBias(anchor.id, model = m, anchor = anchor, t = w.t)
            // Our position at the window's time = now minus the steps walked since.
            val back = displacementSince(w.t)
            val a = anchor.position
            val sa = anchor.sigma(at = w.t)
            val smear = cfg.walkingSpeed * cfg.medianWindow / 4
            val fewSamples = if (w.channel == RSSIChannel.relayedSmoothed) 1.0
            else max(1.0, (rssi.minSamples * 3).toDouble() / max(1, w.count).toDouble())
            val prior = x.copyOf()
            val xi = x.copyOf()
            var h = row(emptyMap())
            var r = 0.0
            var innovation = 0.0
            for (iteration in 0 until 3) {
                val px = xi[X] - back.x - a.x
                val pz = xi[Z] - back.z - a.z
                val d = max(m.minDistance, hypot(px, pz))
                val g = if (hypot(px, pz) > m.minDistance) -m.slope / (d * d) else 0.0
                h = row(mapOf(X to g * px, Z to g * pz, bi to 1.0))
                val grad2 = m.slope * m.slope / (d * d)
                r = m.sigmaFast * m.sigmaFast * min(4.0, fewSamples) +
                    grad2 * (sa * sa + smear * smear + (0.1 * back.length).pow(2))
                val predicted = m.expectedRSSI(distance = d) + xi[bi]
                // IEKF: linearize at xi, correct relative to the prior.
                var hd = 0.0
                for (j in 0 until dim) if (h[j] != 0.0) hd += h[j] * (prior[j] - xi[j])
                innovation = w.median - predicted - hd
                val ph = DoubleArray(dim)
                var s = r
                for (i in 0 until dim) {
                    var v = 0.0
                    for (j in 0 until dim) if (h[j] != 0.0) v += P[i, j] * h[j]
                    ph[i] = v
                }
                for (j in 0 until dim) if (h[j] != 0.0) s += h[j] * ph[j]
                for (i in 0 until dim) xi[i] = prior[i] + ph[i] / s * innovation
            }
            // Gate and commit with the final linearization (innovation relative to the prior).
            val applied = scalarUpdate(h, innovation = innovation, r = r, gate = Stats.chi2_1dof_997)
            rangeNIS = noteResidual(lastNIS, dimensions = 1.0, average = rangeNIS)
            if (applied) {
                diag.rangeUpdates += 1
                lastBluetoothUpdate = now
                pointConfirmed = true
                lastAbsoluteAt = max(lastAbsoluteAt ?: w.t, w.t)
                usedAnchors[anchor.id] = now
                if (anchor.gnssDependent) gnssDependent = true
                bluetoothConflicts = 0
                record(Contribution.Source.bleRange, anchor.id, w.t, used = true, null)
            } else {
                diag.rangeRejected += 1
                record(Contribution.Source.bleRange, anchor.id, w.t, used = false, "range outlier (blocked link or reflection)")
            }
        }

        /**
         * Broad prior. Point evidence (a multilateration, or the candidate of an ambiguous pair that
         * the prior clearly prefers) is fused when it is tighter than the prior. Region evidence (a disc,
         * an unresolved pair) is not fused: `estimate` shows the region when it is tighter. If dead
         * reckoning keeps contradicting Bluetooth, the point is dropped in favour of Bluetooth.
         */
        private fun applyGeometry(g: GeometrySolution, now: TimeInterval) {
            diag.geometryUpdates += 1
            val source = when (g.kind) {
                GeometrySolution.Kind.proximity -> Contribution.Source.bleProximity
                GeometrySolution.Kind.ambiguous -> Contribution.Source.bleAmbiguous
                GeometrySolution.Kind.multilateration -> Contribution.Source.bleMultilateration
            }
            val dependent = g.anchorIds.any { anchors[it]?.gnssDependent ?: false }

            if (!positionReady) {
                if (g.kind == GeometrySolution.Kind.multilateration) {
                    initializePosition(g.center, g.covariance, source = Estimate.Method.multilateration)
                    markBluetooth(g, now = now, dependent = dependent, source = source, note = "initialized")
                } else if (g.kind == GeometrySolution.Kind.proximity && cfg.useMotion) {
                    // With steps, a disc is a usable start: motion and later ranges resolve it. It is
                    // shown as the disc until something confirms a point.
                    initializePosition(g.center, g.covariance, source = Estimate.Method.proximity)
                    markRegion(g, now = now, source = source)
                } else {
                    markRegion(g, now = now, source = source)
                }
                return
            }

            val prior = Covariance2(xx = P[X, X], xz = P[X, Z], zz = P[Z, Z])
            val p = Vec2(x = x[X], z = x[Z])
            var point: Pair<Vec2, Covariance2>? = null
            when (g.kind) {
                GeometrySolution.Kind.multilateration -> point = Pair(g.center, g.covariance)
                GeometrySolution.Kind.ambiguous -> {
                    val side = g.r95 - g.candidates.maxOf { it.distance(to = g.center) }
                    val candidateCov = Covariance2.isotropic(sigma = max(1.0, side) / Stats.r95PerSigma)
                    val scored = g.candidates.mapNotNull { c ->
                        val s = Covariance2(xx = prior.xx + candidateCov.xx, xz = prior.xz, zz = prior.zz + candidateCov.zz)
                        s.mahalanobis2(c - p)?.let { Pair(c, it) }
                    }.sortedWith { l, r -> if (l.second < r.second) -1 else if (r.second < l.second) 1 else 0 }
                    if (scored.size == 2 && scored[0].second < Stats.chi2_2dof_999 && scored[1].second - scored[0].second > 6) {
                        point = Pair(scored[0].first, candidateCov)
                    }
                }
                GeometrySolution.Kind.proximity -> {}
            }

            val chosen = point
            if (chosen != null) {
                // Region-derived evidence may repeat the same windows: only ever tighten.
                if (!(chosen.second.eigenvalues.major < prior.eigenvalues.major)) return
                val consistent = Covariance2(
                    xx = prior.xx + chosen.second.xx, xz = prior.xz + chosen.second.xz, zz = prior.zz + chosen.second.zz,
                ).mahalanobis2(chosen.first - p)?.let { it <= Stats.chi2_2dof_999 } ?: false
                if (consistent && positionUpdate(chosen.first, chosen.second)) {
                    bluetoothConflicts = 0
                    markBluetooth(g, now = now, dependent = dependent, source = source, note = null)
                    return
                }
            } else if (p.distance(to = g.center) <= g.r95 + prior.r95) {
                bluetoothConflicts = 0
                markRegion(g, now = now, source = source)
                return
            }
            bluetoothConflicts += 1
            if (bluetoothConflicts < cfg.bluetoothResetAfter) {
                for (id in g.anchorIds) record(source, id, g.t, used = false, "disagrees with dead reckoning")
                return
            }
            restartedFromBluetoothAt = now
            bluetoothConflicts = 0
            if (g.kind == GeometrySolution.Kind.multilateration) {
                initializePosition(g.center, g.covariance, source = Estimate.Method.multilateration)
                markBluetooth(g, now = now, dependent = dependent, source = source, note = "restarted: dead reckoning disagreed with Bluetooth")
            } else {
                positionReady = false
                markRegion(g, now = now, source = source)
                for (id in g.anchorIds) record(source, id, g.t, used = true, "dead reckoning dropped: it disagreed with Bluetooth")
            }
        }

        /** Region evidence considered (not fused): kept for the provenance of a region estimate. */
        private fun markRegion(g: GeometrySolution, now: TimeInterval, source: Contribution.Source) {
            for (id in g.anchorIds) {
                usedAnchors[id] = now
                record(source, id, g.t, used = true, if (g.kind == GeometrySolution.Kind.ambiguous) "two candidate spots" else "within a disc around it")
            }
            if (g.anchorIds.any { anchors[it]?.gnssDependent ?: false }) gnssDependent = true
        }

        private fun markBluetooth(g: GeometrySolution, now: TimeInterval, dependent: Boolean, source: Contribution.Source, note: String?) {
            lastBluetoothUpdate = now
            pointConfirmed = true
            lastAbsoluteAt = max(lastAbsoluteAt ?: g.t, g.t)
            for (id in g.anchorIds) usedAnchors[id] = now
            if (dependent) gnssDependent = true
            for (id in g.anchorIds) record(source, id, g.t, used = true, note)
        }

        private fun pruneAnchors(now: TimeInterval) {
            for ((id, a) in anchors.entries.map { Pair(it.key, it.value) }) {
                if (now - a.measuredAt > cfg.anchorMaxAge) {
                    anchors.remove(id)
                    latestWindows.remove(id)
                }
            }
            for (id in biasLink.keys.sorted()) {
                val link = biasLink[id] ?: continue
                if (now - link.t > cfg.forgetAnchorBiasAfter) removeBias(id)
            }
        }

        // MARK: - Provenance

        private fun record(source: Contribution.Source, peer: String?, t: TimeInterval, used: Boolean, reason: String?) {
            contributions.add(Contribution(source = source, peerId = peer, t = t, used = used, reason = reason))
            if (contributions.size > 256) contributions.subList(0, contributions.size - 256).clear()
        }

        /**
         * The latest contribution per (source, peer) from the last 60 s, newest first, at most 16
         * (the contract's input limit).
         */
        private fun summarizedProvenance(now: TimeInterval): List<Contribution> {
            val seen = HashSet<String>()
            val out = ArrayList<Contribution>()
            for (c in contributions.asReversed()) {
                if (!(now - c.t <= 60)) continue
                val key = c.source.rawValue + "|" + (c.peerId ?: "")
                if (seen.add(key)) out.add(c)
                if (out.size == 16) break
            }
            return out
        }
    }

    // MARK: ContractMapping.swift

    /**
     * This phone's two clocks: the engine runs on monotonic seconds, contract records carry Unix
     * seconds on this phone's clock. Only ever used for this phone's own times.
     */
    data class Clock(val unixMinusMonotonic: Double) {
        fun unix(monotonic: TimeInterval): Double = monotonic + unixMinusMonotonic
        fun monotonic(unix: Double): TimeInterval = unix - unixMinusMonotonic

        companion object {
            /**
             * `uptime` defaults to the JVM's monotonic clock (`System.nanoTime`). On Android, pass
             * the base the motion samples use (`SystemClock.elapsedRealtimeNanos() / 1e9` for
             * `SensorEvent.timestamp`), since the engine compares them.
             */
            fun now(date: Double = currentTime(), uptime: TimeInterval = System.nanoTime() / 1e9): Clock =
                Clock(unixMinusMonotonic = date - uptime)
        }
    }

    /** Maps engine values onto the GhostCore contract and relayed contract records onto engine inputs. */
    object ContractMapping {
        const val algorithm = "ghostcore-positioning@0.1"
        const val positionMaxAge = 10.0
        const val motionMaxAge = 5.0
        /** Relay latency not covered by `ageAtHandoff` (radio and queueing), s. */
        const val relayTimeSigma = 0.5

        // MARK: Engine -> contract

        /**
         * `upstream`: provenance of the anchors behind `e` (their producer is the anchor). GNSS-based
         * anchors in use are listed as `gnss` inputs with their ids, so circular evidence is visible.
         * `producerId` defaults to the subject (a phone placing itself).
         */
        fun positionEstimate(
            e: Estimate,
            subjectId: String,
            clock: Clock,
            upstream: List<Provenance> = emptyList(),
            simulated: Boolean = false,
            producerId: String? = null,
            maxAge: Double = positionMaxAge,
        ): PositionEstimate {
            var ambiguous = false
            val (kind, method, source) = when (e.method) {
                Estimate.Method.gnss -> Triple(PositionEstimate.Kind.measured, PositionEstimate.Method.gnss, EvidenceSource.gnss)
                Estimate.Method.deadReckoning -> Triple(PositionEstimate.Kind.estimated, PositionEstimate.Method.deadReckoning, EvidenceSource.inertial)
                Estimate.Method.fused -> Triple(PositionEstimate.Kind.estimated, PositionEstimate.Method.fusion, EvidenceSource.fusion)
                Estimate.Method.multilateration -> Triple(PositionEstimate.Kind.estimated, PositionEstimate.Method.multilateration, EvidenceSource.bluetooth)
                Estimate.Method.proximity -> {
                    ambiguous = true
                    Triple(PositionEstimate.Kind.estimated, PositionEstimate.Method.proximity, EvidenceSource.bluetooth)
                }
                Estimate.Method.ambiguous -> {
                    ambiguous = true
                    Triple(PositionEstimate.Kind.estimated, PositionEstimate.Method.proximity, EvidenceSource.bluetooth)
                }
                Estimate.Method.declared -> Triple(PositionEstimate.Kind.declared, PositionEstimate.Method.manual, EvidenceSource.manual)
                Estimate.Method.unavailable -> Triple(PositionEstimate.Kind.unavailable, PositionEstimate.Method.none, EvidenceSource.fusion)
            }
            val point = if (kind == PositionEstimate.Kind.unavailable) null else (e.position ?: e.regionCenter)
            val covariance = e.covariance?.let { FloorCovariance(xx = it.xx, xz = it.xz, zz = it.zz) }
            val r95 = min(GhostCoreContract.maxRadius, e.r95 ?: GhostCoreContract.maxRadius)
            val candidates = if (ambiguous && e.candidates.isNotEmpty())
                e.candidates.take(GhostCoreContract.maxCandidates).map { FloorVector(x = it.x, z = it.z) } else null
            val gnssAnchors = e.anchorIds.filter { id -> upstream.any { it.producerId == id && it.gnssDependent } }.map {
                ProvenanceInput(source = EvidenceSource.gnss, id = it, used = true, reason = "anchor: its trusted GNSS position")
            }
            val evidenceInputs = e.provenance.map { c ->
                ProvenanceInput(
                    source = evidence(c.source), id = c.peerId?.let { if (DashboardContract.isValidId(it)) it else null },
                    age = max(0.0, e.t - c.t), used = c.used, reason = c.reason?.take(GhostCoreContract.maxTextLength),
                )
            }
            val inputs = (gnssAnchors + evidenceInputs).take(GhostCoreContract.maxInputs)
            val provenance = Provenance.derived(
                producerId = producerId ?: subjectId, algorithm = algorithm, inputs = inputs,
                from = upstream, usesGNSS = e.gnssDependent, simulated = simulated,
            )
            return PositionEstimate(
                subjectId = subjectId, timestamp = clock.unix(e.t), frameId = e.frameId, kind = kind, method = method,
                position = point?.let { Position(x = it.x, y = 0.0, z = it.z) }, positionMode = PositionMode.floor,
                uncertainty = PositionUncertainty(r95 = r95, ambiguous = ambiguous, covariance = if (point == null) null else covariance),
                candidates = candidates, heading = e.heading, headingSigma = e.headingSigma,
                lastAbsoluteAt = e.lastAbsoluteAt?.let { min(clock.unix(it), clock.unix(e.t)) },
                source = source, freshness = Freshness(ageAtHandoff = 0.0, maxAge = maxAge), provenance = provenance,
            )
        }

        /** The interval's steps and dead-reckoned displacement; nil before any motion data. */
        fun motionObservation(
            m: MotionSummary,
            subjectId: String,
            frameId: String,
            clock: Clock,
            method: MotionObservation.Method = MotionObservation.Method.stepDetector,
            simulated: Boolean = false,
        ): MotionObservation = MotionObservation(
            subjectId = subjectId, timestamp = clock.unix(m.t), interval = m.window, frameId = frameId, method = method,
            steps = m.steps,
            displacement = if (m.stationary) FloorVector(x = 0.0, z = 0.0) else FloorVector(x = m.displacement.x, z = m.displacement.z),
            heading = m.heading, stationary = m.stationary,
            uncertainty = MotionObservation.Uncertainty(
                displacementR95 = min(GhostCoreContract.maxRadius, m.displacementR95), headingSigma = m.headingSigma,
            ),
            source = EvidenceSource.inertial, freshness = Freshness(ageAtHandoff = 0.0, maxAge = motionMaxAge),
            provenance = Provenance(producerId = subjectId, algorithm = algorithm, gnssDependent = false, simulated = simulated),
        )

        internal fun evidence(s: Contribution.Source): EvidenceSource = when (s) {
            Contribution.Source.gnss, Contribution.Source.gnssCourse -> EvidenceSource.gnss
            Contribution.Source.compass, Contribution.Source.steps, Contribution.Source.stationary -> EvidenceSource.inertial
            Contribution.Source.bleRange, Contribution.Source.bleProximity, Contribution.Source.bleMultilateration,
            Contribution.Source.bleAmbiguous -> EvidenceSource.bluetooth
            Contribution.Source.declared -> EvidenceSource.manual
        }

        // MARK: Contract -> engine

        sealed class AnchorDecision {
            data class anchor(val value: Anchor) : AnchorDecision()
            data class refused(val value: String) : AnchorDecision()
        }

        /**
         * Whether another phone's relayed position may anchor this phone, and as what. A GNSS fix
         * needs that phone's integrity check to say `mayAnchorOthers`; anything that already
         * contains this phone is refused (no loops); regions and predictions never anchor.
         * `receivedAt` is this phone's monotonic receipt time.
         */
        fun anchor(from: PositionEstimate, integrity: IntegrityAssessment?, selfId: String, receivedAt: TimeInterval): AnchorDecision {
            val p = from
            if (p.subjectId == selfId) return AnchorDecision.refused("own estimate")
            if (p.provenance.contains(device = selfId)) return AnchorDecision.refused("depends on this phone")
            val position = p.position
            if (position == null || p.uncertainty.ambiguous) return AnchorDecision.refused("no single position")
            if (!(p.freshness.ageAtHandoff <= p.freshness.maxAge)) return AnchorDecision.refused("stale")
            val sigma = p.uncertainty.covariance?.let { sqrt(it.largestVariance) }
                ?: (p.uncertainty.r95 / PositionUncertainty.sigmaTo95)
            val measuredAt = receivedAt - p.freshness.ageAtHandoff
            val speed = p.velocity?.let { it.length + 0.5 } ?: 1.5
            val point = Vec2(x = position.x, z = position.z)
            val kind = p.kind
            val method = p.method
            return when {
                kind == PositionEstimate.Kind.measured && method == PositionEstimate.Method.gnss -> {
                    if (integrity == null || integrity.subjectId != p.subjectId) return AnchorDecision.refused("no integrity assessment")
                    if (!integrity.mayAnchorOthers) return AnchorDecision.refused("GNSS not trusted: ${integrity.status.rawValue}")
                    AnchorDecision.anchor(
                        Anchor(
                            id = p.subjectId, position = point, sigma = sigma, kind = Anchor.Kind.gnss, measuredAt = measuredAt,
                            timeSigma = relayTimeSigma, speedBound = speed, dependsOn = p.provenance.contributors,
                            gnssDependent = true,
                        ),
                    )
                }
                kind == PositionEstimate.Kind.measured || kind == PositionEstimate.Kind.declared -> AnchorDecision.anchor(
                    Anchor(
                        id = p.subjectId, position = point, sigma = sigma, kind = Anchor.Kind.surveyed, measuredAt = measuredAt,
                        timeSigma = relayTimeSigma, speedBound = if (kind == PositionEstimate.Kind.declared) 0.3 else speed,
                        dependsOn = p.provenance.contributors, gnssDependent = p.provenance.gnssDependent,
                    ),
                )
                kind == PositionEstimate.Kind.estimated && (
                    method == PositionEstimate.Method.fusion || method == PositionEstimate.Method.multilateration ||
                        method == PositionEstimate.Method.deadReckoning || method == PositionEstimate.Method.particle
                    ) -> AnchorDecision.anchor(
                    Anchor(
                        id = p.subjectId, position = point, sigma = sigma, kind = Anchor.Kind.estimated, measuredAt = measuredAt,
                        timeSigma = relayTimeSigma, speedBound = speed, dependsOn = p.provenance.contributors,
                        gnssDependent = p.provenance.gnssDependent,
                    ),
                )
                else -> AnchorDecision.refused("${kind.rawValue} ${method.rawValue} cannot anchor")
            }
        }

        /**
         * Raw RSSI from a snapshot, for the engine's median filter: our own readings of a peer, or a
         * peer's readings of us (`reciprocal`). Samples are spread evenly over the snapshot window.
         * Our own snapshots are timed by `clock`; a peer's by receipt time minus its age.
         */
        fun rssiSamples(from: PeerObservation, selfId: String, receivedAt: TimeInterval, clock: Clock): List<RSSISample> {
            val o = from
            val peer: String
            val channel: RSSIChannel
            val newest: TimeInterval
            val ownPeer = o.peerId
            if (o.observerId == selfId && ownPeer != null) {
                peer = ownPeer
                channel = if (o.channel == PeerObservation.Channel.connection) RSSIChannel.connection else RSSIChannel.advertisement
                newest = clock.monotonic(o.timestamp)
            } else if (o.peerId == selfId) {
                peer = o.observerId
                channel = RSSIChannel.reciprocal
                newest = receivedAt - o.freshness.ageAtHandoff
            } else {
                return emptyList()
            }
            val n = o.rawRSSI.size
            if (n <= 0) return emptyList()
            val step = if (n > 1) o.window / (n - 1).toDouble() else 0.0
            return o.rawRSSI.mapIndexed { i, rssi ->
                RSSISample(peerId = peer, rssi = rssi, t = newest - (n - 1 - i).toDouble() * step, channel = channel)
            }
        }
    }

    // MARK: PeerLocator.swift

    /**
     * Places phones that have no trusted position of their own, for the pipeline's positioning slot
     * (`GhostPositioningEngine`), with the rules this phone's own engine follows: one anchor gives a
     * disc around it, two give a candidate pair, a point needs three well-placed anchors or a
     * remembered trusted position carried forward. Each lost phone gets its own `Engine` without
     * motion (a peer's steps are not relayed), so its uncertainty grows at walking pace between
     * Bluetooth evidence and is never pulled toward an anchor by a single range.
     *
     * `model`: path loss for the mesh's link RSSI (smoothed on the reporting phones).
     */
    class PeerLocator(
        val producerId: String,
        val frameId: String,
        model: PathLossModel? = null,
    ) : GhostPositioningEngine {
        private val config: Engine.Config = Engine.Config().also { config ->
            config.useMotion = false
            config.useCompass = false
            // A remembered fix starts the track; it is never this phone's measurement of the peer now.
            config.gnssFreshFor = -1.0
            if (model != null) config.models[RSSIChannel.relayedSmoothed] = model.copy()
        }
        private val engines: MutableMap<String, Engine> = HashMap()
        private val lastAnchor: MutableMap<String, PositionEstimate> = HashMap()

        override fun place(
            anchors: List<PositionEstimate>,
            lost: List<String>,
            links: List<LinkMeasurement>,
            observations: List<PeerObservation>,
            now: Double,
        ): List<PositionEstimate> {
            val usable = anchors.filter { it.position != null && !it.uncertainty.ambiguous }
            for (a in usable) {
                val last = lastAnchor[a.subjectId]
                if (last == null || last.timestamp <= a.timestamp) lastAnchor[a.subjectId] = a
            }
            // A phone with its own position again starts from scratch the next time it is lost.
            engines.keys.retainAll(lost.toSet())
            val out = ArrayList<PositionEstimate>()
            for (id in lost.toSet().sorted()) {
                val engine = engines[id] ?: start(id, now = now)
                val upstream = HashMap<String, Provenance>()
                for (a in usable) {
                    if (a.subjectId == id || a.provenance.contains(device = id)) continue
                    engine.ingest(anchor = anchor(a))
                    upstream[a.subjectId] = a.provenance
                }
                for (link in links) {
                    val other = if (link.a == id) link.b else (if (link.b == id) link.a else null)
                    if (other == null || upstream[other] == null) continue
                    engine.ingest(rssi = RSSISample(peerId = other, rssi = link.rssi, t = now, channel = RSSIChannel.relayedSmoothed))
                }
                val e = engine.estimate(at = now)
                if (e.method == Estimate.Method.unavailable) continue
                // The lost phone contributed its own link readings.
                val sources = e.anchorIds.mapNotNull { upstream[it] } +
                    listOf(Provenance(producerId = id, algorithm = "mesh-report@1", gnssDependent = false))
                val record = ContractMapping.positionEstimate(
                    e, subjectId = id, clock = Clock(unixMinusMonotonic = 0.0),
                    upstream = sources, simulated = sources.any { it.simulated },
                    producerId = producerId, maxAge = maxAge,
                )
                val valid = try {
                    record.validate()
                    true
                } catch (error: Exception) {
                    false
                }
                if (valid) out.add(record)
            }
            return out
        }

        private fun start(id: String, now: Double): Engine {
            val engine = Engine(selfId = id, frameId = frameId, config = config)
            engines[id] = engine
            val last = lastAnchor[id]
            val p = last?.position
            if (last != null && p != null && now - last.timestamp <= rememberFor) {
                // Its last trusted position, widening at walking pace for its age.
                val radius68 = last.uncertainty.r95 / PositionUncertainty.r95(fromRadius68 = 1.0)
                engine.ingest(
                    gnss = GNSSFix(
                        t = last.timestamp - last.freshness.ageAtHandoff, position = Vec2(x = p.x, z = p.z),
                        horizontalAccuracy = radius68, trusted = true,
                    ),
                )
            }
            return engine
        }

        companion object {
            const val algorithm = "ghostcore-peer-locator@0.1"
            /** A lost phone's last anchor-grade position older than this is not used as its start. */
            const val rememberFor = 120.0
            /** Matches the baseline estimator's freshness for placed peers. */
            const val maxAge = 6.0

            /** An anchor-grade contract position as an engine anchor; timed by its receipt, not its sender's clock. */
            internal fun anchor(a: PositionEstimate): Anchor {
                val p = a.position!!
                val sigma = a.uncertainty.covariance?.let { sqrt(it.largestVariance) }
                    ?: (a.uncertainty.r95 / PositionUncertainty.sigmaTo95)
                val kind = if (a.kind == PositionEstimate.Kind.measured) Anchor.Kind.gnss
                else (if (a.kind == PositionEstimate.Kind.declared) Anchor.Kind.surveyed else Anchor.Kind.estimated)
                return Anchor(
                    id = a.subjectId, position = Vec2(x = p.x, z = p.z), sigma = sigma, kind = kind,
                    measuredAt = a.timestamp - a.freshness.ageAtHandoff, timeSigma = ContractMapping.relayTimeSigma,
                    speedBound = if (a.kind == PositionEstimate.Kind.declared) 0.3 else 1.5,
                    dependsOn = a.provenance.contributors, gnssDependent = a.provenance.gnssDependent,
                )
            }
        }
    }

    // MARK: PositioningReplay.swift

    /**
     * One recorded engine input or ground-truth sample. A walk recorded on a phone (JSON lines) and
     * a synthetic track use the same records, so both go through the same replay and metrics.
     *
     * JSON matches Swift's synthesized `Codable` for an enum with associated values:
     * `{"gnss":{"fix":{...}}}`, `{"removeAnchor":{"id":"phone-c","t":12.5}}`.
     */
    @Serializable(with = LogRecordSerializer::class)
    sealed class LogRecord {
        abstract val t: TimeInterval

        data class header(val selfId: String, val frameId: String, val note: String) : LogRecord() {
            override val t: TimeInterval get() = Double.NEGATIVE_INFINITY
        }

        data class gnss(val fix: GNSSFix) : LogRecord() {
            override val t: TimeInterval get() = fix.t
        }

        data class motion(val sample: MotionSample) : LogRecord() {
            override val t: TimeInterval get() = sample.t
        }

        data class compass(val sample: CompassSample) : LogRecord() {
            override val t: TimeInterval get() = sample.t
        }

        data class step(val event: StepEvent) : LogRecord() {
            override val t: TimeInterval get() = event.t
        }

        data class rssi(val sample: RSSISample) : LogRecord() {
            override val t: TimeInterval get() = sample.t
        }

        data class anchor(val anchor: Anchor) : LogRecord() {
            override val t: TimeInterval get() = anchor.measuredAt
        }

        data class removeAnchor(val id: String, override val t: TimeInterval) : LogRecord()

        data class declared(val position: Vec2, val sigma: Double, override val t: TimeInterval) : LogRecord()

        /** Independent reference position (surveyed marker, RTK, or a simulation's true track). */
        data class truth(val position: Vec2, override val t: TimeInterval) : LogRecord()

        companion object {
            /** One JSON object per line, keys sorted (Swift: `.sortedKeys`). */
            fun encodeLines(records: List<LogRecord>): ByteArray {
                val out = StringBuilder()
                for (r in records) {
                    out.append(MeshJson.encodeToString(JsonElement.serializer(), sortedKeys(MeshJson.encodeToJsonElement(LogRecordSerializer, r))))
                    out.append('\n')
                }
                return out.toString().toByteArray(Charsets.UTF_8)
            }

            fun decodeLines(data: ByteArray): List<LogRecord> =
                data.toString(Charsets.UTF_8).split('\n').filter { it.isNotEmpty() }
                    .map { MeshJson.decodeFromString(LogRecordSerializer, it) }

            private fun sortedKeys(e: JsonElement): JsonElement = when (e) {
                is JsonObject -> JsonObject(e.entries.sortedBy { it.key }.associateTo(LinkedHashMap()) { it.key to sortedKeys(it.value) })
                is JsonArray -> JsonArray(e.map { sortedKeys(it) })
                else -> e
            }
        }
    }

    internal object LogRecordSerializer : KSerializer<LogRecord> {
        @OptIn(ExperimentalSerializationApi::class)
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Positioning.LogRecord")

        override fun serialize(encoder: Encoder, value: LogRecord) {
            val output = encoder as JsonEncoder
            val json = output.json
            val (key, body) = when (value) {
                is LogRecord.header -> "header" to JsonObject(
                    mapOf("selfId" to JsonPrimitive(value.selfId), "frameId" to JsonPrimitive(value.frameId), "note" to JsonPrimitive(value.note)),
                )
                is LogRecord.gnss -> "gnss" to JsonObject(mapOf("fix" to json.encodeToJsonElement(value.fix)))
                is LogRecord.motion -> "motion" to JsonObject(mapOf("sample" to json.encodeToJsonElement(value.sample)))
                is LogRecord.compass -> "compass" to JsonObject(mapOf("sample" to json.encodeToJsonElement(value.sample)))
                is LogRecord.step -> "step" to JsonObject(mapOf("event" to json.encodeToJsonElement(value.event)))
                is LogRecord.rssi -> "rssi" to JsonObject(mapOf("sample" to json.encodeToJsonElement(value.sample)))
                is LogRecord.anchor -> "anchor" to JsonObject(mapOf("anchor" to json.encodeToJsonElement(value.anchor)))
                is LogRecord.removeAnchor -> "removeAnchor" to JsonObject(mapOf("id" to JsonPrimitive(value.id), "t" to JsonPrimitive(value.t)))
                is LogRecord.declared -> "declared" to JsonObject(
                    mapOf("position" to json.encodeToJsonElement(value.position), "sigma" to JsonPrimitive(value.sigma), "t" to JsonPrimitive(value.t)),
                )
                is LogRecord.truth -> "truth" to JsonObject(mapOf("position" to json.encodeToJsonElement(value.position), "t" to JsonPrimitive(value.t)))
            }
            output.encodeJsonElement(JsonObject(mapOf(key to body)))
        }

        override fun deserialize(decoder: Decoder): LogRecord {
            val input = decoder as JsonDecoder
            val json = input.json
            val root = input.decodeJsonElement().jsonObject
            val (key, element) = root.entries.singleOrNull() ?: throw IllegalArgumentException("LogRecord: expected one case key")
            val body = element.jsonObject
            fun str(name: String): String = body.getValue(name).jsonPrimitive.content
            fun dbl(name: String): Double = body.getValue(name).jsonPrimitive.double
            return when (key) {
                "header" -> LogRecord.header(selfId = str("selfId"), frameId = str("frameId"), note = str("note"))
                "gnss" -> LogRecord.gnss(fix = json.decodeFromJsonElement(body.getValue("fix")))
                "motion" -> LogRecord.motion(sample = json.decodeFromJsonElement(body.getValue("sample")))
                "compass" -> LogRecord.compass(sample = json.decodeFromJsonElement(body.getValue("sample")))
                "step" -> LogRecord.step(event = json.decodeFromJsonElement(body.getValue("event")))
                "rssi" -> LogRecord.rssi(sample = json.decodeFromJsonElement(body.getValue("sample")))
                "anchor" -> LogRecord.anchor(anchor = json.decodeFromJsonElement(body.getValue("anchor")))
                "removeAnchor" -> LogRecord.removeAnchor(id = str("id"), t = dbl("t"))
                "declared" -> LogRecord.declared(position = json.decodeFromJsonElement(body.getValue("position")), sigma = dbl("sigma"), t = dbl("t"))
                "truth" -> LogRecord.truth(position = json.decodeFromJsonElement(body.getValue("position")), t = dbl("t"))
                else -> throw IllegalArgumentException("LogRecord: unknown case $key")
            }
        }
    }

    data class ReplayEpoch(
        val estimate: Estimate,
        val truth: Vec2?,
        /** Distance from the point estimate to the truth (nil for region-only estimates). */
        val error: Double?,
        /** Truth inside the reported r95 around the position or region centre. */
        val contained: Boolean?,
        /** For ambiguous estimates: distance from the truth to the nearest candidate. */
        val candidateError: Double?,
    )

    object Replay {
        class Options {
            var estimateEvery: TimeInterval = 1.0
            /**
             * Real walks: record with GPS on, then hide the fixes after this time from the engine and
             * use them as the reference instead (only fixes at least this accurate).
             */
            var maskGNSSAfter: TimeInterval? = null
            var gnssTruthMaxAccuracy = 10.0
            var start: TimeInterval? = null
            var end: TimeInterval? = null
        }

        /** Swift's `(t: TimeInterval, p: Vec2)` reference sample. */
        data class TruthSample(val t: TimeInterval, val p: Vec2)

        /**
         * Feeds the records to `engine` in time order and asks for an estimate every
         * `estimateEvery` seconds, scoring each against the interpolated reference.
         */
        fun run(records: List<LogRecord>, engine: Engine, options: Options = Options()): List<ReplayEpoch> {
            val sorted = records.withIndex().sortedWith { l, r ->
                when {
                    l.value.t < r.value.t -> -1
                    r.value.t < l.value.t -> 1
                    else -> l.index.compareTo(r.index)
                }
            }.map { it.value }
            val truth = ArrayList<TruthSample>()
            val mask = options.maskGNSSAfter
            for (r in sorted) {
                when (r) {
                    is LogRecord.truth -> truth.add(TruthSample(r.t, r.position))
                    is LogRecord.gnss -> if ((mask?.let { r.fix.t > it } ?: false) && r.fix.horizontalAccuracy <= options.gnssTruthMaxAccuracy) {
                        truth.add(TruthSample(r.fix.t, r.fix.position))
                    }
                    else -> {}
                }
            }
            truth.sortWith { l, r -> if (l.t < r.t) -1 else if (r.t < l.t) 1 else 0 }
            val times = sorted.map { it.t }.filter { it.isFinite() }
            val first = times.firstOrNull() ?: return emptyList()
            val last = times.last()
            var next = options.start ?: ceil(first)
            val end = options.end ?: last
            val epochs = ArrayList<ReplayEpoch>()

            fun emit(upTo: TimeInterval) {
                while (next <= upTo && next <= end) {
                    val e = engine.estimate(at = next)
                    epochs.add(score(e, truth = interpolate(truth, at = next)))
                    next += options.estimateEvery
                }
            }

            for (r in sorted) {
                emit(upTo = r.t)
                when (r) {
                    is LogRecord.header, is LogRecord.truth -> {}
                    is LogRecord.gnss -> {
                        if (mask?.let { r.fix.t > it } ?: false) continue
                        engine.ingest(gnss = r.fix)
                    }
                    is LogRecord.motion -> engine.ingest(motion = r.sample)
                    is LogRecord.compass -> engine.ingest(compass = r.sample)
                    is LogRecord.step -> engine.ingest(step = r.event)
                    is LogRecord.rssi -> engine.ingest(rssi = r.sample)
                    is LogRecord.anchor -> engine.ingest(anchor = r.anchor)
                    is LogRecord.removeAnchor -> engine.removeAnchor(r.id, at = r.t)
                    is LogRecord.declared -> engine.declare(position = r.position, sigma = r.sigma, at = r.t)
                }
            }
            emit(upTo = end)
            return epochs
        }

        /** Linear interpolation of the reference; nil if no sample within 2 s on both sides. */
        internal fun interpolate(truth: List<TruthSample>, at: TimeInterval): Vec2? {
            val t = at
            val hi = truth.indexOfFirst { it.t >= t }
            if (hi < 0) return null
            if (truth[hi].t == t || hi == 0) return if (t >= truth[hi].t - 2) truth[hi].p else null
            val a = truth[hi - 1]
            val b = truth[hi]
            if (!(t - a.t <= 2 && b.t - t <= 2)) return null
            val f = (t - a.t) / (b.t - a.t)
            return a.p + (b.p - a.p) * f
        }

        fun score(e: Estimate, truth: Vec2?): ReplayEpoch {
            if (truth == null) return ReplayEpoch(estimate = e, truth = null, error = null, contained = null, candidateError = null)
            val error = e.position?.distance(to = truth)
            var contained: Boolean? = null
            val r = e.r95
            val c = e.position ?: e.regionCenter
            if (r != null && c != null) contained = c.distance(to = truth) <= r
            val candidateError = e.candidates.map { it.distance(to = truth) }.minOrNull()
            return ReplayEpoch(estimate = e, truth = truth, error = error, contained = contained, candidateError = candidateError)
        }
    }

    /** Accuracy against ground truth over a set of epochs. */
    @Serializable
    data class AccuracySummary(
        val epochs: Int,
        /** Share of scored epochs with a point estimate (the rest are regions or unavailable). */
        val pointAvailability: Double,
        val medianError: Double?,
        val p95Error: Double?,
        val maxError: Double?,
        val rmse: Double?,
        /**
         * Share of epochs with an r95 whose circle held the truth. 0.95 is honest; well below means
         * overconfident; 1.0 with a huge r95 means honest but uninformative.
         */
        val containment: Double?,
        val medianR95: Double?,
        val methods: Map<String, Int>,
    ) {
        companion object {
            fun of(epochs: List<ReplayEpoch>): AccuracySummary {
                val scored = epochs.filter { it.truth != null }
                val errors = scored.mapNotNull { it.error }
                val contained = scored.mapNotNull { it.contained }
                val r95s = scored.mapNotNull { it.estimate.r95 }
                val methods = LinkedHashMap<String, Int>()
                for (e in scored) methods[e.estimate.method.rawValue] = (methods[e.estimate.method.rawValue] ?: 0) + 1
                return AccuracySummary(
                    epochs = scored.size,
                    pointAvailability = if (scored.isEmpty()) 0.0 else errors.size.toDouble() / scored.size.toDouble(),
                    medianError = Stats.median(errors), p95Error = Stats.percentile(errors, 0.95), maxError = errors.maxOrNull(),
                    rmse = if (errors.isEmpty()) null else sqrt(errors.map { it * it }.fold(0.0) { a, b -> a + b } / errors.size.toDouble()),
                    containment = if (contained.isEmpty()) null else contained.count { it }.toDouble() / contained.size.toDouble(),
                    medianR95 = Stats.median(r95s), methods = methods,
                )
            }
        }
    }
}
