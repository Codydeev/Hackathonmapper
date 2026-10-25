package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Acceptance checks from ARCHITECTURE.md section 11 on the synthetic fault harness. All numbers are
 * synthetic. `GNSS_REPORT=<file.md> ./gradlew :meshcore:test --tests '*GNSSFaultHarnessTests.testComparisonReport'`
 * writes the full comparison and the alert-limit sweep.
 */
class GNSSFaultHarnessTests {
    private val seeds: List<UInt> = (1u..10u).toList()
    private val withMotion = listOf(GNSSDetectorConfig.inertial, GNSSDetectorConfig.full)
    private val withoutMotion = listOf(GNSSDetectorConfig.gnssOnly, GNSSDetectorConfig.peers, GNSSDetectorConfig.peersAndAnchors)

    private fun runs(scenario: GNSSScenario, config: GNSSDetectorConfig): List<GNSSRunResult> =
        seeds.map { GNSSFaultHarness.run(GNSSSimulatedWorld(scenario, it), config) }

    /** AC-5: a 400 m jump is flagged within 3 s in 10 of 10 runs, whatever the detector has. */
    @Test
    fun testAC5JumpFlaggedWithinThreeSeconds() {
        for (config in GNSSDetectorConfig.all) {
            for (result in runs(GNSSScenario.jump400, config)) {
                val delay = result.metrics.detectionDelay
                assertNotNull("${config.name} seed ${result.seed}", delay)
                assertTrue("${config.name} seed ${result.seed}", delay!! <= 3)
            }
        }
    }

    /**
     * AC-6: with motion, a 1 m/s drift is flagged before 50 m in at least 9 of 10 runs. Without
     * motion it is not flagged, and the minimum detectable offset says so (unbounded).
     */
    @Test
    fun testAC6DriftFlaggedBeforeFiftyMetresOrBoundHonest() {
        for (config in withMotion) {
            val early = runs(GNSSScenario.drift1, config).filter {
                (it.metrics.errorAtDetection ?: Double.POSITIVE_INFINITY) < 50
            }
            assertTrue(config.name, early.size >= 9)
        }
        for (config in withoutMotion) {
            for (result in runs(GNSSScenario.drift1, config)) {
                val start = GNSSScenario.drift1.detectionStart!!.toInt()
                for ((index, assessment) in result.assessments.withIndex()) {
                    if (!(index + 1 >= start && assessment.usableAsPosition)) continue
                    val error = result.errors[index + 1] ?: 0.0
                    val bound = assessment.uncertainty.minimumDetectableOffset ?: Double.POSITIVE_INFINITY
                    assertTrue("${config.name} seed ${result.seed} t=${index + 1}", bound >= error)
                }
            }
        }
    }

    /** AC-7: open-sky clean runs give no rejected second and at most one suspect episode per 10 min. */
    @Test
    fun testAC7NoFalseAlarmsOnOpenSky() {
        for (name in listOf("clean walk", "clean, phone still")) {
            val scenario = GNSSScenario.named(name)!!
            for (config in GNSSDetectorConfig.all) {
                for (result in runs(scenario, config)) {
                    val minutes = result.metrics.cleanEpochs.toDouble() / 60
                    assertEquals("$name ${config.name} seed ${result.seed}", 0, result.metrics.falseRejectEpochs)
                    assertTrue("$name ${config.name} seed ${result.seed}",
                        result.metrics.falseAlarmEvents.toDouble() <= maxOf(1.0, minutes / 10))
                }
            }
        }
    }

    /**
     * S4: once the offset is removed, trust climbs back through recovering or insufficient
     * evidence; it never snaps straight back to trusted.
     */
    @Test
    fun testS4RecoveryIsNotInstant() {
        val end = GNSSScenario.recovery.injections[0].end!!.toInt()
        for (config in withMotion) {
            for (result in runs(GNSSScenario.recovery, config)) {
                assertTrue(result.metrics.detected)
                val after = result.assessments.subList(end - 1, result.assessments.size)
                val firstTrusted = after.indexOfFirst { it.status == GNSSIntegrityStatus.trusted }
                if (firstTrusted >= 0) {
                    assertTrue("${config.name} seed ${result.seed}", firstTrusted >= 5)
                }
                assertTrue("${config.name} seed ${result.seed}", after.any {
                    it.reasons.contains(GNSSReasonCode.recovering) || it.status == GNSSIntegrityStatus.insufficientEvidence
                })
            }
        }
    }

