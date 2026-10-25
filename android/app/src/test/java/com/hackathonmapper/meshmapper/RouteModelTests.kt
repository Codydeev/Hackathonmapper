package com.hackathonmapper.meshmapper

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/** Loaded once for all route tests: the path graph is 4 MB. */
internal object RouteFixtures {
    val model: RouteModel by lazy {
        RouteModel(File(mlExport, "route-model.json").readBytes(), File(mlExport, "graphs/hervanta.json").readBytes())
    }
}

/**
 * Replays ml/export/golden-routes.json (the JS runtime's answers) through the Kotlin route model,
 * with the checks and tolerances of ml/runtime/test-golden-routes/main.swift.
 */
class RouteModelTests {
    private val rm = RouteFixtures.model

    @Test
    fun goldenRoutes() {
        val cases = Json.parseToJsonElement(File(mlExport, "golden-routes.json").readText()).jsonArray.map { it.jsonObject }
        assertEquals(16, cases.size)
        var mismatch = 0
        var worst = 0.0
        val problems = mutableListOf<String>()
        for ((ci, c) in cases.withIndex()) {
            val pred = rm.predictRoutes(c["hist"]!!.points(), c["acc"]!!.jsonPrimitive.double)
            val g = c["out"]!!.jsonObject
            val routes = g["routes"]!!.jsonArray.map { it.jsonObject }
            val offNow = g["offNow"]!!.jsonPrimitive.boolean
            val bin = g["bin"]!!.jsonPrimitive.int
            if (pred.routes.size != routes.size || pred.offNow != offNow || pred.bin != bin) {
                mismatch += 1
                problems.add("case $ci: ${pred.routes.size} routes vs ${routes.size}, offNow ${pred.offNow} vs $offNow, bin ${pred.bin} vs $bin")
                continue
            }
            worst = max(worst, abs(pred.offPath - g["offPath"]!!.jsonPrimitive.double))
            for ((i, r) in pred.routes.withIndex()) {
                val e = routes[i]
                val text = e["text"]!!.jsonPrimitive.content
                val n = e["n"]!!.jsonPrimitive.int
                if (r.text != text || r.line.size != n) {
                    mismatch += 1
                    problems.add("case $ci route $i: '${r.text}' (${r.line.size} pts) vs '$text' ($n pts)")
                }
                val end = e["end"]!!.doubles()
                worst = maxOf(
                    worst, abs(r.p - e["p"]!!.jsonPrimitive.double), abs(r.cum.last() - e["length"]!!.jsonPrimitive.double) / 100,
                    abs(r.line.last().x - end[0]) / 100, abs(r.line.last().y - end[1]) / 100,
                )
            }
            val at = g["at"]!!.jsonObject
            for (t in listOf(120, 300, 600)) {
                val expected = at[t.toString()]!!.jsonArray.map { it.jsonObject }
                for ((i, m) in rm.whereAlong(pred, t.toDouble()).withIndex()) {
                    val e = expected[i]
                    val point = e["point"]!!.doubles()
                    worst = maxOf(worst, abs(m.point.x - point[0]) / 100, abs(m.point.y - point[1]) / 100)
                    if (m.atEnd != e["atEnd"]!!.jsonPrimitive.boolean) mismatch += 1
                }
            }
        }
        assertTrue("$mismatch mismatched routes or labels: $problems", mismatch == 0)
        assertTrue("worst difference $worst", worst <= 0.01)
    }

    @Test
    fun frameRoundTrip() {
        val p = rm.toXY(61.4499, 23.8560)
        val back = rm.toLatLon(p)
        assertEquals(61.4499, back.lat, 1e-9)
        assertEquals(23.8560, back.lon, 1e-9)
    }

    /** predict(track:now:accuracy:) resamples the reports into the 31-point history first. */
    @Test
    fun predictFromTrack() {
        val cases = Json.parseToJsonElement(File(mlExport, "golden-routes.json").readText()).jsonArray
        val hist = cases[0].jsonObject["hist"]!!.points()
        val track = hist.mapIndexed { i, p -> MovementModel.TrackPoint(1000.0 + 2 * i, p.x, p.y) }
        val fromTrack = rm.predict(track, track.last().t, 4.0)
        val direct = rm.predictRoutes(hist, 4.0)
        assertEquals(direct.routes.map { it.text }, fromTrack.routes.map { it.text })
        for ((a, b) in direct.routes.zip(fromTrack.routes)) assertEquals(a.p, b.p, 1e-12)
        val marker = rm.whereAlong(direct, 60.0).first()
        assertTrue(hypot(marker.point.x - direct.routes[0].line[0].x, marker.point.y - direct.routes[0].line[0].y) > 0)
    }
}
