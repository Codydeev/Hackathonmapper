package com.hackathonmapper.meshcore

import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

/** RSSI from one anchor, already corrected for both radios' offsets. */
data class RangeInput(
    val anchorX: Double,
    val anchorZ: Double,
    val verticalOffset: Double,
    val rssi: Double,
    val sigmaDB: Double,
)

data class RangeFix(
    val x: Double,
    val z: Double,
    /** One-sigma radial error from the geometry and RSSI spread, meters. */
    val accuracy: Double,
    val anchorCount: Int,
    /** Weighted RMS of the remaining RSSI residuals, dB. */
    val residualDB: Double,
)

/**
 * RSSI-only position from three or more anchors: robust (Huber-weighted) Gauss-Newton in the
 * dB domain. Shown on its own in the app and used to start or recover the fused estimate;
 * never published as a measured position by itself.
 */
object RangeSolver {
    fun solve(inputs: List<RangeInput>, model: PathLossModel, iterations: Int = 15): RangeFix? {
        val usable = inputs.filter { it.rssi.isFinite() && it.sigmaDB > 0 }
        if (usable.size < 3) return null

        // Start at the centroid weighted toward the strongest (closest) anchors.
        val weights = usable.map { input ->
            val d = model.distance(input.rssi)
            1 / (d * d)
        }
        var total = 0.0
        for (w in weights) total += w
        var sumX = 0.0
        var sumZ = 0.0
        for (i in usable.indices) sumX += usable[i].anchorX * weights[i]
        for (i in usable.indices) sumZ += usable[i].anchorZ * weights[i]
        var x = sumX / total
        var z = sumZ / total

        var information = arrayOf(doubleArrayOf(0.0, 0.0), doubleArrayOf(0.0, 0.0))
        var residualDB = 0.0
        for (iteration in 0 until iterations) {
            val a = arrayOf(doubleArrayOf(0.0, 0.0), doubleArrayOf(0.0, 0.0))
            val b = doubleArrayOf(0.0, 0.0)
            var squares = 0.0
            var weightSum = 0.0
            for (input in usable) {
                var dx = x - input.anchorX
                var dz = z - input.anchorZ
                if (dx * dx + dz * dz < 1e-6) { dx = 0.01; dz = 0.01 }
                val d2 = dx * dx + dz * dz + input.verticalOffset * input.verticalOffset
                val distance = sqrt(d2)
                val residual = input.rssi - model.predictedRSSI(distance)
                val slope = if (distance > PathLossModel.minDistance) -model.dBPerLogDistance / d2 else 0.0
                val j = doubleArrayOf(slope * dx, slope * dz)
                // Huber: full weight within 1.5 σ, then down-weighted so one blocked anchor can't dominate.
                val normalized = abs(residual) / input.sigmaDB
                val robust = if (normalized <= 1.5) 1.0 else 1.5 / normalized
                val w = robust / (input.sigmaDB * input.sigmaDB)
                for (r in 0 until 2) {
                    for (c in 0 until 2) a[r][c] += w * j[r] * j[c]
                    b[r] += w * j[r] * residual
                }
                squares += w * residual * residual
                weightSum += w
            }
            // Swift copies the array value here, before the damping below.
            information = arrayOf(a[0].copyOf(), a[1].copyOf())
            residualDB = if (weightSum > 0) sqrt(squares / weightSum) else 0.0
            // A little damping keeps nearly collinear anchors from throwing the estimate away.
            val damping = 1e-3 * (a[0][0] + a[1][1]) + 1e-9
            a[0][0] += damping
            a[1][1] += damping
            val delta = solveLinearSystem(a.map { it.toList() }, b.toList()) ?: break
            val length = sqrt(delta[0] * delta[0] + delta[1] * delta[1])
            val scale = if (length > 5) 5 / length else 1.0
            x += delta[0] * scale
            z += delta[1] * scale
            if (length < 1e-3) break
        }

        val det = information[0][0] * information[1][1] - information[0][1] * information[1][0]
        val trace = information[0][0] + information[1][1]
        val accuracy = if (det > 1e-12) sqrt(trace / det) else DashboardContract.maxAccuracyMeters
        if (!(x.isFinite() && z.isFinite())) return null
        return RangeFix(
            x = x, z = z, accuracy = min(accuracy, DashboardContract.maxAccuracyMeters),
            anchorCount = usable.size, residualDB = residualDB,
        )
    }
}
