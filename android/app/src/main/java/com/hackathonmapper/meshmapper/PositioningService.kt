package com.hackathonmapper.meshmapper

import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.MeshJson
import com.hackathonmapper.meshcore.MotionObservation
import com.hackathonmapper.meshcore.PeerObservation
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.Positioning
import com.hackathonmapper.meshcore.Provenance
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.currentTime
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * This phone's positioning engine and everything that feeds it: its own GNSS (used only while the
 * integrity check trusts it), device motion, Bluetooth snapshots and the positions other phones
 * relay. `tick()` returns the contract `PositionEstimate` once a second. It can also record every
 * input as JSON lines so a field walk can be replayed through the same engine (`Positioning.Replay`).
 *
 * Integration (GhostCoreHub / pipeline): create one per app run, call `start()`, forward inputs as
 * they arrive, call `tick()` from the one-second loop, and `withdraw(anchor, reason)` when a
 * phone's integrity drops. Times from other phones are never compared with ours: relayed records
 * are timed by receipt minus their `freshness.ageAtHandoff`.
 *
 * Android: the engine clock is `elapsedRealtime` (seconds since boot including sleep), which is
 * what sensor event timestamps use, as iOS uses Core Motion's uptime. Recordings go to the app's
 * external files folder (`Android/data/<package>/files`, reachable over USB) instead of Documents.
 * Main thread only.
 */
