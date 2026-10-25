package com.hackathonmapper.meshcore

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.expm1
import kotlin.math.ln
import kotlin.math.ln1p
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.Serializable

/**
 * A position belief on the floor plane (x east, z north, metres): a centre and how far off it may
 * be. Ghost Mode never hands out a centre without its spread.
 *
 * Swift struct with `var`s: Kotlin callers that mutate one must `copy()` it first wherever Swift
 * relied on a value copy. Equality follows Swift's `Double ==` (0.0 equals -0.0).
 */
data class GhostGaussian(
    var x: Double,
    var z: Double,
    /** Covariance in m². */
    var xx: Double,
    var xz: Double = 0.0,
    var zz: Double,
) {
    /** Swift's `(major: Double, minor: Double, angle: Double)` tuple. */
    data class Principal(val major: Double, val minor: Double, val angle: Double)

    val determinant: Double get() = max(xx * zz - xz * xz, 1e-12)

    /** Squared Mahalanobis distance of a point from the centre. */
    fun mahalanobis2(px: Double, pz: Double): Double {
        val dx = px - x
        val dz = pz - z
        return (zz * dx * dx - 2 * xz * dx * dz + xx * dz * dz) / determinant
    }

    /**
     * Mass of the smallest ellipse (same shape as the belief) that reaches the point: 0 at the
     * centre, near 1 far out. A calibrated belief gives uniform levels for the true positions.
     */
    fun level(px: Double, pz: Double): Double = -expm1(-0.5 * mahalanobis2(px, pz))

    fun logDensity(px: Double, pz: Double): Double =
        -ln(2 * PI) - 0.5 * ln(determinant) - 0.5 * mahalanobis2(px, pz)

    /**
     * Variances along the principal axes (largest first) and the angle of the major axis,
     * radians counterclockwise from east.
     */
    val principal: Principal
        get() {
            val mean = (xx + zz) / 2
            val d = sqrt(((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz)
            val major = mean + d
            val angle = if (abs(xz) > 1e-12) atan2(major - xx, xz) else (if (xx >= zz) 0.0 else PI / 2)
            return Principal(major, max(mean - d, 1e-12), angle)
        }

    /** The ellipse that holds `level` of the mass. */
    fun ellipse(level: Double): GhostEllipse {
        val k = sqrt(-2 * ln1p(-min(level, 0.999_999)))
        val p = principal
        return GhostEllipse(semiMajor = k * sqrt(p.major), semiMinor = k * sqrt(p.minor), angle = p.angle)
    }

    /** Area in m² of the ellipse that holds `level` of the mass. */
    fun area(level: Double): Double = -2 * PI * sqrt(determinant) * ln1p(-min(level, 0.999_999))

    /**
     * Mass inside a circle of radius `r` around the centre. Exact for any covariance: the radial
     * part integrates in closed form, the angle numerically (periodic, so few nodes suffice).
     */
    fun mass(r: Double): Double {
        if (!(r > 0)) return 0.0
        val p = principal
        val l1 = p.major
        val l2 = p.minor
        val n = 48
        var sum = 0.0
        for (i in 0 until n) {
            val th = (i.toDouble() + 0.5) * (PI / 2) / n.toDouble()
            val c = cos(th)
            val s = sin(th)
            val a = c * c / l1 + s * s / l2
            sum += -expm1(-0.5 * r * r * a) / a
        }
        return min(1.0, sum / n.toDouble() / sqrt(l1 * l2))
    }

    /**
     * Radius of the circle around the centre that holds `level` of the mass, for maps that draw
     * circles rather than ellipses.
     */
    fun circleRadius(level: Double): Double {
        val clamped = min(max(level, 1e-6), 0.999_999)
        val k = sqrt(-2 * ln1p(-clamped))
        val p = principal
        var lo = k * sqrt(p.minor)
        var hi = k * sqrt(p.major)
        for (i in 0 until 40) {
            if (!(hi - lo > 1e-4)) break
            val mid = (lo + hi) / 2
            if (mass(mid) < clamped) lo = mid else hi = mid
        }
        return hi
    }

    /** Deterministic points drawn from the belief, for drawing it as a cloud. */
    fun samples(count: Int, seed: ULong): List<FloorPoint> {
        val p = principal
        val a = sqrt(p.major)
        val b = sqrt(p.minor)
        val c = cos(p.angle)
        val s = sin(p.angle)
        var state = seed
        fun uniform(): Double {
            state += 0x9E37_79B9_7F4A_7C15uL
            var v = state
            v = (v xor (v shr 30)) * 0xBF58_476D_1CE4_E5B9uL
            v = (v xor (v shr 27)) * 0x94D0_49BB_1331_11EBuL
            v = v xor (v shr 31)
            return ((v shr 11).toDouble() + 0.5) / (1uL shl 53).toDouble()
        }
        return (0 until count).map {
            val r = sqrt(-2 * ln(uniform()))
            val th = 2 * PI * uniform()
            val u = a * r * cos(th)
            val v = b * r * sin(th)
            FloorPoint(x + c * u - s * v, z + s * u + c * v)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is GhostGaussian && x == other.x && z == other.z && xx == other.xx && xz == other.xz && zz == other.zz

    override fun hashCode(): Int {
        var result = (x + 0.0).hashCode()
        result = 31 * result + (z + 0.0).hashCode()
        result = 31 * result + (xx + 0.0).hashCode()
        result = 31 * result + (xz + 0.0).hashCode()
        result = 31 * result + (zz + 0.0).hashCode()
        return result
    }

    companion object {
        /** `sigma` is the standard deviation along each axis. */
        fun isotropic(x: Double, z: Double, sigma: Double): GhostGaussian =
            GhostGaussian(x = x, z = z, xx = sigma * sigma, zz = sigma * sigma)
    }
}

/** Semi-axes in metres; `angle` is the major axis, radians counterclockwise from east. */
@Serializable
data class GhostEllipse(
    val semiMajor: Double,
    val semiMinor: Double,
    val angle: Double,
)

/**
 * A Gaussian with heavy tails: the same centre and shape at a few scales. People mostly keep
 * going the way the filter expects, and sometimes stop or turn; one scale cannot say both. All
 * regions are still ellipses of the core shape, so levels, circles and areas stay exact.
 *
 * The constructor normalizes the weights like Swift's `init(core:scales:)`; `core` is copied so
 * the belief keeps Swift's value semantics.
 */
class GhostBelief(
    core: GhostGaussian,
    scales: List<Scale> = listOf(Scale(weight = 1.0, variance = 1.0)),
) {
    @Serializable
    data class Scale(
        val weight: Double,
        /** Variance multiplier on the core covariance. */
        val variance: Double,
    )

    var core: GhostGaussian = core.copy()
    var scales: List<Scale> = run {
        val total = scales.sumOf { it.weight }
        scales.map { Scale(weight = it.weight / total, variance = it.variance) }
    }

    val x: Double get() = core.x
    val z: Double get() = core.z

    /** Mixture covariance (for consumers that only take one ellipse). */
    val covariance: GhostGaussian
        get() {
            val m = scales.sumOf { it.weight * it.variance }
            return GhostGaussian(x = core.x, z = core.z, xx = core.xx * m, xz = core.xz * m, zz = core.zz * m)
        }

    /** Mass of the smallest centred ellipse that reaches the point. */
    fun level(px: Double, pz: Double): Double = cdf(core.mahalanobis2(px, pz))

    fun logDensity(px: Double, pz: Double): Double {
        val d2 = core.mahalanobis2(px, pz)
        val terms = scales.map { ln(it.weight) - ln(it.variance) - 0.5 * d2 / it.variance }
        val m = terms.max()
        return m + ln(terms.sumOf { exp(it - m) }) - ln(2 * PI) - 0.5 * ln(core.determinant)
    }

    fun mass(r: Double): Double = scales.sumOf { it.weight * scaled(it.variance).mass(r) }

    fun circleRadius(level: Double): Double {
        val clamped = min(max(level, 1e-6), 0.999_999)
        var lo = 0.0
        var hi = scales.map { scaled(it.variance).circleRadius(clamped) }.max()
        for (i in 0 until 50) {
            if (!(hi - lo > 1e-4)) break
            val mid = (lo + hi) / 2
            if (mass(mid) < clamped) lo = mid else hi = mid
        }
        return hi
    }

    /** Squared Mahalanobis radius (in the core's metric) of the ellipse that holds `level`. */
    fun radius2(level: Double): Double {
        val clamped = min(max(level, 1e-6), 0.999_999)
        var lo = 0.0
        var hi = 1.0
        while (cdf(hi) < clamped) hi *= 2
        for (i in 0 until 60) {
            if (!(hi - lo > 1e-9 * hi)) break
            val mid = (lo + hi) / 2
            if (cdf(mid) < clamped) lo = mid else hi = mid
        }
        return hi
    }

    fun ellipse(level: Double): GhostEllipse {
        val k = sqrt(radius2(level))
        val p = core.principal
        return GhostEllipse(semiMajor = k * sqrt(p.major), semiMinor = k * sqrt(p.minor), angle = p.angle)
    }

    fun area(level: Double): Double = PI * radius2(level) * sqrt(core.determinant)

    fun samples(count: Int, seed: ULong): List<FloorPoint> {
        val unit = core.samples(count, seed)
        var cum = 0.0
        val bounds = scales.map { s -> cum += s.weight; Pair(cum, sqrt(s.variance)) }
        return unit.mapIndexed { i, p ->
            // Spread the scales evenly over the points instead of drawing them, so the cloud is stable.
            val u = (i.toDouble() + 0.5) / count.toDouble()
            val k = bounds.firstOrNull { u <= it.first }?.second ?: bounds[bounds.size - 1].second
            FloorPoint(core.x + k * (p.x - core.x), core.z + k * (p.z - core.z))
        }
    }

    private fun cdf(d2: Double): Double = scales.sumOf { it.weight * -expm1(-0.5 * d2 / it.variance) }

    private fun scaled(v: Double): GhostGaussian =
        GhostGaussian(x = core.x, z = core.z, xx = core.xx * v, xz = core.xz * v, zz = core.zz * v)

    override fun equals(other: Any?): Boolean =
        other is GhostBelief && core == other.core && scales == other.scales

    override fun hashCode(): Int = 31 * core.hashCode() + scales.hashCode()

    override fun toString(): String = "GhostBelief(core=$core, scales=$scales)"
}
