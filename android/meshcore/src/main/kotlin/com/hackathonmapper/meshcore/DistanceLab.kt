package com.hackathonmapper.meshcore

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.sqrt

// Port of ios/MeshCore/Sources/MeshCore/DistanceLab.swift.

/**
 * The ways this app can turn what two phones measure into a distance, compared side by side on
 * the Track tab. The map uses `signalMap`; the others are there to test it, and each other, against
 * a tape measure.
 */
@Serializable
enum class DistanceMethod(val rawValue: String) {
    /** Nearby Interaction distance this phone measured (iPhone 11 or newer on both ends, not SE). */
    @SerialName("uwb") uwb("uwb"),
    /** The distance on the signal map: every link and position solved together. What the map draws. */
    @SerialName("signalMap") signalMap("signalMap"),
    /**
     * Both ends' smoothed RSSI averaged, through the radio model the signal map calibrated from UWB
     * distances and placed phones.
     */
    @SerialName("rssiCalibrated") rssiCalibrated("rssiCalibrated"),
    /** This phone's smoothed RSSI through the default radio model (-59 dBm at 1 m, n 2.5). */
    @SerialName("rssiDefault") rssiDefault("rssiDefault"),
    /**
     * GhostCore's filter: a 4 s median of this phone's raw RSSI after Hampel outlier removal,
     * through its outdoor path-loss model.
     */
    @SerialName("rssiMedian") rssiMedian("rssiMedian"),
    /** The distance between both phones' GPS positions: an outdoor reference, good to their accuracy. */
    @SerialName("gps") gps("gps");

    val id: String get() = rawValue

    val title: String
        get() = when (this) {
            uwb -> "UWB"
            signalMap -> "Signal map"
            rssiCalibrated -> "RSSI, calibrated, both ends"
            rssiDefault -> "RSSI, default model"
            rssiMedian -> "RSSI, median filter"
            gps -> "GPS"
        }
}

/** One method's distance for one link, with the 95 % interval where the method has one. */
data class DistanceReading(
    val method: DistanceMethod,
    val meters: Double,
    val low: Double? = null,
    val high: Double? = null,
) {
    /** Whether `distance` lies inside the 95 % interval; null when the method has none. */
    fun covers(distance: Double): Boolean? {
        val low = low ?: return null
        val high = high ?: return null
        return distance >= low && distance <= high
    }
}

/** What this phone knows this second about its link to one neighbor. */
data class DistanceInputs(
    /** Fresh UWB distance this phone measured, m. */
    var uwb: Double? = null,
    /** This phone's smoothed RSSI of the neighbor (connection where it is the central, else advertisements). */
    var smoothedRSSI: Double? = null,
    /** The neighbor's own reading of the link, from its latest report. */
    var peerRSSI: Double? = null,
    /** The distance between the two on the signal map, m. */
    var signalMap: Double? = null,
    /** This phone's and the neighbor's GPS positions with their 95 % radii. */
    var ownGPS: FloorPoint? = null,
    var ownGPSR95: Double? = null,
    var peerGPS: FloorPoint? = null,
    var peerGPSR95: Double? = null,
)

/**
 * Computes every method's distance for a link. Holds the raw-RSSI median filter, so feed it this
 * phone's raw samples of each neighbor as they arrive (`add`), then ask for `readings`.
 * A Swift struct with mutating methods; it is never copied (the app replaces it), so there is no `copy()`.
 */
