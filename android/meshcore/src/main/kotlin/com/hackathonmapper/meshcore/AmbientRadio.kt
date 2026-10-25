package com.hackathonmapper.meshcore

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// Ambient radio fingerprinting (experimental). A phone records the Bluetooth LE advertisements it
// can hear at a spot whose position is known, and later compares what it hears with those
// recordings: "this sounds like the spot by the main door, give or take 12 m", or "insufficient
// evidence".
//
// Everything here is an observation of the surroundings. The devices behind the advertisements
// (beacons, TVs, printers, other people's phones and earbuds) are not GhostCore peers: they do not
// relay messages, report positions or act as anchors, and nothing here claims to know where they
// are. A match places the phone near a spot somebody recorded, never at a device.
//
// Isolated on purpose: GNSS integrity, positioning and the pipeline do not use this module until
// field data shows that it helps (AmbientRadioTests guards that). Nothing readable about other
// people's devices is kept: identifiers and advertisement contents are reduced to digests. What
// iOS lets an app see, what is stored and why fingerprints decay is in docs/AMBIENT_RADIO.md.
//
// Port of ios/MeshCore/Sources/MeshCore/AmbientRadio.swift.

/** How an advertiser, or a kind of advertiser, is recognised again. Values are digests. */
@Serializable
data class AmbientEmitterKey(val kind: Kind, val value: String) : Comparable<AmbientEmitterKey> {
    @Serializable
    enum class Kind(val rawValue: String) {
        /**
         * The platform's identifier for the advertiser (iOS: `CBPeripheral.identifier`; Android: the
         * advertiser's address as the scan reports it), digested. On iOS a random UUID assigned on
         * this phone, never the hardware address. It changes when the advertiser rotates its address
         * (most phones, watches and earbuds do, about every 15 minutes), and another phone sees a
         * different one for the same device.
         */
        @SerialName("ios") ios("ios"),
        /**
         * An Eddystone-UID beacon's namespace and instance, digested: set by whoever configured
         * the beacon, the same on every phone, stable until reconfigured.
         */
        @SerialName("eddystoneUID") eddystoneUID("eddystoneUID"),
        /**
         * The n-th strongest steady advertiser of one advertisement class (`classDigest#n`). Not a
         * device: it survives address rotation, but a new device of the same class can take the rank.
         */
        @SerialName("classRank") classRank("classRank"),
    }

    /** Recognised by any phone, not only the one that recorded it. */
    val isPortable: Boolean get() = kind != Kind.ios
    /** One device, rather than a rank within a class. */
    val isIdentity: Boolean get() = kind != Kind.classRank
    val description: String get() = "${kind.rawValue}:$value"

    override fun toString(): String = description

    override fun compareTo(other: AmbientEmitterKey): Int = description.compareTo(other.description)

