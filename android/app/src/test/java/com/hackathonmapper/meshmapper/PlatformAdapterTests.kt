package com.hackathonmapper.meshmapper

import android.hardware.SensorManager
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.MeshProtocol
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.Positioning
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs

/** Android-free logic of the platform adapters: gateway timing, event log, sensor and scan conversions. */
class PlatformAdapterTests {
    private fun update(id: String, sequence: Long) = DeviceUpdate(
        id = id,
        label = "Phone $id",
        epochId = "8FA55DDD-0A2B-49A5-9C58-8FC90F66A555",
        sequence = sequence,
        role = "mobile",
        position = Position(1.0, 0.0, 2.0),
        positionMode = "floor",
        accuracyMeters = 5.0,
    )

    // MARK: Gateway

    @Test
    fun pendingVersionChangesOnlyWithNewData() {
        val pending = GatewayPending()
        pending.enqueue(listOf(update("a", 1)))
        val first = pending.version
        pending.enqueue(listOf(update("a", 1)))
        assertEquals("same report again is no new data", first, pending.version)
        pending.enqueue(listOf(update("a", 2)))
        assertEquals(first + 1, pending.version)
    }

    @Test
    fun scheduleSendsNewDataFastAndUnchangedDataAsHeartbeat() {
        val schedule = GatewaySchedule()
        val gap = GatewayClient.fastUploadGap
        assertFalse("nothing pending", schedule.due(0.0, false, 1, gap))
        assertTrue(schedule.due(0.0, true, 1, gap))
        schedule.succeeded(1)
        // New data, but within the minimum gap.
        assertFalse(schedule.due(0.1, true, 2, gap))
        assertTrue(schedule.due(0.2, true, 2, gap))
        schedule.succeeded(2)
        // Unchanged data waits for the heartbeat.
        assertFalse(schedule.due(0.5, true, 2, gap))
        assertFalse(schedule.due(1.15, true, 2, gap))
        assertTrue(schedule.due(1.2, true, 2, gap))
        // Fast updates off: the gap is the heartbeat.
        schedule.succeeded(2)
        assertFalse(schedule.due(1.5, true, 3, GatewayClient.heartbeatInterval))
        assertTrue(schedule.due(2.2, true, 3, GatewayClient.heartbeatInterval))
    }

    @Test
    fun scheduleBacksOffAndPausesAfterRejection() {
        val schedule = GatewaySchedule()
        val gap = GatewayClient.fastUploadGap
        assertTrue(schedule.due(0.0, true, 1, gap))
        schedule.failed(0.0)
        assertEquals(1.0, schedule.backoff, 0.0)
        assertFalse(schedule.due(0.9, true, 1, gap))
        assertTrue(schedule.due(1.0, true, 1, gap))
        schedule.failed(1.0)
        schedule.failed(1.0)
        schedule.failed(1.0)
        assertEquals(GatewayClient.maxDelay, schedule.backoff, 0.0)
        schedule.succeeded(1)
        assertEquals(0.0, schedule.backoff, 0.0)
        // A 4xx pauses even new data for rejectedPause.
        assertTrue(schedule.due(10.0, true, 2, gap))
        schedule.rejected(2, 10.0)
        assertFalse(schedule.due(14.9, true, 3, gap))
        assertTrue(schedule.due(10.0 + GatewayClient.rejectedPause, true, 3, gap))
    }

    // MARK: Event log

    @Test
    fun eventLogKeepsRecentEntriesAndExportsSortedJsonLines() {
        var mono = 100.0
        val log = MeshEventLog(appVersion = "0.1.0", build = "7", monotonic = { mono }, wallClock = { 1_761_400_000.25 })
        for (i in 1..50) {
            mono += 1
            log.note("link", "event $i")
        }
        assertEquals(MeshEventLog.recentCount, log.recent.size)
        assertEquals("event 50", log.recent.last().detail)
        assertEquals(50, log.entries.size)
        val lines = log.export(deviceId = "ABCDEF12-0000", label = "P1").lines()
        assertEquals(51, lines.size)
        val header = Json.parseToJsonElement(lines[0]).jsonObject
        assertEquals("header", header["type"]?.jsonPrimitive?.content)
        assertEquals("ABCDEF12-0000", header["deviceId"]?.jsonPrimitive?.content)
        assertEquals("7", header["build"]?.jsonPrimitive?.content)
        assertEquals(MeshProtocol.version, header["wireVersion"]?.jsonPrimitive?.int)
        assertEquals(header.keys.sorted(), header.keys.toList())
        val event = Json.parseToJsonElement(lines[1]).jsonObject
        assertEquals(listOf("cat", "event", "mono", "t"), event.keys.toList())
        assertEquals("2025-10-25T13:46:40.250Z", event["t"]?.jsonPrimitive?.content)
        assertEquals("event 1", event["event"]?.jsonPrimitive?.content)
        assertEquals("ABCDEF12", MeshEventLog.short("ABCDEF12-0000"))
        log.clear()
        assertTrue(log.entries.isEmpty() && log.recent.isEmpty())
    }

