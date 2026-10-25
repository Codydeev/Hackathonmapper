@file:Suppress("EnumEntryName")

package com.hackathonmapper.meshmapper

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.hackathonmapper.meshcore.AnchorGeometry
import com.hackathonmapper.meshcore.AnchorLinkObservation
import com.hackathonmapper.meshcore.AnchorRange
import com.hackathonmapper.meshcore.AnchorSighting
import com.hackathonmapper.meshcore.DashboardContract
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.FrameType
import com.hackathonmapper.meshcore.FusionEngine
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.MeshCoreError
import com.hackathonmapper.meshcore.MeshPacket
import com.hackathonmapper.meshcore.MeshStore
import com.hackathonmapper.meshcore.MotionAwareRSSI
import com.hackathonmapper.meshcore.MotionSample
import com.hackathonmapper.meshcore.NeighborObservation
import com.hackathonmapper.meshcore.PathLossCalibration
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.RangeFix
import com.hackathonmapper.meshcore.RangingFix
import com.hackathonmapper.meshcore.RangingToken
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

enum class AppTab {
    track, start, network, position, gateway
}

enum class DeviceRole(val rawValue: String) {
    mobile("mobile"), anchor("anchor"), gateway("gateway");

    val id: String get() = rawValue

    companion object {
        fun fromRawValue(value: String?): DeviceRole? = entries.firstOrNull { it.rawValue == value }
    }
}

/** How this phone gets the position it publishes. */
enum class PositionChoice(val rawValue: String) {
    /** The phone's own GPS; without a usable fix it reports no position. */
    gps("gps"),

    /** Typed coordinates (a fixed spot, for indoor demos). */
    manual("manual"),

    /** Dead reckoning fused with RSSI to BLE anchors; GPS or no position until tracking starts. */
    fused("fused");

    val id: String get() = rawValue

    val title: String
        get() = when (this) {
            gps -> "GPS"
            manual -> "Fixed spot (manual)"
            fused -> "Motion + BLE anchors"
        }

    companion object {
        fun fromRawValue(value: String?): PositionChoice? = entries.firstOrNull { it.rawValue == value }
    }
}

/** SwiftUI's `ScenePhase`, fed from the activity lifecycle by MainActivity. */
enum class ScenePhase { active, inactive, background }

data class KnownDevice(
    val update: DeviceUpdate,
    val receivedAt: Double,
    /**
     * Phones that relayed the accepted copy, oldest first; empty if it came straight from the
     * origin, null for this phone's own reports.
     */
    val path: List<String>?,
) {
    val id: String get() = update.id
}

data class ReceivedFix(
    val fix: RangingFix,
    val receivedAt: Double,
)

data class MeshDiagnostics(
    val received: Int = 0,
    val accepted: Int = 0,
    val duplicate: Int = 0,
    val relayed: Int = 0,
    val rejected: Int = 0,
)

/** What the Position tab shows of the fusion engine; refreshed each second and on every step. */
data class FusionStatus(
    val tracking: Boolean = false,
    val x: Double? = null,
    val z: Double? = null,
    val accuracy: Double? = null,
    val headingDegrees: Double = 0.0,
    val headingOffsetDegrees: Double = 0.0,
    val steps: Int = 0,
    val walked: Double = 0.0,
    val walking: Boolean = false,
    val receiverOffsetDB: Double? = null,
    val ranges: List<AnchorRange> = emptyList(),
    val fix: RangeFix? = null,
    val calibration: PathLossCalibration = PathLossCalibration.uncalibrated,
    val accepted: Int = 0,
    val rejected: Int = 0,
    val recoveries: Int = 0,
)

/** The GPS fix as a position in this phone's frame (Swift: a `(position:accuracy:)` tuple). */
data class GpsPosition(val position: Position, val accuracy: Double)

/**
 * A `@Published var` with a `didSet`: Compose snapshot state that runs `didSet(old, new)` after
 * every assignment (on the main thread, like the Swift property observers).
 */
private class Observed<T>(initial: T, private val didSet: (old: T, new: T) -> Unit) : ReadWriteProperty<Any?, T> {
    private val state = mutableStateOf(initial)
    override fun getValue(thisRef: Any?, property: KProperty<*>): T = state.value
    override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
        val old = state.value
        state.value = value
        didSet(old, value)
    }
}

/** `UserDefaults.double(forKey:)` on SharedPreferences: doubles are stored as raw long bits. */
private fun SharedPreferences.getDouble(key: String): Double =
    if (contains(key)) {
        try {
            Double.fromBits(getLong(key, 0))
        } catch (e: ClassCastException) {
            0.0
        }
    } else {
        0.0
    }

private fun SharedPreferences.Editor.putDouble(key: String, value: Double): SharedPreferences.Editor =
    putLong(key, value.toRawBits())

