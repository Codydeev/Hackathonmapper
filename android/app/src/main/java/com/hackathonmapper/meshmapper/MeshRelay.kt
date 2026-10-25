package com.hackathonmapper.meshmapper

import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.BeaconPayload
import com.hackathonmapper.meshcore.BeaconStats
import com.hackathonmapper.meshcore.Frame
import com.hackathonmapper.meshcore.FrameType
import com.hackathonmapper.meshcore.MeshProtocol
import com.hackathonmapper.meshcore.ReceivedRecord
import com.hackathonmapper.meshcore.RecordAction
import com.hackathonmapper.meshcore.RecordRelay
import com.hackathonmapper.meshcore.RecordRelayStatistics
import com.hackathonmapper.meshcore.RelayAction
import com.hackathonmapper.meshcore.RelayDelivery
import com.hackathonmapper.meshcore.RelayEngine
import com.hackathonmapper.meshcore.RelayEnvelope
import com.hackathonmapper.meshcore.RelayMessage
import com.hackathonmapper.meshcore.RelayReceiptInfo
import com.hackathonmapper.meshcore.RelayStatistics
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.currentTime
import com.hackathonmapper.meshcore.swiftRounded
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

/**
 * Messaging over the Bluetooth mesh. Drives `RelayEngine` (store-and-forward messages, frame
 * types 5 and 6) and `RecordRelay` (GhostCore contract records, frame type 7). `BluetoothMesh`
 * owns it and starts and stops it with the mesh. Main thread only, like `BluetoothMesh`.
 */