    /** Only evidence that does not depend on GNSS can make a fix trusted. */
    @Test
    fun testGNSSDerivedEvidenceNeverMakesTrusted() {
        for (scenario in GNSSScenario.library) {
            if (scenario.anchorsAt.isNotEmpty()) continue
            for (config in listOf(GNSSDetectorConfig.gnssOnly, GNSSDetectorConfig.peers)) {
                val result = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario, 3u), config)
                assertFalse("${scenario.name} ${config.name}",
                    result.assessments.any { it.status == GNSSIntegrityStatus.trusted })
            }
        }
    }

    /** Correlated (common-mode) errors defeat peer consensus; only independent evidence catches them. */
    @Test
    fun testCommonModeDriftNeedsIndependentEvidence() {
        val drift = GNSSScenario.named("common-mode drift 0.5 m/s")!!
        assertTrue("peers share the error", runs(drift, GNSSDetectorConfig.peers).all { !it.metrics.detected })
        assertTrue(runs(drift, GNSSDetectorConfig.inertial).all { it.metrics.detected })
        val beacon = GNSSScenario.named("common-mode drift 0.5 m/s, anchor at 600 s")!!
        assertTrue("a surveyed beacon catches it", runs(beacon, GNSSDetectorConfig.peersAndAnchors).all { it.metrics.detected })
        // The same drift on this phone alone is caught by its peers.
        val alone = GNSSScenario.named("slow drift 0.5 m/s")!!
        assertTrue(runs(alone, GNSSDetectorConfig.peers).all { it.metrics.detected })
    }

    /**
     * Faults touch only the application data they target: nothing before the onset, and peers only
     * in common-mode faults.
     */
    @Test
    fun testFaultsTouchOnlyTheirTarget() {
        val clean = GNSSSimulatedWorld(GNSSScenario("clean"), 4u)
        val jumped = GNSSSimulatedWorld(GNSSScenario.jump400, 4u)
        val onset = GNSSScenario.jump400.detectionStart!!.toInt()
        assertEquals(clean.fixes.subList(0, onset), jumped.fixes.subList(0, onset))
        assertNotEquals(clean.fixes[onset], jumped.fixes[onset])
        assertEquals(clean.peerReports, jumped.peerReports)
        assertEquals(clean.motion, jumped.motion)
        val common = GNSSSimulatedWorld(GNSSScenario("common", injections = listOf(
            GNSSFaultInjection(GNSSFault.jump(dx = 400.0, dz = 0.0), start = onset.toDouble(), commonMode = true),
        )), 4u)
        assertNotEquals(clean.peerReports[onset + 1], common.peerReports[onset + 1])
    }

    @Test
    fun testHarnessIsDeterministic() {
        val scenario = GNSSScenario.named("clean walk, urban multipath")!!
        val first = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario, 9u), GNSSDetectorConfig.full)
        val second = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario, 9u), GNSSDetectorConfig.full)
        assertEquals(first.metrics, second.metrics)
        assertEquals(first.assessments, second.assessments)
    }

    /** The full comparison (10 seeds) and the alert-limit sweep, written to $GNSS_REPORT. */
    @Test
    fun testComparisonReport() {
        val path = System.getenv("GNSS_REPORT")
        assumeTrue("set GNSS_REPORT=<file.md> to write the comparison", path != null)
        val rows = GNSSFaultHarness.compare(seeds = seeds)
        var report = "All numbers synthetic: GNSSFaultHarness, seeds 1–10, generated by `GNSS_REPORT=… ./gradlew :meshcore:test --tests '*GNSSFaultHarnessTests.testComparisonReport'`.\n\n"
        report += GNSSFaultHarness.markdown(rows) + "\n\n" + alertLimitSweep() + "\n"
        File(path!!).writeText(report)
        println(report)
    }

    /**
     * What the `trusted` bound buys and costs: trusted share on a clean walk against the time a
     * slow fault spends marked trusted while more than 30 m off.
     */
    private fun alertLimitSweep(): String {
        val lines = mutableListOf(
            "| alertLimit | Trusted share, clean walk | Trusted share, clean still | Trusted while > 30 m off: drift 0.2 m/s | drift 0.05 m/s | replay 30 s |",
            "|---|---|---|---|---|---|",
        )
        val scenarios = listOf("clean walk", "clean, phone still", "slow drift 0.2 m/s", "very slow drift 0.05 m/s",
            "replay 30 s old").map { GNSSScenario.named(it)!! }
        val worlds = scenarios.map { scenario -> seeds.map { GNSSSimulatedWorld(scenario, it) } }
        for (limit in listOf(30.0, 50.0, 75.0, 100.0, 150.0, 1_000.0)) {
            val options = GNSSIntegrityEngine.Options.pedestrian
            options.alertLimit = limit
            val config = GNSSDetectorConfig("full", useInertial = true, usePeers = true, useAnchors = true, options = options)
            val metrics = worlds.map { list -> list.map { GNSSFaultHarness.run(it, config).metrics } }
            fun share(index: Int): String {
                val trusted = metrics[index].sumOf { it.trustedCleanEpochs }
                val clean = metrics[index].sumOf { it.cleanEpochs }
                return "${swiftRounded(100 * trusted.toDouble() / maxOf(1, clean).toDouble()).toLong()} %"
            }
            fun wrong(index: Int): String = "${metrics[index].sumOf { it.trustedButWrongEpochs }} s"
            lines.add("| ${limit.toInt()} m | ${share(0)} | ${share(1)} | ${wrong(2)} | ${wrong(3)} | ${wrong(4)} |")
        }
        return lines.joinToString("\n")
    }
}