class MeshModel(application: Application) : AndroidViewModel(application) {
    companion object {
        // Ingesting our own packet consumes one hop, so neighbors receive 4 remaining hops.
        const val originHops = 5

        /** Reports not refreshed within this time are no longer resent or uploaded. */
        const val staleAfter: Double = 30.0

        /** An anchor sends each neighbor at most this many UWB fixes per second. */
        const val fixesPerSecond = 2.0

        /** 95 % over 68 % radius of a 2-D Gaussian: sqrt(-2 ln 0.05) / sqrt(-2 ln 0.32). */
        const val gpsR95PerAccuracy = 1.62

        /** A short readable default name, stable for this phone ("Otter 42"). */
        fun friendlyName(id: String): String {
            val words = listOf("Otter", "Lynx", "Moose", "Hare", "Fox", "Owl", "Seal", "Wolf", "Elk", "Crane", "Pike", "Bear")
            var seed = 0L
            id.codePoints().forEach { seed = (seed * 31 + it) and 0x7fff_ffffL }
            val s = seed.toInt()
            return "${words[s % words.size]} ${10 + (s / words.size) % 90}"
        }

        /** Outbox key: a newer report from the same origin replaces one still queued on a link. */
        private fun positionKey(origin: String): String = "position:$origin"

        /** The motion clock (Core Motion's system uptime): seconds since boot, as SensorEvent timestamps. */
        private fun systemUptime(): Double = MotionTracker.uptime()
    }

    private val defaults: SharedPreferences = application.getSharedPreferences("meshmapper", Context.MODE_PRIVATE)

    val bluetooth = BluetoothMesh(application)
    val gateway = GatewayClient()
    val motion = MotionTracker(application)
    val uwb = UWBRanging()
    val location = LocationSource(application)
    val tracker = BluetoothTracker()
    val predictor = MovementPredictor(application)
    val deviceID: String
    val epochID: String = UUID.randomUUID().toString().uppercase()

    var serverURL: String by Observed(defaults.getString("serverURL", null) ?: "http://192.168.1.20:3000") { _, new ->
        defaults.edit().putString("serverURL", new).apply()
    }

    // Only the internet (Cloudflare tunnel) endpoint needs it; a LAN URL works without one.
    var gatewayToken: String by Observed(defaults.getString("gatewayToken", null) ?: "") { _, new ->
        defaults.edit().putString("gatewayToken", new).apply()
    }
    var selectedTab: AppTab by mutableStateOf(AppTab.track)
    var frameID: String by Observed(defaults.getString("frameID", null) ?: GeoFrame.defaultFrameId) { _, new ->
        defaults.edit().putString("frameID", new).apply()
    }

    private var labelState by mutableStateOf("")
    var label: String
        get() = labelState
        set(value) {
            labelState = if (value.length > DashboardContract.maxLabelLength) DashboardContract.truncatedLabel(value) else value
            defaults.edit().putString("deviceLabel", labelState).apply()
        }

    var role: DeviceRole by Observed(DeviceRole.fromRawValue(defaults.getString("role", null)) ?: DeviceRole.mobile) { old, new ->
        defaults.edit().putString("role", new.rawValue).apply()
        // Anchor and target do different UWB work; turn it on again for the new role.
        if (uwbEnabled && new != old) setUWB(false)
    }

    /** Direction the back of the mounted anchor faces, in degrees from map +z towards map +x. */
    var anchorHeading: Double by Observed(defaults.getDouble("anchorHeading")) { _, new ->
        defaults.edit().putDouble("anchorHeading", new).apply()
    }

    /** Off by default and after every launch: UWB is optional, not on the mesh's critical path. */
    var uwbEnabled: Boolean by mutableStateOf(false)
        private set

    /** Latest UWB fix from each direction anchor, by anchor device ID. */
    var rangingFixes: Map<String, ReceivedFix> by mutableStateOf(emptyMap())
        private set
    var manualX: Double by Observed(defaults.getDouble("manualX")) { _, new -> defaults.edit().putDouble("manualX", new).apply() }
    var manualY: Double by Observed(defaults.getDouble("manualY")) { _, new -> defaults.edit().putDouble("manualY", new).apply() }
    var manualZ: Double by Observed(defaults.getDouble("manualZ")) { _, new -> defaults.edit().putDouble("manualZ", new).apply() }
    var fusionStatus: FusionStatus by mutableStateOf(FusionStatus())
        private set
    var positionMode: String by mutableStateOf("floor")
    var accuracyKnown: Boolean by mutableStateOf(false)
    var accuracyMeters: Double by mutableStateOf(1.0)
    var keepAwake: Boolean by Observed(defaults.getBoolean("keepAwake", true)) { _, new ->
        defaults.edit().putBoolean("keepAwake", new).apply()
        updateIdleTimer()
    }
    var positionChoice: PositionChoice by Observed(
        PositionChoice.fromRawValue(defaults.getString("positionChoice", null)) ?: PositionChoice.gps,
    ) { _, new -> defaults.edit().putString("positionChoice", new.rawValue).apply() }

    /** Demo switch: publish as if GPS were lost, so the dashboard places this phone from Bluetooth. */
    var simulateGPSLoss: Boolean by Observed(defaults.getBoolean("simulateGPSLoss", false)) { _, new ->
        defaults.edit().putBoolean("simulateGPSLoss", new).apply()
    }

    /** The settings sheet (the detailed tabs) on top of the map. */
    var showingSettings: Boolean by mutableStateOf(false)

