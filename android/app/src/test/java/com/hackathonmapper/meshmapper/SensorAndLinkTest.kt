package com.hackathonmapper.meshmapper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SensorAndLinkTest {
    @Test
    fun androidAccelerationBecomesCoreMotionUnitsAndSign() {
        // A phone lying face up: Android gravity (0, 0, +9.81 m/s²), Core Motion (0, 0, −1 g).
        val gravity = MotionTracker.coreMotionAcceleration(floatArrayOf(0f, 0f, 9.80665f))
        assertEquals(0.0, gravity.x, 1e-9)
        assertEquals(0.0, gravity.y, 1e-9)
        assertEquals(-1.0, gravity.z, 1e-6)
        val push = MotionTracker.coreMotionAcceleration(floatArrayOf(-4.903325f, 0f, 0f))
        assertEquals(0.5, push.x, 1e-6)
    }

    @Test
    fun chunksFitOneAttWrite() {
        assertEquals(20, BluetoothMesh.chunkLength(23))
        assertEquals(182, BluetoothMesh.chunkLength(185))
        // ATT values are at most 512 bytes even with the 517-byte MTU.
        assertEquals(512, BluetoothMesh.chunkLength(517))
        assertEquals(20, BluetoothMesh.chunkLength(0))
    }

    private fun fix(accuracy: Double, at: Double, provider: String = "gps") =
        LocationFix(LocationCoordinate(61.45, 23.85), accuracy, null, at, provider)

    @Test
    fun usableFixMatchesSwiftFilter() {
        val now = 1_000.0
        assertTrue(LocationSource.isUsable(fix(30.0, now - 30), now))
        assertFalse(LocationSource.isUsable(fix(30.1, now), now))
        assertFalse(LocationSource.isUsable(fix(5.0, now - 30.5), now))
        assertFalse(LocationSource.isUsable(fix(-1.0, now), now))
        assertFalse(LocationSource.isUsable(null, now))
    }

    @Test
    fun networkFixDoesNotOverwriteABetterRecentGpsFix() {
        val now = 1_000.0
        val gps = fix(4.0, now - 2)
        assertFalse(LocationSource.shouldReplace(gps, fix(25.0, now, "network"), now))
        assertTrue(LocationSource.shouldReplace(gps, fix(3.0, now, "network"), now))
        assertTrue(LocationSource.shouldReplace(fix(4.0, now - 11), fix(25.0, now, "network"), now))
        assertTrue(LocationSource.shouldReplace(gps, fix(50.0, now), now))
        assertTrue(LocationSource.shouldReplace(null, fix(50.0, now, "network"), now))
    }
}