    companion object {
        /**
         * Swift takes a `UUID` and digests its `uuidString` (upper case); here the identifier is a
         * string, upper-cased the same way, so a UUID string gives the same key on both platforms.
         */
        fun ios(identifier: String): AmbientEmitterKey =
            AmbientEmitterKey(kind = Kind.ios, value = digest(identifier.uppercase()))

        /**
         * Eddystone service (16-bit UUID FEAA) UID frame: type 0x00, Tx power, a 10-byte namespace and
         * a 6-byte instance. Other Eddystone frames (URL, TLM, EID) are not stable identities.
         */
        fun eddystoneUID(serviceData: ByteArray): AmbientEmitterKey? {
            if (!(serviceData.size >= 18 && serviceData[0] == 0x00.toByte())) return null
            val hex = (2 until 18).joinToString("") { hex2(serviceData[it]) }
            return AmbientEmitterKey(kind = Kind.eddystoneUID, value = digest(hex))
        }

        /**
         * The most stable key an advertisement allows. `serviceData` is keyed by service UUID string
         * ("FEAA" for Eddystone).
         */
        fun best(identifier: String, serviceData: Map<String, ByteArray> = emptyMap()): AmbientEmitterKey =
            serviceData.entries.firstOrNull { it.key.uppercase() == "FEAA" }?.let { eddystoneUID(serviceData = it.value) }
                ?: ios(identifier)

        /**
         * What kind of advertisement this is, whichever device sent it: the company and the first
         * payload byte of the manufacturer data (a message type for Apple and Microsoft), the
         * advertised services and connectability. Survives address rotation; many devices share one.
         * Only the digest is kept, never the manufacturer data.
         */
        fun advertisementClass(manufacturerData: ByteArray?, serviceUUIDs: List<String>, connectable: Boolean?): String {
            val parts = mutableListOf<String>()
            if (manufacturerData != null && manufacturerData.size >= 2) {
                parts.add("m" + hex2(manufacturerData[1]) + hex2(manufacturerData[0]))
                if (manufacturerData.size >= 3) parts.add("t" + hex2(manufacturerData[2]))
            }
            parts += serviceUUIDs.map { "s" + it.uppercase() }.sorted()
            if (connectable != null) parts.add(if (connectable) "c" else "n")
            return digest(parts.joinToString("|"))
        }

        /**
         * FNV-1a, 64 bit, as 16 hex digits: keeps identifiers and advertisement contents out of
         * storage. Not cryptographic; a class comes from a small space and could be guessed back.
         */
        internal fun digest(text: String): String {
            var hash: ULong = 0xcbf29ce484222325uL
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                hash = hash xor (byte.toUByte().toULong())
                hash *= 0x100000001b3uL
            }
            return hash.toString(16).padStart(16, '0')
        }

