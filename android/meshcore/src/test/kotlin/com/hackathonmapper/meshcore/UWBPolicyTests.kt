package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Test

/** Port of ios/MeshCore/Tests/MeshCoreTests/UWBPolicyTests.swift. */
class UWBPolicyTests {
    private val now = 1_000_000.0

    private fun peer(
        id: String,
        rssi: Double? = -70.0,
        anchor: Boolean = false,
        unplaced: Boolean = false,
        measuringFor: TimeInterval? = null,
    ): UWBPeerCandidate = UWBPeerCandidate(
        id = id, rssi = rssi, isDirectionAnchor = anchor, touchesUnplaced = unplaced,
        measuringSince = measuringFor?.let { now - it },
    )

    @Test
    fun testRanksAnchorThenUnplacedThenRSSI() {
        val candidates = listOf(
            peer("strong", rssi = -40.0),
            peer("weak", rssi = -90.0),
            peer("unplaced", rssi = -85.0, unplaced = true),
            peer("anchor", rssi = -95.0, anchor = true),
            peer("silent", rssi = null),
        )
        assertEquals(setOf("anchor"), UWBSessionPolicy.select(candidates, budget = 1, now = now))
        assertEquals(setOf("anchor", "unplaced"), UWBSessionPolicy.select(candidates, budget = 2, now = now))
        assertEquals(setOf("anchor", "unplaced", "strong"), UWBSessionPolicy.select(candidates, budget = 3, now = now))
        assertEquals(setOf("anchor", "unplaced", "strong", "weak"), UWBSessionPolicy.select(candidates, budget = 4, now = now))
        assertEquals(5, UWBSessionPolicy.select(candidates, budget = 10, now = now).size)
        assertEquals(emptySet<String>(), UWBSessionPolicy.select(candidates, budget = 0, now = now))
        assertEquals(emptySet<String>(), UWBSessionPolicy.select(emptyList(), budget = 4, now = now))
    }

    @Test
    fun testTiesAreDeterministicAndDuplicatesCountOnce() {
        val candidates = listOf(peer("b", rssi = -60.0), peer("a", rssi = -60.0), peer("a", rssi = -30.0))
        assertEquals(setOf("a"), UWBSessionPolicy.select(candidates, budget = 1, now = now))
        assertEquals(setOf("a", "b"), UWBSessionPolicy.select(candidates, budget = 2, now = now))
    }

    @Test
    fun testMeasuringSessionHoldsItsSlotAgainstSameClass() {
        // "held" is weaker but measured for 5 s, so a stronger newcomer of the same class waits.
        val candidates = listOf(peer("newcomer", rssi = -50.0), peer("held", rssi = -80.0, measuringFor = 5.0))
        assertEquals(setOf("held"), UWBSessionPolicy.select(candidates, budget = 1, now = now))
        // After the hold time it competes on rank again.
        val expired = listOf(peer("newcomer", rssi = -50.0), peer("held", rssi = -80.0, measuringFor = 25.0))
        assertEquals(setOf("newcomer"), UWBSessionPolicy.select(expired, budget = 1, now = now))
        assertEquals(setOf("newcomer"), UWBSessionPolicy.select(candidates, budget = 1, now = now, minHold = 3.0))
    }

    @Test
    fun testHigherClassDisplacesAHeldSession() {
        val anchor = listOf(peer("anchor", rssi = -95.0, anchor = true), peer("held", rssi = -40.0, measuringFor = 5.0))
        assertEquals(setOf("anchor"), UWBSessionPolicy.select(anchor, budget = 1, now = now))
        val unplaced = listOf(peer("lost", rssi = -95.0, unplaced = true), peer("held", rssi = -40.0, measuringFor = 5.0))
        assertEquals(setOf("lost"), UWBSessionPolicy.select(unplaced, budget = 1, now = now))
        // A held plain link displaces the weakest plain newcomer, never the higher-class one.
        val mixed = listOf(
            peer("lost", unplaced = true), peer("x", rssi = -40.0), peer("y", rssi = -50.0),
            peer("heldPlain", rssi = -99.0, measuringFor = 2.0),
        )
        assertEquals(setOf("lost", "x", "heldPlain"), UWBSessionPolicy.select(mixed, budget = 3, now = now))
        assertEquals(setOf("lost"), UWBSessionPolicy.select(mixed, budget = 1, now = now))
    }

    @Test
    fun testHeldSessionsNeverDisplaceEachOther() {
        val candidates = listOf(
            peer("a", rssi = -50.0, measuringFor = 1.0), peer("b", rssi = -60.0, measuringFor = 1.0),
            peer("c", rssi = -70.0, measuringFor = 1.0),
        )
        assertEquals(setOf("a", "b"), UWBSessionPolicy.select(candidates, budget = 2, now = now))
    }

    @Test
    fun testBudgetShrinksAfterSessionLimit() {
        assertEquals(4, UWBSessionPolicy.initialBudget)
        assertEquals(3, UWBSessionPolicy.reducedBudget(active = 4))
        assertEquals(1, UWBSessionPolicy.reducedBudget(active = 2))
        assertEquals(1, UWBSessionPolicy.reducedBudget(active = 1))
        assertEquals(1, UWBSessionPolicy.reducedBudget(active = 0))
        val candidates = (0 until 6).map { peer("p$it", rssi = (-50 - it).toDouble()) }
        val budget = UWBSessionPolicy.reducedBudget(active = 4)
        assertEquals(setOf("p0", "p1", "p2"), UWBSessionPolicy.select(candidates, budget = budget, now = now))
    }
}
