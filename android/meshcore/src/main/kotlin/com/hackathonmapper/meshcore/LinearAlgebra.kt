package com.hackathonmapper.meshcore

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin

/**
 * Solves `a · x = b` by Gaussian elimination with partial pivoting; null if `a` is singular.
 * Sized for the handful of unknowns the positioning code needs.
 */
fun solveLinearSystem(a: List<List<Double>>, b: List<Double>): List<Double>? {
    val n = b.size
    if (a.size != n || !a.all { it.size == n }) return null
    val m = Array(n) { a[it].toDoubleArray() }
    val v = b.toDoubleArray()
    for (column in 0 until n) {
        // First row with the largest magnitude, like Swift's `max(by:)`.
        var pivot = column
        for (row in column + 1 until n) {
            if (abs(m[pivot][column]) < abs(m[row][column])) pivot = row
        }
        if (abs(m[pivot][column]) <= 1e-12) return null
        val swapRow = m[column]; m[column] = m[pivot]; m[pivot] = swapRow
        val swapValue = v[column]; v[column] = v[pivot]; v[pivot] = swapValue
        for (row in column + 1 until n) {
            val factor = m[row][column] / m[column][column]
            if (factor == 0.0) continue
            for (k in column until n) m[row][k] -= factor * m[column][k]
            v[row] -= factor * v[column]
        }
    }
    val x = DoubleArray(n)
    for (row in n - 1 downTo 0) {
        var sum = v[row]
        for (k in row + 1 until n) sum -= m[row][k] * x[k]
        x[row] = sum / m[row][row]
    }
    return x.toList()
}

/** Wraps an angle to -π...π. */
fun normalizedAngle(angle: Double): Double = atan2(sin(angle), cos(angle))

/**
 * Swift's `x.rounded()`: to the nearest integer, halves away from zero. Kotlin's `round()` rounds
 * halves to even and `Math.round` rounds them up, so ported code uses this instead.
 */
fun swiftRounded(x: Double): Double {
    if (!x.isFinite()) return x
    val magnitude = abs(x)
    val whole = floor(magnitude)
    // The fraction `magnitude - whole` is exact, unlike `floor(magnitude + 0.5)`, which rounds
    // 0.49999999999999994 up to 1.
    val result = if (magnitude - whole >= 0.5) whole + 1 else whole
    return Math.copySign(result, x)
}