        private fun hex2(byte: Byte): String = (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}

/** One advertisement from a passive scan. An observation of the surroundings, not a peer. */
data class AmbientAdvertisement(
    val time: TimeInterval,
    val emitter: AmbientEmitterKey,
    /** dBm. */
    val rssi: Double,
    /** `AmbientEmitterKey.advertisementClass`, when known. */
    val advertisementClass: String? = null,
    /** Advertised service UUIDs; used only to leave GhostCore's own peers out, never stored. */
    val serviceUUIDs: List<String> = emptyList(),
)

/** What a scan heard of one emitter (or class rank) over an interval. */
@Serializable
data class AmbientEmitterSummary(
    val emitter: AmbientEmitterKey,
    /** Median RSSI, dBm, to 0.5 dB. */
    val rssi: Double,
    /** Robust spread (1.4826 × median absolute deviation), dB. */
    val spread: Double,
    /** Share of the interval's one-second slots in which it was heard, 0...1. */
    val presence: Double,
    val samples: Int,
    /** Least-squares slope of the per-second median RSSI, dB/s. Something walking past changes fast. */
    val trend: Double,
)

/** Everything heard over one interval. */
@Serializable
data class AmbientSnapshot(
    val start: TimeInterval,
    val end: TimeInterval,
    /** Devices and class ranks, sorted by key. */
    val emitters: List<AmbientEmitterSummary>,
) {
    val duration: TimeInterval get() = end - start
}

/**
 * Rolling buffer of advertisements, summarised over any recent interval.
 * A Swift struct with mutating methods: `copy()` where Swift copies the value.
 */
class AmbientRecorder(
    excludedServices: Set<String> = emptySet(),
    /** Seconds kept. */
    val horizon: TimeInterval = 120.0,
) {
    /** One advertisement's time and level (Swift tuple). */
    private class Sample(val time: TimeInterval, val rssi: Double)

    /**
     * Service UUIDs whose advertisers are left out (GhostCore's own mesh service: those are peers,
     * handled by the mesh, and they move).
     */
    val excludedServices: Set<String> = excludedServices.map { it.uppercase() }.toSet()
    private var samples: MutableMap<AmbientEmitterKey, MutableList<Sample>> = HashMap()
    private var classes: MutableMap<AmbientEmitterKey, String> = HashMap()

    /** A value copy, as assigning the Swift struct makes. */
    fun copy(): AmbientRecorder {
        val other = AmbientRecorder(excludedServices, horizon)
        for ((key, list) in samples) other.samples[key] = list.toMutableList()
        other.classes = HashMap(classes)
        return other
    }

    /** Devices currently in the buffer. */
    val emitterCount: Int get() = samples.size

    /**
     * Adds one advertisement; false when it is dropped (a GhostCore peer, or no usable RSSI: iOS
     * reports 127 when it has none).
     */
    fun add(advertisement: AmbientAdvertisement): Boolean {
        if (!(advertisement.rssi.isFinite() && advertisement.rssi != 127.0 && advertisement.rssi >= -127 && advertisement.rssi <= 20 &&
                advertisement.time.isFinite() && advertisement.emitter.isIdentity &&
                !advertisement.serviceUUIDs.any { excludedServices.contains(it.uppercase()) })
        ) return false
        val list = samples.getOrPut(advertisement.emitter) { mutableListOf() }
        if (list.size == maxSamplesPerEmitter) list.removeAt(0)
        list.add(Sample(advertisement.time, advertisement.rssi))
        val advertisementClass = advertisement.advertisementClass
        if (advertisementClass != null) classes[advertisement.emitter] = advertisementClass
        return true
    }

    /** Forgets everything older than `horizon` before `now`. */
    fun prune(now: TimeInterval) {
        val cutoff = now - horizon
        for ((key, list) in samples.entries.toList()) {
            val kept = list.filter { it.time >= cutoff }
            if (kept.isEmpty()) samples.remove(key) else samples[key] = kept.toMutableList()
            if (kept.isEmpty()) classes.remove(key)
        }
    }

    fun removeAll() {
        samples = HashMap()
        classes = HashMap()
    }

    /**
     * Summary of what was heard in `[start, end)`: each device, then each class's strongest steady
     * devices as ranks.
     */
    fun snapshot(from: TimeInterval, to: TimeInterval): AmbientSnapshot {
        val start = from
        val end = to
        val slots = max(1, ceil(end - start).toInt())
        val devices = mutableListOf<AmbientEmitterSummary>()
        for ((key, list) in samples) {
            val inside = list.filter { it.time >= start && it.time < end }
            if (inside.isEmpty()) continue
            devices.add(summary(key, inside, start, slots))
        }
        val ranks = mutableListOf<AmbientEmitterSummary>()
        val byClass = devices.filter { it.presence >= rankPresence && classes[it.emitter] != null }
            .groupBy { classes[it.emitter]!! }
        for ((advertisementClass, members) in byClass) {
            val ordered = members.sortedWith { l, r ->
                if (l.rssi != r.rssi) r.rssi.compareTo(l.rssi) else l.emitter.compareTo(r.emitter)
            }
            for ((index, member) in ordered.take(maxRanksPerClass).withIndex()) {
                ranks.add(
                    AmbientEmitterSummary(
                        emitter = AmbientEmitterKey(kind = AmbientEmitterKey.Kind.classRank, value = "$advertisementClass#${index + 1}"),
                        rssi = member.rssi, spread = member.spread, presence = member.presence, samples = member.samples,
                        trend = member.trend,
                    ),
                )
            }
        }
        return AmbientSnapshot(start = start, end = end, emitters = (devices + ranks).sortedWith { l, r -> l.emitter.compareTo(r.emitter) })
    }

    companion object {
        /** Samples kept per emitter; scans with duplicates allowed deliver several a second. */
        const val maxSamplesPerEmitter = 1_200
        /** Class ranks kept per class: deeper ranks shuffle whenever anyone walks by. */
        const val maxRanksPerClass = 3
        /** A device ranks within its class only if heard in this share of the interval. */
        const val rankPresence = 0.5

        private fun summary(key: AmbientEmitterKey, inside: List<Sample>, start: TimeInterval, slots: Int): AmbientEmitterSummary {
            val bySlot = HashMap<Int, MutableList<Double>>()
            for (sample in inside) {
                bySlot.getOrPut(min(slots - 1, max(0, (sample.time - start).toInt()))) { mutableListOf() }.add(sample.rssi)
            }
            val values = inside.map { it.rssi }
            val middle = median(values)
            val spread = 1.4826 * median(values.map { abs(it - middle) })
            // In slot order, so the same samples always give bit-identical sums.
            val points = bySlot.keys.sorted().map { kotlin.Pair(it.toDouble() + 0.5, median(bySlot[it]!!)) }
            return AmbientEmitterSummary(
                emitter = key, rssi = swiftRounded(middle * 2) / 2, spread = spread,
                presence = bySlot.size.toDouble() / slots.toDouble(), samples = inside.size,
                trend = slope(points),
            )
        }

        internal fun median(values: List<Double>): Double {
            if (values.isEmpty()) return Double.NaN
            val sorted = values.sorted()
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) sorted[middle] else (sorted[middle - 1] + sorted[middle]) / 2
        }

        /** Least-squares slope; 0 with fewer than three points. */
        internal fun slope(points: List<kotlin.Pair<Double, Double>>): Double {
            if (points.size < 3) return 0.0
            val n = points.size.toDouble()
            val mx = points.fold(0.0) { s, p -> s + p.first } / n
            val my = points.fold(0.0) { s, p -> s + p.second } / n
            val sxx = points.fold(0.0) { s, p -> s + (p.first - mx) * (p.first - mx) }
            if (!(sxx > 0)) return 0.0
            return points.fold(0.0) { s, p -> s + (p.first - mx) * (p.second - my) } / sxx
        }
    }
}

