package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin

/**
 * Ambient radio fingerprinting: keys, recording, matching and its failure modes on a synthetic
 * site, plus the guard that keeps the module out of GNSS integrity and positioning. All numbers
 * are synthetic. `AMBIENT_REPORT=<file.md> ./gradlew :meshcore:test --tests '*AmbientRadioTests.testEvaluationReport'`
 * writes the evaluation table.
 * Port of ios/MeshCore/Tests/MeshCoreTests/AmbientRadioTests.swift.
 */
class AmbientRadioTests {
    companion object {
        const val meshService = "F7A40001-5AB1-4E90-A989-21B5E52E2210"

        /**
         * A deterministic UUID from text, standing in for the identifiers iOS hands out. Upper case,
         * as Swift's `UUID(uuidString:)!.uuidString` gives it.
         */
        fun uuid(text: String): String {
            val hex = AmbientEmitterKey.digest(text) + AmbientEmitterKey.digest("$text#")
            fun part(from: Int, to: Int): String = hex.substring(from, to)
            return "${part(0, 8)}-${part(8, 12)}-${part(12, 16)}-${part(16, 20)}-${part(20, 32)}".uppercase()
        }

        private fun data(vararg bytes: Int): ByteArray = ByteArray(bytes.size) { bytes[it].toByte() }
    }