class DistanceLab(
    var defaultRadio: RadioModel = RadioModel.standard,
    var medianModel: Positioning.PathLossModel = Positioning.PathLossModel.defaultOutdoor,
) {
    /** The radio model the signal map calibrated this second. */
    var calibratedRadio: RadioModel = defaultRadio
    private val filter = Positioning.RSSIMedianFilter()
    /** Newest raw sample time already added per neighbor, so resent sample lists add nothing twice. */
    private var newest: MutableMap<String, TimeInterval> = HashMap()


    /**
     * Adds this phone's raw RSSI readings of `from` (the peer id), skipping ones already added.
     * Each sample is Swift's `(rssi:, t:)` tuple as `Pair(rssi, t)`, times in seconds.
     */
    fun add(rawRSSI: List<Pair<Double, TimeInterval>>, from: String) {
        val peerId = from
        var latest = newest[peerId] ?: Double.NEGATIVE_INFINITY
        for (sample in rawRSSI.sortedWith { l, r -> l.second.compareTo(r.second) }) {
            if (!(sample.second > latest)) continue
            filter.add(Positioning.RSSISample(peerId = peerId, rssi = sample.first, t = sample.second, channel = Positioning.RSSIChannel.connection))
            latest = sample.second
        }
        newest[peerId] = latest
    }

    /** Forgets neighbors with nothing newer than a minute. */
    fun prune(now: TimeInterval) {
        filter.prune(now = now)
        newest = HashMap(newest.filterValues { it >= now - 60 })
    }

    /**
     * Every method that has what it needs this second, in `DistanceMethod` order. Swift's argument
     * label `for` is a Kotlin keyword, so the peer parameter is `peerId`.
     */
    fun readings(peerId: String, inputs: DistanceInputs, now: TimeInterval): List<DistanceReading> {
        val out = mutableListOf<DistanceReading>()
        val uwb = inputs.uwb
        if (uwb != null && uwb.isFinite() && uwb >= 0) {
            val spread = 1.96 * SignalMap.uwbSigma
            out.add(DistanceReading(method = DistanceMethod.uwb, meters = uwb, low = max(0.0, uwb - spread), high = uwb + spread))
        }
        val map = inputs.signalMap
        if (map != null && map.isFinite()) {
            out.add(DistanceReading(method = DistanceMethod.signalMap, meters = map))
        }
        val ends = listOfNotNull(inputs.smoothedRSSI, inputs.peerRSSI).filter { it.isFinite() }
        if (ends.isNotEmpty()) {
            out.add(rssiReading(DistanceMethod.rssiCalibrated, rssi = ends.fold(0.0) { s, v -> s + v } / ends.size.toDouble(), radio = calibratedRadio))
        }
        val own = inputs.smoothedRSSI
        if (own != null && own.isFinite()) {
            out.add(rssiReading(DistanceMethod.rssiDefault, rssi = own, radio = defaultRadio))
        }
        val window = filter.current(peerId = peerId, channel = Positioning.RSSIChannel.connection, now = now)
        if (window != null) {
            val interval = medianModel.distanceInterval(rssi = window.median)
            out.add(
                DistanceReading(
                    method = DistanceMethod.rssiMedian, meters = medianModel.medianDistance(rssi = window.median),
                    low = interval.lowerBound, high = interval.upperBound,
                ),
            )
        }
        val ownGPS = inputs.ownGPS
        val peerGPS = inputs.peerGPS
        if (ownGPS != null && peerGPS != null) {
            val d = hypot(ownGPS.x - peerGPS.x, ownGPS.z - peerGPS.z)
            val spread = sqrt((inputs.ownGPSR95 ?: 0.0) * (inputs.ownGPSR95 ?: 0.0) + (inputs.peerGPSR95 ?: 0.0) * (inputs.peerGPSR95 ?: 0.0))
            out.add(DistanceReading(method = DistanceMethod.gps, meters = d, low = max(0.0, d - spread), high = d + spread))
        }
        return out
    }

    companion object {
        /** Log-normal RSSI range: the median distance, and the interval of ±1.96 sigma in dB. */
        internal fun rssiReading(method: DistanceMethod, rssi: Double, radio: RadioModel): DistanceReading {
            val spread = 1.96 * radio.sigma
            return DistanceReading(
                method = method, meters = SignalMap.range(rssi, radio = radio),
                low = SignalMap.range(rssi + spread, radio = radio),
                high = SignalMap.range(rssi - spread, radio = radio),
            )
        }
    }
}

/**
 * A tape-measure trial: two phones held at a known distance while every method's reading is
 * recorded, then scored. The CSV goes to a spreadsheet for longer comparisons.
 * A Swift struct with mutating `record`: `copy()` where Swift copies the value.
 */