/** Where a recorded spot's position came from. */
@Serializable
enum class SpotPositionSource(val rawValue: String) {
    /** Typed or pinned by a person, or surveyed: independent of GNSS. */
    @SerialName("declared") declared("declared"),
    /** This phone's GNSS, trusted by the integrity engine when the spot was recorded. */
    @SerialName("gnss") gnss("gnss"),
    /** This phone's GNSS with the GPS check off: nobody judged it. */
    @SerialName("gnssUnchecked") gnssUnchecked("gnssUnchecked"),
}

/** What a spot sounded like when it was recorded. */
@Serializable
data class RadioFingerprint(
    val id: String,
    val label: String,
    val frameId: String,
    /** The spot on the frame's floor plane, meters. */
    val x: Double,
    val z: Double,
    val positionSource: SpotPositionSource,
    /** 95 % radius of the spot's own position, meters. */
    val positionR95: Double,
    /** App device ID of the recording phone: its `ios` keys mean nothing on other phones. */
    val recordedBy: String,
    val recordedAt: TimeInterval,
    val duration: TimeInterval,
    /** Devices and class ranks that stayed steady through the recording. */
    val emitters: List<AmbientEmitterSummary>,
    /** Heard but left out as unsteady: passing by, heard too rarely, or too erratic. */
    val unsteadyCount: Int,
) {
    data class Options(
        /** Seconds of standing still a recording needs. */
        var minDuration: TimeInterval = 15.0,
        var minPresence: Double = 0.5,
        var minSamples: Int = 5,
        /** dB. */
        var maxSpread: Double = 8.0,
        /** dB/s: faster than this, the emitter (or someone between) was moving. */
        var maxTrend: Double = 0.4,
        /** A spot with fewer steady devices cannot be told apart from others. */
        var minSteadyDevices: Int = 3,
    )

    enum class Problem(val rawValue: String) {
        tooShort("tooShort"), tooFewSteadyDevices("tooFewSteadyDevices"), invalidPosition("invalidPosition"),
    }

    /** Swift's `Result<RadioFingerprint, Problem>`: `success` or `failure`, with `get()`. */
    sealed class RecordResult {
        data class success(val fingerprint: RadioFingerprint) : RecordResult()
        data class failure(val problem: Problem) : RecordResult()

        /** The fingerprint; throws on a failure, like `Result.get()`. */
        fun get(): RadioFingerprint = when (this) {
            is success -> fingerprint
            is failure -> throw IllegalStateException("recording failed: ${problem.rawValue}")
        }
    }

    companion object {
        /** Keeps what stayed steady through `snapshot`, recorded standing still at a known spot. */
        fun record(
            snapshot: AmbientSnapshot,
            id: String = UUID.randomUUID().toString().uppercase(),
            label: String,
            frameId: String,
            x: Double,
            z: Double,
            positionSource: SpotPositionSource,
            positionR95: Double,
            recordedBy: String,
            options: Options = Options(),
        ): RecordResult {
            if (!(x.isFinite() && z.isFinite() && abs(x) <= DashboardContract.maxCoordinate && abs(z) <= DashboardContract.maxCoordinate &&
                    positionR95.isFinite() && positionR95 >= 0)
            ) return RecordResult.failure(Problem.invalidPosition)
            if (!(snapshot.duration >= options.minDuration)) return RecordResult.failure(Problem.tooShort)
            val steady = snapshot.emitters.filter {
                it.presence >= options.minPresence && it.samples >= options.minSamples &&
                    it.spread <= options.maxSpread && abs(it.trend) <= options.maxTrend
            }
            if (!(steady.count { it.emitter.isIdentity } >= options.minSteadyDevices)) return RecordResult.failure(Problem.tooFewSteadyDevices)
            val devices = snapshot.emitters.count { it.emitter.isIdentity }
            return RecordResult.success(
                RadioFingerprint(
                    id = id, label = DashboardContract.truncatedLabel(label), frameId = frameId, x = x, z = z,
                    positionSource = positionSource, positionR95 = positionR95, recordedBy = recordedBy, recordedAt = snapshot.end,
                    duration = snapshot.duration, emitters = steady, unsteadyCount = devices - steady.count { it.emitter.isIdentity },
                ),
            )
        }
    }
}