    /** Source of the last report this phone published. */
    var lastSource: PositionSource? by mutableStateOf(null)
        private set
    var devices: List<KnownDevice> by mutableStateOf(emptyList())
        private set
    var diagnostics: MeshDiagnostics by mutableStateOf(MeshDiagnostics())
        private set
    var isRunning: Boolean by mutableStateOf(false)
        private set
    var isPublishing: Boolean by mutableStateOf(false)
        private set
    var lastSequence: Long? by mutableStateOf(null)
        private set
    var lastError: String? by mutableStateOf(null)
        private set

    /** Direct BLE neighbors by app device ID, as included in this phone's last report. */
    var directNeighbors: List<NeighborObservation> by mutableStateOf(emptyList())
        private set

    /**
     * `UIApplication.isIdleTimerDisabled`: MainActivity keeps the screen on
     * (FLAG_KEEP_SCREEN_ON) while this is true.
     */
    var isIdleTimerDisabled: Boolean by mutableStateOf(false)
        private set

    /**
     * Android only: why the mesh cannot start (a runtime permission was denied), shown where iOS
     * shows Bluetooth and location authorization. Set by MainActivity.
     */
    var permissionProblem: String? by mutableStateOf(null)

    /** Android only: asks MainActivity to request the runtime permissions again (or open app settings). */
    var onRequestPermissions: (() -> Unit)? = null

    private var sequence = 0L
    private var ticks = 0

    /** Relay path of each accepted report from another phone. */
    private val paths = mutableMapOf<String, List<String>>()

    /** Neighbors whose ranging token said they are direction anchors. */
    private val anchorNeighbors = mutableSetOf<String>()
    private val lastFixSent = mutableMapOf<String, Double>()
    private val store: MeshStore
    private var timer: Job? = null
    private var fusion = FusionEngine()

    /** Barometric altitude when tracking started; height changes are measured from it. */
    private var altitudeBaseline: Double? = null
    private var launched = false

    /** A `meshmapper://gateway` link that arrived before launch(). */
    private var pendingLink: String? = null

    val positions: List<DeviceUpdate> get() = store.latest.values.sortedBy { it.id }
    private val freshPositions: List<DeviceUpdate> get() = positions.filter { store.isFresh(it.id, staleAfter) }

    init {
        val id = defaults.getString("deviceID", null) ?: UUID.randomUUID().toString().uppercase()
        defaults.edit().putString("deviceID", id).apply()
        deviceID = id
        labelState = DashboardContract.truncatedLabel(defaults.getString("deviceLabel", null) ?: friendlyName(id))
        store = MeshStore(frameID, id)
        bluetooth.onPacket = { data, neighbor -> receive(data, neighbor) }
        bluetooth.onNeighborReady = { neighbor -> sync(neighbor) }
        bluetooth.onRanging = { type, data, neighbor -> receiveRanging(type, data, neighbor) }
        uwb.sendToken = { token, neighbor -> sendRangingToken(token, neighbor) }
        uwb.onMeasurement = { neighbor, measurement -> measured(neighbor, measurement) }
        motion.onSample = { sample -> handleMotion(sample) }
    }

    /**
     * App launch: start GPS, and bring back the mesh (on by default) and the gateway (if it was on)
     * so a phone needs no taps after the first setup. MainActivity calls it once the runtime
     * permissions are granted; later calls do nothing.
     */
    fun launch() {
        if (launched) return
        launched = true
        location.start()
        if (defaults.getBoolean("meshRunning", true)) {
            start()
            if (defaults.getBoolean("gatewayWanted", false)) setGateway(true)
        }
        // A QR link that opened the app is applied last, so starting the mesh (which resets the
        // gateway) neither cancels its connection check nor uploads to the scanned URL.
        applyPendingConnectLink()
    }

    fun start() {
        if (isRunning) return
        val frame = frameID.trim()
        if (!Regex("^[A-Za-z0-9._-]{1,64}$").matches(frame)) {
            lastError = "Frame ID must be 1–64 letters, digits, '.', '_' or '-'"
            return
        }
        if (frame != frameID) frameID = frame
        store.reset(frameID)
        tracker.reset()
        predictor.reset()
        paths.clear()
        directNeighbors = emptyList()
        devices = emptyList()
        diagnostics = MeshDiagnostics()
        gateway.reset()
        isRunning = true
        val trimmed = label.trim()
        bluetooth.start(MeshIdentity(deviceID, if (trimmed.isEmpty()) null else trimmed, frameID))
        // A new session may use another frame: calibration and tracking start over.
        fusion = FusionEngine()
        altitudeBaseline = null
        motion.start()
        refreshFusionStatus()
        lastError = null
        ticks = 0
        updateIdleTimer()
        timer?.cancel()
        timer = viewModelScope.launch {
            while (isActive) {
                delay(1000)
                tick()
            }
        }
        defaults.edit().putBoolean("meshRunning", true).apply()
        // Publishing is what puts this phone (and its Bluetooth links) on the map, so it starts too.
        setPublishing(true)
    }

