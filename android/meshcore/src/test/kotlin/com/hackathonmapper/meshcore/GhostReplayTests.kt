package com.hackathonmapper.meshcore

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs every scenario in ghost/fixtures/ through the tracker (regenerate them with
 * `python3 -I ghost/fixtures/make_fixtures.py`). The fixtures are read in place under `repo.root`.
 */
class GhostReplayTests {
    private val fixtures: List<File>
        get() {
            val root = System.getProperty("repo.root") ?: "../.."
            val dir = File(root, "ghost/fixtures")
            return (dir.listFiles() ?: emptyArray())
                .filter { it.extension == "json" }.sortedBy { it.name }
        }

    @Test
    fun testAllScenariosMeetTheirChecks() {
        assertTrue("ghost/fixtures/ not found under repo.root", fixtures.size >= 10)
        for (file in fixtures) {
            val result = GhostReplay.run(GhostReplay.load(file.readBytes()))
            assertEquals(file.name, emptyList<String>(), result.failures)
        }
    }

    /** While a phone stays out of sight, its area may only grow, and ages never run backwards. */
    @Test
    fun testGhostAreasOnlyGrow() {
        for (file in fixtures) {
            val result = GhostReplay.run(GhostReplay.load(file.readBytes()))
            for (id in result.samples.map { it.id }.toSet()) {
                var previous: GhostReplayResult.Sample? = null
                for (s in result.samples.filter { it.id == id }) {
                    assertTrue(s.age >= 0)
                    val p = previous
                    val a = p?.r95
                    val b = s.r95
                    if (p != null && p.status == GhostStatus.ghost && s.status == GhostStatus.ghost && s.age > p.age &&
                        a != null && b != null && !file.name.contains("dead-reckoning") && !file.name.contains("standing")
                    ) {
                        assertTrue("${file.name} $id t=${s.t}", b >= a - 1e-6)
                    }
                    previous = s
                }
            }
        }
    }

    @Test
    fun testDemoScenarioKeepsTheTruthInsideMostOfTheTime() {
        val file = fixtures.firstOrNull { it.name == "walk-out-of-range.json" }
        assertNotNull(file)
        val result = GhostReplay.run(GhostReplay.load(file!!.readBytes()))
        assertTrue(result.ghostSeconds >= 80)
        assertTrue((result.ghostCoverageR95 ?: 0.0) >= 0.95)
    }
}