/**
 * The recorded spots. They stay on the phone that recorded them.
 * `fingerprints` is `private(set)` in Swift; change it through `add` and `remove`. A Swift value
 * type: `copy()` where Swift copies it (the list is replaced, never mutated in place).
 */
@Serializable
data class FingerprintDatabase(var fingerprints: List<RadioFingerprint> = emptyList()) {
    /** Adds a spot, replacing one with the same ID. */
    fun add(fingerprint: RadioFingerprint) {
        fingerprints = fingerprints.filter { it.id != fingerprint.id } + fingerprint
    }

    fun remove(id: String) {
        fingerprints = fingerprints.filter { it.id != id }
    }

    /**
     * Emitters heard strongly at spots too far apart for one fixed device to be near both: carried
     * along (the user's own watch or earbuds, a companion's phone), so never evidence of place.
     * −72 dBm is within a few meters of a typical advertiser.
     */
    fun travellingEmitters(strongerThan: Double = -72.0, apart: Double = 30.0): Set<AmbientEmitterKey> {
        val strong = strongerThan
        val travelling = HashSet<AmbientEmitterKey>()
        for ((i, a) in fingerprints.withIndex()) {
            for (b in fingerprints.subList(i + 1, fingerprints.size)) {
                if (!(a.frameId == b.frameId && hypot(a.x - b.x, a.z - b.z) >= apart)) continue
                val strongInB = b.emitters.filter { it.rssi >= strong }.map { it.emitter }.toSet()
                for (emitter in a.emitters) {
                    if (emitter.rssi >= strong && strongInB.contains(emitter.emitter)) travelling.add(emitter.emitter)
                }
            }
        }
        return travelling
    }

    /** JSON with sorted keys, like Swift's `JSONEncoder` with `.sortedKeys`. */
    fun encoded(): ByteArray = sortKeys(MeshJson.encodeToJsonElement(this)).toString().toByteArray(Charsets.UTF_8)

    companion object {
        fun decode(data: ByteArray): FingerprintDatabase =
            MeshJson.decodeFromString(serializer(), data.toString(Charsets.UTF_8))

        private fun sortKeys(element: JsonElement): JsonElement = when (element) {
            is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associate { it.key to sortKeys(it.value) })
            is JsonArray -> JsonArray(element.map { sortKeys(it) })
            else -> element
        }
    }
}