class DistanceTrial(
    val peerId: String,
    val peerLabel: String,
    val trueDistance: Double,
    val startedAt: TimeInterval,
) {
    data class Sample(
        /** Seconds since the trial started. */
        val t: TimeInterval,
        val meters: Map<DistanceMethod, Double>,
        /** Whether the true distance was inside each method's 95 % interval. */
        val covered: Map<DistanceMethod, Boolean>,
    )

    data class Score(
        val method: DistanceMethod,
        val count: Int,
        /** Mean of (reading − true), m: positive reads long. */
        val bias: Double,
        val meanAbsoluteError: Double,
        val rmse: Double,
        /** Share of readings whose 95 % interval held the true distance; null without intervals. */
        val coverage: Double?,
    ) {
        val id: String get() = method.rawValue
    }

    var samples: List<Sample> = emptyList()
        private set

    fun copy(): DistanceTrial {
        val other = DistanceTrial(peerId, peerLabel, trueDistance, startedAt)
        other.samples = samples
        return other
    }

    fun record(readings: List<DistanceReading>, at: TimeInterval) {
        if (readings.isEmpty()) return
        val meters = LinkedHashMap<DistanceMethod, Double>()
        val covered = LinkedHashMap<DistanceMethod, Boolean>()
        for (reading in readings) {
            meters[reading.method] = reading.meters
            // Assigning nil removes the key in Swift.
            val covers = reading.covers(trueDistance)
            if (covers != null) covered[reading.method] = covers else covered.remove(reading.method)
        }
        samples = samples + Sample(t = at - startedAt, meters = meters, covered = covered)
    }

    /** One score per method with readings, in `DistanceMethod` order. */
    val scores: List<Score>
        get() = DistanceMethod.entries.mapNotNull { method ->
            val errors = samples.mapNotNull { it.meters[method] }.map { it - trueDistance }
            if (errors.isEmpty()) return@mapNotNull null
            val n = errors.size.toDouble()
            val hits = samples.mapNotNull { it.covered[method] }
            Score(
                method = method, count = errors.size,
                bias = errors.fold(0.0) { s, v -> s + v } / n,
                meanAbsoluteError = errors.map { abs(it) }.fold(0.0) { s, v -> s + v } / n,
                rmse = sqrt(errors.map { it * it }.fold(0.0) { s, v -> s + v } / n),
                coverage = if (hits.isEmpty()) null else hits.count { it }.toDouble() / hits.size.toDouble(),
            )
        }

    /** One row per sample: time, neighbor, true distance, then each method's reading (empty when it had none). */
    fun csv(): String {
        val lines = mutableListOf("t_s,peer,true_m," + DistanceMethod.entries.joinToString(",") { it.rawValue })
        val peer = if (peerLabel.contains(",")) "\"${peerLabel.replace("\"", "\"\"")}\"" else peerLabel
        for (sample in samples) {
            val values = DistanceMethod.entries.map { method -> sample.meters[method]?.let { fixed(it, 2) } ?: "" }
            lines.add(
                listOf(fixed(sample.t, 1), peer, fixed(trueDistance, 2)).joinToString(",") +
                    "," + values.joinToString(","),
            )
        }
        return lines.joinToString("\n") + "\n"
    }

    override fun equals(other: Any?): Boolean =
        other is DistanceTrial && peerId == other.peerId && peerLabel == other.peerLabel &&
            trueDistance == other.trueDistance && startedAt == other.startedAt && samples == other.samples

    override fun hashCode(): Int = listOf(peerId, peerLabel, trueDistance, startedAt, samples).hashCode()

    private companion object {
        /**
         * `String(format: "%.Nf")`: the double's exact binary value rounded half to even, as C's
         * printf does (Java's `String.format` rounds half up), with a '.' whatever the locale.
         */
        fun fixed(value: Double, digits: Int): String {
            if (!value.isFinite()) return if (value.isNaN()) "nan" else if (value > 0) "inf" else "-inf"
            val text = BigDecimal(value).setScale(digits, RoundingMode.HALF_EVEN).toPlainString()
            return if (value < 0 && !text.startsWith("-")) "-$text" else text
        }
    }
}