class MeshRelay(
    private val bluetooth: BluetoothMesh,
    private val log: MeshEventLog,
) {
    data class SentMessage(
        val envelope: RelayEnvelope,
        val sentAt: Double,
        val receipt: RelayDelivery? = null,
    ) {
        val id: String get() = envelope.messageId
    }

    data class ReceivedMessage(
        val delivery: RelayDelivery,
        /** This phone's wall clock on arrival, for reading only. */
        val arrivedAt: Double,
    ) {
        val id: String get() = delivery.envelope.messageId
    }

    companion object {
        const val maxListed = 200
        const val maxPendingRecords = 512

        /**
         * Seconds on a clock that keeps counting while the phone sleeps and never follows wall clock
         * changes (Swift: `CLOCK_MONOTONIC`; Android: `elapsedRealtime`). Ages and TTLs use it; wall
         * clocks on different phones are never compared.
         */
        fun monotonicNow(): TimeInterval = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0
    }

    var isRunning: Boolean by mutableStateOf(false)
        private set
    var selfId: String? by mutableStateOf(null)
        private set
    var sent: List<SentMessage> by mutableStateOf(emptyList())
        private set
    var received: List<ReceivedMessage> by mutableStateOf(emptyList())
        private set
    var statistics: RelayStatistics by mutableStateOf(RelayStatistics())
        private set
    var storedCount: Int by mutableStateOf(0)
        private set
    /** Ready neighbors that run the relay. */
    var relayNeighbors: List<String> by mutableStateOf(emptyList())
        private set
    /** Labels of phones seen in a Hello or as a message origin or relay; empty when unknown. */
    var knownPeers: Map<String, String> by mutableStateOf(emptyMap())
        private set
    var recordStatistics: RecordRelayStatistics by mutableStateOf(RecordRelayStatistics())
        private set
    /** Relays of the latest accepted record from each origin, oldest first. */
    var recordRoutes: Map<String, List<String>> by mutableStateOf(emptyMap())
        private set

    /** Every delivered message, receipts included, for modules that send their own kinds. */
    var onDelivery: ((RelayDelivery) -> Unit)? = null
    /** Every accepted contract record, as it arrives. `takeReceivedRecords()` returns them too. */
    var onRecord: ((ReceivedRecord) -> Unit)? = null

    /** Relay test T3: this phone's beacon run while sending, and what arrived from others' runs. */
    var beaconRun: String? by mutableStateOf(null)
        private set
    var beaconsSent: Int by mutableStateOf(0)
        private set
    var beaconStats: Map<String, BeaconStats> by mutableStateOf(emptyMap())
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var beaconTimer: Job? = null
    private var beaconHops = 2

    private var engine: RelayEngine? = null
    private var records: RecordRelay? = null
    private var pendingRecords = ArrayDeque<ReceivedRecord>()
    private var linked: Set<String> = emptySet()

    fun start(selfId: String) {
        engine = RelayEngine(selfId)
        records = RecordRelay(selfId)
        pendingRecords = ArrayDeque()
        recordRoutes = emptyMap()
        this.selfId = selfId
        isRunning = true
        linked = emptySet()
        sent = emptyList()
        received = emptyList()
        refresh()
    }

    fun stop() {
        stopBeacon()
        engine = null
        records = null
        pendingRecords = ArrayDeque()
        isRunning = false
        linked = emptySet()
        refresh()
    }

    // MARK: Transport events

    fun updateNeighbors(ready: Set<String>) {
        val engine = engine ?: return
        if (ready == linked) return
        val now = monotonicNow()
        for (neighbor in (linked - ready).sorted()) {
            engine.neighborLost(neighbor)
            records?.neighborLost(neighbor)
            log.note("relay", "neighbor gone ${name(neighbor)}")
        }
        for (neighbor in (ready - linked).sorted()) {
            bluetooth.neighbors.firstOrNull { it.deviceId == neighbor }?.label?.let { knownPeers = knownPeers + (neighbor to it) }
            learn(neighbor)
            perform(engine.neighborReady(neighbor, now))
            records?.let { perform(it.neighborReady(neighbor, now)) }
        }
        linked = ready.toSet()
        refresh()
    }

    fun receive(frame: Frame, from: String) {
        val neighbor = from
        if (frame.type == FrameType.record) {
            val records = records ?: return
            val invalid = records.statistics.invalid
            perform(records.receive(frame, neighbor, monotonicNow(), currentTime()))
            if (records.statistics.invalid > invalid) log.note("record", "invalid record from ${name(neighbor)}")
            refresh()
            return
        }
        val engine = engine ?: return
        val before = engine.statistics
        perform(engine.receive(frame, neighbor, monotonicNow()))
        val after = engine.statistics
        if (frame.type == FrameType.relayMessage) {
            if (after.duplicates > before.duplicates) log.note("relay", "duplicate from ${name(neighbor)} suppressed")
            if (after.loops > before.loops) log.note("relay", "looped copy from ${name(neighbor)} dropped")
            if (after.expired > before.expired) log.note("relay", "expired copy from ${name(neighbor)} dropped")
            if (after.invalid > before.invalid) log.note("relay", "invalid message from ${name(neighbor)}")
        }
        refresh()
    }

    fun tick() {
        records?.tick(monotonicNow())
        val engine = engine ?: return
        val expired = engine.statistics.expired
        perform(engine.tick(monotonicNow()))
        if (engine.statistics.expired > expired) {
            log.note("relay", "${engine.statistics.expired - expired} stored message(s) reached their TTL")
        }
        refresh()
    }

    // MARK: Sending

    /** Sends a message from this phone. Returns a readable error, or null on success. */
    fun send(kind: String = "text", body: String, to: String?, ttlMs: Int, hops: Int): String? {
        val engine = engine ?: return "Start the mesh first"
        return try {
            val (envelope, actions) = engine.originate(
                kind = kind, body = body, to = to, ttlMs = ttlMs, hops = hops,
                now = monotonicNow(), wallClock = currentTime(),
            )
            val isBeacon = kind == BeaconPayload.kind
            if (!isBeacon) sent = (listOf(SentMessage(envelope, currentTime())) + sent).take(maxListed)
            val copies = actions.count { it is RelayAction.send }
            log.note(
                if (isBeacon) "t3" else "relay",
                "sent ${envelope.messageId.uppercase()} $kind${if (isBeacon) " $body" else ""} to " +
                    "${to?.let { name(it) } ?: "everyone"}, TTL ${ttlMs / 1000} s, $hops hops, " +
                    "$copies neighbor(s) now",
            )
            perform(actions)
            refresh()
            null
        } catch (_: Exception) {
            "Message not sent: at most ${RelayEnvelope.maxBodyBytes} bytes, TTL up to ${RelayEnvelope.maxTTLMs / 60_000} min, 0–${RelayEnvelope.maxHops} hops"
        }
    }

    // MARK: Relay test T3

    /** Sends a numbered broadcast beacon every second until stopped (BLE_MESH_TEST_PROTOCOL.md, T3). */
    fun startBeacon(hops: Int) {
        stopBeacon()
        if (engine == null) return
        val run = UUID.randomUUID().toString().uppercase().take(8)
        beaconRun = run
        beaconsSent = 0
        beaconHops = hops
        log.note("t3", "beacon run $run started: 1 Hz, $hops hops, TTL 30 s")
        sendBeacon()
        beaconTimer = scope.launch {
            while (isActive) {
                delay(1_000)
                sendBeacon()
            }
        }
    }

    fun stopBeacon() {
        beaconTimer?.cancel()
        beaconTimer = null
        beaconRun?.let { log.note("t3", "beacon run $it stopped after $beaconsSent beacons") }
        beaconRun = null
    }

    fun resetBeaconStats() {
        beaconStats = emptyMap()
        log.note("t3", "received beacon statistics reset")
    }

    private fun sendBeacon() {
        val run = beaconRun ?: return
        if (send(BeaconPayload.kind, BeaconPayload(run, beaconsSent).body, null, 30_000, beaconHops) == null) {
            beaconsSent += 1
        }
    }

    // MARK: Contract records

    /**
     * Sends one of this phone's records (built by the pipeline: origin = this phone, empty path).
     * Returns a readable error, or null on success. Swift: `send(record:)`.
     */
    fun send(record: RelayMessage): String? {
        val message = record
        val records = records ?: return "Start the mesh first"
        return try {
            perform(records.publish(message, monotonicNow()))
            log.note(
                "record",
                "published ${RecordRelay.payloadType(message.payload)} ${message.messageId} " +
                    "epoch ${message.epochId} seq ${message.sequence} hops ${message.hopsRemaining}",
            )
            refresh()
            null
        } catch (error: Exception) {
            log.note("record", "not sent: ${RecordRelay.payloadType(message.payload)} seq ${message.sequence}: $error")
            "Record not sent: $error"
        }
    }

    /** Records accepted since the last call, oldest first: this phone's pipeline input. */
    fun takeReceivedRecords(): List<ReceivedRecord> {
        val result = pendingRecords.toList()
        pendingRecords.clear()
        return result
    }

    // MARK: Names

    fun name(deviceId: String): String {
        if (deviceId == selfId) return "this phone"
        val label = knownPeers[deviceId]
        if (!label.isNullOrEmpty()) return label
        return MeshEventLog.short(deviceId)
    }

    /** "Origin → relay → … → this phone" for a delivered copy. */
    fun route(envelope: RelayEnvelope): String =
        (listOf(envelope.originId) + envelope.path).joinToString(" → ") { name(it) } + " → this phone"

    // MARK: Internals

    // Both `perform` overloads erase to `perform(List)` on the JVM; the JVM name tells them apart.
    @JvmName("performRecords")
    private fun perform(actions: List<RecordAction>) {
        for (action in actions) {
            when (action) {
                is RecordAction.send -> {
                    val payload = try {
                        action.message.encoded()
                    } catch (_: Exception) {
                        continue
                    }
                    bluetooth.send(payload, FrameType.record, action.key, action.to, action.droppable)
                }
                is RecordAction.deliver -> {
                    val record = action.record
                    val message = record.message
                    log.note(
                        "record",
                        "received ${RecordRelay.payloadType(message.payload)} ${message.messageId} from ${message.originId} " +
                            "epoch ${message.epochId} seq ${message.sequence} path [${message.path.joinToString(",")}] " +
                            String.format(Locale.US, "ageAtHandoff %.3f", message.freshness.ageAtHandoff) +
                            " via ${name(record.fromNeighbor)}",
                    )
                    if (pendingRecords.size >= maxPendingRecords) pendingRecords.removeFirst()
                    pendingRecords.addLast(record)
                    learn(message.originId)
                    message.path.forEach { learn(it) }
                    recordRoutes = recordRoutes + (message.originId to message.path)
                    onRecord?.invoke(record)
                }
            }
        }
    }

    private fun perform(actions: List<RelayAction>) {
        for (action in actions) {
            when (action) {
                is RelayAction.send -> {
                    val payload = try {
                        action.envelope.encoded()
                    } catch (_: Exception) {
                        continue
                    }
                    // One outbox entry per message, so queued messages never replace each other.
                    bluetooth.send(payload, FrameType.relayMessage, "relay:" + action.envelope.messageId.uppercase(), action.to)
                }
                is RelayAction.sendSummary -> {
                    val payload = try {
                        action.summary.encoded()
                    } catch (_: Exception) {
                        continue
                    }
                    bluetooth.send(payload, FrameType.relaySummary, "relaySummary", action.to)
                }
                is RelayAction.deliver -> deliver(action.delivery)
            }
        }
    }

    private fun deliver(delivery: RelayDelivery) {
        val envelope = delivery.envelope
        learn(envelope.originId)
        envelope.path.forEach { learn(it) }
        val id = MeshEventLog.short(envelope.messageId.uppercase())
        val beacon = if (envelope.kind == BeaconPayload.kind) BeaconPayload.decode(envelope.body) else null
        if (envelope.isReceipt) {
            val confirmed = envelope.acknowledges
            val index = if (confirmed == null) -1 else sent.indexOfFirst { it.id.equals(confirmed, ignoreCase = true) }
            if (confirmed != null && index >= 0) {
                sent = sent.toMutableList().also { it[index] = it[index].copy(receipt = delivery) }
                val info = RelayReceiptInfo.decode(envelope.body)
                val delivered = info?.let { (listOf(selfId ?: "") + it.path).joinToString(" → ") { id -> name(id) } } ?: "?"
                log.note(
                    "relay",
                    "receipt: ${MeshEventLog.short(confirmed.uppercase())} reached ${name(envelope.originId)} " +
                        "via $delivered, age ≥ ${info?.ageMs ?: -1} ms; receipt came ${route(envelope)}, ${delivery.hops} hop(s)",
                )
            }
        } else if (beacon != null) {
            // BeaconStats is a Swift struct: record into a copy and store it.
            val stats = beaconStats[envelope.originId]?.takeIf { it.run == beacon.run }?.copy()
                ?: BeaconStats(envelope.originId, beacon.run)
            stats.record(envelope)
            beaconStats = beaconStats + (envelope.originId to stats)
            log.note(
                "t3",
                "received ${envelope.messageId.uppercase()} ${envelope.body} from ${envelope.originId} " +
                    "path [${envelope.path.joinToString(",")}] ageMs ${envelope.ageMs} via ${name(delivery.fromNeighbor)}",
            )
        } else {
            received = (listOf(ReceivedMessage(delivery, currentTime())) + received).take(maxListed)
            log.note(
                "relay",
                "received $id ${envelope.kind} ${route(envelope)}, ${delivery.hops} hop(s), " +
                    "age ≥ ${envelope.ageMs} ms, ${envelope.hopsRemaining} hops left, from ${name(delivery.fromNeighbor)}",
            )
        }
        onDelivery?.invoke(delivery)
    }

    private fun learn(deviceId: String) {
        if (deviceId == selfId || knownPeers[deviceId] != null) return
        knownPeers = knownPeers + (deviceId to "")
    }

    private fun refresh() {
        records?.let { if (recordStatistics != it.statistics) recordStatistics = it.statistics }
        val engine = engine
        if (engine == null) {
            if (relayNeighbors.isNotEmpty()) relayNeighbors = emptyList()
            return
        }
        if (statistics != engine.statistics) statistics = engine.statistics
        if (storedCount != engine.storedCount) storedCount = engine.storedCount
        val capable = linked.intersect(engine.relayCapable).sorted()
        if (relayNeighbors != capable) relayNeighbors = capable
    }
}

