package com.hackathonmapper.meshmapper

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.max

/**
 * Replays ml/export/golden.json (predictions of the trained PyTorch model) through the Kotlin
 * runtime, with the tolerances of ml/runtime/test-golden/main.swift.
 */
class MovementModelTests {
    @Serializable
    private data class Case(
        val hist: List<List<Double>>,
        val acc: Double,
        val h: Double,
        val weights: List<Double>,
        val means: List<List<Double>>,
        val covs: List<List<Double>>,
    )

    // Unit tests run in the module directory (android/app).
    private val model = MovementModel(File("src/main/assets/movement-model.json").readText())

    @Test
    fun goldenCases() {
        val cases = Json { ignoreUnknownKeys = true }
            .decodeFromString(ListSerializer(Case.serializer()), File("../../ml/export/golden.json").readText())
        assertEquals(24, cases.size)
        var worst = 0.0
        for (c in cases) {
            val p = model.predict(c.hist.map { MovementModel.Point(it[0], it[1]) }, c.acc, c.h)
            for (k in c.weights.indices) {
                val got = listOf(p.means[k].x, p.means[k].y)
                val cov = listOf(p.covs[k].xx, p.covs[k].xy, p.covs[k].yy)
                worst = max(worst, abs(p.weights[k] - c.weights[k]) / 1e-3)
                for (i in 0 until 2) worst = max(worst, abs(got[i] - c.means[k][i]) / (1e-2 + 1e-4 * abs(c.means[k][i])))
                for (i in 0 until 3) worst = max(worst, abs(cov[i] - c.covs[k][i]) / (1e-2 + 1e-3 * abs(c.covs[k][i])))
            }
        }
        assertTrue("worst error $worst of tolerance", worst <= 1)
    }

    @Test
    fun historyAndSampling() {
        val track = (0 until 60).map { MovementModel.TrackPoint(100 + 1.3 * it, 1.3 * it, 0.0) }
        val hist = model.history(track, track.last().t)
        assertEquals(31, hist.size)
        assertEquals(track.last().x, hist[30].x, 1e-9)
        assertEquals(track.last().x - 60, hist[0].x, 1e-9)
        val prediction = model.predict(hist, 5.0, 60.0)
        val dots = prediction.sample(4000, SplitMix64(42uL))
        val mx = dots.sumOf { it.x } / dots.size
        val ex = prediction.weights.zip(prediction.means).sumOf { (w, m) -> w * m.x }
        assertTrue("sample mean $mx vs $ex", abs(mx - ex) < 4)
    }
}