class PositioningService(
    context: Context,
    val selfId: String,
    val frameId: String = GeoFrame.defaultFrameId,
) {
    var estimate: Positioning.Estimate? by mutableStateOf(null)
        private set
    var record: PositionEstimate? by mutableStateOf(null)
        private set
    /** The current or last recording (Swift: a file URL in Documents). */
    var recordingURL: File? by mutableStateOf(null)
        private set
    var calibration: Positioning.CalibrationSession? by mutableStateOf(null)
        private set
    /** "Simulate losing GPS": fixes are kept from the engine (and recorded as reference only). */
    var gnssHidden: Boolean by mutableStateOf(false)

    private val appContext = context.applicationContext
    val motion = MotionSource(appContext)

    private var engine = Positioning.Engine(selfId, frameId)
    private var anchorProvenance = HashMap<String, Provenance>()
    private var recorder: FileOutputStream? = null

    companion object {
        /** This phone's monotonic clock (the sensors'), which the engine runs on. */
        val now: TimeInterval get() = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0

        /** A wall-clock time (Unix seconds) from this phone converted to its monotonic clock. */
        fun monotonic(date: Double): TimeInterval = now - (currentTime() - date)

        /** This phone's two clocks right now (Swift `Positioning.Clock.now()` with Core Motion's uptime). */
        private fun clock(): Positioning.Clock = Positioning.Clock(currentTime() - now)

        /** Swift reads the hardware identifier (e.g. `iPhone15,2`); Android has no such code. */
        val hardwareModel: String
            get() = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

        private val stampFormat: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss'Z'", Locale.US).withZone(ZoneOffset.UTC)
        private val isoFormat: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT

        /** Keys sorted at every level, like Swift's `JSONEncoder` with `.sortedKeys`. */
        private fun sortKeys(element: JsonElement): JsonElement = when (element) {
            is JsonObject -> JsonObject(element.mapValues { sortKeys(it.value) }.toSortedMap())
            is JsonArray -> JsonArray(element.map { sortKeys(it) })
            else -> element
        }
    }

    /**
     * Feature switches: accelerometer + gyroscope (dead reckoning) and magnetometer heading. With both
     * off the sensors stop entirely; the engine then places this phone from GPS and Bluetooth alone.
     */
    var useMotion: Boolean = true
        set(value) {
            val changed = value != field
            field = value
            if (changed) updateSensors()
        }
    var useCompass: Boolean = true
        set(value) {
            val changed = value != field
            field = value
            if (changed) updateSensors()
        }
    private var started = false

    fun start() {
        motion.onMotion = { sample ->
            if (useMotion) {
                engine.ingest(sample)
                write(Positioning.LogRecord.motion(sample))
            }
        }
        motion.onCompass = { sample ->
            if (useCompass) {
                engine.ingest(sample)
                write(Positioning.LogRecord.compass(sample))
            }
        }
        started = true
        updateSensors()
    }

    private fun updateSensors() {
        if (!started) return
        if (useMotion || useCompass) motion.start() else motion.stop()
    }

    fun stop() {
        started = false
        motion.stop()
        stopRecording()
    }

    /** Starts over, e.g. when the frame changes. */
    fun reset() {
        engine = Positioning.Engine(selfId, frameId)
        anchorProvenance = HashMap()
        estimate = null
        record = null
    }

    // MARK: Inputs

    /**
     * This phone's own fix; `trusted` is its IntegrityAssessment's verdict (`status == trusted`).
     * `LocationFix` carries no course or speed (LocationSource keeps only what MeshModel reads), so
     * they go in as unknown (nil), like an iPhone fix with a negative `course` and `speed`.
     */
    fun ingest(location: LocationFix, trusted: Boolean) {
        val t = monotonic(location.timestamp)
        val fix = Positioning.GNSSFix.make(
            frameId = frameId, t = t, latitude = location.coordinate.latitude, longitude = location.coordinate.longitude,
            horizontalAccuracy = location.horizontalAccuracy, courseDegrees = null,
            courseAccuracyDegrees = null, speed = null, trusted = trusted,
        ) ?: return
        if (gnssHidden) {
            // Kept from the engine; good fixes stay in the recording as the reference for replay.
            if (fix.horizontalAccuracy <= 10) write(Positioning.LogRecord.truth(fix.position, t))
            return
        }
        engine.ingest(fix)
        write(Positioning.LogRecord.gnss(fix))
    }

    fun ingest(observation: PeerObservation, receivedAt: Double = currentTime()) {
        val samples = Positioning.ContractMapping.rssiSamples(observation, selfId, monotonic(receivedAt), clock())
        for (s in samples) {
            engine.ingest(s)
            // CalibrationSession is a Swift struct mutated in place; record into a copy and publish it.
            calibration?.let { session -> calibration = session.copy().also { it.record(s) } }
            write(Positioning.LogRecord.rssi(s))
        }
    }

    /**
     * Another phone's relayed position with its own GNSS assessment (if it sent one). Returns why it
     * was refused as an anchor, or null when it was used. Swift: `ingest(relayed:integrity:receivedAt:)`.
     */
    fun ingest(relayed: PositionEstimate, integrity: IntegrityAssessment?, receivedAt: Double = currentTime()): String? {
        val position = relayed
        return when (val decision = Positioning.ContractMapping.anchor(position, integrity, selfId, monotonic(receivedAt))) {
            is Positioning.ContractMapping.AnchorDecision.anchor -> {
                val a = decision.value
                engine.ingest(a)
                anchorProvenance[a.id] = position.provenance
                write(Positioning.LogRecord.anchor(a))
                null
            }
            is Positioning.ContractMapping.AnchorDecision.refused -> {
                // A phone that was anchoring us and stopped qualifying leaves at once.
                if (anchorProvenance[position.subjectId] != null) withdraw(position.subjectId, decision.value)
                decision.value
            }
        }
    }

    /** Swift: `withdraw(anchor:reason:)`. */
    fun withdraw(anchor: String, reason: String) {
        val t = now
        engine.removeAnchor(anchor, t, reason)
        anchorProvenance.remove(anchor)
        write(Positioning.LogRecord.removeAnchor(anchor, t))
    }

    /** "I am here": a pinned spot or a marked start point. */
    fun declare(point: Positioning.Vec2, sigma: Double) {
        val t = now
        engine.declare(point, sigma, t)
        write(Positioning.LogRecord.declared(point, sigma, t))
    }

    /** Swift: `setModel(_:for:)`. */
    fun setModel(model: Positioning.PathLossModel, channel: Positioning.RSSIChannel) {
        engine.setModel(model, channel)
    }

    // MARK: Output

    /** The estimate for now, as a contract record. Call once a second. */
    fun tick(simulated: Boolean = false): PositionEstimate {
        val e = engine.estimate(now)
        val upstream = e.anchorIds.mapNotNull { anchorProvenance[it] }
        val r = Positioning.ContractMapping.positionEstimate(e, selfId, clock(), upstream, simulated)
        estimate = e
        record = r
        return r
    }

    fun motionObservation(window: TimeInterval = 1.0): MotionObservation =
        Positioning.ContractMapping.motionObservation(engine.motionSummary(now, window), selfId, frameId, clock())

    // MARK: Calibration (ARCHITECTURE.md T2: 2, 5, 10, 20 m)

    fun beginCalibration(peerId: String, channel: Positioning.RSSIChannel, peerModel: String, environment: String) {
        calibration = Positioning.CalibrationSession(peerId, channel, hardwareModel, peerModel, environment)
    }

    fun calibrationStep(distance: Double?, label: String = "") {
        val session = calibration ?: return
        calibration = session.copy().also { if (distance != null) it.begin(distance, label) else it.end() }
    }

    /** Fits and, if `apply`, uses the model for that channel from now on. Throws `Positioning.CalibrationError`. */
    fun finishCalibration(apply: Boolean): Positioning.CalibrationResult? {
        val session = calibration ?: return null
        val result = session.fit(4.0, isoFormat.format(Instant.now()))
        if (apply) setModel(result.model, session.channel)
        return result
    }

    fun cancelCalibration() {
        calibration = null
    }

    // MARK: Recording

    fun startRecording() {
        stopRecording()
        val folder = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        folder.mkdirs()
        val stamp = stampFormat.format(Instant.now())
        val file = File(folder, "positioning-$selfId-$stamp.jsonl")
        recorder = FileOutputStream(file)
        recordingURL = file
        write(Positioning.LogRecord.header(selfId, frameId, "$hardwareModel $stamp"))
    }

    fun stopRecording() {
        try {
            recorder?.close()
        } catch (_: Exception) {
        }
        recorder = null
    }

    private fun write(record: Positioning.LogRecord) {
        val recorder = recorder ?: return
        try {
            val json = sortKeys(MeshJson.encodeToJsonElement(Positioning.LogRecord.serializer(), record)).toString()
            recorder.write((json + "\n").toByteArray(Charsets.UTF_8))
        } catch (_: Exception) {
        }
    }
}