/** The answer to "which recorded spot does this sound like?". */
data class FingerprintMatch(
    val verdict: Verdict,
    val reasons: List<Reason>,
    /** Best first, at most three. */
    val candidates: List<Candidate>,
    /** Probability of being at none of the recorded spots. */
    val elsewhere: Double,
    /** A match only: where, and a 95 % radius never below the matcher's `spotRadius`. */
    val x: Double?,
    val z: Double?,
    val r95: Double?,
    /** Posterior of the matched spot together with any spots close to it. */
    val confidence: Double?,
    val positionSource: SpotPositionSource?,
    /** Steady devices used from the live window. */
    val devicesHeard: Int,
    /** One line for the UI. */
    val summary: String,
) {
    @Serializable
    enum class Verdict(val rawValue: String) {
        @SerialName("match") match("match"),
        @SerialName("insufficientEvidence") insufficientEvidence("insufficientEvidence"),
    }

    @Serializable
    enum class Reason(val rawValue: String) {
        /** Listened for less than the minimum window. */
        @SerialName("windowTooShort") windowTooShort("windowTooShort"),
        /** No spot recorded in this frame. */
        @SerialName("noFingerprints") noFingerprints("noFingerprints"),
        /** Too few steady devices heard at all. */
        @SerialName("tooFewEmittersHeard") tooFewEmittersHeard("tooFewEmittersHeard"),
        /**
         * No recorded spot shares enough with what is heard now (elsewhere, or the devices rotated
         * their addresses since).
         */
        @SerialName("tooFewCommonEmitters") tooFewCommonEmitters("tooFewCommonEmitters"),
        /** Two spots far apart fit about equally well. */
        @SerialName("ambiguous") ambiguous("ambiguous"),
        /** The best fit is not convincing against "somewhere not recorded". */
        @SerialName("weakMatch") weakMatch("weakMatch"),
    }

    data class Candidate(
        val fingerprintId: String,
        val label: String,
        val x: Double,
        val z: Double,
        /** 0...1, shared with the other spots and with "somewhere not recorded". */
        val posterior: Double,
        /** Devices heard now that were recorded there. */
        val commonDevices: Int,
        /** Class ranks heard now that were recorded there. */
        val commonClassRanks: Int,
        /** Median |ΔRSSI| over everything in common, dB. */
        val rssiDifference: Double?,
    )

    val isMatch: Boolean get() = verdict == Verdict.match
}

/** Compares what is heard now with the recorded spots. */
class FingerprintMatcher(options: Options = Options()) {
    data class Options(
        /** Seconds of listening needed, standing still. */
        var minWindow: TimeInterval = 10.0,
        /** Live emitters heard in less of the window than this are ignored (passing by). */
        var minPresence: Double = 0.3,
        /** Devices, or class ranks, a spot must share with what is heard now. */
        var minCommon: Int = 3,
        /**
         * Devices (not class ranks) a spot must share. Class ranks exist in every building ("the
         * strongest Apple phone"), so on their own they matched other buildings in a third of
         * synthetic visits: they may strengthen a match, never make one.
         */
        var minCommonDevices: Int = 2,
        /** Compare device identities (lost when devices rotate their address). */
        var useDevices: Boolean = true,
        /** Compare class ranks (survive rotation, but any device of the class can fill a rank). */
        var useClasses: Boolean = true,
        /** Class ranks repeat much of what the devices say, so they count this much. */
        var classWeight: Double = 0.5,
        /**
         * dB: how much one emitter's level differs between two visits to the same spot (body,
         * orientation, people in between, another phone model).
         */
        var rssiSigma: Double = 6.0,
        /** Recorded emitters stronger than this that are not heard now count against a spot. */
        var strongRSSI: Double = -75.0,
        /**
         * Chance a recorded emitter is not heard on a later visit: strong ones rarely vanish (unless
         * they rotate their address or are switched off), weak ones often.
         */
        var missStrong: Double = 0.25,
        var missWeak: Double = 0.7,
        /** Weight of "somewhere not recorded", as one more spot. */
        var elsewhereWeight: Double = 1.0,
        var minConfidence: Double = 0.7,
        /**
         * How far from a recorded spot the surroundings still sound alike, meters: the floor on r95.
         * Moving 15 m relative to a device 20 m away changes its level by about 6 dB, no more than
         * two visits to the same spot differ, so a fingerprint cannot resolve finer than this.
         */
        var spotRadius: Double = 20.0,
    )

    val options: Options = options.copy()

