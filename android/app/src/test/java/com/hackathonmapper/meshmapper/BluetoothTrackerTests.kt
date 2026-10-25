package com.hackathonmapper.meshmapper

import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.NeighborObservation
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.PositionSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.hypot

class BluetoothTrackerTests {
    private val epoch = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    private fun update(id: String, source: PositionSource, x: Double, z: Double, neighbors: List<NeighborObservation>) =
        DeviceUpdate(
            id = id, label = id, epochId = epoch, sequence = 1, role = "mobile",
            position = Position(x, 0.0, z), positionMode = "floor",
            accuracyMeters = if (source == PositionSource.none) null else 3.0,
            neighbors = neighbors, positionSource = source,
        )

    @Test
    fun phoneWithoutGpsIsPlacedFromItsLinkAndFadesWhenStale() {
        val tracker = BluetoothTracker()
        val now = 1_000_000.0
        val reports = listOf(
            update("a", PositionSource.gps, 10.0, 20.0, listOf(NeighborObservation("b", -65, 0))),
            update("b", PositionSource.none, 0.0, 0.0, listOf(NeighborObservation("a", -65, 0))),
        )
        tracker.update(reports, mapOf("a" to now, "b" to now), "a", now)
        assertEquals("a", tracker.phones.first().id)
        assertTrue(tracker.me!!.isSelf)
        val b = tracker.phones.first { it.id == "b" }
        assertEquals(TrackedPhone.State.estimated, b.state)
        val point = b.point
        assertNotNull(point)
        val link = tracker.link("b", "a")
        assertNotNull(link)
        // The map keeps the measured Bluetooth distance.
        assertEquals(link!!.measured, hypot(point!!.x - 10.0, point.z - 20.0), 0.5)

        // Out of reach: last spot, with a circle growing at walking pace.
        tracker.update(reports, mapOf("a" to now + 20, "b" to now), "a", now + 20)
        val lost = tracker.phones.first { it.id == "b" }
        assertEquals(TrackedPhone.State.lastSeen, lost.state)
        assertTrue(lost.radius!! > b.radius!!)
    }
}
