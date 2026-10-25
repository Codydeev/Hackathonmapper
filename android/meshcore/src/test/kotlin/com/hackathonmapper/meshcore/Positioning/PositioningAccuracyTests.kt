package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.AfterClass
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.Locale
import kotlin.math.abs

/**
 * Accuracy against ground truth on synthetic tracks (never field accuracy). Each scenario runs a
 * few seeds through four variants on identical data and scores the GNSS outage only:
 * - hold-last: the last trusted fix with a circle growing at walking pace (the app before this)
 * - pdr: the engine without Bluetooth
 * - ble: the engine without motion sensors
 * - fusion: everything
 * Set POSITIONING_SEEDS for more seeds and POSITIONING_REPORT=<path> to write the JSON report.
 */
class PositioningAccuracyTests {
    @Serializable
    data class VariantResult(
        val summary: PZ.AccuracySummary,
        /** Pooled median error at fixed times after GNSS was lost. */
        val horizonErrors: Map<String, Double>,
        /** Seconds after the outage until the first non-unavailable estimate (worst seed). */
        val placedAfter: Double?,
    )

    @Serializable
    data class ScenarioResult(
        val name: String,
        val seeds: Int,
        val outage: Double,
        val variants: Map<String, VariantResult>,
    )

    companion object {
        private val report = ArrayList<ScenarioResult>()

        fun table(s: ScenarioResult): String {
            fun f(v: Double?): String = v?.let { if (it.isFinite()) String.format(Locale.ROOT, "%.1f", it) else "never" } ?: "-"
            fun pct(v: Double?): String = v?.let { String.format(Locale.ROOT, "%.0f%%", 100 * it) } ?: "-"
            val lines = mutableListOf(
                "", "### ${s.name} (${s.seeds} seeds, ${s.outage.toInt()} s outage)",
                "| variant | median err | p95 err | median r95 | truth in r95 | point avail | placed after | err@60s | err@120s | err@300s | methods |",
                "|---|---|---|---|---|---|---|---|---|---|---|",
            )
            for (name in listOf("hold-last", "pdr", "ble", "fusion")) {
                val v = s.variants[name] ?: continue
                val m = v.summary
                val methods = m.methods.entries.sortedByDescending { it.value }.joinToString(", ") { "${it.key} ${it.value}" }
                lines.add(
                    "| $name | ${f(m.medianError)} | ${f(m.p95Error)} | ${f(m.medianR95)} | ${pct(m.containment)} | ${pct(m.pointAvailability)} | " +
                        "${f(v.placedAfter)} | ${f(v.horizonErrors["60s"])} | ${f(v.horizonErrors["120s"])} | ${f(v.horizonErrors["300s"])} | $methods |",
                )
            }
            return lines.joinToString("\n")
        }

        @JvmStatic
        @AfterClass
        fun tearDown() {
            val path = System.getenv("POSITIONING_REPORT")
            if (path != null && report.isNotEmpty()) {
                val json = Json { prettyPrint = true; encodeDefaults = true; explicitNulls = false; allowSpecialFloatingPointValues = true }
                runCatching { File(path).writeText(json.encodeToString(ListSerializer(ScenarioResult.serializer()), report)) }
            }
        }

        // MARK: - Scenarios

        /** ARCHITECTURE.md S1 / T5: B loses GNSS on a 3-minute loop, one trusted phone 10-20 m away. */
        fun s1(seed: ULong): SyntheticWalk {
            val w = SyntheticWalk()
            w.seed = seed
            w.duration = 240.0
            w.gnssUntil = 60.0
            w.waypoints = listOf(PZ.Vec2(x = 30.0, z = 0.0), PZ.Vec2(x = 30.0, z = 20.0), PZ.Vec2(x = 0.0, z = 20.0), PZ.Vec2(x = 0.0, z = 0.0))
            w.pauses = listOf(SyntheticWalk.Pause(150.0, 10.0))
            w.disturbances = listOf(SyntheticWalk.Disturbance(center = PZ.Vec2(x = 30.0, z = 20.0), radius = 5.0, bias = PZ.degrees(35.0), flagged = false))
            val r = SimRandom(seed = seed + 7uL)
            w.anchors = listOf(SyntheticWalk.AnchorSpec(id = "phone-a", position = PZ.Vec2(x = 15.0, z = 10.0), rssiOffset = 2 * r.gauss()))
            w.strideLength = r.uniform(0.66, 0.80)
            w.accelAmplitude = r.uniform(0.25, 0.35)
            return w
        }

        fun fourAnchors(seed: ULong): SyntheticWalk {
            val w = SyntheticWalk()
            w.seed = seed
            w.anchors = SyntheticWalk.fourCornerAnchors(seed = seed)
            val r = SimRandom(seed = seed + 7uL)
            w.strideLength = r.uniform(0.66, 0.80)
            w.accelAmplitude = r.uniform(0.25, 0.35)
            return w
        }

        /**
         * S1 with sensors worse than the model assumes: unseen speed changes, a 1°/s gyro bias, noisy
         * compass with unflagged disturbances, 5 m correlated GNSS error, ±4 dB phones, 6 dB shadowing.
         */
        fun s1Harsh(seed: ULong): SyntheticWalk {
            val w = s1(seed)
            val r = SimRandom(seed = seed + 13uL)
            w.strideVariation = 0.15
            w.gyroBias = PZ.degrees(1.0)
            w.compassNoise = PZ.degrees(10.0)
            w.disturbances = listOf(
                SyntheticWalk.Disturbance(center = PZ.Vec2(x = 30.0, z = 20.0), radius = 6.0, bias = PZ.degrees(50.0), flagged = false),
                SyntheticWalk.Disturbance(center = PZ.Vec2(x = 0.0, z = 10.0), radius = 5.0, bias = PZ.degrees(-40.0), flagged = false),
                SyntheticWalk.Disturbance(center = PZ.Vec2(x = 15.0, z = 0.0), radius = 4.0, bias = PZ.degrees(60.0), flagged = false),
            )
            w.gnssCorrelated = 5.0
            w.shadowSigma = 6.0
            w.anchors = listOf(SyntheticWalk.AnchorSpec(id = "phone-a", position = PZ.Vec2(x = 15.0, z = 10.0), rssiOffset = 4 * r.gauss()))
            return w
        }
    }