    /** A building full of advertisers, and a phone listening in it. */
    class Site(
        val name: String,
        seed: UInt,
        size: Double = 100.0,
        /** No beacons and no fixed-address devices, only phones, laptops and earbuds. */
        rotatingOnly: Boolean = false,
    ) {
        enum class Kind(val rawValue: String) {
            beacon("beacon"), tv("tv"), printer("printer"), applePhone("applePhone"), appleLaptop("appleLaptop"),
            androidPhone("androidPhone"), earbuds("earbuds");

            /** Address rotation, as phones, laptops and earbuds do. */
            val rotates: Boolean get() = this in listOf(applePhone, appleLaptop, androidPhone, earbuds)

            val advertisementClass: String
                get() = when (this) {
                    beacon -> AmbientEmitterKey.advertisementClass(manufacturerData = null, serviceUUIDs = listOf("FEAA"), connectable = false)
                    tv -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x75, 0x00, 0x42), serviceUUIDs = emptyList(), connectable = true)
                    printer -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x65, 0x00, 0x01), serviceUUIDs = emptyList(), connectable = true)
                    applePhone -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x10), serviceUUIDs = emptyList(), connectable = true)
                    appleLaptop -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x0c), serviceUUIDs = emptyList(), connectable = true)
                    androidPhone -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x06, 0x00, 0x01), serviceUUIDs = emptyList(), connectable = false)
                    earbuds -> AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x07), serviceUUIDs = emptyList(), connectable = false)
                }
        }

        class Emitter(
            val name: String,
            val kind: Kind,
            val x: Double,
            val z: Double,
            /** dBm at 1 m. */
            val p0: Double,
            /** Seconds into its 15-minute rotation cycle at time 0. */
            val phase: Double,
            val shadowA: Double,
            val shadowB: Double,
        )

        private class Walker(val x: Double, val z: Double, val dx: Double, val dz: Double, val key: AmbientEmitterKey)

        val radio = RadioModel(p0 = -59.0, n = 2.5, sigma = 4.0, range = 35.0, soft = 5.0)
        val emitters: List<Emitter>

        init {
            val random = DeterministicRandom(seed = seed)
            val fixed: List<Kind> = if (rotatingOnly) emptyList() else
                List(4) { Kind.beacon } + List(4) { Kind.tv } + List(3) { Kind.printer }
            val mix: List<Kind> = fixed + List(if (rotatingOnly) 12 else 8) { Kind.applePhone } +
                List(if (rotatingOnly) 8 else 5) { Kind.appleLaptop } + List(if (rotatingOnly) 6 else 4) { Kind.androidPhone } +
                List(4) { Kind.earbuds }
            emitters = mix.mapIndexed { index, kind ->
                // Argument order is evaluation order, as in Swift.
                val x = random.uniform(0.0, size)
                val z = random.uniform(0.0, size)
                val p0 = random.uniform(-65.0, -55.0)
                val phase = random.uniform(0.0, 900.0)
                val shadowA = random.uniform(0.0, 2 * PI)
                val shadowB = random.uniform(0.0, 2 * PI)
                Emitter(
                    name = "$name-${kind.rawValue}-$index", kind = kind, x = x, z = z, p0 = p0, phase = phase,
                    shadowA = shadowA, shadowB = shadowB,
                )
            }
        }

        /**
         * What `device` knows an emitter as at `time`: beacons by their Eddystone UID, everything
         * else by iOS's per-phone identifier, which changes whenever the emitter rotates.
         */
        fun key(emitter: Emitter, device: String, time: Double): AmbientEmitterKey {
            if (emitter.kind == Kind.beacon) return AmbientEmitterKey(kind = AmbientEmitterKey.Kind.eddystoneUID, value = AmbientEmitterKey.digest(emitter.name))
            val epoch = if (emitter.kind.rotates) ((time + emitter.phase) / 900).toInt() else 0
            return AmbientEmitterKey.ios(uuid("$device|${emitter.name}|$epoch"))
        }

        /** Slow spatial variation (walls, furniture), about ±5 dB, different for each emitter. */
        fun shadow(emitter: Emitter, x: Double, z: Double): Double =
            5 * sin(x / 6 + emitter.shadowA) * cos(z / 8 + emitter.shadowB)

        /**
         * `seconds` of listening at (x, z) from `start`, two advertisements a second per emitter in
         * range; with the user's own watch, a few people walking past, and a GhostCore peer.
         */
        fun listen(
            device: String,
            x: Double,
            z: Double,
            start: Double,
            seconds: Int,
            seed: UInt,
            passersBy: Int = 2,
            watch: Boolean = true,
        ): AmbientSnapshot {
            val random = DeterministicRandom(seed = seed)
            val recorder = AmbientRecorder(excludedServices = setOf(meshService))
            val body = 3 * random.gauss()
            val visit = emitters.map { 2 * random.gauss() }
            val walkers = (0 until passersBy).map { index ->
                val angle = random.uniform(0.0, 2 * PI)
                val side = random.uniform(2.0, 8.0)
                val back = random.uniform(10.0, 25.0)
                Walker(
                    x - back * sin(angle) + side * cos(angle), z - back * cos(angle) - side * sin(angle),
                    1.4 * sin(angle), 1.4 * cos(angle), AmbientEmitterKey.ios(uuid("$device|walker|$seed|$index")),
                )
            }
            val watchKey = AmbientEmitterKey.ios(uuid("$device|watch|${(start / 900).toInt()}"))
            for (second in 0 until seconds) {
                for (half in 0 until 2) {
                    val t = start + second.toDouble() + 0.5 * half.toDouble() + 0.2 * random.next()
                    for ((index, emitter) in emitters.withIndex()) {
                        val d = hypot(emitter.x - x, emitter.z - z)
                        if (!(random.next() <= radio.hearProbability(d))) continue
                        val rssi = emitter.p0 - 10 * radio.n * log10(max(0.5, d)) + shadow(emitter, x, z) +
                            visit[index] + body + 3 * random.gauss()
                        recorder.add(
                            AmbientAdvertisement(
                                time = t, emitter = key(emitter, device, t), rssi = rssi,
                                advertisementClass = emitter.kind.advertisementClass,
                            ),
                        )
                    }
                    if (watch) {
                        recorder.add(
                            AmbientAdvertisement(time = t, emitter = watchKey, rssi = -47 + 2 * random.gauss(), advertisementClass = watchClass),
                        )
                    }
                    for (walker in walkers) {
                        val elapsed = t - start
                        val d = hypot(walker.x + walker.dx * elapsed - x, walker.z + walker.dz * elapsed - z)
                        if (!(random.next() <= radio.hearProbability(d))) continue
                        recorder.add(
                            AmbientAdvertisement(
                                time = t, emitter = walker.key, rssi = -59 - 25 * log10(max(0.5, d)) + 3 * random.gauss(),
                                advertisementClass = Kind.applePhone.advertisementClass,
                            ),
                        )
                    }
                    recorder.add(
                        AmbientAdvertisement(
                            time = t, emitter = AmbientEmitterKey.ios(uuid("peer")), rssi = -60.0,
                            serviceUUIDs = listOf(meshService.lowercase()),
                        ),
                    )
                }
            }
            return recorder.snapshot(from = start, to = start + seconds.toDouble())
        }

        /** Records a 4 × 4 grid of spots 25 m apart, 20 s each, one after another from time 0. */
        fun recordGrid(device: String, seed: UInt): FingerprintDatabase {
            val database = FingerprintDatabase()
            for ((index, spot) in grid.withIndex()) {
                val snapshot = listen(device, spot.first, spot.second, start = index.toDouble() * 30, seconds = 20, seed = seed + index.toUInt())
                val result = RadioFingerprint.record(
                    snapshot, id = "spot-$index", label = "Spot $index", frameId = "site", x = spot.first, z = spot.second,
                    positionSource = SpotPositionSource.declared, positionR95 = 2.0, recordedBy = device,
                )
                if (result is RadioFingerprint.RecordResult.success) database.add(result.fingerprint)
            }
            return database
        }

        companion object {
            val watchClass = AmbientEmitterKey.advertisementClass(
                manufacturerData = data(0x4c, 0x00, 0x0f), serviceUUIDs = emptyList(), connectable = true,
            )

            /** (x, z) */
            val grid: List<Pair<Double, Double>> =
                listOf(12.5, 37.5, 62.5, 87.5).flatMap { x -> listOf(12.5, 37.5, 62.5, 87.5).map { Pair(x, it) } }
        }
    }

    // Keys and recording

    @Test
    fun testKeysKeepNothingReadable() {
        val identifier = "12345678-1234-1234-1234-1234567890AB"
        val key = AmbientEmitterKey.ios(identifier)
        assertEquals("the same identifier gives the same key", AmbientEmitterKey.ios(identifier), key)
        assertFalse(key.value.contains("1234567890"))
        assertFalse(key.isPortable)

        val frame = data(0x00, 0xEE) + ByteArray(16) { it.toByte() }
        val beacon = AmbientEmitterKey.best(identifier = identifier, serviceData = mapOf("FEAA" to frame))
        assertEquals(AmbientEmitterKey.Kind.eddystoneUID, beacon.kind)
        assertTrue(beacon.isPortable)
        assertEquals(
            "same beacon on any phone", beacon,
            AmbientEmitterKey.best(identifier = UUID.randomUUID().toString(), serviceData = mapOf("feaa" to frame)),
        )
        assertNull("URL frames are not identities", AmbientEmitterKey.eddystoneUID(serviceData = data(0x10, 0xEE, 0x00)))
        assertEquals(key, AmbientEmitterKey.best(identifier = identifier, serviceData = mapOf("FEAA" to data(0x20))))
    }

    @Test
    fun testAdvertisementClassIgnoresWhichDeviceSentIt() {
        val a = AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x10, 0x05, 0xAB), serviceUUIDs = emptyList(), connectable = true)
        val b = AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x10, 0x07, 0x01), serviceUUIDs = emptyList(), connectable = true)
        val other = AmbientEmitterKey.advertisementClass(manufacturerData = data(0x4c, 0x00, 0x07), serviceUUIDs = emptyList(), connectable = true)
        assertEquals("the payload after the type byte (per-device and rotating) is ignored", a, b)
        assertNotEquals(a, other)
        assertFalse("manufacturer data is not kept in clear", a.contains("4c"))
    }

    @Test
    fun testRecorderDropsPeersAndSummarises() {
        val recorder = AmbientRecorder(excludedServices = setOf(meshService))
        val tv = AmbientEmitterKey.ios(UUID.randomUUID().toString())
        val passing = AmbientEmitterKey.ios(UUID.randomUUID().toString())
        assertFalse(
            "a GhostCore peer",
            recorder.add(
                AmbientAdvertisement(
                    time = 0.0, emitter = AmbientEmitterKey.ios(UUID.randomUUID().toString()), rssi = -50.0,
                    serviceUUIDs = listOf(meshService.lowercase()),
                ),
            ),
        )
        assertFalse("no RSSI", recorder.add(AmbientAdvertisement(time = 0.0, emitter = tv, rssi = 127.0)))
        for (second in 0 until 20) {
            recorder.add(
                AmbientAdvertisement(time = second.toDouble(), emitter = tv, rssi = if (second % 2 == 0) -70.0 else -72.0, advertisementClass = "tv"),
            )
            recorder.add(
                AmbientAdvertisement(time = second.toDouble(), emitter = passing, rssi = -90 + 2 * second.toDouble(), advertisementClass = "phone"),
            )
        }
        assertEquals(2, recorder.emitterCount)
        val snapshot = recorder.snapshot(from = 0.0, to = 20.0)
        val steady = snapshot.emitters.first { it.emitter == tv }
        assertEquals(1.0, steady.presence, 0.0)
        assertEquals(-71.0, steady.rssi, 0.0)
        assertEquals(0.0, steady.trend, 0.2)
        assertEquals(2.0, snapshot.emitters.first { it.emitter == passing }.trend, 0.01)
        assertTrue(snapshot.emitters.any { it.emitter == AmbientEmitterKey(kind = AmbientEmitterKey.Kind.classRank, value = "tv#1") })
        recorder.prune(now = 200.0)
        assertEquals(0, recorder.emitterCount)
    }

    @Test
    fun testRecordingKeepsOnlySteadyDevices() {
        val site = Site(name = "a", seed = 1u)
        val snapshot = site.listen(device = "p1", x = 50.0, z = 50.0, start = 0.0, seconds = 20, seed = 7u, passersBy = 3)
        val fingerprint = RadioFingerprint.record(
            snapshot, label = "Hall", frameId = "site", x = 50.0, z = 50.0,
            positionSource = SpotPositionSource.declared, positionR95 = 2.0, recordedBy = "p1",
        ).get()
        assertTrue(fingerprint.emitters.count { it.emitter.isIdentity } >= 3)
        assertTrue("passers-by are left out", fingerprint.unsteadyCount > 0)
        assertTrue(fingerprint.emitters.all { abs(it.trend) <= 0.4 && it.presence >= 0.5 })

        val short = site.listen(device = "p1", x = 50.0, z = 50.0, start = 0.0, seconds = 8, seed = 7u)
        assertEquals(
            RadioFingerprint.RecordResult.failure(RadioFingerprint.Problem.tooShort),
            RadioFingerprint.record(
                short, label = "x", frameId = "site", x = 0.0, z = 0.0, positionSource = SpotPositionSource.declared,
                positionR95 = 2.0, recordedBy = "p1",
            ),
        )
        val empty = AmbientSnapshot(start = 0.0, end = 20.0, emitters = emptyList())
        assertEquals(
            RadioFingerprint.RecordResult.failure(RadioFingerprint.Problem.tooFewSteadyDevices),
            RadioFingerprint.record(
                empty, label = "x", frameId = "site", x = 0.0, z = 0.0, positionSource = SpotPositionSource.declared,
                positionR95 = 2.0, recordedBy = "p1",
            ),
        )
        assertEquals(
            RadioFingerprint.RecordResult.failure(RadioFingerprint.Problem.invalidPosition),
            RadioFingerprint.record(
                snapshot, label = "x", frameId = "site", x = Double.NaN, z = 0.0, positionSource = SpotPositionSource.declared,
                positionR95 = 2.0, recordedBy = "p1",
            ),
        )
    }

    @Test
    fun testDatabaseRoundTripAndTravellingDevices() {
        val site = Site(name = "a", seed = 2u)
        val database = site.recordGrid(device = "p1", seed = 30u)
        assertEquals(16, database.fingerprints.size)
        val data = database.encoded()
        assertEquals(database, FingerprintDatabase.decode(data))
        val text = data.toString(Charsets.UTF_8)
        assertFalse("no raw identifiers stored", text.contains(uuid("p1|a-tv-4|0")))

        // The user's watch is strong at every spot: carried along, so never evidence of place.
        val travelling = database.travellingEmitters()
        assertTrue(travelling.any { it.kind == AmbientEmitterKey.Kind.classRank && it.value.startsWith(Site.watchClass) })
        assertFalse("fixed beacons do not travel", travelling.any { it.kind == AmbientEmitterKey.Kind.eddystoneUID })

        val edited = database.copy()
        edited.remove(id = "spot-0")
        assertEquals(15, edited.fingerprints.size)
        assertEquals(16, database.fingerprints.size)
    }

    // Matching

    @Test
    fun testMatchesTheRecordedSpot() {
        val site = Site(name = "a", seed = 3u)
        val database = site.recordGrid(device = "p1", seed = 40u)
        val spot = Site.grid[5]
        val snapshot = site.listen(device = "p1", x = spot.first, z = spot.second, start = 600.0, seconds = 15, seed = 99u)
        val result = FingerprintMatcher().match(snapshot, database, frameId = "site", deviceId = "p1")
        assertTrue(result.summary, result.isMatch)
        assertEquals("spot-5", result.candidates.firstOrNull()?.fingerprintId)
        assertTrue(result.r95!! >= 20)
        assertTrue(hypot(result.x!! - spot.first, result.z!! - spot.second) <= result.r95!!)
        assertEquals(SpotPositionSource.declared, result.positionSource)
        assertTrue(result.summary, result.summary.startsWith("Sounds like \"Spot 5\""))
    }

    @Test
    fun testInsufficientEvidenceStates() {
        val site = Site(name = "a", seed = 4u)
        val database = site.recordGrid(device = "p1", seed = 50u)
        val matcher = FingerprintMatcher()
        val spot = Site.grid[0]
        val short = site.listen(device = "p1", x = spot.first, z = spot.second, start = 600.0, seconds = 5, seed = 1u)
        assertEquals(listOf(FingerprintMatch.Reason.windowTooShort), matcher.match(short, database, frameId = "site", deviceId = "p1").reasons)
        val snapshot = site.listen(device = "p1", x = spot.first, z = spot.second, start = 600.0, seconds = 15, seed = 1u)
        assertEquals(
            listOf(FingerprintMatch.Reason.noFingerprints),
            matcher.match(snapshot, FingerprintDatabase(), frameId = "site", deviceId = "p1").reasons,
        )
        assertEquals(
            listOf(FingerprintMatch.Reason.noFingerprints),
            matcher.match(snapshot, database, frameId = "elsewhere", deviceId = "p1").reasons,
        )
        val quiet = AmbientSnapshot(start = 0.0, end = 15.0, emitters = snapshot.emitters.filter { it.emitter.isIdentity }.take(1))
        assertEquals(
            listOf(FingerprintMatch.Reason.tooFewEmittersHeard),
            matcher.match(quiet, database, frameId = "site", deviceId = "p1").reasons,
        )

        // Another building: nothing recorded is heard there.
        val other = Site(name = "b", seed = 77u)
        val away = other.listen(device = "p1", x = 50.0, z = 50.0, start = 600.0, seconds = 15, seed = 2u)
        val devicesOnly = FingerprintMatcher.Options()
        devicesOnly.useClasses = false
        val result = FingerprintMatcher(options = devicesOnly).match(away, database, frameId = "site", deviceId = "p1")
        assertEquals(FingerprintMatch.Verdict.insufficientEvidence, result.verdict)
        assertEquals(listOf(FingerprintMatch.Reason.tooFewCommonEmitters), result.reasons)
        assertNull(result.x)
        assertTrue(result.summary.startsWith("Insufficient evidence"))
    }

    @Test
    fun testTwoSpotsThatSoundAlikeAreAmbiguous() {
        val summaries = (0 until 5).map { index ->
            AmbientEmitterSummary(
                emitter = AmbientEmitterKey(kind = AmbientEmitterKey.Kind.eddystoneUID, value = "b$index"), rssi = -80 - index.toDouble(),
                spread = 2.0, presence = 1.0, samples = 30, trend = 0.0,
            )
        }
        val snapshot = AmbientSnapshot(start = 0.0, end = 20.0, emitters = summaries)
        fun spot(id: String, x: Double): RadioFingerprint =
            RadioFingerprint.record(
                snapshot, id = id, label = id, frameId = "site", x = x, z = 0.0, positionSource = SpotPositionSource.declared,
                positionR95 = 1.0, recordedBy = "p1",
            ).get()
        val far = FingerprintDatabase(fingerprints = listOf(spot("west", 0.0), spot("east", 80.0)))
        assertEquals(listOf(FingerprintMatch.Reason.ambiguous), FingerprintMatcher().match(snapshot, far, frameId = "site", deviceId = "p1").reasons)
        // Close together they merge: one answer, with a radius that covers both.
        val near = FingerprintDatabase(fingerprints = listOf(spot("left", 0.0), spot("right", 8.0)))
        val merged = FingerprintMatcher().match(snapshot, near, frameId = "site", deviceId = "p1")
        assertTrue(merged.isMatch)
        assertEquals(4.0, merged.x!!, 0.5)
        assertTrue(merged.r95!! >= 20 + 4)
    }

    @Test
    fun testSpotsFromAnotherPhoneUsePortableKeysOnly() {
        val site = Site(name = "a", seed = 5u)
        val database = site.recordGrid(device = "p1", seed = 60u)
        val spot = Site.grid[10]
        val snapshot = site.listen(device = "p2", x = spot.first, z = spot.second, start = 600.0, seconds = 15, seed = 3u)
        val result = FingerprintMatcher().match(snapshot, database, frameId = "site", deviceId = "p2")
        assertTrue("only the four beacons can be recognised", result.candidates.all { it.commonDevices <= 4 })
        if (result.isMatch) assertTrue(hypot(result.x!! - spot.first, result.z!! - spot.second) <= result.r95!!)
    }

    @Test
    fun testDeterministic() {
        val site = Site(name = "a", seed = 6u)
        assertEquals(site.recordGrid(device = "p1", seed = 70u), site.recordGrid(device = "p1", seed = 70u))
    }

    /**
     * The module stays out of the GPS trust decision and the pipeline until it is validated. The
     * Swift test reads the Swift sources next to it; this one reads the Kotlin MeshCore sources.
     */
    @Test
    fun testIsolatedFromGNSSIntegrityAndPositioning() {
        val root = System.getProperty("repo.root") ?: "../.."
        val sources = File(root, "android/meshcore/src/main/kotlin")
        val names = listOf(
            "AmbientEmitterKey", "AmbientAdvertisement", "AmbientRecorder", "AmbientSnapshot", "RadioFingerprint",
            "FingerprintDatabase", "FingerprintMatcher", "FingerprintMatch",
        )
        var checked = 0
        for (file in sources.walkTopDown()) {
            if (!file.isFile || file.extension != "kt" || file.name == "AmbientRadio.kt") continue
            val text = file.readText(Charsets.UTF_8)
            for (name in names) assertFalse("${file.name} uses $name", text.contains(name))
            checked += 1
        }
        assertTrue("checked $checked files", checked > 20)
    }

    // Evaluation

    class Outcome {
        var correct = 0
        var wrong = 0
        var insufficient = 0
        val total: Int get() = correct + wrong + insufficient
        val line: String
            get() {
                fun percent(value: Int): String = "${swiftRounded(100 * value.toDouble() / max(1, total).toDouble()).toInt()} %"
                return "${percent(correct)} | ${percent(wrong)} | ${percent(insufficient)}"
            }
    }

    enum class Place(val rawValue: String) {
        atSpot("at a recorded spot"),
        near("5 m from a spot"),
        between("between spots (12–18 m)"),
        otherBuilding("another building"),
    }

    private class Visit(val place: Place, val site: Site, val x: Double, val z: Double)

    /**
     * Recorded 16 spots, then listens 15 s at places around them after `minutes`, for each feature
     * set. Correct: a match whose radius holds the truth. Wrong: a match whose radius does not.
     */
    private fun evaluate(
        minutes: Double,
        devices: Boolean,
        classes: Boolean,
        seeds: List<UInt> = listOf(1u, 2u, 3u, 4u, 5u),
        rotatingOnly: Boolean = false,
    ): Map<Place, Outcome> {
        val options = FingerprintMatcher.Options()
        options.useDevices = devices
        options.useClasses = classes
        // Without devices the device requirement cannot hold; class ranks alone show why it exists.
        if (!devices) options.minCommonDevices = 0
        val matcher = FingerprintMatcher(options = options)
        val outcomes = HashMap<Place, Outcome>()
        for (seed in seeds) {
            val site = Site(name = "site$seed", seed = seed, rotatingOnly = rotatingOnly)
            val other = Site(name = "other$seed", seed = seed + 1_000u, rotatingOnly = rotatingOnly)
            val database = site.recordGrid(device = "p1", seed = seed * 100u)
            val start = 16.0 * 30 + minutes * 60
            val random = DeterministicRandom(seed = seed + 500u)
            for ((index, spot) in Site.grid.withIndex()) {
                val angle = random.uniform(0.0, 2 * PI)
                val betweenX = spot.first + 12.5 + random.uniform(-3.0, 3.0)
                val betweenZ = spot.second + 12.5 + random.uniform(-3.0, 3.0)
                val places = listOf(
                    Visit(Place.atSpot, site, spot.first, spot.second),
                    Visit(Place.near, site, spot.first + 5 * sin(angle), spot.second + 5 * cos(angle)),
                    Visit(Place.between, site, betweenX, betweenZ),
                    Visit(Place.otherBuilding, other, spot.first, spot.second),
                )
                for (visit in places) {
                    val snapshot = visit.site.listen(
                        device = "p1", x = visit.x, z = visit.z, start = start + index.toDouble() * 20, seconds = 15,
                        seed = seed * 1_000u + index.toUInt() * 7u + visit.place.ordinal.toUInt(),
                    )
                    val result = matcher.match(snapshot, database, frameId = "site", deviceId = "p1")
                    val outcome = outcomes.getOrPut(visit.place) { Outcome() }
                    if (!result.isMatch) {
                        outcome.insufficient += 1
                    } else if (visit.place != Place.otherBuilding && hypot(result.x!! - visit.x, result.z!! - visit.z) <= result.r95!!) {
                        outcome.correct += 1
                    } else {
                        outcome.wrong += 1
                    }
                }
            }
        }
        return outcomes
    }

    /**
     * Default matcher (devices and class ranks): matches at and near recorded spots, and never
     * claims a spot in another building, fresh or after the devices rotated.
     */
    @Test
    fun testDefaultsMatchSpotsAndNeverAnotherBuilding() {
        for (minutes in listOf(2.0, 60.0)) {
            val outcomes = evaluate(minutes, devices = true, classes = true, seeds = listOf(1u, 2u, 3u))
            val atSpot = outcomes[Place.atSpot]!!
            assertTrue("$minutes min", atSpot.correct.toDouble() / atSpot.total.toDouble() >= 0.7)
            for (place in listOf(Place.atSpot, Place.near, Place.between)) {
                val outcome = outcomes[place]!!
                assertTrue("$place $minutes min", outcome.wrong.toDouble() / outcome.total.toDouble() <= 0.05)
            }
            assertEquals("$minutes min", 0, outcomes[Place.otherBuilding]!!.wrong)
        }
    }

    /**
     * Phones, laptops and earbuds rotate their addresses: device identities decay within minutes,
     * and what remains must answer "insufficient evidence" rather than a wrong spot. With nothing
     * but rotating devices around, an hour later almost nothing can be matched.
     */
    @Test
    fun testRotationDecaysIdentitiesWithoutWrongAnswers() {
        val fresh = evaluate(2.0, devices = true, classes = false, seeds = listOf(1u, 2u, 3u))
        val later = evaluate(60.0, devices = true, classes = false, seeds = listOf(1u, 2u, 3u))
        assertTrue(later[Place.atSpot]!!.correct < fresh[Place.atSpot]!!.correct)
        val rotating = evaluate(60.0, devices = true, classes = true, seeds = listOf(1u, 2u, 3u), rotatingOnly = true)
        val atSpot = rotating[Place.atSpot]!!
        assertTrue(atSpot.insufficient.toDouble() / atSpot.total.toDouble() >= 0.9)
        for (outcomes in listOf(later, rotating)) {
            for (place in Place.entries) {
                val outcome = outcomes[place]!!
                assertTrue(place.rawValue, outcome.wrong.toDouble() / outcome.total.toDouble() <= 0.05)
            }
        }
    }

    @Test
    fun testEvaluationReport() {
        val path = System.getenv("AMBIENT_REPORT")
        assumeTrue("set AMBIENT_REPORT=<file.md> to write the evaluation", path != null)
        val lines = mutableListOf(
            "Synthetic: AmbientRadioTests.Site, 5 sites × 16 spots recorded 20 s each, then 15 s visits. Correct = match whose radius holds the truth; wrong = match whose radius does not (any match in another building is wrong).",
            "",
            "| Features | Minutes after recording | Place | Correct | Wrong | Insufficient evidence |",
            "|---|---|---|---|---|---|",
        )
        class Configuration(val label: String, val devices: Boolean, val classes: Boolean, val rotatingOnly: Boolean)
        val configurations = listOf(
            Configuration("devices only", true, false, false),
            Configuration("class ranks only (no device requirement)", false, true, false),
            Configuration("both (default)", true, true, false),
            Configuration("both, site with only rotating devices", true, true, true),
        )
        for (configuration in configurations) {
            for (minutes in listOf(2.0, 30.0, 60.0)) {
                val outcomes = evaluate(minutes, configuration.devices, configuration.classes, rotatingOnly = configuration.rotatingOnly)
                for (place in Place.entries) {
                    lines.add("| ${configuration.label} | ${minutes.toInt()} | ${place.rawValue} | ${outcomes[place]!!.line} |")
                }
            }
        }
        val report = lines.joinToString("\n") + "\n"
        File(path!!).writeText(report, Charsets.UTF_8)
        println(report)
    }
}
