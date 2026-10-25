package com.hackathonmapper.meshmapper

import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.NeighborObservation
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.SignalRanges
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    /** A UWB distance is the measured range; the Track tab's range source can drop it or keep only UWB links. */
    @Test
    fun uwbDistanceIsMeasuredAndRangeSourceFilters() {
        val tracker = BluetoothTracker()
        val now = 1_000_000.0
        val withUWB = listOf(
            update("a", PositionSource.gps, 10.0, 20.0, listOf(NeighborObservation("b", -80, 0, uwbDistanceM = 4.0))),
            update("b", PositionSource.none, 0.0, 0.0, listOf(NeighborObservation("a", -80, 0, uwbDistanceM = 4.0))),
        )
        val received = mapOf("a" to now, "b" to now)
        tracker.update(withUWB, received, "a", now)
        val link = tracker.link("a", "b")
        assertNotNull(link)
        assertEquals(4.0, link!!.uwb!!, 1e-9)
        assertEquals(4.0, link.measured, 1e-9)

        tracker.rangeSource = SignalRanges.bluetoothOnly
        tracker.update(withUWB, received, "a", now)
        assertNull(tracker.link("a", "b")!!.uwb)

        val rssiOnly = listOf(
            update("a", PositionSource.gps, 10.0, 20.0, listOf(NeighborObservation("b", -80, 0))),
            update("b", PositionSource.none, 0.0, 0.0, listOf(NeighborObservation("a", -80, 0))),
        )
        tracker.rangeSource = SignalRanges.uwbOnly
        tracker.update(rssiOnly, received, "a", now)
        assertNull(tracker.link("a", "b"))
        tracker.rangeSource = SignalRanges.all
        tracker.update(rssiOnly, received, "a", now)
        assertNotNull(tracker.link("a", "b"))
    }
}
