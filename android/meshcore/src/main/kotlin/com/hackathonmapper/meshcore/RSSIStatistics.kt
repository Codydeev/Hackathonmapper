package com.hackathonmapper.meshcore

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.sqrt

/** A Swift struct: use [copy] where Swift relies on a value copy (e.g. link snapshots). */
class RSSIStatistics {
    companion object {
        /** Smoothing time constant. Time-based, so uneven sample rates smooth over the same window. */
        const val timeConstant: TimeInterval = 3.0
    }

    var raw: Int? = null
        private set
    var smoothed: Double? = null
        private set
    var sampleCount: Int = 0
        private set
    var lastSampleAt: Double? = null
        private set

    private var samples: ArrayDeque<Double> = ArrayDeque()

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
        if (samples.size == 20) samples.removeFirst()
        samples.addLast(value)
        return true
    }

    // Population deviation over the last 20 accepted samples; null before any samples.
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
        it.samples = ArrayDeque(samples)
    }
}