    private class Scored(
        val spot: RadioFingerprint,
        val logLikelihood: Double,
        val devices: Int,
        val ranks: Int,
        val difference: Double?,
    )

    private fun uses(key: AmbientEmitterKey): Boolean = if (key.isIdentity) options.useDevices else options.useClasses

    /**
     * `deviceId`: this phone. Spots recorded by another phone are compared on portable keys only.
     * Swift's argument label `in` is a Kotlin keyword, so the database parameter is `database`.
     */
    fun match(snapshot: AmbientSnapshot, database: FingerprintDatabase, frameId: String, deviceId: String): FingerprintMatch {
        val spots = database.fingerprints.filter { it.frameId == frameId }
        val travelling = database.travellingEmitters()
        val live = snapshot.emitters.filter {
            it.presence >= options.minPresence && !travelling.contains(it.emitter) && uses(it.emitter)
        }
        val devicesHeard = live.count { it.emitter.isIdentity }
        fun insufficient(
            reason: FingerprintMatch.Reason,
            candidates: List<FingerprintMatch.Candidate> = emptyList(),
            elsewhere: Double = 1.0,
            detail: String,
        ): FingerprintMatch = FingerprintMatch(
            verdict = FingerprintMatch.Verdict.insufficientEvidence, reasons = listOf(reason), candidates = candidates,
            elsewhere = elsewhere, x = null, z = null, r95 = null, confidence = null, positionSource = null,
            devicesHeard = devicesHeard, summary = "Insufficient evidence: $detail",
        )
        if (!(snapshot.duration >= options.minWindow)) {
            return insufficient(FingerprintMatch.Reason.windowTooShort, detail = "listen for at least ${options.minWindow.toInt()} s, standing still")
        }
        if (spots.isEmpty()) return insufficient(FingerprintMatch.Reason.noFingerprints, detail = "no spots recorded here yet")
        if (!(devicesHeard >= options.minCommon || (!options.useDevices && live.size >= options.minCommon))) {
            return insufficient(
                FingerprintMatch.Reason.tooFewEmittersHeard,
                detail = "only $devicesHeard steady device${if (devicesHeard == 1) "" else "s"} heard",
            )
        }

        // Log-likelihood of each spot against "somewhere not recorded", under which every live
        // emitter is unexplained (its RSSI anywhere in a 60 dB span).
        val liveByKey = HashMap<AmbientEmitterKey, AmbientEmitterSummary>()
        for (summary in live) if (!liveByKey.containsKey(summary.emitter)) liveByKey[summary.emitter] = summary
        val scored = mutableListOf<Scored>()
        for (spot in spots) {
            val portableOnly = spot.recordedBy != deviceId
            val reference = spot.emitters.filter {
                !travelling.contains(it.emitter) && uses(it.emitter) && (!portableOnly || it.emitter.isPortable)
            }
            val referenceKeys = reference.map { it.emitter }.toSet()
            var logLikelihood = 0.0
            val differences = mutableListOf<Double>()
            var devices = 0
            var ranks = 0
            for (emitter in reference) {
                val weight = if (emitter.emitter.isIdentity) 1.0 else options.classWeight
                val heard = liveByKey[emitter.emitter]
                if (heard != null) {
                    val sigma = sqrt(
                        options.rssiSigma * options.rssiSigma + emitter.spread * emitter.spread +
                            heard.spread * heard.spread,
                    )
                    val difference = heard.rssi - emitter.rssi
                    differences.add(abs(difference))
                    if (emitter.emitter.isIdentity) devices += 1 else ranks += 1
                    logLikelihood += weight * (-0.5 * (difference / sigma) * (difference / sigma) -
                        ln(sigma * sqrt(2 * PI) / 60))
                } else {
                    logLikelihood += weight * ln((if (emitter.rssi >= options.strongRSSI) options.missStrong else options.missWeak) / 0.9)
                }
            }
            for (heard in live) {
                if (!(heard.rssi >= options.strongRSSI && !referenceKeys.contains(heard.emitter) &&
                        (!portableOnly || heard.emitter.isPortable))
                ) continue
                logLikelihood += (if (heard.emitter.isIdentity) 1.0 else options.classWeight) * ln(0.5)
            }
            val enough = max(devices, ranks) >= options.minCommon && devices >= options.minCommonDevices
            scored.add(
                Scored(
                    spot, if (enough) logLikelihood else Double.NEGATIVE_INFINITY, devices, ranks,
                    if (differences.isEmpty()) null else AmbientRecorder.median(differences),
                ),
            )
        }

        val elsewhereLog = ln(options.elsewhereWeight)
        val top = max(elsewhereLog, scored.maxOfOrNull { it.logLikelihood } ?: elsewhereLog)
        val total = exp(elsewhereLog - top) + scored.fold(0.0) { s, it -> s + exp(it.logLikelihood - top) }
        val elsewhere = exp(elsewhereLog - top) / total
        val ranked = scored.map { item ->
            FingerprintMatch.Candidate(
                fingerprintId = item.spot.id, label = item.spot.label, x = item.spot.x, z = item.spot.z,
                posterior = if (item.logLikelihood.isFinite()) exp(item.logLikelihood - top) / total else 0.0,
                commonDevices = item.devices, commonClassRanks = item.ranks,
                rssiDifference = item.difference,
            )
        }.sortedWith { l, r ->
            // Swift: (posterior, common, other id) > (other posterior, other common, own id).
            when {
                l.posterior != r.posterior -> r.posterior.compareTo(l.posterior)
                l.commonDevices + l.commonClassRanks != r.commonDevices + r.commonClassRanks ->
                    (r.commonDevices + r.commonClassRanks).compareTo(l.commonDevices + l.commonClassRanks)
                else -> l.fingerprintId.compareTo(r.fingerprintId)
            }
        }
        val shown = ranked.take(3)

        val best = ranked.firstOrNull()
        if (best == null || !(best.posterior > 0)) {
            val most = ranked.maxOfOrNull { max(it.commonDevices, it.commonClassRanks) } ?: 0
            return insufficient(
                FingerprintMatch.Reason.tooFewCommonEmitters, shown, elsewhere = elsewhere,
                detail = "at most $most of the recorded signals heard here",
            )
        }
        // Spots close together sound alike: their posteriors add up, and the radius covers them all.
        val cluster = ranked.filter { hypot(it.x - best.x, it.z - best.z) <= 2 * options.spotRadius && it.posterior > 0 }
        val confidence = cluster.fold(0.0) { s, it -> s + it.posterior }
        if (!(confidence >= options.minConfidence)) {
            val rival = ranked.firstOrNull { hypot(it.x - best.x, it.z - best.z) > 2 * options.spotRadius && it.posterior >= 0.2 }
            if (rival != null) {
                return insufficient(
                    FingerprintMatch.Reason.ambiguous, shown, elsewhere = elsewhere,
                    detail = "sounds like \"${best.label}\" or \"${rival.label}\"",
                )
            }
            return insufficient(
                FingerprintMatch.Reason.weakMatch, shown, elsewhere = elsewhere,
                detail = "closest is \"${best.label}\" at ${swiftRounded(confidence * 100).toInt()} %",
            )
        }
        val x = cluster.fold(0.0) { s, it -> s + it.x * it.posterior } / confidence
        val z = cluster.fold(0.0) { s, it -> s + it.z * it.posterior } / confidence
        val spot = spots.first { it.id == best.fingerprintId }
        val reach = cluster.maxOfOrNull { hypot(it.x - x, it.z - z) } ?: 0.0
        val r95 = sqrt(options.spotRadius * options.spotRadius + spot.positionR95 * spot.positionR95) + reach
        return FingerprintMatch(
            verdict = FingerprintMatch.Verdict.match, reasons = emptyList(), candidates = shown, elsewhere = elsewhere,
            x = x, z = z, r95 = r95, confidence = confidence, positionSource = spot.positionSource, devicesHeard = devicesHeard,
            summary = "Sounds like \"${best.label}\" (±${swiftRounded(r95).toInt()} m, ${swiftRounded(confidence * 100).toInt()} %)",
        )
    }
}