    private val seeds: List<ULong>
        get() {
            val n = System.getenv("POSITIONING_SEEDS")?.toIntOrNull() ?: 6
            return (1..maxOf(1, n)).map { it.toULong() }
        }

    private fun engine(bluetooth: Boolean = true, motion: Boolean = true): PZ.Engine {
        val config = PZ.Engine.Config()
        config.useBluetooth = bluetooth
        config.useMotion = motion
        config.useCompass = motion
        return PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1", config = config)
    }

    private fun run(
        name: String,
        outageFrom: Double,
        make: (ULong) -> SyntheticWalk,
        variants: List<String> = listOf("hold-last", "pdr", "ble", "fusion"),
    ): ScenarioResult {
        val lossAt = outageFrom
        val pooled = HashMap<String, MutableList<PZ.ReplayEpoch>>()
        val horizons = HashMap<String, MutableMap<Int, MutableList<Double>>>()
        val placed = HashMap<String, MutableList<Double>>()
        var duration = 0.0
        for (seed in seeds) {
            val walk = make(seed)
            duration = walk.duration
            val records = walk.generate().records
            for (v in variants) {
                val epochs = when (v) {
                    "hold-last" -> HoldLastBaseline.run(records, end = walk.duration)
                    "pdr" -> PZ.Replay.run(records, engine = engine(bluetooth = false))
                    "ble" -> PZ.Replay.run(records, engine = engine(motion = false))
                    else -> PZ.Replay.run(records, engine = engine())
                }
                val outage = epochs.filter { it.estimate.t > lossAt }
                pooled.getOrPut(v) { ArrayList() }.addAll(outage)
                for (h in listOf(10, 30, 60, 120, 180, 300, 600)) {
                    val e = outage.firstOrNull { abs(it.estimate.t - (lossAt + h.toDouble())) < 0.5 } ?: continue
                    val err = e.error ?: e.candidateError ?: e.truth?.let { t -> e.estimate.regionCenter?.distance(to = t) }
                    if (err != null) horizons.getOrPut(v) { HashMap() }.getOrPut(h) { ArrayList() }.add(err)
                }
                val first = outage.firstOrNull { it.estimate.method != PZ.Estimate.Method.unavailable }
                placed.getOrPut(v) { ArrayList() }.add(if (first != null) first.estimate.t - lossAt else Double.POSITIVE_INFINITY)
            }
        }
        val results = LinkedHashMap<String, VariantResult>()
        for (v in variants) {
            val h = LinkedHashMap<String, Double>()
            for ((k, values) in horizons[v] ?: emptyMap()) PZ.Stats.median(values)?.let { h["${k}s"] = it }
            results[v] = VariantResult(summary = PZ.AccuracySummary.of(pooled[v] ?: emptyList()), horizonErrors = h, placedAfter = placed[v]?.maxOrNull())
        }
        val scenario = ScenarioResult(name = name, seeds = seeds.size, outage = duration - lossAt, variants = results)
        report.add(scenario)
        println(table(scenario))
        return scenario
    }

