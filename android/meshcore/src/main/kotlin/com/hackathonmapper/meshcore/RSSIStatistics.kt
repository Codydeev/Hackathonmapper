package com.hackathonmapper.meshcore

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.sqrt
import kotlinx.serialization.Serializable

/** `at` is Swift's `Date`: seconds since the Unix epoch. */
@Serializable
data class RSSISample(
    val rssi: Int,
    val at: Double,
)

/** A Swift struct: use [copy] where Swift relies on a value copy (e.g. link snapshots). */
class RSSIStatistics {
    /** Swift's `(samples:, dropped:)` tuple from [takeRecentSamples]. */
    data class RecentSamples(val samples: List<RSSISample>, val dropped: Int)

    companion object {
        /** Smoothing time constant. Time-based, so uneven sample rates smooth over the same window. */
        const val timeConstant: TimeInterval = 3.0
        /** Raw samples kept between two `takeRecentSamples()` calls; older ones are counted, not kept. */
        const val maxRecentSamples = 16
        /** Samples the standard deviation is computed over. */
        const val deviationWindow = 20
    }

    var raw: Int? = null
        private set
    var smoothed: Double? = null
        private set
    var sampleCount: Int = 0
        private set
    var lastSampleAt: Double? = null
        private set
    /** Accepted raw samples since the last `takeRecentSamples()`, oldest first. */
    var recentSamples: List<RSSISample> = emptyList()
        private set
    var droppedRecentSamples: Int = 0
        private set

    private var samples: ArrayDeque<Double> = ArrayDeque()

    /** Samples behind `standardDeviation`: the last `deviationWindow` accepted. */
    val deviationSampleCount: Int get() = samples.size

    /** Returns and clears the raw samples since the previous call, plus how many did not fit. */
    fun takeRecentSamples(): RecentSamples {
        val result = RecentSamples(recentSamples, droppedRecentSamples)
        recentSamples = emptyList()
        droppedRecentSamples = 0
        return result
    }

    fun record(rssi: Int, now: Double = currentTime()): Boolean {
        if (rssi == 127 || rssi !in -127..20) return false
        val value = rssi.toDouble()
        raw = rssi
        val smoothed = smoothed
        val lastSampleAt = lastSampleAt
        if (smoothed != null && lastSampleAt != null) {
            val elapsed = max(0.0, now - lastSampleAt)
            val alpha = 1 - exp(-elapsed / timeConstant)
            this.smoothed = smoothed + alpha * (value - smoothed)
        } else {
            this.smoothed = value
        }
        this.lastSampleAt = now
        if (sampleCount < Int.MAX_VALUE) sampleCount += 1
        if (samples.size == deviationWindow) samples.removeFirst()
        samples.addLast(value)
        var recent = recentSamples
        if (recent.size == maxRecentSamples) {
            recent = recent.drop(1)
            droppedRecentSamples += 1
        }
        recentSamples = recent + RSSISample(rssi = rssi, at = now)
        return true
    }

    // Population deviation over the last `deviationWindow` accepted samples; null before any samples.
    val standardDeviation: Double?
        get() {
            if (samples.isEmpty()) return null
            val mean = samples.fold(0.0) { sum, value -> sum + value } / samples.size
            val variance = samples.fold(0.0) { sum, value -> sum + (value - mean) * (value - mean) } / samples.size
            return sqrt(variance)
        }

    /** Value copy (Swift struct semantics). */
    fun copy(): RSSIStatistics = RSSIStatistics().also {
        it.raw = raw
        it.smoothed = smoothed
        it.sampleCount = sampleCount
        it.lastSampleAt = lastSampleAt
        it.recentSamples = recentSamples
        it.droppedRecentSamples = droppedRecentSamples
        it.samples = ArrayDeque(samples)
    }
}
