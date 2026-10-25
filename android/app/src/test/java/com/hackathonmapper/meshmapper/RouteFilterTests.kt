package com.hackathonmapper.meshmapper

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Replays ml/export/golden-filter.json (the JS route filter: same seed, same signals) through the
 * Kotlin route filter, with the tolerance of ml/runtime/test-golden-filter/main.swift (0.01 m).
 */
class RouteFilterTests {
    @Test
    fun goldenFilter() {
        val rm = RouteFixtures.model
        val cases = Json.parseToJsonElement(File(mlExport, "golden-filter.json").readText()).jsonArray.map { it.jsonObject }
        assertEquals(9, cases.size)
        var worst = 0.0
        val report = mutableListOf<String>()
        for ((i, c) in cases.withIndex()) {
            val f = RouteFilter(rm, c["particles"]!!.jsonPrimitive.int, c["seed"]!!.jsonPrimitive.long.toUInt())
            val s = f.start(c["hist"]!!.points(), c["acc"]!!.jsonPrimitive.double)
            for (element in c["events"]!!.jsonArray) {
                val e = element.jsonObject
                f.advance(s, e["t"]!!.jsonPrimitive.double)
                if (e["kind"]!!.jsonPrimitive.content == "steps") {
                    f.observeSteps(s, e["dx"]!!.jsonPrimitive.double, e["dy"]!!.jsonPrimitive.double, e["seconds"]!!.jsonPrimitive.double)
                } else {
                    val listener = e["listener"]!!.doubles()
                    f.observeBluetooth(
                        s, MovementModel.Point(listener[0], listener[1]),
                        listenerAcc = e["listenerAcc"]!!.jsonPrimitive.double, rssi = e["rssi"]!!.jsonPrimitive.double,
                    )
                }
            }
            f.advance(s, c["T"]!!.jsonPrimitive.double)
            val est = f.estimate(s)
            val out = c["out"]!!.jsonObject
            val center = out["center"]!!.doubles()
            val diff = hypot(est.center.x - center[0], est.center.y - center[1])
            val r95Diff = abs(est.r95 - out["r95"]!!.jsonPrimitive.double)
            worst = maxOf(worst, diff, r95Diff)
            report.add("case $i ${c["kind"]!!.jsonPrimitive.content}: center ${"%.4f".format(diff)} m, r95 ${"%.4f".format(r95Diff)} m")
        }
        assertTrue("worst difference $worst m: $report", worst <= 0.01)
    }

    /** The generator matches mulberry32 as the JS goldens write it (values from node). */
    @Test
    fun mulberry32ReferenceValues() {
        val g = Mulberry32(1000u)
        for (expected in listOf(0.7951949068810791, 0.8276879135519266, 0.6915161057841033, 0.8805752142798156)) {
            assertEquals(expected, g.next(), 0.0)
        }
        val wrapped = Mulberry32(4294967295u)
        assertEquals(0.8964226141106337, wrapped.next(), 0.0)
        assertEquals(0.189478256739676, wrapped.next(), 0.0)
    }
}
