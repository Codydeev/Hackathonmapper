package com.hackathonmapper.meshmapper

import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.NeighborObservation
import com.hackathonmapper.meshcore.Position
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GatewayClientTest {
    private fun update(id: String, sequence: Long = 1, neighbors: Int = 0) = DeviceUpdate(
        id = id,
        label = "Phone $id",
        epochId = "8FA55DDD-0A2B-49A5-9C58-8FC90F66A555",
        sequence = sequence,
        role = "mobile",
        position = Position(1.0, 0.0, 2.0),
        positionMode = "floor",
        accuracyMeters = 5.0,
        neighbors = (0 until neighbors).map { NeighborObservation(id = "neighbor-$it", rssi = -60, ageMs = 100) },
    )

    @Test
    fun normalizedOriginAcceptsWhatPeoplePaste() {
        assertEquals("http://192.168.1.20:3000", GatewayClient.normalizedOrigin(" 192.168.1.20:3000 "))
        assertEquals("http://192.168.1.20:3000", GatewayClient.normalizedOrigin("http://192.168.1.20:3000/"))
        assertEquals("https://mesh.example.com", GatewayClient.normalizedOrigin("https://mesh.example.com/api/updates"))
        assertEquals("http://x", GatewayClient.normalizedOrigin("http://x/API/health"))
        assertEquals("http://x", GatewayClient.normalizedOrigin("http://x/api"))
        // Same order of suffix checks as Swift: a trailing slash after /api/updates stays.
        assertEquals("http://x/api/updates", GatewayClient.normalizedOrigin("http://x/api/updates/"))
        assertEquals("", GatewayClient.normalizedOrigin("  "))
    }

    @Test
    fun endpointAppendsPathToTheBaseOnly() {
        assertEquals("http://192.168.1.20:3000/api/updates",
            GatewayClient.endpoint("192.168.1.20:3000", "api/updates").toString())
        assertEquals("https://abc.trycloudflare.com/api/health",
            GatewayClient.endpoint("https://abc.trycloudflare.com/", "api/health").toString())
        for (bad in listOf("", "ftp://host", "http://user:pw@host", "http://host/other", "http://host?x=1", "http://host#f", "http://")) {
            try {
                GatewayClient.endpoint(bad, "api/updates")
                fail("accepted $bad")
            } catch (_: GatewayURLException) {
            }
        }
    }

    @Test
    fun pendingKeepsLatestPerOriginAndRemovesOnlyWhatWasSent() {
        val pending = GatewayPending()
        pending.enqueue(listOf(update("b", 1), update("a", 1)))
        val sent = pending.snapshot()
        assertEquals(listOf("a", "b"), sent.map { it.id })
        // A newer report for "a" arrives while the request is in flight.
        pending.enqueue(listOf(update("a", 2)))
        pending.removeSent(sent)
        assertEquals(listOf(update("a", 2)), pending.snapshot())
    }

    @Test
    fun pendingIsCappedButUpdatesKnownOrigins() {
        val pending = GatewayPending(capacity = 3)
        pending.enqueue((1..5).map { update("d$it") })
        assertEquals(3, pending.count)
        pending.enqueue(listOf(update("d1", 7), update("d9")))
        assertEquals(3, pending.count)
        assertEquals(7L, pending.snapshot().first { it.id == "d1" }.sequence)
        assertFalse(pending.snapshot().any { it.id == "d9" })
    }

    @Test
    fun batchJsonHasTheContractFields() {
        val body = GatewayBatching.encode(GatewayBatch(gatewayId = "gw", frameId = "hervanta-v1", devices = listOf(update("a"))))
            .decodeToString()
        for (field in listOf("\"schemaVersion\":1", "\"gatewayId\":\"gw\"", "\"frameId\":\"hervanta-v1\"", "\"units\":\"m\"", "\"devices\":[{")) {
            assertTrue("$field in $body", body.contains(field))
        }
        assertFalse(body.contains("null"))
    }

    @Test
    fun splitRespectsDeviceAndByteLimitsExactly() {
        val devices = (0 until 250).map { update("device-%03d".format(it), neighbors = 16) }
        val byCount = GatewayBatching.split(devices, "gw", "f")
        assertEquals(listOf(100, 100, 50), byCount.map { it.size })
        assertEquals(devices, byCount.flatten())

        val maxBytes = 8_000
        val bySize = GatewayBatching.split(devices, "gw", "f", maxBytes = maxBytes)
        assertEquals(devices, bySize.flatten())
        for (batch in bySize) {
            val size = GatewayBatching.encode(GatewayBatch(gatewayId = "gw", frameId = "f", devices = batch)).size
            assertTrue("batch of $size bytes", size <= maxBytes)
        }
        // Greedy: adding the next device to any batch but the last would break the limit.
        for (i in 0 until bySize.size - 1) {
            val grown = bySize[i] + bySize[i + 1].first()
            assertTrue(GatewayBatching.encode(GatewayBatch(gatewayId = "gw", frameId = "f", devices = grown)).size > maxBytes)
        }
    }

    @Test
    fun describeGivesReadableErrors() {
        assertEquals("The request timed out.", GatewayClient.describe(java.net.SocketTimeoutException("x")))
        assertEquals("Could not connect to the server.", GatewayClient.describe(java.net.ConnectException("x")))
        assertEquals("The dashboard answered HTTP 502", GatewayClient.describe(GatewayServerException(502)))
    }
}