    fun stop() {
        setUWB(false)
        isRunning = false
        isPublishing = false
        timer?.cancel()
        timer = null
        bluetooth.stop()
        gateway.stop()
        motion.stop()
        fusion.stop()
        refreshFusionStatus()
        updateIdleTimer()
        defaults.edit().putBoolean("meshRunning", false).apply()
    }

    fun setGateway(enabled: Boolean) {
        defaults.edit().putBoolean("gatewayWanted", enabled).apply()
        if (!enabled) {
            gateway.stop(); return
        }
        if (!isRunning) {
            lastError = "Start the mesh before enabling the gateway"; return
        }
        if (usesTunnelURL && gatewayToken.trim().isEmpty()) {
            lastError = "Internet URLs need the gateway token printed by `npm run tunnel`"
            return
        }
        gateway.enqueue(freshPositions)
        gateway.start(serverURL, deviceID, frameID, gatewayToken)
    }

    fun checkGatewayConnection() {
        gateway.checkConnection(serverURL, gatewayToken)
    }

    /**
     * Opens `meshmapper://gateway?url=…&token=…` from the dashboard's QR code: fills in the
     * gateway settings, shows the Gateway tab and checks the connection. It never starts uploading.
     */
    fun applyConnectLink(link: Uri) = applyConnectLink(link.toString())

    fun applyConnectLink(link: String) {
        // On a cold start the link arrives before launch(); it waits for it (see launch()).
        if (!launched) {
            pendingLink = link
            return
        }
        openConnectLink(link)
    }

    /**
     * Applies a link that arrived before launch(). MainActivity also calls it when the mesh cannot
     * start (permissions denied), so the scanned settings are still filled in.
     */
    fun applyPendingConnectLink() {
        val link = pendingLink ?: return
        pendingLink = null
        openConnectLink(link)
    }

    private fun openConnectLink(link: String) {
        val parsed = ConnectLink.parse(link)
        if (parsed == null) {
            lastError = "That QR code is not a MeshMapper gateway link"
            return
        }
        // Stops uploading and forgets that the gateway was on, so the scanned URL is never
        // uploaded to until the user turns uploading on (also after a relaunch).
        setGateway(false)
        serverURL = parsed.server
        gatewayToken = parsed.token
        lastError = null
        selectedTab = AppTab.gateway
        showingSettings = true
        checkGatewayConnection()
    }

    /** Cloudflare quick-tunnel URLs always need the token; a custom tunnel hostname may too. */
    val usesTunnelURL: Boolean
        get() = ConnectLink.host(GatewayClient.normalizedOrigin(serverURL))?.lowercase()?.endsWith(".trycloudflare.com") == true

    @JvmName("setPublishingEnabled") // `isPublishing`'s private setter is already setPublishing on the JVM.
    fun setPublishing(enabled: Boolean) {
        if (!enabled) {
            isPublishing = false; return
        }
        if (!isRunning) {
            lastError = "Start the mesh before publishing"; return
        }
        isPublishing = true
        publishCurrent()
    }

    fun scenePhaseChanged(phase: ScenePhase) {
        // Connections are not assumed to survive backgrounding; rescan and re-advertise.
        if (phase == ScenePhase.active && isRunning) bluetooth.resume()
        updateIdleTimer()
    }

    // Solver integration point: coordinates must already be in the selected shared frame.
    fun publish(position: Position, mode: String, accuracyMeters: Double? = null, source: PositionSource = PositionSource.manual) {
        if (!isRunning) {
            lastError = "Start the mesh before publishing"; return
        }
        if (!listOf(position.x, position.y, position.z).all { abs(it) <= DashboardContract.maxCoordinate }) {
            lastError = "Coordinates must be within ±${DashboardContract.maxCoordinate.toInt()} m"
            isPublishing = false
            return
        }
        if (accuracyMeters != null && accuracyMeters !in 0.0..DashboardContract.maxAccuracyMeters) {
            lastError = "Accuracy must be between 0 and ${DashboardContract.maxAccuracyMeters.toInt()} m"
            isPublishing = false
            return
        }
        val nextSequence = sequence + 1
        val trimmed = label.trim()
        val neighbors = bluetooth.neighborObservations()
        directNeighbors = neighbors
        val update = DeviceUpdate(
            id = deviceID, label = if (trimmed.isEmpty()) null else trimmed, epochId = epochID,
            sequence = nextSequence, role = role.rawValue, position = position,
            positionMode = mode, accuracyMeters = accuracyMeters, neighbors = neighbors,
            positionSource = source,
        )
        try {
            val packet = MeshPacket(frameID, originHops, update)
            accept(packet, null)
            sequence = nextSequence
            lastSequence = nextSequence
            lastSource = source
            lastError = null
        } catch (error: Exception) {
            lastError = describe(error)
            isPublishing = false
        }
    }

    private fun publishManual() {
        val floor = positionMode == "floor"
        publish(
            Position(manualX, if (floor) 0.0 else manualY, manualZ),
            positionMode, if (accuracyKnown) accuracyMeters else null, PositionSource.manual,
        )
    }