/**
 * Timestamped mesh events for hardware test evidence: wall clock for reading, monotonic seconds
 * for measuring intervals on one phone. Main thread only.
 *
 * Android: the export header names the platform (`"platform": "android"`, `"android"`: the OS
 * release) where Swift writes `"ios"`; `appVersion`/`build` come from the package (versionName,
 * versionCode). The other header fields and every event line match Swift, so
 * `tools/ble-mesh/t3_check.py` reads both.
 */
class MeshEventLog(
    private val appVersion: String = "",
    private val build: String = "",
    private val monotonic: () -> TimeInterval = { MeshRelay.monotonicNow() },
    private val wallClock: () -> Double = { currentTime() },
) {
    data class Entry(
        val id: Int,
        val wallClock: Double,
        val monotonic: TimeInterval,
        val category: String,
        val detail: String,
    )

    companion object {
        const val capacity = 10_000
        const val recentCount = 40

        fun short(id: String): String = id.take(8)

        private val iso8601: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).withZone(ZoneOffset.UTC)

        /** Swift's `ISO8601DateFormatter` with fractional seconds: `2026-10-25T12:34:56.789Z`. */
        fun iso8601(seconds: Double): String =
            iso8601.format(Instant.ofEpochMilli(swiftRounded(seconds * 1000).toLong()))

        private fun platformHeader(): Map<String, JsonElement> = try {
            mapOf(
                "model" to JsonPrimitive("${Build.MANUFACTURER} ${Build.MODEL}"),
                "android" to JsonPrimitive(Build.VERSION.RELEASE ?: ""),
            )
        } catch (_: RuntimeException) {
            // JVM unit tests: android.os.Build is not available.
            mapOf("model" to JsonPrimitive(""), "android" to JsonPrimitive(""))
        }
    }

    /** Every kept entry, oldest first. Not observable, so a long log isn't copied on each event. */
    private val kept = ArrayList<Entry>()
    val entries: List<Entry> get() = kept

    /** The newest `recentCount` entries, oldest first, for the screen. */
    var recent: List<Entry> by mutableStateOf(emptyList())
        private set
    private var nextId = 0

    fun note(category: String, detail: String) {
        nextId += 1
        val entry = Entry(nextId, wallClock(), monotonic(), category, detail)
        kept.add(entry)
        // Trim in batches so a full log doesn't shift the list on every event.
        if (kept.size > capacity + 500) kept.subList(0, kept.size - capacity).clear()
        recent = (recent + entry).takeLast(recentCount)
    }

    fun clear() {
        kept.clear()
        recent = emptyList()
    }

    /** JSON lines: a header describing this phone and build, then one object per event. Keys sorted, like Swift. */
    fun export(deviceId: String?, label: String?): String {
        val header: Map<String, JsonElement> = mapOf(
            "type" to JsonPrimitive("header"),
            "deviceId" to JsonPrimitive(deviceId ?: ""),
            "label" to JsonPrimitive(label ?: ""),
            "platform" to JsonPrimitive("android"),
            "appVersion" to JsonPrimitive(appVersion),
            "build" to JsonPrimitive(build),
            "wireVersion" to JsonPrimitive(MeshProtocol.version),
            "relaySchema" to JsonPrimitive(RelayEnvelope.schemaVersion),
            "exportedAt" to JsonPrimitive(iso8601(wallClock())),
            "monotonicAtExport" to JsonPrimitive(monotonic()),
        ) + platformHeader()
        val lines = listOf(header) + kept.map { entry ->
            mapOf(
                "t" to JsonPrimitive(iso8601(entry.wallClock)),
                "mono" to JsonPrimitive(swiftRounded(entry.monotonic * 1000) / 1000),
                "cat" to JsonPrimitive(entry.category),
                "event" to JsonPrimitive(entry.detail),
            )
        }
        return lines.joinToString("\n") { line -> JsonObject(line.toSortedMap()).toString() }
    }
}