    @Test
    fun testS1OutageWithOneTrustedNeighbour() {
        val s = run("S1/T5: one trusted neighbour, 3 min outage, synthetic", outageFrom = 60.0, make = ::s1)
        val fusion = s.variants["fusion"]!!
        // AC-4: placed within 5 s; truth inside r95 in >= 90 % of 1 s samples.
        assertTrue(fusion.placedAfter!! <= 5)
        assertTrue(fusion.summary.containment!! >= 0.90)
        assertTrue("one anchor alone: honest region", s.variants["ble"]!!.summary.containment!! >= 0.90)
        assertTrue(fusion.summary.medianError!! < s.variants["hold-last"]!!.summary.medianError!!)
    }

    @Test
    fun testS1WithHarshSensors() {
        val s = run("S1 harsh: unseen speed changes, 1°/s gyro bias, disturbed compass, 6 dB shadowing, synthetic", outageFrom = 60.0, make = ::s1Harsh)
        val fusion = s.variants["fusion"]!!
        assertTrue(fusion.placedAfter!! <= 5)
        // Beyond the model on purpose; AC-4's 90 % applies to S1 above. Here r95 must degrade, not collapse.
        assertTrue("worse sensors must widen r95, not break it", fusion.summary.containment!! >= 0.85)
    }

    @Test
    fun testFourAnchorsTenMinuteOutage() {
        val s = run("Four anchors, 10 min outage, synthetic", outageFrom = 120.0, make = ::fourAnchors)
        val fusion = s.variants["fusion"]!!.summary
        val pdr = s.variants["pdr"]!!.summary
        val hold = s.variants["hold-last"]!!.summary
        assertTrue(fusion.containment!! >= 0.90)
        assertTrue(fusion.medianError!! < pdr.medianError!!)
        assertTrue(fusion.medianError!! < hold.medianError!!)
    }

    @Test
    fun testNoAnchorsDeadReckoningOnly() {
        val s = run("No anchors, 10 min outage, synthetic", outageFrom = 120.0, make = { seed ->
            val w = fourAnchors(seed)
            w.anchors = emptyList()
            w
        }, variants = listOf("hold-last", "pdr"))
        val pdr = s.variants["pdr"]!!.summary
        assertTrue(pdr.containment!! >= 0.90)
        assertTrue(pdr.medianError!! < s.variants["hold-last"]!!.summary.medianError!!)
    }

    /**
     * Scores a walk recorded on a phone (PositioningService.startRecording). With "simulate losing
     * GPS" on, the hidden fixes are already reference records; for a walk recorded with GPS in use,
     * set POSITIONING_MASK_AFTER=<seconds of monotonic time> to hide fixes after that time instead.
     *   POSITIONING_LOG=walk.jsonl ./gradlew :meshcore:test --tests '*PositioningAccuracyTests.testReplayRecordedWalk'
     */
    @Test
    fun testReplayRecordedWalk() {
        val path = System.getenv("POSITIONING_LOG")
        assumeTrue("set POSITIONING_LOG to a recorded .jsonl walk", path != null)
        val records = PZ.LogRecord.decodeLines(File(path!!).readBytes())
        var selfId = "phone"
        var frameId = GeoFrame.defaultFrameId
        for (r in records) {
            if (r is PZ.LogRecord.header) {
                selfId = r.selfId
                frameId = r.frameId
            }
        }
        val options = PZ.Replay.Options()
        options.maskGNSSAfter = System.getenv("POSITIONING_MASK_AFTER")?.toDoubleOrNull()
        val epochs = PZ.Replay.run(records, engine = PZ.Engine(selfId = selfId, frameId = frameId), options = options)
        val lossAt = options.maskGNSSAfter ?: epochs.firstOrNull { it.truth != null }?.estimate?.t ?: 0.0
        val outage = epochs.filter { it.estimate.t > lossAt }
        val summary = PZ.AccuracySummary.of(outage)
        val placed = outage.firstOrNull { it.estimate.method != PZ.Estimate.Method.unavailable }?.let { it.estimate.t - lossAt }
        val scenario = ScenarioResult(
            name = "Recorded walk ${File(path).name}, scored against its GPS reference (which has its own error)",
            seeds = 1, outage = (outage.lastOrNull()?.estimate?.t ?: lossAt) - lossAt,
            variants = mapOf("fusion" to VariantResult(summary = summary, horizonErrors = emptyMap(), placedAfter = placed)),
        )
        report.add(scenario)
        println(table(scenario))
        assertTrue("no reference positions in the recording", summary.epochs > 0)
    }

    @Test
    fun testColdStartWithoutGNSS() {
        val s = run("Cold start, never any GNSS, four anchors, synthetic", outageFrom = 0.0, make = { seed ->
            val w = fourAnchors(seed)
            w.gnssUntil = 0.0
            w.duration = 300.0
            w
        }, variants = listOf("ble", "fusion"))
        assertTrue(s.variants["fusion"]!!.summary.containment!! >= 0.85)
    }
}