    /**
     * The GPS fix as a position in this phone's frame, if there is a usable one and GPS is not
     * being simulated as lost.
     */
    val gpsPosition: GpsPosition?
        get() {
            if (simulateGPSLoss) return null
            val fix = location.usableFix() ?: return null
            val position = GeoFrame.position(frameID, fix.coordinate.latitude, fix.coordinate.longitude) ?: return null
            // Android's accuracy, like Core Location's, is a ~68 % radius; the wire carries a 95 % radius.
            return GpsPosition(position, min(fix.horizontalAccuracy * gpsR95PerAccuracy, DashboardContract.maxAccuracyMeters))
        }

    /**
     * With UWB on, a target publishes fresh UWB fixes and otherwise GPS or no position, never the
     * manual coordinates: those are not measured. The fused estimate is published only while
     * tracking (started from a known point or an RSSI fix), so no position is invented.
     */
    private fun publishCurrent() {
        val usesUWB = uwbEnabled && role != DeviceRole.anchor
        val fix = currentFix?.fix
        if (usesUWB && fix != null) {
            val floor = positionMode == "floor"
            publish(
                Position(fix.position.x, if (floor) 0.0 else fix.position.y, fix.position.z),
                positionMode, fix.accuracyMeters, PositionSource.uwb,
            )
            return
        }
        if (positionChoice == PositionChoice.manual && !usesUWB) {
            publishManual(); return
        }
        val filter = fusion.filter
        if (positionChoice == PositionChoice.fused && filter != null) {
            val floor = positionMode == "floor"
            publish(
                Position(filter.x, if (floor) 0.0 else trackedHeight, filter.z), positionMode,
                min(filter.r95, DashboardContract.maxAccuracyMeters), PositionSource.fused,
            )
            return
        }
        val gps = gpsPosition
        if (gps != null) {
            publish(gps.position, "floor", gps.accuracy, PositionSource.gps)
        } else {
            // Placeholder only: `none` tells the dashboard to place this phone from its Bluetooth links.
            publish(Position(0.0, 0.0, 0.0), "floor", null, PositionSource.none)
        }
    }

    /** Indoors GPS is often too poor to anchor anyone: pin this phone at a spot tapped on the map. */
    fun pinHere(latitude: Double, longitude: Double) {
        val position = GeoFrame.position(frameID, latitude, longitude)
        if (position == null) {
            lastError = "This frame has no map origin; use ${GeoFrame.defaultFrameId}"
            return
        }
        pinHere(position)
    }

    /**
     * Android: the map is drawn in frame coordinates, so the tapped spot is already a frame
     * position (Swift converts the tapped coordinate with `GeoFrame.position`).
     */
    fun pinHere(position: Position) {
        manualX = position.x
        manualY = 0.0
        manualZ = position.z
        positionMode = "floor"
        accuracyKnown = true
        accuracyMeters = 5.0
        positionChoice = PositionChoice.manual
        if (isPublishing) publishCurrent()
    }

    fun unpin() {
        positionChoice = PositionChoice.gps
        if (isPublishing) publishCurrent()
    }

    // MARK: Motion + BLE anchor tracking

    /** Anchors known through the mesh, other than this phone. */
    val anchors: List<DeviceUpdate>
        get() = positions.filter { it.role == DeviceRole.anchor.rawValue && it.id != deviceID }

    /** Starts at the manual coordinates; the user faces +z (frame forward) while tapping. */
    fun startTracking() {
        if (!isRunning) {
            lastError = "Start the mesh before tracking"; return
        }
        if (!motion.isMotionAvailable) {
            lastError = "This device has no motion sensors"; return
        }
        fusion.start(manualX, manualZ, 0.0)
        altitudeBaseline = motion.relativeAltitude
        lastError = null
        refreshFusionStatus()
    }

    /** Starts at the RSSI-only fix, which needs three or more anchors; the user faces +z. */
    fun startTrackingFromFix() {
        if (!isRunning) {
            lastError = "Start the mesh before tracking"; return
        }
        if (!fusion.startFromFix(0.0)) {
            lastError = "No RSSI fix yet: link to three or more anchors"; return
        }
        altitudeBaseline = motion.relativeAltitude
        lastError = null
        refreshFusionStatus()
    }

    /** The user faces +z again; resets gyro heading drift. */
    fun alignHeading() {
        fusion.alignHeading(0.0)
        refreshFusionStatus()
    }

    fun stopTracking() {
        fusion.stop()
        refreshFusionStatus()
    }

    /** The user stands next to an anchor: a strong position correction, not a reset. */
    fun markNear(anchor: String) {
        val update = store.latest[anchor] ?: return
        if (update.role != DeviceRole.anchor.rawValue) return
        fusion.observePosition(update.position.x, update.position.z, 1.0)
        refreshFusionStatus()
    }

    /** Start height plus the barometric change since tracking started. */
    private val trackedHeight: Double
        get() {
            val altitude = motion.relativeAltitude ?: return manualY
            val baseline = altitudeBaseline ?: return manualY
            return manualY + altitude - baseline
        }

    private fun handleMotion(sample: MotionSample) {
        if (fusion.process(sample) != null) refreshFusionStatus()
    }

