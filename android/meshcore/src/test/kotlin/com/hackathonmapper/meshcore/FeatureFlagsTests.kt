package com.hackathonmapper.meshcore

import kotlin.math.hypot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of ios/MeshCore/Tests/MeshCoreTests/FeatureFlagsTests.swift.
 *
 * The runtime feature switches (Start → Features): stored settings always load, and the switches
 * change what the engines in GhostCore's slots do. Numbers from website/shared/signalmap.ts on the
 * same geometry (Bluetooth only: 8.0000 m; calibration off keeps p0 -59, n 2.5; on gives -62.4, 3.52).
 */
class FeatureFlagsTests {
    private val t0 = 1_793_000_000.0
    private val radio = RadioModel.standard

    private fun data(text: String): ByteArray = text.encodeToByteArray()

    @Test
    fun testDefaultsKeepEveryFeatureOn() {
        val f = FeatureFlags()
        assertTrue(f.motion)
        assertTrue(f.compass)
        assertEquals(PeerPlacement.signalMap, f.peerPlacement)
        assertEquals(SignalRanges.all, f.mainMapRanges)
        assertTrue(f.calibrateRadio)
        assertEquals(PredictionMode.model, f.prediction)
        assertTrue(f.likelyPaths)
        assertTrue(f.fastUpdates)
        assertTrue(f.relayIntegrity)
    }

    @Test
    fun testMissingOrUnreadableStorageGivesDefaults() {
        assertEquals(FeatureFlags(), FeatureFlags.decode(null))
        assertEquals(FeatureFlags(), FeatureFlags.decode(data("{}")))
        assertEquals(FeatureFlags(), FeatureFlags.decode(data("not json")))
        assertEquals(FeatureFlags(), FeatureFlags.decode(data("[]")))
    }

    /**
     * Settings saved by another build: unknown keys are ignored, and an unknown case or a wrong type
     * falls back to that one switch's default without losing the others.
     */
    @Test
    fun testOtherBuildsSettingsLoadKeyByKey() {
        val json = """{"motion":"yes","compass":false,"peerPlacement":"quantum","mainMapRanges":"uwbOnly","prediction":"off","newSwitch":true}"""
        val f = FeatureFlags.decode(data(json))
        assertTrue(f.motion)
        assertFalse(f.compass)
        assertEquals(PeerPlacement.signalMap, f.peerPlacement)
        assertEquals(SignalRanges.uwbOnly, f.mainMapRanges)
        assertEquals(PredictionMode.off, f.prediction)
        assertTrue(f.fastUpdates)
    }

    @Test
    fun testRoundTrip() {
        val f = FeatureFlags()
        f.motion = false
        f.peerPlacement = PeerPlacement.particleFilter
        f.mainMapRanges = SignalRanges.bluetoothOnly
        f.calibrateRadio = false
        f.prediction = PredictionMode.walkingCircle
        f.likelyPaths = false
        f.fastUpdates = false
        f.relayIntegrity = false
        val data = f.encoded()!!
        assertEquals(f, FeatureFlags.decode(data))
    }

    @Test
    fun testEveryChoiceHasATitle() {
        for (c in SignalRanges.entries) assertFalse(c.title.isEmpty())
        for (c in PeerPlacement.entries) assertFalse(c.title.isEmpty())
        for (c in PredictionMode.entries) assertFalse(c.title.isEmpty())
    }

    @Test
    fun testSignalRangesKeepTheChosenDistances() {
        val links = listOf(LinkMeasurement(a = "a", b = "b", rssi = -60.0, uwb = 2.0), LinkMeasurement(a = "a", b = "c", rssi = -70.0))
        assertEquals(listOf(2.0, null), SignalRanges.all.apply(links).map { it.uwb })
        val bluetooth = SignalRanges.bluetoothOnly.apply(links)
        assertEquals(listOf("b", "c"), bluetooth.map { it.b })
        assertEquals(listOf(-60.0, -70.0), bluetooth.map { it.rssi })
        assertTrue(bluetooth.all { it.uwb == null })
        val uwb = SignalRanges.uwbOnly.apply(links)
        assertEquals(listOf("b"), uwb.map { it.b })
        assertEquals(2.0, uwb.first().uwb!!, 0.0)
    }

    // MARK: Engines

    private fun anchor(): PositionEstimate = PositionEstimate(
        subjectId = "gps", timestamp = t0, frameId = "hervanta-v1", kind = PositionEstimate.Kind.measured,
        method = PositionEstimate.Method.gnss, position = Position(x = 10.0, y = 0.0, z = 20.0),
        uncertainty = PositionUncertainty(r95 = 15.0), source = EvidenceSource.gnss,
        freshness = Freshness(maxAge = 15.0),
        provenance = Provenance(producerId = "gps", algorithm = "mesh-report@1", gnssDependent = true),
    )

    /** A UWB link of 3 m whose RSSI reads 8 m (as in SignalMapPositioningTests). */
    private fun place(ranges: SignalRanges, calibrate: Boolean = true): Pair<SignalMapPositioning, List<PositionEstimate>> {
        val engine = SignalMapPositioning(producerId = "phone-me", frameId = "hervanta-v1")
        engine.ranges = ranges
        engine.calibrate = calibrate
        val placed = engine.place(
            anchors = listOf(anchor()), lost = listOf("lost"),
            links = listOf(LinkMeasurement(a = "gps", b = "lost", rssi = radio.expectedRSSI(atDistance = 8.0), uwb = 3.0)),
            observations = emptyList(), now = t0,
        )
        return Pair(engine, placed)
    }

    @Test
    fun testBluetoothOnlyIgnoresTheUWBDistance() {
        val estimate = place(SignalRanges.bluetoothOnly).second.first()
        assertEquals(EvidenceSource.bluetooth, estimate.source)
        val p = estimate.position!!
        assertEquals(8.0, hypot(p.x - 10, p.z - 20), 0.01)
    }

    @Test
    fun testUWBOnlyUsesTheUWBDistance() {
        val estimate = place(SignalRanges.uwbOnly).second.first()
        assertEquals(EvidenceSource.uwb, estimate.source)
        val p = estimate.position!!
        assertEquals(3.0, hypot(p.x - 10, p.z - 20), 0.01)
    }

    /** UWB only drops a link without a UWB distance, so a phone linked by Bluetooth alone isn't placed. */
    @Test
    fun testUWBOnlyLeavesBluetoothOnlyPhonesUnplaced() {
        val engine = SignalMapPositioning(producerId = "phone-me", frameId = "hervanta-v1")
        engine.ranges = SignalRanges.uwbOnly
        val placed = engine.place(
            anchors = listOf(anchor()), lost = listOf("lost"),
            links = listOf(LinkMeasurement(a = "gps", b = "lost", rssi = -70.0)), observations = emptyList(), now = t0,
        )
        assertTrue(placed.isEmpty())
    }

    @Test
    fun testCalibrationSwitch() {
        assertEquals(radio, place(SignalRanges.all, calibrate = false).first.calibratedRadio)
        val calibrated = place(SignalRanges.all, calibrate = true).first.calibratedRadio
        assertEquals(-62.4, calibrated.p0, 0.1)
        assertEquals(3.52, calibrated.n, 0.01)
    }

    @Test
    fun testNoPredictionNeverPredicts() {
        val engine = NoPrediction()
        engine.observe(anchor(), t0)
        assertNull(engine.predict("gps", t0 + 30))
    }
}