    @Test
    fun eventLogTrimsInBatches() {
        val log = MeshEventLog(monotonic = { 0.0 }, wallClock = { 0.0 })
        repeat(MeshEventLog.capacity + 501) { log.note("x", "$it") }
        assertEquals(MeshEventLog.capacity, log.entries.size)
        assertEquals("${MeshEventLog.capacity + 500}", log.entries.last().detail)
    }

    // MARK: Ambient radio

    @Test
    fun serviceUuidsAreWrittenLikeCoreBluetooth() {
        assertEquals("FEAA", AmbientRadioScanner.uuidString(UUID.fromString("0000feaa-0000-1000-8000-00805f9b34fb")))
        assertEquals("1234ABCD", AmbientRadioScanner.uuidString(UUID.fromString("1234abcd-0000-1000-8000-00805f9b34fb")))
        assertEquals(
            "F7A40001-5AB1-4E90-A989-21B5E52E2210",
            AmbientRadioScanner.uuidString(BluetoothMesh.serviceID),
        )
        // Apple (0x004C) iBeacon payload: company ID back in front, little endian.
        val data = AmbientRadioScanner.manufacturerData(0x004C, byteArrayOf(0x02, 0x15))
        assertEquals(listOf(0x4C, 0x00, 0x02, 0x15), data.map { it.toInt() and 0xFF })
    }

    // MARK: Motion

    @Test
    fun androidVectorsBecomeCoreMotionGravity() {
        // Face up on a table: Android TYPE_GRAVITY (0, 0, +9.81 m/s²); Core Motion gravity (0, 0, −1 g).
        val g = MotionSource.coreMotion(0f, 0f, 9.80665f)
        assertEquals(0.0, g.x, 1e-9)
        assertEquals(0.0, g.y, 1e-9)
        assertEquals(-1.0, g.z, 1e-6)
    }

    @Test
    fun compassSigmaFollowsMagnetometerAccuracy() {
        assertEquals(6.0, MotionSource.sigmaDegrees(SensorManager.SENSOR_STATUS_ACCURACY_HIGH)!!, 0.0)
        assertEquals(12.0, MotionSource.sigmaDegrees(SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM)!!, 0.0)
        assertEquals(25.0, MotionSource.sigmaDegrees(SensorManager.SENSOR_STATUS_ACCURACY_LOW)!!, 0.0)
        assertNull(MotionSource.sigmaDegrees(SensorManager.SENSOR_STATUS_UNRELIABLE))
        val gravity = MotionSource.coreMotion(0f, 0f, 9.80665f)
        val (none, state) = MotionSource.compass(
            Positioning.Vec3(0.0, 15.0, -50.0), SensorManager.SENSOR_STATUS_UNRELIABLE, gravity, 1.0, 0.0,
        )
        assertNull(none)
        assertTrue(state.startsWith("uncalibrated"))
    }

    @Test
    fun flatPhoneFacingMagneticNorthReadsTheDeclination() {
        // Tampere-like field: 52.5 µT at 74° dip. Phone flat, top edge (+y) to magnetic north.
        val dip = Positioning.degrees(74.0)
        val field = Positioning.Vec3(0.0, 52.5 * kotlin.math.cos(dip), -52.5 * kotlin.math.sin(dip))
        val gravity = MotionSource.coreMotion(0f, 0f, 9.80665f)
        val declination = Positioning.Compass.tampereDeclination
        val (sample, state) = MotionSource.compass(field, SensorManager.SENSOR_STATUS_ACCURACY_HIGH, gravity, 2.0, declination)
        assertNotNull(sample)
        sample!!
        assertFalse(state, sample.disturbed)
        assertEquals("ok ±6°", state)
        val error = abs(((sample.heading - declination) + 3 * PI) % (2 * PI) - PI)
        assertTrue("heading ${sample.heading}", error < 1e-6)
    }
}