    private fun updateFusion() {
        val uptime = systemUptime()
        if (ticks % 5 == 0) fusion.setCalibration(PathLossCalibration.fit(anchorLinks()))
        fusion.ownHeight = if (positionMode == "floor") 0.0 else trackedHeight
        fusion.update(anchorSightings(uptime), uptime)
        refreshFusionStatus()
    }

    /** The latest raw RSSI of each linked anchor, timed on the motion clock (system uptime). */
    private fun anchorSightings(uptime: Double): List<AnchorSighting> {
        val now = currentTime()
        return bluetooth.neighbors.mapNotNull { neighbor ->
            val anchor = store.latest[neighbor.deviceId] ?: return@mapNotNull null
            if (anchor.role != DeviceRole.anchor.rawValue || !store.isFresh(anchor.id, staleAfter)) return@mapNotNull null
            // Connection RSSI (1 Hz, links this phone opened) when current, else advertisements.
            val current = listOfNotNull(neighbor.connectionRSSI, neighbor.advertisementRSSI).firstOrNull { stats ->
                stats.lastSampleAt?.let { now - it <= MotionAwareRSSI.maxSampleAge } ?: false
            } ?: return@mapNotNull null
            val raw = current.raw ?: return@mapNotNull null
            val sampledAt = current.lastSampleAt ?: return@mapNotNull null
            AnchorSighting(anchor.id, anchor.position, anchor.accuracyMeters, raw.toDouble(), uptime - (now - sampledAt))
        }
    }

    /**
     * Links between anchors as reported in their own updates; both ends' positions are known,
     * which calibrates the path-loss model and each anchor's radio.
     */
    private fun anchorLinks(): List<AnchorLinkObservation> {
        val fresh = positions.filter { it.role == DeviceRole.anchor.rawValue && store.isFresh(it.id, staleAfter) }
        val byId = fresh.associateBy { it.id }
        return fresh.flatMap { observer ->
            (observer.neighbors ?: emptyList()).mapNotNull { neighbor ->
                val target = byId[neighbor.id] ?: return@mapNotNull null
                val rssi = neighbor.rssi ?: return@mapNotNull null
                val p = observer.position
                val q = target.position
                val distance = sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z))
                AnchorLinkObservation(observer.id, target.id, distance, rssi.toDouble())
            }
        }
    }

    private fun refreshFusionStatus() {
        val now = systemUptime()
        val filter = fusion.filter
        fusionStatus = FusionStatus(
            tracking = fusion.isTracking,
            x = filter?.x,
            z = filter?.z,
            accuracy = filter?.r95,
            headingDegrees = fusion.heading * 180 / Math.PI,
            headingOffsetDegrees = (filter?.headingOffset ?: 0.0) * 180 / Math.PI,
            steps = fusion.deadReckoning.stepCount,
            walked = fusion.walkedDistance,
            walking = fusion.isWalking(now),
            receiverOffsetDB = filter?.receiverOffsetDB,
            ranges = fusion.ranges,
            fix = fusion.lastFix,
            calibration = fusion.calibration,
            accepted = fusion.acceptedUpdates,
            rejected = fusion.rejectedUpdates,
            recoveries = fusion.recoveries,
        )
    }

    private fun tick() {
        if (!isRunning) return
        updateFusion()
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        if (isPublishing) publishCurrent()
        if (uwbEnabled) uwb.reconcile(wantedRangingPeers)
        // Re-upload unchanged identities as a gateway heartbeat, not a new measurement.
        if (gateway.enabled) gateway.enqueue(freshPositions)
        // Places phones without GPS from Bluetooth, on this phone: no network needed.
        tracker.update(positions, store.receivedAt, deviceID)
        // Phones Bluetooth lost: where the movement model says they have probably walked since.
        predictor.update(tracker.phones)
        ticks += 1
        if (ticks % 5 == 0) sync()
    }

    /** Display name for a device ID: its reported label where known, otherwise a short ID. */
    fun displayName(id: String): String {
        if (id == deviceID) return "this phone"
        return store.latest[id]?.label
            ?: bluetooth.neighbors.firstOrNull { it.deviceId == id }?.label
            ?: shortID(id)
    }

    private fun receive(data: ByteArray, neighbor: String) {
        if (!isRunning) return
        diagnostics = diagnostics.copy(received = diagnostics.received + 1)
        try {
            val packet = MeshPacket.decode(data)
            // Reports returning to their own origin are never re-applied.
            if (packet.update.id == deviceID) {
                diagnostics = diagnostics.copy(duplicate = diagnostics.duplicate + 1); return
            }
            accept(packet, neighbor)
        } catch (error: Exception) {
            diagnostics = diagnostics.copy(rejected = diagnostics.rejected + 1)
            lastError = describe(error)
        }
    }

    /** `neighbor` is the device the packet arrived from; null for this phone's own reports. */
    private fun accept(packet: MeshPacket, neighbor: String?) {
        val id = packet.update.id
        val previous = store.latest[id]
        val relay = store.ingest(packet)
        if (store.latest[id] == previous) {
            diagnostics = diagnostics.copy(duplicate = diagnostics.duplicate + 1)
            return
        }
        if (neighbor == null) paths.remove(id) else paths[id] = packet.path
        if (neighbor != null) diagnostics = diagnostics.copy(accepted = diagnostics.accepted + 1)
        devices = positions.mapNotNull { update ->
            store.receivedAt[update.id]?.let { KnownDevice(update, it, paths[update.id]) }
        }
        if (gateway.enabled) gateway.enqueue(freshPositions)
        if (relay == null) return
        val payload = relay.encoded()
        if (neighbor != null) {
            // Never echo a packet back over the link it came from.
            bluetooth.relay(payload, positionKey(id), neighbor)
            diagnostics = diagnostics.copy(relayed = diagnostics.relayed + 1)
        } else {
            bluetooth.broadcast(payload, positionKey(id))
        }
    }

    /** Periodic resend of fresh cached reports. Hop counts and paths are never refreshed. */
    private fun sync() {
        if (!isRunning) return
        for ((id, packet) in store.relayPackets) {
            if (!store.isFresh(id, staleAfter)) continue
            try {
                bluetooth.broadcast(packet.encoded(), positionKey(id))
            } catch (error: Exception) {
                lastError = describe(error)
            }
        }
    }

    /** Brings a newly linked neighbor up to date without resending to every other link. */
    private fun sync(neighbor: String) {
        if (!isRunning) return
        for ((id, packet) in store.relayPackets) {
            if (!store.isFresh(id, staleAfter)) continue
            try {
                bluetooth.send(packet.encoded(), FrameType.position, positionKey(id), neighbor)
            } catch (error: Exception) {
                lastError = describe(error)
            }
        }
    }

    // MARK: UWB positioning

    /** A mounted anchor that can measure direction; only these send fixes. */
    val isDirectionAnchor: Boolean get() = role == DeviceRole.anchor && UWBRanging.supportsDirection

    /** Freshest usable fix, preferring the most accurate when several anchors see this phone. */
    val currentFix: ReceivedFix?
        get() {
            val now = currentTime()
            return rangingFixes.values
                .filter { now - it.receivedAt <= RangingFix.maxAge }
                .minByOrNull { it.fix.accuracyMeters }
        }

    fun setUWB(enabled: Boolean) {
        if (!enabled) {
            uwbEnabled = false
            uwb.stop()
            rangingFixes = emptyMap()
            anchorNeighbors.clear()
            lastFixSent.clear()
            return
        }
        if (!isRunning) {
            lastError = "Start the mesh before turning on UWB"; return
        }
        if (!UWBRanging.supportsDistance) {
            lastError = UWBRanging.unsupportedReason
            return
        }
        if (role == DeviceRole.anchor && !UWBRanging.supportsDirection) {
            lastError = "This phone cannot measure UWB direction while mounted."
            return
        }
        uwbEnabled = true
        lastError = null
        uwb.start(role == DeviceRole.anchor)
        uwb.reconcile(wantedRangingPeers)
    }

    /**
     * Only links between a direction anchor and a non-anchor need a UWB session; anchors mounted
     * side by side would otherwise use up each other's sessions. Anchors announce themselves with
     * their token and keep resending it, so other phones never open sessions on a guess.
     */
    private val wantedRangingPeers: Set<String>
        get() {
            val linked = bluetooth.neighbors.map { it.deviceId }.toSet()
            anchorNeighbors.retainAll(linked)
            val isAnchor = { id: String -> id in anchorNeighbors || store.latest[id]?.role == DeviceRole.anchor.rawValue }
            return if (isDirectionAnchor) linked.filter { !isAnchor(it) }.toSet() else linked.filter { it in anchorNeighbors }.toSet()
        }

    private fun sendRangingToken(token: ByteArray, neighbor: String) {
        try {
            val payload = RangingToken(token, isDirectionAnchor).encoded()
            bluetooth.send(payload, FrameType.rangingToken, "rangingToken", neighbor)
        } catch (error: Exception) {
            lastError = describe(error)
        }
    }

    private fun receiveRanging(type: FrameType, data: ByteArray, neighbor: String) {
        if (!isRunning || !uwbEnabled) return
        try {
            when (type) {
                FrameType.rangingToken -> {
                    val token = RangingToken.decode(data)
                    if (token.isAnchor) anchorNeighbors.add(neighbor) else anchorNeighbors.remove(neighbor)
                    if (neighbor in wantedRangingPeers) uwb.receive(token.token, neighbor)
                }
                FrameType.rangingFix -> {
                    val fix = RangingFix.decode(data)
                    if (role == DeviceRole.anchor || fix.targetId != deviceID || fix.anchorId != neighbor) return
                    rangingFixes = rangingFixes + (neighbor to ReceivedFix(fix, currentTime()))
                }
                FrameType.hello, FrameType.position -> return
            }
        } catch (error: Exception) {
            diagnostics = diagnostics.copy(rejected = diagnostics.rejected + 1)
            lastError = "Invalid UWB message from ${displayName(neighbor)}"
        }
    }

    /** Anchor side: turns a measurement into a map position and sends it to the measured phone. */
    private fun measured(neighbor: String, measurement: UWBMeasurement) {
        if (!isRunning || !uwbEnabled || !isDirectionAnchor) return
        val distance = measurement.distance ?: return
        val direction = measurement.direction ?: return
        val gravity = uwb.gravity
        if (gravity == null) {
            uwb.reportError("No motion sensor data, so this anchor's tilt is unknown and it sends no fixes")
            return
        }
        if (measurement.updatedAt - (lastFixSent[neighbor] ?: Double.NEGATIVE_INFINITY) < 1 / fixesPerSecond) return
        // In floor mode the anchor counts as y = 0, so fixes give heights relative to the floor
        // under it; targets in floor mode, the default, ignore height anyway.
        val floor = positionMode == "floor"
        val anchor = Position(manualX, if (floor) 0.0 else manualY, manualZ)
        val fix = AnchorGeometry.fix(deviceID, neighbor, anchor, anchorHeading, gravity, distance, direction, false) ?: return
        val payload = try {
            fix.encoded()
        } catch (error: Exception) {
            return
        }
        lastFixSent[neighbor] = measurement.updatedAt
        bluetooth.send(payload, FrameType.rangingFix, "rangingFix", neighbor)
    }

    private fun updateIdleTimer() {
        isIdleTimerDisabled = keepAwake && isRunning
    }

    override fun onCleared() {
        timer?.cancel()
        bluetooth.release()
        gateway.stop()
        motion.stop()
        uwb.stop()
        location.stop()
        super.onCleared()
    }
}

/** Readable messages for errors shown in the app's status lines. */
val MeshCoreError.errorDescription: String
    get() = when (this) {
        is MeshCoreError.invalidUpdate -> "A position report broke the dashboard's limits and was dropped."
        is MeshCoreError.invalidPacket -> "Received a malformed mesh packet; it was ignored."
        is MeshCoreError.packetTooLarge -> "A mesh packet was too large to send."
        is MeshCoreError.frameMismatch -> "A nearby phone uses a different frame ID; set the same frame on every phone."
        is MeshCoreError.deviceCapacityReached -> "Too many phones in this mesh; new ones are ignored."
        is MeshCoreError.epochCapacityReached -> "Too many app restarts seen this session; restart the mesh."
        is MeshCoreError.invalidFrame -> "Received a corrupted Bluetooth frame; it was ignored."
        is MeshCoreError.invalidHello -> "A nearby phone sent an invalid hello; update it to the same app version."
        is MeshCoreError.invalidRanging -> "Received an invalid UWB ranging message; it was ignored."
    }

/**
 * Swift's `error.localizedDescription`: MeshCore errors get their readable message; a JSON
 * decoding failure reads like Foundation's.
 */
fun describe(error: Throwable): String = when (error) {
    is MeshCoreError -> error.errorDescription
    is kotlinx.serialization.SerializationException, is IllegalArgumentException ->
        "The data couldn't be read because it isn't in the correct format."
    else -> error.message ?: error.toString()
}

/** Parsing of the dashboard's `meshmapper://gateway?url=…&token=…` QR link; no Android APIs. */
object ConnectLink {
    data class Parsed(val server: String, val token: String)

    /** The trimmed server URL and the token, or null if the link is not a gateway link with an http(s) URL. */
    fun parse(link: String): Parsed? {
        val uri = try {
            java.net.URI(link.trim())
        } catch (e: java.net.URISyntaxException) {
            return null
        }
        val items = queryItems(uri.rawQuery)
        val server = (items.firstOrNull { it.first == "url" }?.second ?: "").trim()
        if (uri.scheme?.lowercase() != "meshmapper" || uri.host?.lowercase() != "gateway") return null
        val parsed = try {
            java.net.URI(server)
        } catch (e: java.net.URISyntaxException) {
            return null
        }
        if (parsed.scheme?.lowercase() !in setOf("http", "https") || parsed.host.isNullOrEmpty()) return null
        return Parsed(server, items.firstOrNull { it.first == "token" }?.second ?: "")
    }

    /** The host of a URL string, or null (URLComponents(string:)?.host). */
    fun host(url: String): String? = try {
        java.net.URI(url).host
    } catch (e: java.net.URISyntaxException) {
        null
    }

    /** URLComponents.queryItems: split on & and =, percent-decode; '+' stays a plus. */
    private fun queryItems(rawQuery: String?): List<Pair<String, String?>> {
        if (rawQuery.isNullOrEmpty()) return emptyList()
        return rawQuery.split('&').map { part ->
            val eq = part.indexOf('=')
            if (eq < 0) Pair(percentDecode(part), null) else Pair(percentDecode(part.substring(0, eq)), percentDecode(part.substring(eq + 1)))
        }
    }

    private fun percentDecode(text: String): String {
        if (!text.contains('%')) return text
        val bytes = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '%' && i + 2 < text.length) {
                val value = text.substring(i + 1, i + 3).toIntOrNull(16)
                if (value != null) {
                    bytes.write(value); i += 3; continue
                }
            }
            bytes.write(c.toString().toByteArray(Charsets.UTF_8))
            i += 1
        }
        return bytes.toString("UTF-8")
    }
}
